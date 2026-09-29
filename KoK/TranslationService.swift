//
//  TranslationService.swift
//  KoK
//
//  Created by Kakar on 2025/12/3.
//

import Foundation
import Combine

// MARK: - 翻译结果

struct TranslationResult {
    let text: String
    let sourceLang: String?
}

// MARK: - 统一翻译服务（根据 EngineConfig 动态调用）

class UnifiedTranslationService {
    
    func translate(text: String, to targetLang: String, using config: EngineConfig) async throws -> TranslationResult {
        switch config.type {
        case .deepL:
            return try await translateWithDeepL(text: text, targetLang: targetLang, config: config)
        case .openAICompatible:
            return try await translateWithOpenAI(text: text, targetLang: targetLang, config: config)
        case .gemini:
            return try await translateWithGemini(text: text, targetLang: targetLang, config: config)
        }
    }
    
    // MARK: - DeepL
    
    private func translateWithDeepL(text: String, targetLang: String, config: EngineConfig) async throws -> TranslationResult {
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
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        struct DeepLResponse: Decodable {
            struct Translation: Decodable {
                let text: String
                let detected_source_language: String
            }
            let translations: [Translation]
        }
        
        let decoded = try JSONDecoder().decode(DeepLResponse.self, from: data)
        guard let result = decoded.translations.first else { throw URLError(.badServerResponse) }
        return TranslationResult(text: result.text, sourceLang: result.detected_source_language)
    }
    
    // MARK: - OpenAI 兼容（通义千问 / DeepSeek / Moonshot / GPT 等）
    
    private func translateWithOpenAI(text: String, targetLang: String, config: EngineConfig) async throws -> TranslationResult {
        guard !config.resolvedAPIKey.isEmpty else {
            throw ServiceError.missingAPIKey(config.name)
        }
        
        guard let url = URL(string: config.apiURL) else { throw URLError(.badURL) }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.resolvedAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let prompt = resolvePrompt(targetLang: targetLang)
        
        let body: [String: Any] = [
            "model": config.modelName,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": text]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "未知错误"
            throw ServiceError.apiError(config.name, errorText)
        }
        
        // OpenAI 标准响应格式
        struct OpenAIResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]?
        }
        
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let resultText = decoded.choices?.first?.message.content else {
            throw URLError(.cannotParseResponse)
        }
        
        return TranslationResult(text: resultText, sourceLang: "Auto")
    }
    
    // MARK: - Gemini
    
    private func translateWithGemini(text: String, targetLang: String, config: EngineConfig) async throws -> TranslationResult {
        guard !config.resolvedAPIKey.isEmpty else {
            throw ServiceError.missingAPIKey(config.name)
        }
        
        // 替换 URL 中的 {{MODEL}} 占位符
        let urlString = config.apiURL
            .replacingOccurrences(of: "{{MODEL}}", with: config.modelName)
            + "?key=\(config.resolvedAPIKey)"
        
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let prompt = resolvePrompt(targetLang: targetLang)
        let fullPrompt = "\(prompt)\n\n\(text)"
        
        let body: [String: Any] = [
            "contents": [["parts": [["text": fullPrompt]]]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        struct GeminiResponse: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String }
                    let parts: [Part]
                }
                let content: Content
            }
            let candidates: [Candidate]?
        }
        
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        guard let resultText = decoded.candidates?.first?.content.parts.first?.text else {
            throw URLError(.cannotParseResponse)
        }
        
        return TranslationResult(text: resultText, sourceLang: "Auto")
    }
    
    // MARK: - 提示词解析
    
    private func resolvePrompt(targetLang: String) -> String {
        // 只认全局提示词；留空时回退到内置默认值，
        // 否则会把空的 system message 发给模型
        let manager = EngineManager.shared
        let template = manager.globalSystemPrompt.isEmpty
            ? EngineConfig.defaultSystemPrompt
            : manager.globalSystemPrompt
        
        let langName = (targetLang == "ZH") ? "Simplified Chinese" : "English"
        return template.replacingOccurrences(of: "{{TARGET_LANG}}", with: langName)
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
