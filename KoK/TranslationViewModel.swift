//
//  TranslationViewModel.swift
//  KoK
//
//  Created by Kakar on 2025/12/3.
//

import SwiftUI
import Combine

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
    
    let engineManager = EngineManager.shared
    
    private let service = UnifiedTranslationService()
    private var outputTask: Task<Void, Never>?
    
    private let historyKey = "translation_history"
    private let maxHistoryCount = 50
    
    init() {
        loadHistory()
    }
    
    // 当前选中的引擎名
    var selectedEngineName: String {
        engineManager.selectedEngine?.name ?? "未选择"
    }
    
    // 可用引擎列表（仅启用的）
    var availableEngines: [EngineConfig] {
        engineManager.engines.filter { $0.isEnabled }
    }
    
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
        
        Task {
            do {
                let targetLang = isContainsChinese(text) ? "EN-US" : "ZH"
                let result = try await service.translate(text: text, to: targetLang, using: config)
                
                self.isLoading = false
                startTypewriterEffect(fullText: result.text, engineName: config.name)
                
            } catch {
                self.isLoading = false
                self.errorMessage = "翻译失败: \(error.localizedDescription)"
            }
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
    
    private func startTypewriterEffect(fullText: String, engineName: String) {
        outputTask = Task {
            let cleanText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            
            for char in cleanText {
                if Task.isCancelled { return }
                
                self.translatedText.append(char)
                
                let delay = cleanText.count > 100 ? 0.005 : 0.02
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            
            // 打字完成后记录到历史
            if !Task.isCancelled {
                self.addToHistory(source: self.sourceText, translated: cleanText, engine: engineName)
            }
        }
    }
}
