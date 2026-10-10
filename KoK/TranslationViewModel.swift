//
//  TranslationViewModel.swift
//  KoK
//
//  Created by Kakar on 2025/12/3.
//
//  动作系统：翻译 / 总结 / 润色 是零输入型（抓到文本立即执行），
//  问答是需输入型（打字或语音）。翻译走翻译专线（引擎+方向+历史），
//  总结 / 润色 / 问答走对话引擎。
//

import SwiftUI
import Combine

// MARK: - 翻译方向

/// 自动 = 原文含中文译成英文、其余译成中文；也可以手动指定目标语言
enum TranslateDirection: String, CaseIterable, Identifiable {
    case auto, zh, en, ja, ko
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .auto: return "自动"
        case .zh: return "中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        }
    }
    
    /// 目标语言名（提示词用）；auto 时由调用方按原文推导
    var targetName: String {
        switch self {
        case .zh: return "Simplified Chinese"
        case .en: return "English"
        case .ja: return "Japanese"
        case .ko: return "Korean"
        case .auto: return ""
        }
    }
    
    /// DeepL 语言代码
    var code: String {
        switch self {
        case .zh: return "ZH"
        case .en: return "EN-US"
        case .ja: return "JA"
        case .ko: return "KO"
        case .auto: return ""
        }
    }
}

// MARK: - 翻译历史记录
struct TranslationRecord: Identifiable, Codable {
    let id: UUID
    let sourceText: String
    let translatedText: String
    let engineName: String
    let timestamp: Date
    
    init(sourceText: String, translatedText: String, engineName: String) {
        self.id = UUID()
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.engineName = engineName
        self.timestamp = Date()
    }
}

@MainActor
class TranslationViewModel: ObservableObject {
    @Published var sourceText: String = ""
    @Published var translatedText: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var copyFeedback: Bool = false // 复制成功反馈
    @Published var history: [TranslationRecord] = []
    @Published var direction: TranslateDirection = .auto
    
    /// 当前动作。每次面板重新弹出时回到默认「翻译」（临时状态，不困住用户）
    @Published var action: ChatAction = .translate
    /// 问答动作的输入
    @Published var questionInput: String = ""
    /// 问答的语音状态
    @Published var isListening = false
    @Published var voiceError: String?
    /// 问答输入框聚焦请求（面板弹出 / 切到问答动作时自增）
    @Published var focusRequest = 0
    
    let engineManager = EngineManager.shared
    
    private let service = UnifiedTranslationService()
    private let chatClient = LLMClient()
    private var outputTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?
    
    let voice = VoiceInputService()
    private var voiceTask: Task<Void, Never>?
    private var voiceTimeoutTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    
    private let historyKey = "translation_history"
    private let directionKey = "translation_direction"
    private let maxHistoryCount = 50
    
    init() {
        loadHistory()
        if let saved = UserDefaults.standard.string(forKey: directionKey),
           let stored = TranslateDirection(rawValue: saved) {
            direction = stored
        }
        
        // voice 是内层 ObservableObject，转写变化也要触发外层刷新
        voice.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
    
    /// 面板重新弹出时调用：回到默认形态，清掉上一轮的问答状态
    func prepareForNewCapture() {
        action = .translate
        questionInput = ""
        voiceError = nil
        errorMessage = nil
    }
    
    // MARK: - 动作
    
    /// 当前选中引擎名（翻译动作用翻译引擎，其余用对话引擎）
    var selectedEngineName: String {
        action.usesTranslationPath
            ? engineManager.selectedEngine?.name ?? "未选择"
            : engineManager.selectedChatEngine?.name ?? "未选择"
    }
    
    func selectEngine(id: UUID) {
        if action.usesTranslationPath {
            engineManager.selectEngine(id: id)
        } else {
            engineManager.selectChatEngine(id: id)
        }
        rerunIfPossible()
    }
    
    /// 切换动作：零输入型立即执行（有文本的话），需输入型准备输入框
    func selectAction(_ newAction: ChatAction) {
        guard action != newAction else { return }
        action = newAction
        translatedText = ""
        errorMessage = nil
        voiceError = nil
        
        if newAction.needsInput {
            if !sourceText.isEmpty {
                focusRequest += 1
            }
        } else {
            rerunIfPossible()
        }
    }
    
    /// 按当前动作重新处理已有文本
    private func rerunIfPossible() {
        guard !sourceText.isEmpty, !isLoading else { return }
        if action == .translate {
            translate(text: sourceText)
        } else {
            runTextTransform()
        }
    }
    
    // MARK: - 翻译（专线）
    
    func translate(text: String) {
        guard let config = engineManager.selectedEngine else {
            self.errorMessage = "请先在设置中添加并选择一个翻译引擎"
            return
        }
        
        self.sourceText = text
        self.translatedText = ""
        self.errorMessage = nil
        self.isLoading = true
        
        outputTask?.cancel()
        chatTask?.cancel()
        
        let target = makeTarget(for: text)
        outputTask = Task { [weak self] in
            guard let self else { return }
            var received = false
            
            do {
                // 流式：首字到达就显示，不再等整段生成完
                for try await chunk in self.service.translateStream(text: text, to: target, using: config) {
                    if Task.isCancelled { return }
                    received = true
                    self.translatedText += chunk
                }
                
                self.isLoading = false
                if Task.isCancelled { return }
                
                guard received else {
                    self.errorMessage = ServiceError.emptyResponse(config.name).localizedDescription
                    return
                }
                
                self.addToHistory(
                    source: text,
                    translated: self.translatedText.trimmingCharacters(in: .whitespacesAndNewlines),
                    engine: config.name
                )
            } catch {
                self.isLoading = false
                if !Task.isCancelled {
                    self.errorMessage = "翻译失败: \(error.localizedDescription)"
                }
            }
        }
    }
    
    // MARK: - 总结 / 润色（对话引擎）
    
    private func runTextTransform() {
        guard let config = engineManager.selectedChatEngine else {
            self.errorMessage = "没有可用于「\(action.title)」的对话引擎，请先在设置中添加并启用一个"
            return
        }
        
        translatedText = ""
        errorMessage = nil
        isLoading = true
        outputTask?.cancel()
        chatTask?.cancel()
        
        let messages = [
            ChatMessage(role: .system, content: action.systemPrompt),
            ChatMessage(role: .user, content: sourceText),
        ]
        
        chatTask = Task { [weak self] in
            guard let self else { return }
            var received = false
            
            do {
                for try await chunk in self.chatClient.stream(messages: messages, using: config) {
                    if Task.isCancelled { return }
                    received = true
                    self.translatedText += chunk
                }
                
                self.isLoading = false
                if Task.isCancelled { return }
                guard received else {
                    self.errorMessage = ServiceError.emptyResponse(config.name).localizedDescription
                    return
                }
            } catch {
                self.isLoading = false
                if !Task.isCancelled {
                    self.errorMessage = "\(self.action.title)失败：\(error.localizedDescription)"
                }
            }
        }
    }
    
    // MARK: - 问答（需输入型；打字或语音）
    
    var canSubmitQuestion: Bool {
        !questionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
    }
    
    func submitQuestion() {
        let question = questionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isLoading else { return }
        guard let config = engineManager.selectedChatEngine else {
            errorMessage = "没有可用于对话的引擎，请先在设置中添加并启用一个"
            return
        }
        
        questionInput = ""
        translatedText = ""
        errorMessage = nil
        voiceError = nil
        isLoading = true
        outputTask?.cancel()
        chatTask?.cancel()
        
        let systemPrompt = engineManager.chatSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        
        var parts: [MessagePart] = []
        if !sourceText.isEmpty {
            parts.append(.text("【选中内容】\n\(sourceText)\n\n"))
        }
        parts.append(.text(question))
        
        let messages = [
            ChatMessage(role: .system, content: systemPrompt),
            ChatMessage(role: .user, parts: parts),
        ]
        
        chatTask = Task { [weak self] in
            guard let self else { return }
            var received = false
            
            do {
                for try await chunk in self.chatClient.stream(messages: messages, using: config) {
                    if Task.isCancelled { return }
                    received = true
                    self.translatedText += chunk
                }
                
                self.isLoading = false
                if Task.isCancelled { return }
                guard received else {
                    self.errorMessage = ServiceError.emptyResponse(config.name).localizedDescription
                    return
                }
            } catch {
                self.isLoading = false
                if !Task.isCancelled {
                    self.errorMessage = "问答失败：\(error.localizedDescription)"
                }
            }
        }
    }
    
    // MARK: - 问答语音
    
    /// 面板内麦克风按钮：点按开始，再点结束并发送
    func toggleVoice() {
        isListening ? finishVoice() : startVoice()
    }
    
    private func startVoice() {
        guard !isListening else { return }
        voiceError = nil
        errorMessage = nil
        isListening = true
        
        voiceTask?.cancel()
        voiceTask = Task { [weak self] in
            guard let self else { return }
            
            if VoiceInputService.needsPermission {
                let granted = await VoiceInputService.requestPermissions()
                guard granted.microphone && granted.speech else {
                    self.voiceError = granted.microphone
                        ? VoiceInputService.VoiceError.speechDenied.localizedDescription
                        : VoiceInputService.VoiceError.microphoneDenied.localizedDescription
                    self.isListening = false
                    return
                }
            }
            
            guard !Task.isCancelled else { return }
            
            do {
                try self.voice.start(localeIdentifier: self.engineManager.voiceLocale)
            } catch {
                self.voiceError = error.localizedDescription
                self.isListening = false
            }
        }
        
        // 兜底：录音不会一直开着
        voiceTimeoutTask?.cancel()
        voiceTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(VoiceInputService.maxRecordingSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finishVoice()
        }
    }
    
    private func finishVoice() {
        guard isListening else { return }
        isListening = false
        voiceTimeoutTask?.cancel()
        voiceTimeoutTask = nil
        
        Task { [weak self] in
            guard let self else { return }
            
            await self.voiceTask?.value
            self.voiceTask = nil
            
            guard self.voiceError == nil else { return }
            
            let spoken = await self.voice.finish()
            let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                self.voiceError = "没听清，再按一次试试"
                return
            }
            
            self.questionInput = text
            self.submitQuestion()
        }
    }
    
    // MARK: - 方向
    
    private func makeTarget(for text: String) -> TranslationTarget {
        let sourceIsChinese = isContainsChinese(text)
        let sourceName = sourceIsChinese ? "Simplified Chinese" : "English"
        
        switch direction {
        case .auto:
            return TranslationTarget(
                code: sourceIsChinese ? "EN-US" : "ZH",
                languageName: sourceIsChinese ? "English" : "Simplified Chinese",
                sourceName: sourceName
            )
        default:
            return TranslationTarget(
                code: direction.code,
                languageName: direction.targetName,
                sourceName: sourceName
            )
        }
    }
    
    /// 切换方向并自动重译当前内容
    func selectDirection(_ newDirection: TranslateDirection) {
        guard direction != newDirection else { return }
        direction = newDirection
        UserDefaults.standard.set(newDirection.rawValue, forKey: directionKey)
        if !sourceText.isEmpty {
            translate(text: sourceText)
        }
    }
    
    // 重试
    func retry() {
        guard !sourceText.isEmpty else { return }
        rerunIfPossible()
    }
    
    // 复制并显示反馈
    func copyTranslation() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(translatedText, forType: .string)
        
        copyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.copyFeedback = false
        }
    }
    
    // 未选中文本提示
    func showNoTextError() {
        self.sourceText = ""
        self.translatedText = ""
        self.errorMessage = "未检测到选中的文本，请先选中要处理的文字"
        self.isLoading = false
    }
    
    // MARK: - 历史记录（只有翻译动作记历史）
    
    func addToHistory(source: String, translated: String, engine: String) {
        let record = TranslationRecord(sourceText: source, translatedText: translated, engineName: engine)
        history.insert(record, at: 0)
        if history.count > maxHistoryCount {
            history = Array(history.prefix(maxHistoryCount))
        }
        saveHistory()
    }
    
    func clearHistory() {
        history.removeAll()
        saveHistory()
    }
    
    func translateFromHistory(_ record: TranslationRecord) {
        action = .translate
        self.sourceText = record.sourceText
        translate(text: record.sourceText)
    }
    
    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }
    
    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([TranslationRecord].self, from: data) {
            self.history = decoded
        }
    }
    
    // MARK: - 辅助功能
    
    private func isContainsChinese(_ text: String) -> Bool {
        return text.range(of: "\\p{Han}", options: .regularExpression) != nil
    }
}
