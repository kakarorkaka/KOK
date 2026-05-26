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

// MARK: - 引擎配置模型（可序列化存储）

struct EngineConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String           // 显示名称，如 "DeepL", "GPT-4o", "我的通义千问"
    var type: EngineType       // 引擎类型：决定请求/响应的解析方式
    var apiURL: String         // API 地址
    var apiKey: String         // API Key
    var modelName: String      // 模型名（LLM 类型才需要）
    var systemPrompt: String   // 系统提示词（LLM 类型才需要）
    var isEnabled: Bool        // 是否启用
    
    enum EngineType: String, Codable, CaseIterable {
        case deepL = "DeepL"                    // DeepL 专用协议
        case openAICompatible = "OpenAI 兼容"    // OpenAI / 通义千问 / DeepSeek / Moonshot 等
        case gemini = "Gemini"                   // Google Gemini 协议
    }
    
    // 默认提示词
    static let defaultSystemPrompt = "You are a professional translator. Translate the user's text to {{TARGET_LANG}}. Only output the translated text directly. Do not add any explanations, notes, or punctuation that wasn't in the original text."
}

// MARK: - 引擎配置管理器

class EngineManager: ObservableObject {
    static let shared = EngineManager()
    
    @Published var engines: [EngineConfig] = []
    @Published var selectedEngineId: UUID?
    @Published var globalSystemPrompt: String = ""
    
    private var cancellables = Set<AnyCancellable>()
    private let enginesKey = "engine_configs"
    private let selectedKey = "selected_engine_id"
    
    var selectedEngine: EngineConfig? {
        engines.first { $0.id == selectedEngineId }
    }
    
    private init() {
        self.globalSystemPrompt = UserDefaults.standard.string(forKey: "global_system_prompt")
            ?? EngineConfig.defaultSystemPrompt
        loadEngines()
        
        // 监听 globalSystemPrompt 变化，自动持久化
        $globalSystemPrompt
            .dropFirst()
            .sink { newValue in
                UserDefaults.standard.set(newValue, forKey: "global_system_prompt")
            }
            .store(in: &cancellables)
    }
    
    // MARK: - 持久化
    
    func saveEngines() {
        if let data = try? JSONEncoder().encode(engines) {
            UserDefaults.standard.set(data, forKey: enginesKey)
        }
        if let id = selectedEngineId {
            UserDefaults.standard.set(id.uuidString, forKey: selectedKey)
        }
    }
    
    func loadEngines() {
        if let data = UserDefaults.standard.data(forKey: enginesKey),
           let decoded = try? JSONDecoder().decode([EngineConfig].self, from: data) {
            self.engines = decoded
        } else {
            // 首次启动，写入默认引擎
            self.engines = Self.defaultEngines()
        }
        
        if let idString = UserDefaults.standard.string(forKey: selectedKey),
           let id = UUID(uuidString: idString) {
            self.selectedEngineId = id
        } else {
            self.selectedEngineId = engines.first?.id
        }
        
        saveEngines()
    }
    
    // MARK: - CRUD
    
    func addEngine(_ engine: EngineConfig) {
        engines.append(engine)
        saveEngines()
    }
    
    func updateEngine(_ engine: EngineConfig) {
        if let index = engines.firstIndex(where: { $0.id == engine.id }) {
            engines[index] = engine
            saveEngines()
        }
    }
    
    func deleteEngine(id: UUID) {
        engines.removeAll { $0.id == id }
        if selectedEngineId == id {
            selectedEngineId = engines.first?.id
        }
        saveEngines()
    }
    
    func selectEngine(id: UUID) {
        selectedEngineId = id
        saveEngines()
    }
    
    // MARK: - 默认引擎列表
    
    static func defaultEngines() -> [EngineConfig] {
        [
            EngineConfig(
                id: UUID(),
                name: "DeepL",
                type: .deepL,
                apiURL: "https://api-free.deepl.com/v2/translate",
                apiKey: "a116b38d-f049-45af-a42b-2f7bda9402f9:fx",
                modelName: "",
                systemPrompt: "",
                isEnabled: true
            ),
            EngineConfig(
                id: UUID(),
                name: "Gemini",
                type: .gemini,
                apiURL: "https://generativelanguage.googleapis.com/v1beta/models/{{MODEL}}:generateContent",
                apiKey: "AIzaSyCEc2wUrfjTUdP8sxkFjIP3jKN_jkPEt3c",
                modelName: "gemini-2.0-flash",
                systemPrompt: EngineConfig.defaultSystemPrompt,
                isEnabled: true
            ),
            EngineConfig(
                id: UUID(),
                name: "Qwen",
                type: .openAICompatible,
                apiURL: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
                apiKey: "sk-86e422a45e484637a054a9dc3a26bffb",
                modelName: "qwen-turbo",
                systemPrompt: EngineConfig.defaultSystemPrompt,
                isEnabled: true
            ),
        ]
    }
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
        guard !config.apiKey.isEmpty else {
            throw ServiceError.missingAPIKey(config.name)
        }
        
        guard let url = URL(string: config.apiURL) else { throw URLError(.badURL) }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("DeepL-Auth-Key \(config.apiKey)", forHTTPHeaderField: "Authorization")
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
        guard !config.apiKey.isEmpty else {
            throw ServiceError.missingAPIKey(config.name)
        }
        
        guard let url = URL(string: config.apiURL) else { throw URLError(.badURL) }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let prompt = resolvePrompt(config: config, targetLang: targetLang)
        
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
        guard !config.apiKey.isEmpty else {
            throw ServiceError.missingAPIKey(config.name)
        }
        
        // 替换 URL 中的 {{MODEL}} 占位符
        let urlString = config.apiURL
            .replacingOccurrences(of: "{{MODEL}}", with: config.modelName)
            + "?key=\(config.apiKey)"
        
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let prompt = resolvePrompt(config: config, targetLang: targetLang)
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
    
    private func resolvePrompt(config: EngineConfig, targetLang: String) -> String {
        // 优先使用全局自定义提示词，否则用引擎自己的
        let manager = EngineManager.shared
        let template = manager.globalSystemPrompt.isEmpty ? config.systemPrompt : manager.globalSystemPrompt
        
        let langName = (targetLang == "ZH") ? "Simplified Chinese" : "English"
        return template.replacingOccurrences(of: "{{TARGET_LANG}}", with: langName)
    }
    
    // MARK: - 错误类型
    
    enum ServiceError: LocalizedError {
        case missingAPIKey(String)
        case apiError(String, String)
        
        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let name):
                return "请在设置中填入 \(name) 的 API Key"
            case .apiError(let name, let detail):
                return "\(name) 接口错误: \(detail)"
            }
        }
    }
}
