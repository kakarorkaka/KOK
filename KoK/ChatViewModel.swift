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
        messages.append(ChatMessage(role: .user, content: text))
        startStreaming(using: config)
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
        messages[index].content += chunk
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
