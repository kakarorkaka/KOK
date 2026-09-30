//
//  ChatViewModel.swift
//  KoK
//
//  快速问答面板的状态：消息列表、流式输出、发送 / 停止 / 重生成。
//  对话只保存在内存里，关掉就重来，不落盘。
//

import SwiftUI
import Combine

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input: String = ""
    @Published var isStreaming: Bool = false
    @Published var errorMessage: String?
    @Published var copyFeedback: Bool = false
    
    /// 每次面板弹出时自增，视图据此把焦点交给输入框
    @Published var focusRequest: Int = 0
    
    /// 本次要附带的选中内容（文本 / 图片）
    @Published var context: SelectionProvider.Capture?
    /// 是否正在录音
    @Published var isListening = false
    /// 语音相关错误（权限、没听清等）
    @Published var voiceError: String?
    
    let voice = VoiceInputService()
    private var voiceTimeoutTask: Task<Void, Never>?
    private var voiceStartTask: Task<Void, Never>?
    /// 本次录音是否需要抓取选中内容
    private var wantsSelection = false
    
    /// 语音即将发送时的回调。
    /// 语音弹出时是「不激活 App」的（否则抓不到原 App 的选中内容），
    /// 到这里选中内容已经抓完，把面板提到前台就不会再有副作用了。
    var onVoiceReadyToSend: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // voice 是内层 ObservableObject，它自己的变化不会触发外层视图刷新，
        // 这里把它的变更转发出去，聆听时的实时转写才能显示出来。
        voice.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
    
    let engineManager = EngineManager.shared
    
    private let service = LLMClient()
    private var streamTask: Task<Void, Never>?
    
    /// 送入模型的最大历史条数（约 10 轮）
    private let maxContextMessages = 20
    
    var availableEngines: [EngineConfig] { engineManager.chatEngines }
    
    var selectedEngineName: String {
        engineManager.selectedChatEngine?.name ?? "未选择"
    }
    
    var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming
    }
    
    // MARK: - 外部动作
    
    func requestFocus() {
        focusRequest += 1
    }
    
    func selectEngine(id: UUID) {
        engineManager.selectChatEngine(id: id)
    }
    
    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        guard let config = engineManager.selectedChatEngine else {
            errorMessage = "没有可用于对话的引擎，请先在设置中添加 OpenAI 兼容或 Gemini 引擎"
            return
        }
        
        input = ""
        errorMessage = nil
        messages.append(userMessage(text: text, context: context))
        context = nil
        startStreaming(using: config)
    }
    
    /// 把选中内容拼进用户消息：图片作为独立片段，文本带个前缀标明来源
    private func userMessage(text: String, context: SelectionProvider.Capture?) -> ChatMessage {
        var parts: [MessagePart] = []
        
        if let image = context?.image {
            parts.append(.image(image))
        }
        if let selected = context?.text, !selected.isEmpty {
            let note = context?.truncated == true ? "（已截断）" : ""
            parts.append(.text("【选中内容\(note)】\n\(selected)\n\n"))
        }
        
        parts.append(.text(text))
        return ChatMessage(role: .user, parts: parts)
    }
    
    // MARK: - 按住说话
    
    /// 按下快捷键：立刻开录（用户已经在说话了），抓选中内容并行进行
    /// - Parameter captureSelection: 是否顺带抓取当前选中内容。
    ///   只有全局快捷键那条路径该传 true——从面板里点麦克风时，
    ///   焦点已经在 KoK 自己身上，抓到的会是输入框里的文字。
    func beginVoice(captureSelection: Bool = true) {
        guard !isListening else { return }
        
        voiceError = nil
        errorMessage = nil
        isListening = true
        wantsSelection = captureSelection
        
        // 首次使用会在这里弹系统权限对话框，所以录音启动是异步的；
        // endVoiceAndSend 会等这个任务结束再收尾。
        voiceStartTask?.cancel()
        voiceStartTask = Task { [weak self] in
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
        
        // 兜底：万一「松开」事件丢了，录音也不能一直开着
        voiceTimeoutTask?.cancel()
        voiceTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(VoiceInputService.maxRecordingSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.endVoiceAndSend()
        }
    }
    
    /// 松开快捷键：结束录音，带上选中内容一起发出去
    func endVoiceAndSend() {
        guard isListening else { return }
        isListening = false
        voiceTimeoutTask?.cancel()
        voiceTimeoutTask = nil
        
        let shouldCapture = wantsSelection
        wantsSelection = false
        
        Task { [weak self] in
            guard let self else { return }
            
            // 等录音真正开始（可能刚才在弹权限对话框）
            await self.voiceStartTask?.value
            self.voiceStartTask = nil
            
            // 启动阶段已经报过错（权限被拒、没有输入设备），就不要再覆盖成「没听清」
            guard self.voiceError == nil else { return }
            
            var captured: SelectionProvider.Capture?
            if shouldCapture {
                // 松手后等一下再抓：让 ⌥ 彻底松开，
                // 否则合成出来的是 ⌥⌘C，很多 App 不认
                try? await Task.sleep(nanoseconds: 80_000_000)
                captured = await SelectionProvider.capture()
            }
            
            let spoken = await self.voice.finish()
            
            // 抓取已完成，现在可以安全地把面板提到前台
            self.onVoiceReadyToSend?()
            
            if let captured, !captured.isEmpty {
                self.context = captured
            }
            
            let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                self.voiceError = "没听清，再按一次试试"
                return
            }
            
            self.input = text
            self.send()
        }
    }
    
    func removeContext() {
        context = nil
    }
    
    func regenerate() {
        guard !isStreaming, let config = engineManager.selectedChatEngine else { return }
        if messages.last?.role == .assistant { messages.removeLast() }
        guard messages.contains(where: { $0.role == .user }) else { return }
        
        errorMessage = nil
        startStreaming(using: config)
    }
    
    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }
    
    func clear() {
        stop()
        messages.removeAll()
        errorMessage = nil
    }
    
    func copy(_ text: String) {
        guard !text.isEmpty else { return }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        copyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyFeedback = false
        }
    }
    
    // MARK: - 流式
    
    private func startStreaming(using config: EngineConfig) {
        // 先组装请求再插入占位消息，否则空回答也会被发给模型
        let payload = buildPayload()
        messages.append(ChatMessage(role: .assistant, content: ""))
        let placeholderId = messages[messages.count - 1].id
        isStreaming = true
        
        streamTask = Task { [weak self] in
            guard let self else { return }
            var received = false
            
            do {
                for try await chunk in self.service.stream(messages: payload, using: config) {
                    if Task.isCancelled { break }
                    received = true
                    self.append(chunk, to: placeholderId)
                }
                
                self.isStreaming = false
                if !received, !Task.isCancelled {
                    self.errorMessage = ServiceError.emptyResponse(config.name).localizedDescription
                }
            } catch {
                self.isStreaming = false
                self.discardEmptyPlaceholder(placeholderId)
                if !Task.isCancelled {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func append(_ chunk: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].appendText(chunk)
    }
    
    private func discardEmptyPlaceholder(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].content.isEmpty
        else { return }
        messages.remove(at: index)
    }
    
    /// 请求体 = 对话提示词 + 最近若干轮，且保证以 user 开头
    private func buildPayload() -> [ChatMessage] {
        var payload: [ChatMessage] = []
        
        let systemPrompt = engineManager.chatSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty {
            payload.append(ChatMessage(role: .system, content: systemPrompt))
        }
        
        var recent = messages.suffix(maxContextMessages)
        while let first = recent.first, first.role != .user {
            recent = recent.dropFirst()
        }
        payload.append(contentsOf: recent)
        
        return payload
    }
}
