//
//  TranslationService.swift
//  KoK
//
//  Created by Kakar on 2025/12/3.
//

import Foundation

// MARK: - 翻译结果

struct TranslationResult {
    let text: String
    let sourceLang: String?
}

// MARK: - 翻译服务

/// LLM 引擎的翻译请求本质上就是一次「对话」：system 放提示词、user 放原文，
/// 所以 OpenAI 兼容与 Gemini 都直接复用 `LLMClient`，只有 DeepL 需要单独实现。
/// 过去这里各写了一份请求构造与响应解析，等于把流式能力挡在了外面。
class UnifiedTranslationService {
    
    /// 一次性返回整段译文
    func translate(text: String, to targetLang: String, using config: EngineConfig) async throws -> TranslationResult {
        switch config.type {
        case .deepL:
            return try await translateWithDeepL(text: text, targetLang: targetLang, config: config)
            
        case .openAICompatible, .gemini:
            let translated = try await LLMClient().complete(
                messages: messages(for: text, targetLang: targetLang),
                using: config
            )
            return TranslationResult(text: translated, sourceLang: "Auto")
        }
    }
    
    /// 流式返回译文：首字延迟等于模型的 TTFT，而不是整段生成完的时间。
    /// DeepL 是同步接口，包一层让调用方统一按流处理。
    func translateStream(
        text: String,
        to targetLang: String,
        using config: EngineConfig
    ) -> AsyncThrowingStream<String, Error> {
        switch config.type {
        case .openAICompatible, .gemini:
            return LLMClient().stream(
                messages: messages(for: text, targetLang: targetLang),
                using: config
            )
            
        case .deepL:
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let result = try await self.translateWithDeepL(
                            text: text, targetLang: targetLang, config: config
                        )
                        continuation.yield(result.text)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
    
    // MARK: - 请求组装
    
    private func messages(for text: String, targetLang: String) -> [ChatMessage] {
        [
            ChatMessage(role: .system, content: resolvePrompt(targetLang: targetLang)),
            ChatMessage(role: .user, content: text),
        ]
    }
    
    // MARK: - DeepL（翻译专用协议）
    
    private func translateWithDeepL(
        text: String,
        targetLang: String,
        config: EngineConfig
    ) async throws -> TranslationResult {
        guard !config.resolvedAPIKey.isEmpty else {
            throw ServiceError.missingAPIKey(config.name)
        }
        
        guard let url = URL(string: config.apiURL) else { throw URLError(.badURL) }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("DeepL-Auth-Key \(config.resolvedAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["text": [text], "target_lang": targetLang]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = String(data: data, encoding: .utf8) ?? "未知错误"
            throw ServiceError.apiError(config.name, String(detail.prefix(300)))
        }
        
        struct DeepLResponse: Decodable {
            struct Translation: Decodable {
                let text: String
                let detected_source_language: String
            }
            let translations: [Translation]
        }
        
        let decoded = try JSONDecoder().decode(DeepLResponse.self, from: data)
        guard let result = decoded.translations.first else {
            throw ServiceError.emptyResponse(config.name)
        }
        return TranslationResult(text: result.text, sourceLang: result.detected_source_language)
    }
    
    // MARK: - 提示词解析
    
    private func resolvePrompt(targetLang: String) -> String {
        // 只认全局提示词；留空时回退到内置默认值，
        // 否则会把空的 system message 发给模型
        let manager = EngineManager.shared
        let template = manager.globalSystemPrompt.isEmpty
            ? EngineConfig.defaultSystemPrompt
            : manager.globalSystemPrompt
        
        return PromptTemplate.fill(template, targetLang: targetLang)
    }
}

// MARK: - 错误类型（翻译与对话共用）

enum ServiceError: LocalizedError {
    case missingAPIKey(String)
    case apiError(String, String)
    case unsupportedEngine(String)
    case emptyResponse(String)
    
    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let name):
            return "请在设置中填入 \(name) 的 API Key"
        case .apiError(let name, let detail):
            return "\(name) 接口错误: \(detail)"
        case .unsupportedEngine(let name):
            return "\(name) 不支持对话，请改用 OpenAI 兼容或 Gemini 引擎"
        case .emptyResponse(let name):
            return "\(name) 没有返回内容"
        }
    }
}
