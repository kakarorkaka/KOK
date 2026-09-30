//
//  TranslationViewModel.swift
//  KoK
//
//  Created by Kakar on 2025/12/3.
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
    
    let engineManager = EngineManager.shared
    
    private let service = UnifiedTranslationService()
    private var outputTask: Task<Void, Never>?
    
    private let historyKey = "translation_history"
    private let directionKey = "translation_direction"
    private let maxHistoryCount = 50
    
    init() {
        loadHistory()
        if let saved = UserDefaults.standard.string(forKey: directionKey),
           let stored = TranslateDirection(rawValue: saved) {
            direction = stored
        }
    }
    
    // 当前选中的引擎名
    var selectedEngineName: String {
        engineManager.selectedEngine?.name ?? "未选择"
    }
    
    // 可用引擎列表（仅启用的）
    func selectEngine(id: UUID) {
        engineManager.selectEngine(id: id)
        if !sourceText.isEmpty {
            translate(text: sourceText)
        }
    }
    
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
    
    // 重试翻译
    func retry() {
        guard !sourceText.isEmpty else { return }
        translate(text: sourceText)
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
        self.errorMessage = "未检测到选中的文本，请先选中要翻译的文字"
        self.isLoading = false
    }
    
    // MARK: - 历史记录
    
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
