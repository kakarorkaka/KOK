//
//  ModelDiscovery.swift
//  KoK
//
//  从服务商的模型列表接口自动发现可用模型，免去让用户去文档里抄模型 ID。
//  参考 CC Switch 的「获取模型」：失败时按状态码给出可操作的提示，而不是抛原始报错。
//

import Foundation

enum ModelDiscovery {
    
    enum Failure: LocalizedError {
        case missingAPIKey(String)
        case unauthorized
        case notSupported
        case notApplicable(String)
        case badResponse(String)
        
        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let name):
                return "请先填写 \(name) 的 API Key"
            case .unauthorized:
                return "API Key 无效或没有权限（401 / 403）"
            case .notSupported:
                return "该服务商不提供模型列表接口（404 / 405），请改用「手动添加」"
            case .notApplicable(let name):
                return "\(name) 是翻译专用协议，没有模型列表"
            case .badResponse(let detail):
                return "返回内容无法解析：\(detail)"
            }
        }
    }
    
    /// 列表里明显不是对话模型的，过滤掉，免得把 embeddings / tts 也列出来
    private static let excludedKeywords = [
        "embedding", "embed-", "whisper", "tts", "dall-e", "moderation",
        "rerank", "stable-diffusion", "image", "audio", "speech", "vision-encoder",
    ]
    
    /// 拉取该服务商当前可用的模型
    static func fetchModels(for provider: Provider) async throws -> [ProviderCatalog.ModelTemplate] {
        let apiKey = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw Failure.missingAPIKey(provider.name) }
        
        switch provider.type {
        case .openAICompatible:
            return try await fetchOpenAICompatible(provider: provider, apiKey: apiKey)
        case .gemini:
            return try await fetchGemini(provider: provider, apiKey: apiKey)
        case .deepL:
            // DeepL 是翻译专用协议，压根没有模型列表概念
            throw Failure.notApplicable(provider.name)
        }
    }
    
    // MARK: - OpenAI 兼容
    
    private static func fetchOpenAICompatible(
        provider: Provider,
        apiKey: String
    ) async throws -> [ProviderCatalog.ModelTemplate] {
        guard let urlString = modelsURL(from: provider.apiURL),
              let url = URL(string: urlString) else {
            throw Failure.badResponse("接口地址无法解析")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let data = try await send(request)
        
        struct Response: Decodable {
            struct Item: Decodable { let id: String }
            let data: [Item]?
        }
        
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let items = decoded.data else {
            throw Failure.badResponse(String((String(data: data, encoding: .utf8) ?? "").prefix(120)))
        }
        
        return items
            .map(\.id)
            .filter { !$0.isEmpty && !isExcluded($0) }
            .sorted()
            .map { ProviderCatalog.ModelTemplate(id: $0, name: $0) }
    }
    
    /// 我们存的是「完整 endpoint」，这里反推出模型列表地址：
    ///   https://api.deepseek.com/v1/chat/completions → https://api.deepseek.com/v1/models
    ///   https://api.deepseek.com/chat/completions    → https://api.deepseek.com/models
    static func modelsURL(from apiURL: String) -> String? {
        guard var components = URLComponents(string: apiURL) else { return nil }
        
        var path = components.path
        for suffix in ["/chat/completions", "/completions"] where path.hasSuffix(suffix) {
            path = String(path.dropLast(suffix.count))
            break
        }
        
        components.path = path + "/models"
        components.query = nil      // ?key= 之类只对 Gemini 有意义
        return components.url?.absoluteString
    }
    
    private static func isExcluded(_ modelID: String) -> Bool {
        let lowered = modelID.lowercased()
        return excludedKeywords.contains { lowered.contains($0) }
    }
    
    // MARK: - Gemini
    
    private static func fetchGemini(
        provider: Provider,
        apiKey: String
    ) async throws -> [ProviderCatalog.ModelTemplate] {
        // .../v1beta/models/{{MODEL}}:generateContent → .../v1beta/models?key=...
        guard let marker = provider.apiURL.range(of: "/{{MODEL}}") else {
            throw Failure.badResponse("接口地址里找不到 {{MODEL}} 占位符")
        }
        let base = String(provider.apiURL[provider.apiURL.startIndex..<marker.lowerBound])
        guard let url = URL(string: base + "?key=" + apiKey) else {
            throw Failure.badResponse("接口地址无法解析")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let data = try await send(request)
        
        struct Response: Decodable {
            struct Item: Decodable {
                let name: String
                let displayName: String?
            }
            let models: [Item]?
        }
        
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let items = decoded.models else {
            throw Failure.badResponse(String((String(data: data, encoding: .utf8) ?? "").prefix(120)))
        }
        
        return items
            .map { item in
                // name 形如 "models/gemini-2.0-flash"
                let id = item.name.hasPrefix("models/")
                    ? String(item.name.dropFirst("models/".count))
                    : item.name
                return ProviderCatalog.ModelTemplate(id: id, name: item.displayName ?? id)
            }
            .filter { !$0.id.isEmpty && !isExcluded($0.id) }
            .sorted { $0.id < $1.id }
    }
    
    // MARK: - 请求
    
    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw Failure.badResponse("没有收到 HTTP 响应")
        }
        
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw Failure.unauthorized
        case 404, 405:
            throw Failure.notSupported
        default:
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw Failure.badResponse("HTTP \(http.statusCode) \(String(detail.prefix(120)))")
        }
    }
}
