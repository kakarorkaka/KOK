//
//  EngineStore.swift
//  KoK
//
//  引擎配置的数据层。
//
//  结构：服务商（Provider）→ 模型（Model）两层。
//  API Key / API 地址属于服务商，只填一次；模型只是服务商下的一个条目。
//  运行时再由 `EngineManager.engines` 展平成扁平的 `EngineConfig` 交给协议层，
//  因此 `UnifiedTranslationService` 与 `ChatService` 不需要知道服务商的存在。
//

import Foundation
import Combine

// MARK: - 运行时引擎（协议层使用的扁平结构）

struct EngineConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String           // 显示名称，如 "混元 T1"
    var type: EngineType       // 协议类型
    var apiURL: String
    var apiKey: String
    var modelName: String
    var systemPrompt: String
    var isEnabled: Bool
    
    enum EngineType: String, Codable, CaseIterable {
        case deepL = "DeepL"
        case openAICompatible = "OpenAI 兼容"
        case gemini = "Gemini"
        
        /// 是否支持多轮对话（DeepL 是翻译专用协议，不能对话）
        var supportsChat: Bool {
            switch self {
            case .deepL: return false
            case .openAICompatible, .gemini: return true
            }
        }
        
        /// 用户能看懂的说法，配置界面里用它代替协议名
        var friendlyName: String {
            switch self {
            case .deepL: return "DeepL 翻译协议"
            case .openAICompatible: return "通用（OpenAI 兼容）"
            case .gemini: return "Google Gemini 协议"
            }
        }
    }
    
    static let defaultSystemPrompt = "You are a professional translator. Translate the user's text to {{TARGET_LANG}}. Only output the translated text directly. Do not add any explanations, notes, or punctuation that wasn't in the original text."
    
    static let defaultChatSystemPrompt = "You are a concise, helpful assistant. Answer directly in the user's language. Prefer short paragraphs and bullet points, and use fenced code blocks for code."
    
    /// 解析实际用于请求的 API Key。
    ///
    /// 解析顺序：
    /// 1. 「设置」中为该服务商保存的 Key；
    /// 2. 环境变量 `KOK_API_KEY_<名称>`（名称转大写、非字母数字替换为下划线）。
    ///
    /// 源码中不预置任何真实 Key，仓库里也不会出现凭据。
    var resolvedAPIKey: String {
        if !apiKey.isEmpty { return apiKey }
        let suffix = name.uppercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "_"
        }
        return ProcessInfo.processInfo.environment["KOK_API_KEY_\(String(suffix))"] ?? ""
    }
}

// MARK: - 服务商

struct Provider: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var type: EngineConfig.EngineType
    var apiURL: String
    /// 服务商级凭据：同一下所有模型共用，只填一次
    var apiKey: String
    /// 该服务商专属提示词，留空则跟随全局
    var systemPrompt: String
    var isEnabled: Bool
    var models: [ProviderModel]
    
    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var enabledModels: [ProviderModel] {
        models.filter(\.isEnabled)
    }
    
    /// 列表副标题：比"OpenAI 兼容"有信息量
    var summary: String {
        enabledModels.isEmpty ? "未启用模型" : "\(enabledModels.count) 个模型"
    }
}

struct ProviderModel: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String        // 显示名：混元 T1
    var modelName: String   // 传给 API 的 ID：hunyuan-t1
    var isEnabled: Bool
}

// MARK: - 预设服务商目录

enum ProviderCatalog {
    struct ModelTemplate: Hashable {
        let id: String
        let name: String
    }
    
    struct Template: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let symbol: String
        let type: EngineConfig.EngineType
        let apiURL: String
        let keyPlaceholder: String
        let models: [ModelTemplate]
        let note: String?
    }
    
    static let custom = Template(
        name: "自定义",
        symbol: "slider.horizontal.3",
        type: .openAICompatible,
        apiURL: "",
        keyPlaceholder: "填入你的 API Key",
        models: [],
        note: "自行填写接口地址与模型 ID，适用于任何 OpenAI 兼容服务"
    )
    
    static let all: [Template] = [
        Template(
            name: "腾讯云 Token Plan",
            symbol: "cloud",
            type: .openAICompatible,
            apiURL: "https://api.lkeap.cloud.tencent.com/plan/v3/chat/completions",
            keyPlaceholder: "填入腾讯云 API Key",
            models: [
                ModelTemplate(id: "tc-code-latest", name: "Auto（智能路由）"),
                ModelTemplate(id: "hunyuan-t1", name: "混元 T1"),
                ModelTemplate(id: "hunyuan-turbo", name: "混元 TurboS"),
                ModelTemplate(id: "hunyuan-2.0-instruct", name: "混元 2.0 Instruct"),
                ModelTemplate(id: "hunyuan-2.0-thinking", name: "混元 2.0 Think"),
                ModelTemplate(id: "hy3-preview", name: "混元 Hy3 Preview"),
                ModelTemplate(id: "deepseek-flash", name: "DeepSeek V4"),
                ModelTemplate(id: "glm-5", name: "GLM-5"),
                ModelTemplate(id: "glm-5.1", name: "GLM-5.1"),
                ModelTemplate(id: "kimi-k2.5", name: "Kimi K2.5"),
                ModelTemplate(id: "minimax-m2.5", name: "MiniMax M2.5"),
                ModelTemplate(id: "minimax-m2.7", name: "MiniMax M2.7"),
            ],
            note: nil
        ),
        Template(
            name: "OpenAI",
            symbol: "circle.hexagongrid",
            type: .openAICompatible,
            apiURL: "https://api.openai.com/v1/chat/completions",
            keyPlaceholder: "sk-...",
            models: [
                ModelTemplate(id: "gpt-4o", name: "GPT-4o"),
                ModelTemplate(id: "gpt-4o-mini", name: "GPT-4o mini"),
                ModelTemplate(id: "gpt-4-turbo", name: "GPT-4 Turbo"),
                ModelTemplate(id: "gpt-3.5-turbo", name: "GPT-3.5 Turbo"),
            ],
            note: nil
        ),
        Template(
            name: "DeepSeek",
            symbol: "brain",
            type: .openAICompatible,
            apiURL: "https://api.deepseek.com/chat/completions",
            keyPlaceholder: "sk-...",
            models: [
                ModelTemplate(id: "deepseek-chat", name: "DeepSeek Chat"),
                ModelTemplate(id: "deepseek-reasoner", name: "DeepSeek Reasoner"),
            ],
            note: nil
        ),
        Template(
            name: "智谱 AI",
            symbol: "sparkles",
            type: .openAICompatible,
            apiURL: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
            keyPlaceholder: "填入智谱 API Key",
            models: [
                ModelTemplate(id: "glm-4-plus", name: "GLM-4 Plus"),
                ModelTemplate(id: "glm-4-flash", name: "GLM-4 Flash（免费）"),
                ModelTemplate(id: "glm-4", name: "GLM-4"),
            ],
            note: nil
        ),
        Template(
            name: "Moonshot",
            symbol: "moon.stars",
            type: .openAICompatible,
            apiURL: "https://api.moonshot.cn/v1/chat/completions",
            keyPlaceholder: "sk-...",
            models: [
                ModelTemplate(id: "moonshot-v1-8k", name: "Moonshot V1 8K"),
                ModelTemplate(id: "moonshot-v1-32k", name: "Moonshot V1 32K"),
                ModelTemplate(id: "moonshot-v1-128k", name: "Moonshot V1 128K"),
            ],
            note: nil
        ),
        Template(
            name: "通义千问",
            symbol: "aqi.medium",
            type: .openAICompatible,
            apiURL: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
            keyPlaceholder: "sk-...",
            models: [
                ModelTemplate(id: "qwen-turbo", name: "Qwen Turbo"),
                ModelTemplate(id: "qwen-plus", name: "Qwen Plus"),
                ModelTemplate(id: "qwen-max", name: "Qwen Max"),
            ],
            note: nil
        ),
        Template(
            name: "Google Gemini",
            symbol: "diamond",
            type: .gemini,
            apiURL: "https://generativelanguage.googleapis.com/v1beta/models/{{MODEL}}:generateContent",
            keyPlaceholder: "AIza...",
            models: [
                ModelTemplate(id: "gemini-2.0-flash", name: "Gemini 2.0 Flash"),
                ModelTemplate(id: "gemini-2.0-flash-lite", name: "Gemini 2.0 Flash Lite"),
                ModelTemplate(id: "gemini-1.5-pro", name: "Gemini 1.5 Pro"),
            ],
            note: "模型 ID 会自动填进地址里的 {{MODEL}}"
        ),
        Template(
            name: "DeepL",
            symbol: "character.book.closed",
            type: .deepL,
            apiURL: "https://api-free.deepl.com/v2/translate",
            keyPlaceholder: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx:fx",
            models: [],
            note: "DeepL 仅用于翻译，不支持对话"
        ),
        custom,
    ]
    
    /// 迁移旧数据时，从接口地址反推一个像样的服务商名
    static func suggestedName(forAPIURL url: String) -> String {
        let host = URL(string: url)?.host ?? ""
        let table: [(String, String)] = [
            ("api.lkeap.cloud.tencent.com", "腾讯云 Token Plan"),
            ("api.openai.com", "OpenAI"),
            ("api.deepseek.com", "DeepSeek"),
            ("open.bigmodel.cn", "智谱 AI"),
            ("api.moonshot.cn", "Moonshot"),
            ("dashscope.aliyuncs.com", "通义千问"),
            ("generativelanguage.googleapis.com", "Google Gemini"),
            ("api-free.deepl.com", "DeepL"),
            ("api.deepl.com", "DeepL"),
            ("localhost", "本地模型"),
            ("127.0.0.1", "本地模型"),
        ]
        for (needle, name) in table where host.contains(needle) {
            return name
        }
        return host.isEmpty ? "自定义服务商" : host
    }
}

// MARK: - 服务商 / 模型管理

class EngineManager: ObservableObject {
    static let shared = EngineManager()
    
    @Published var providers: [Provider] = []
    /// 翻译使用的模型 id（= ProviderModel.id）
    @Published var selectedEngineId: UUID?
    /// 对话使用的模型 id
    @Published var chatEngineId: UUID?
    @Published var globalSystemPrompt: String = ""
    @Published var chatSystemPrompt: String = ""
    
    private var cancellables = Set<AnyCancellable>()
    
    private let providersKey = "provider_store_v2"
    /// 旧版扁平结构，仅用于一次性迁移
    private static let legacyEnginesKey = "engine_configs"
    private static let legacyBackupKey = "engine_configs_backup_v1"
    private let selectedKey = "selected_engine_id"
    private let chatEngineKey = "chat_engine_id"
    private let chatPromptKey = "chat_system_prompt"
    private let globalPromptKey = "global_system_prompt"
    
    private init() {
        self.globalSystemPrompt = UserDefaults.standard.string(forKey: globalPromptKey)
            ?? EngineConfig.defaultSystemPrompt
        self.chatSystemPrompt = UserDefaults.standard.string(forKey: chatPromptKey)
            ?? EngineConfig.defaultChatSystemPrompt
        
        loadProviders()
        loadSelections()
        
        $globalSystemPrompt
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: self.globalPromptKey) }
            .store(in: &cancellables)
        
        $chatSystemPrompt
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: self.chatPromptKey) }
            .store(in: &cancellables)
    }
    
    // MARK: - 展平：给协议层用的扁平引擎列表
    
    /// 由「启用的服务商 × 启用的模型」实时展平而成。
    /// `EngineConfig.id` 就是 `ProviderModel.id`，所以已保存的选中项始终有效。
    var engines: [EngineConfig] {
        providers.filter(\.isEnabled).flatMap { provider in
            provider.models.filter(\.isEnabled).map { engine(from: provider, model: $0) }
        }
    }
    
    var selectedEngine: EngineConfig? {
        engines.first { $0.id == selectedEngineId }
    }
    
    var chatEngines: [EngineConfig] {
        engines.filter { $0.type.supportsChat }
    }
    
    var selectedChatEngine: EngineConfig? {
        if let id = chatEngineId, let engine = chatEngines.first(where: { $0.id == id }) {
            return engine
        }
        return chatEngines.first
    }
    
    private func engine(from provider: Provider, model: ProviderModel) -> EngineConfig {
        EngineConfig(
            id: model.id,
            name: model.name,
            type: provider.type,
            apiURL: provider.apiURL,
            apiKey: provider.apiKey,
            modelName: model.modelName,
            systemPrompt: provider.systemPrompt,
            isEnabled: true
        )
    }
    
    // MARK: - 选中项
    
    func selectEngine(id: UUID) {
        selectedEngineId = id
        UserDefaults.standard.set(id.uuidString, forKey: selectedKey)
    }
    
    func selectChatEngine(id: UUID) {
        chatEngineId = id
        UserDefaults.standard.set(id.uuidString, forKey: chatEngineKey)
    }
    
    func isTranslationDefault(_ modelId: UUID) -> Bool { selectedEngineId == modelId }
    func isChatDefault(_ modelId: UUID) -> Bool { chatEngineId == modelId }
    
    // MARK: - 服务商 CRUD
    
    func addProvider(_ provider: Provider) {
        providers.append(provider)
        saveProviders()
        ensureSelections()
    }
    
    func updateProvider(_ provider: Provider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
        saveProviders()
        ensureSelections()
    }
    
    func deleteProvider(id: UUID) {
        providers.removeAll { $0.id == id }
        saveProviders()
        ensureSelections()
    }
    
    // MARK: - 模型 CRUD
    
    func addModels(_ models: [ProviderModel], to providerId: UUID) {
        guard let index = providers.firstIndex(where: { $0.id == providerId }) else { return }
        providers[index].models.append(contentsOf: models)
        saveProviders()
        ensureSelections()
    }
    
    func updateModel(_ model: ProviderModel, in providerId: UUID) {
        guard let pIndex = providers.firstIndex(where: { $0.id == providerId }),
              let mIndex = providers[pIndex].models.firstIndex(where: { $0.id == model.id })
        else { return }
        providers[pIndex].models[mIndex] = model
        saveProviders()
        ensureSelections()
    }
    
    func deleteModel(id: UUID) {
        for index in providers.indices {
            providers[index].models.removeAll { $0.id == id }
        }
        saveProviders()
        ensureSelections()
    }
    
    func provider(containingModel id: UUID) -> Provider? {
        providers.first { $0.models.contains { $0.id == id } }
    }
    
    /// 删除后保证两个用途都还有有效的选中项
    private func ensureSelections() {
        if let id = selectedEngineId, engines.contains(where: { $0.id == id }) {
            // 仍然有效
        } else {
            selectedEngineId = engines.first?.id
            if let id = selectedEngineId {
                UserDefaults.standard.set(id.uuidString, forKey: selectedKey)
            }
        }
        
        let chat = chatEngines
        if let id = chatEngineId, chat.contains(where: { $0.id == id }) {
            // 仍然有效
        } else {
            chatEngineId = chat.first?.id
            if let id = chatEngineId {
                UserDefaults.standard.set(id.uuidString, forKey: chatEngineKey)
            }
        }
    }
    
    // MARK: - 持久化
    
    private func saveProviders() {
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: providersKey)
        }
    }
    
    private func loadProviders() {
        if let data = UserDefaults.standard.data(forKey: providersKey),
           let decoded = try? JSONDecoder().decode([Provider].self, from: data) {
            providers = decoded
            return
        }
        providers = Self.migrateLegacyEngines()
        
        // 迁移完成后立刻落盘，避免下次启动重复迁移
        saveProviders()
    }
    
    private func loadSelections() {
        if let idString = UserDefaults.standard.string(forKey: selectedKey),
           let id = UUID(uuidString: idString) {
            selectedEngineId = id
        }
        if let idString = UserDefaults.standard.string(forKey: chatEngineKey),
           let id = UUID(uuidString: idString) {
            chatEngineId = id
        }
        ensureSelections()
    }
    
    /// 把 1.x / 2.x 的扁平 `engine_configs` 迁移成服务商结构。
    ///
    /// 做法：按「接口地址 + API Key + 协议」分组，每组一个服务商，
    /// 每条旧记录变成一个模型。`ProviderModel.id` 直接沿用旧的 `EngineConfig.id`，
    /// 所以已保存的翻译 / 对话选中项不会丢。
    /// 原始 JSON 会备份到 `engine_configs_backup_v1` 以便回滚。
    private static func migrateLegacyEngines() -> [Provider] {
        guard let data = UserDefaults.standard.data(forKey: legacyEnginesKey),
              let legacy = try? JSONDecoder().decode([EngineConfig].self, from: data),
              !legacy.isEmpty
        else {
            return []
        }
        
        UserDefaults.standard.set(data, forKey: legacyBackupKey)
        
        var grouped: [String: [EngineConfig]] = [:]
        var order: [String] = []
        for engine in legacy {
            let key = "\(engine.type.rawValue)|\(engine.apiURL)|\(engine.apiKey)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(engine)
        }
        
        return order.compactMap { key -> Provider? in
            guard let group = grouped[key], let first = group.first else { return nil }
            
            let models = group.map {
                ProviderModel(id: $0.id, name: $0.name, modelName: $0.modelName, isEnabled: $0.isEnabled)
            }
            
            return Provider(
                id: UUID(),
                name: ProviderCatalog.suggestedName(forAPIURL: first.apiURL),
                type: first.type,
                apiURL: first.apiURL,
                apiKey: first.apiKey,
                systemPrompt: group.first { !$0.systemPrompt.isEmpty }?.systemPrompt ?? "",
                isEnabled: group.contains { $0.isEnabled },
                models: models
            )
        }
        .sorted { $0.name < $1.name }
    }
}
