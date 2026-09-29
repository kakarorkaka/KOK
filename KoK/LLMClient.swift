//
//  LLMClient.swift
//  KoK
//
//  大模型请求客户端，翻译与对话共用：
//  - 翻译 = [system: 提示词, user: 原文]
//  - 对话 = 多轮消息
//  支持 OpenAI 兼容协议与 Gemini 的 SSE 流式返回；服务端不支持流式时自动降级为一次性返回。
//

import Foundation

// MARK: - 消息

/// 一条消息。翻译也复用它：system 放提示词，user 放原文。
struct ChatMessage: Identifiable, Equatable {
    enum Role: String, Codable {
        case system
        case user
        case assistant
    }
    
    let id: UUID
    var role: Role
    var content: String
    
    init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

// MARK: - 客户端

class LLMClient {
    
    /// 流式请求：逐段产出模型回复。翻译与对话共用。
    ///
    /// 若首个请求就失败（例如服务端不支持 `stream`），且尚未产出任何内容，
    /// 会自动降级为一次性的非流式请求。
    func stream(messages: [ChatMessage], using config: EngineConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var didYield = false
                
                do {
                    try await performStream(messages: messages, config: config) { chunk in
                        didYield = true
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    // 已经吐出过内容就不能重来，否则会重复
                    guard !didYield, !Task.isCancelled else {
                        continuation.finish(throwing: didYield ? nil : error)
                        return
                    }
                    
                    do {
                        let full = try await complete(messages: messages, using: config)
                        continuation.yield(full)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    /// 非流式请求（降级路径，也用于连通性测试）
    func complete(messages: [ChatMessage], using config: EngineConfig) async throws -> String {
        let apiKey = config.resolvedAPIKey
        guard !apiKey.isEmpty else { throw ServiceError.missingAPIKey(config.name) }
        
        switch config.type {
        case .openAICompatible:
            let request = try makeOpenAIRequest(config: config, apiKey: apiKey, messages: messages, stream: false)
            let data = try await send(request, engine: config.name)
            return try parseOpenAI(data, engine: config.name)
            
        case .gemini:
            let request = try makeGeminiRequest(config: config, apiKey: apiKey, messages: messages, stream: false)
            let data = try await send(request, engine: config.name)
            return try parseGemini(data, engine: config.name)
            
        case .deepL:
            throw ServiceError.unsupportedEngine(config.name)
        }
    }
    
    // MARK: - 流式实现
    
    private func performStream(
        messages: [ChatMessage],
        config: EngineConfig,
        onChunk: (String) -> Void
    ) async throws {
        let apiKey = config.resolvedAPIKey
        guard !apiKey.isEmpty else { throw ServiceError.missingAPIKey(config.name) }
        
        let request: URLRequest
        switch config.type {
        case .openAICompatible:
            request = try makeOpenAIRequest(config: config, apiKey: apiKey, messages: messages, stream: true)
        case .gemini:
            request = try makeGeminiRequest(config: config, apiKey: apiKey, messages: messages, stream: true)
        case .deepL:
            throw ServiceError.unsupportedEngine(config.name)
        }
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var detail = ""
            for try await line in bytes.lines {
                detail += line
            }
            let message = detail.isEmpty ? "HTTP \(http.statusCode)" : String(detail.prefix(300))
            throw ServiceError.apiError(config.name, message)
        }
        
        for try await line in bytes.lines {
            try Task.checkCancellation()
            
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            
            guard let data = payload.data(using: .utf8),
                  let text = extractChunk(from: data, type: config.type),
                  !text.isEmpty
            else { continue }
            
            onChunk(text)
        }
    }
    
    /// 从一条 SSE 数据里取出增量文本（解析失败返回 nil，跳过该行即可）
    private func extractChunk(from data: Data, type: EngineConfig.EngineType) -> String? {
        switch type {
        case .openAICompatible:
            struct Chunk: Decodable {
                struct Choice: Decodable {
                    struct Delta: Decodable { let content: String? }
                    let delta: Delta?
                }
                let choices: [Choice]?
            }
            guard let decoded = try? JSONDecoder().decode(Chunk.self, from: data) else { return nil }
            return decoded.choices?.first?.delta?.content
            
        case .gemini:
            struct Chunk: Decodable {
                struct Candidate: Decodable {
                    struct Content: Decodable {
                        struct Part: Decodable { let text: String? }
                        let parts: [Part]?
                    }
                    let content: Content?
                }
                let candidates: [Candidate]?
            }
            guard let decoded = try? JSONDecoder().decode(Chunk.self, from: data) else { return nil }
            return decoded.candidates?.first?.content?.parts?.first?.text
            
        case .deepL:
            return nil
        }
    }
    
    // MARK: - 请求构造
    
    private func makeOpenAIRequest(
        config: EngineConfig,
        apiKey: String,
        messages: [ChatMessage],
        stream: Bool
    ) throws -> URLRequest {
        guard let url = URL(string: config.apiURL) else { throw URLError(.badURL) }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        
        var body: [String: Any] = [
            "model": config.modelName,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        ]
        if stream { body["stream"] = true }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    
    private func makeGeminiRequest(
        config: EngineConfig,
        apiKey: String,
        messages: [ChatMessage],
        stream: Bool
    ) throws -> URLRequest {
        let method = stream ? "streamGenerateContent" : "generateContent"
        var urlString = config.apiURL.replacingOccurrences(of: "{{MODEL}}", with: config.modelName)
        urlString = urlString.replacingOccurrences(of: ":generateContent", with: ":\(method)")
        urlString += (urlString.contains("?") ? "&" : "?") + "key=\(apiKey)"
        if stream { urlString += "&alt=sse" }
        
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Gemini 没有 system role：把 system 提示词并入首条用户消息，兼容性最好
        var systemText: String?
        var contents: [[String: Any]] = []
        
        for message in messages {
            switch message.role {
            case .system:
                systemText = (systemText.map { $0 + "\n" } ?? "") + message.content
            case .user:
                var text = message.content
                if let pending = systemText {
                    text = "\(pending)\n\n\(text)"
                    systemText = nil
                }
                contents.append(["role": "user", "parts": [["text": text]]])
            case .assistant:
                contents.append(["role": "model", "parts": [["text": message.content]]])
            }
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: ["contents": contents])
        return request
    }
    
    // MARK: - 响应解析
    
    private func send(_ request: URLRequest, engine: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = String(data: data, encoding: .utf8) ?? "未知错误"
            throw ServiceError.apiError(engine, String(detail.prefix(300)))
        }
        return data
    }
    
    private func parseOpenAI(_ data: Data, engine: String) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message?
            }
            let choices: [Choice]?
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let text = decoded.choices?.first?.message?.content, !text.isEmpty else {
            throw ServiceError.emptyResponse(engine)
        }
        return text
    }
    
    private func parseGemini(_ data: Data, engine: String) throws -> String {
        struct Response: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let text = decoded.candidates?.first?.content?.parts?.first?.text, !text.isEmpty else {
            throw ServiceError.emptyResponse(engine)
        }
        return text
    }
}
