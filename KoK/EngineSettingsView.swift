//
//  EngineSettingsView.swift
//  KoK
//
//  引擎设置界面：服务商列表 + 详情。
//
//  与旧版的区别：
//  - 两层结构：服务商（凭据）→ 模型（勾选），API Key 只填一次
//  - 采用 macOS 原生分组表单外观，写透式自动保存，没有「保存」按钮
//  - 「译 / 聊」两个小标签直接标明该模型用于哪个用途，取代原先混乱的多种状态
//  - 接口地址、协议等实现细节收进「高级」
//

import SwiftUI

// MARK: - Tab: 引擎

struct EngineSettingsTab: View {
    @ObservedObject var manager = EngineManager.shared
    @State private var selectedProviderId: UUID?
    @State private var showingAdd = false
    @State private var providerToDelete: Provider?
    
    private var selectedProvider: Provider? {
        guard let id = selectedProviderId else { return nil }
        return manager.providers.first { $0.id == id }
    }
    
    var body: some View {
        HSplitView {
            providerList
                .frame(minWidth: 190, idealWidth: 200, maxWidth: 230)
            
            if let provider = selectedProvider {
                ProviderDetailView(provider: provider)
            } else {
                emptyDetail
            }
        }
        .onAppear {
            if selectedProviderId == nil { selectedProviderId = manager.providers.first?.id }
        }
        .onChange(of: manager.providers.count) { _, _ in
            if selectedProvider == nil { selectedProviderId = manager.providers.first?.id }
        }
        .sheet(isPresented: $showingAdd) {
            AddProviderSheet { provider in
                manager.addProvider(provider)
                selectedProviderId = provider.id
            }
        }
        .alert(
            "删除服务商「\(providerToDelete?.name ?? "")」？",
            isPresented: Binding(get: { providerToDelete != nil }, set: { if !$0 { providerToDelete = nil } }),
            presenting: providerToDelete
        ) { provider in
            Button("删除", role: .destructive) {
                manager.deleteProvider(id: provider.id)
                selectedProviderId = manager.providers.first?.id
            }
            Button("取消", role: .cancel) {}
        } message: { provider in
            Text("该服务商下的 \(provider.models.count) 个模型会一并移除。此操作不可撤销。")
        }
    }
    
    // MARK: 左侧：服务商列表
    
    private var providerList: some View {
        VStack(spacing: 0) {
            List(manager.providers, selection: $selectedProviderId) { provider in
                ProviderRow(provider: provider)
                    .tag(provider.id)
            }
            .listStyle(.sidebar)
            
            Divider()
            
            HStack(spacing: 2) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.borderless)
                .help("添加服务商")
                
                Button {
                    providerToDelete = selectedProvider
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(selectedProvider == nil)
                .help("删除服务商")
                
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }
    
    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.6))
            Text("还没有配置服务商")
                .font(.headline)
            Text("添加一个服务商，填入 API Key，再勾选要用的模型。\n同一个服务商的多个模型共用一把 Key。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("添加服务商") { showingAdd = true }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - 服务商列表行

private struct ProviderRow: View {
    let provider: Provider
    @ObservedObject var manager = EngineManager.shared
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(provider.isEnabled ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(provider.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    
                    if !provider.hasAPIKey {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                            .help("还没有填 API Key")
                    }
                }
                Text(provider.summary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 右侧：服务商详情

private struct ProviderDetailView: View {
    let provider: Provider
    @ObservedObject var manager = EngineManager.shared
    
    @State private var nameDraft = ""
    @State private var keyDraft = ""
    @State private var urlDraft = ""
    @State private var noteDraft = ""
    @State private var websiteDraft = ""
    @State private var showingAddModel = false
    @State private var showingFetchModels = false
    @State private var editingModel: ProviderModel?
    @State private var testState: TestState = .idle
    
    private enum TestState: Equatable {
        case idle, running
        case ok(String)
        case failed(String)
    }
    
    var body: some View {
        Form {
            // ── 凭据 ──────────────────────────────────────────
            Section {
                LabeledContent("名称") {
                    TextField("", text: $nameDraft)
                        .onChange(of: nameDraft) { _, value in
                            guard value != provider.name else { return }
                            mutate { $0.name = value }
                        }
                }
                
                LabeledContent("API Key") {
                    HStack(spacing: 8) {
                        // 占位符保持为空：标签已经说明是什么，长提示会把窄输入框挤到换行
                        SecureField("", text: $keyDraft)
                            .textFieldStyle(.roundedBorder)
                            .layoutPriority(1)
                            .onChange(of: keyDraft) { _, value in
                                guard value != provider.apiKey else { return }
                                mutate { $0.apiKey = value }
                                testState = .idle
                            }
                        
                        Button("测试") { runTest() }
                            .controlSize(.small)
                            .fixedSize()
                            .disabled(testState == .running || !canTest)
                    }
                }
                
                testResultRow
            } header: {
                Text("凭据")
            } footer: {
                Text(provider.type == .deepL
                     ? "DeepL 的 Key 形如 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx:fx。"
                     : "同一服务商下的所有模型共用这把 Key，不用每个模型填一遍。")
            }
            
            // ── 备注与链接 ─────────────────────────────────────
            Section {
                LabeledContent("备注") {
                    // 占位符留空：LabeledContent 里非空 placeholder 会和实际值并排渲染
                    TextField("", text: $noteDraft)
                        .onChange(of: noteDraft) { _, value in
                            guard value != provider.note else { return }
                            mutate { $0.note = value }
                        }
                }
                
                LabeledContent("官网 / 控制台") {
                    HStack(spacing: 8) {
                        TextField("", text: $websiteDraft)
                            .textFieldStyle(.roundedBorder)
                            .layoutPriority(1)
                            .onChange(of: websiteDraft) { _, value in
                                guard value != provider.website else { return }
                                mutate { $0.website = value }
                            }
                        
                        Button("打开") { openWebsite() }
                            .controlSize(.small)
                            .fixedSize()
                            .disabled(websiteURL == nil)
                    }
                }
            } header: {
                Text("备注与链接")
            } footer: {
                Text("备注会显示在左侧列表上，方便区分多个账号（如「公司账号 · 10 月到期」）；官网地址用于快速去查余额、拿 Key。")
            }
            
            // ── 模型 ──────────────────────────────────────────
            if provider.type != .deepL {
                Section {
                    if provider.models.isEmpty {
                        Text("还没有模型，点下面的按钮添加。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(provider.models) { model in
                            ModelRow(
                                model: model,
                                isTranslationDefault: manager.isTranslationDefault(model.id),
                                isChatDefault: manager.isChatDefault(model.id),
                                supportsChat: provider.type.supportsChat,
                                onToggle: { enabled in
                                    var updated = model
                                    updated.isEnabled = enabled
                                    manager.updateModel(updated, in: provider.id)
                                },
                                onUseForTranslation: { manager.selectEngine(id: model.id) },
                                onUseForChat: { manager.selectChatEngine(id: model.id) },
                                onEdit: { editingModel = model },
                                onDelete: { manager.deleteModel(id: model.id) }
                            )
                        }
                    }
                    
                    HStack(spacing: 16) {
                        Button {
                            showingFetchModels = true
                        } label: {
                            Label("从服务商获取", systemImage: "arrow.down.circle")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        .disabled(!provider.hasAPIKey)
                        .help(provider.hasAPIKey ? "调用模型列表接口，自动发现可用模型" : "请先填写 API Key")
                        
                        Button {
                            showingAddModel = true
                        } label: {
                            Label("手动添加", systemImage: "plus")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                } header: {
                    Text("模型")
                } footer: {
                    Text("勾选的模型会出现在「翻译引擎 / 对话引擎」的选择列表里。\n「译」「聊」用来指定该模型作为哪个用途的默认。")
                }
            }
            
            // ── 高级 ──────────────────────────────────────────
            Section {
                DisclosureGroup("高级") {
                    LabeledContent("接口地址") {
                        TextField("", text: $urlDraft)
                            .onChange(of: urlDraft) { _, value in
                                guard value != provider.apiURL else { return }
                                mutate { $0.apiURL = value }
                                testState = .idle
                            }
                    }
                    
                    LabeledContent("协议") {
                        Picker("", selection: Binding(
                            get: { provider.type },
                            set: { newType in mutate { $0.type = newType } }
                        )) {
                            ForEach(EngineConfig.EngineType.allCases, id: \.self) { type in
                                Text(type.friendlyName).tag(type)
                            }
                        }
                        .labelsHidden()
                    }
                    
                    if provider.type == .gemini {
                        Text("地址里的 {{MODEL}} 会被替换成所选模型 ID。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // ── 启用 ──────────────────────────────────────────
            Section {
                Toggle("启用此服务商", isOn: Binding(
                    get: { provider.isEnabled },
                    set: { value in mutate { $0.isEnabled = value } }
                ))
            } footer: {
                Text("关闭后，该服务商下的所有模型都不会出现在引擎列表里。")
            }
        }
        .formStyle(.grouped)
        .onAppear { syncDrafts() }
        .onChange(of: provider.id) { _, _ in
            syncDrafts()
            testState = .idle
        }
        .sheet(isPresented: $showingAddModel) {
            ModelEditorSheet(model: nil) { model in
                manager.addModels([model], to: provider.id)
            }
        }
        .sheet(isPresented: $showingFetchModels) {
            FetchModelsSheet(provider: provider) { discovered in
                let existing = Set(provider.models.map(\.modelName))
                let fresh = discovered.filter { !existing.contains($0.id) }
                manager.addModels(
                    fresh.map { ProviderModel(id: UUID(), name: $0.name, modelName: $0.id, isEnabled: true) },
                    to: provider.id
                )
            }
        }
        .sheet(item: $editingModel) { model in
            ModelEditorSheet(model: model) { updated in
                manager.updateModel(updated, in: provider.id)
            }
        }
    }
    
    @ViewBuilder
    private var testResultRow: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.5)
                Text("正在测试…").font(.caption).foregroundColor(.secondary)
            }
        case .ok(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.green)
                .lineLimit(2)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(.red)
                .lineLimit(3)
        }
    }
    
    // MARK: 辅助
    
    private func mutate(_ change: (inout Provider) -> Void) {
        var updated = provider
        change(&updated)
        manager.updateProvider(updated)
    }
    
    private func syncDrafts() {
        nameDraft = provider.name
        keyDraft = provider.apiKey
        urlDraft = provider.apiURL
        noteDraft = provider.note
        websiteDraft = provider.website
    }
    
    /// 只有填了合法 http(s) 地址才能「打开」
    private var websiteURL: URL? {
        let trimmed = provider.website.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }
    
    private func openWebsite() {
        guard let url = websiteURL else { return }
        NSWorkspace.shared.open(url)
    }
    
    /// 校验能不能发起测试：得有 Key，且（非 DeepL 时）至少有一个启用的模型
    private var canTest: Bool {
        guard !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return provider.type == .deepL || !provider.enabledModels.isEmpty
    }
    
    private func runTest() {
        let model = provider.enabledModels.first
        if provider.type != .deepL, model == nil { return }
        
        let config = EngineConfig(
            id: model?.id ?? provider.id,
            name: provider.name,
            type: provider.type,
            apiURL: provider.apiURL,
            apiKey: provider.apiKey,
            modelName: model?.modelName ?? "",
            isEnabled: true
        )
        
        testState = .running
        
        Task {
            let started = CFAbsoluteTimeGetCurrent()
            do {
                let summary: String
                if provider.type == .deepL {
                    let result = try await UnifiedTranslationService()
                        .translate(text: "hello", to: "ZH", using: config)
                    summary = "翻译正常：\(result.text.prefix(20))"
                } else {
                    let text = try await ChatService().complete(
                        messages: [ChatMessage(role: .user, content: "Reply with the single word: pong")],
                        using: config
                    )
                    summary = "连接正常：\(text.prefix(20))"
                }
                let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
                testState = .ok("\(summary) · \(model?.name ?? "默认模型") · \(ms) ms")
            } catch {
                let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
                testState = .failed("\(error.localizedDescription)（\(ms) ms）")
            }
        }
    }
}

// MARK: - 模型行

private struct ModelRow: View {
    let model: ProviderModel
    let isTranslationDefault: Bool
    let isChatDefault: Bool
    let supportsChat: Bool
    
    let onToggle: (Bool) -> Void
    let onUseForTranslation: () -> Void
    let onUseForChat: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { model.isEnabled }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.small)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(model.name)
                    .font(.system(size: 12.5))
                    .foregroundColor(model.isEnabled ? .primary : .secondary)
                if model.modelName != model.name {
                    Text(model.modelName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer(minLength: 8)
            
            chip("译", active: isTranslationDefault, help: "设为翻译默认") {
                onUseForTranslation()
            }
            if supportsChat {
                chip("聊", active: isChatDefault, help: "设为对话默认") {
                    onUseForChat()
                }
            }
            
            Menu {
                Button("编辑…", action: onEdit)
                Divider()
                Button("删除", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)
            .help("更多")
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }
    
    private func chip(_ title: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 20, height: 17)
                .background(active ? Color.accentColor : Color.primary.opacity(0.07))
                .foregroundColor(active ? .white : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 模型编辑弹窗

private struct ModelEditorSheet: View {
    let model: ProviderModel?
    let onSave: (ProviderModel) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var modelName = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model == nil ? "添加模型" : "编辑模型")
                .font(.headline)
            
            LabeledContent("显示名") {
                TextField("如：混元 T1", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            
            LabeledContent("模型 ID") {
                TextField("如：hunyuan-t1", text: $modelName)
                    .textFieldStyle(.roundedBorder)
            }
            
            Text("模型 ID 是服务商文档里给出的名称，会原样发给接口。")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(model == nil ? "添加" : "保存") {
                    let result = ProviderModel(
                        id: model?.id ?? UUID(),
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        modelName: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                        isEnabled: model?.isEnabled ?? true
                    )
                    onSave(result)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || modelName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            name = model?.name ?? ""
            modelName = model?.modelName ?? ""
        }
    }
}

// MARK: - 添加服务商弹窗

struct AddProviderSheet: View {
    let onAdd: (Provider) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var template: ProviderCatalog.Template = ProviderCatalog.all[0]
    @State private var name = ""
    @State private var apiURL = ""
    @State private var apiKey = ""
    /// 当前候选模型列表：初始来自预设，可被「获取模型」替换/扩充
    @State private var models: [ProviderCatalog.ModelTemplate] = []
    @State private var selectedModels: Set<String> = []
    @State private var fetchState: FetchState = .idle
    
    private enum FetchState: Equatable {
        case idle
        case running
        case ok(String)
        case failed(String)
    }
    
    private var isCustom: Bool { template.id == ProviderCatalog.custom.id }
    
    private var canFetch: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !apiURL.isEmpty
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加服务商")
                .font(.headline)
            
            // 预设选择（按类别分组）
            LabeledContent("服务商") {
                Picker("", selection: $template) {
                    ForEach(ProviderCatalog.grouped) { group in
                        Section(group.category.rawValue) {
                            ForEach(group.templates) { item in
                                Label(item.name, systemImage: item.symbol).tag(item)
                            }
                        }
                    }
                }
                .labelsHidden()
            }
            .onChange(of: template) { _, newValue in
                apply(template: newValue)
            }
            
            LabeledContent("名称") {
                TextField("给这个服务商起个名", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            
            LabeledContent("API Key") {
                SecureField(template.keyPlaceholder, text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: apiKey) { _, _ in fetchState = .idle }
            }
            
            if isCustom {
                LabeledContent("接口地址") {
                    TextField("https://.../chat/completions", text: $apiURL)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: apiURL) { _, _ in fetchState = .idle }
                }
            } else if let note = template.note {
                Text(note)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            // 模型：可以先用预设列表，也可以直接从服务商拉取
            HStack {
                Text("模型")
                    .font(.subheadline)
                Spacer()
                
                if !models.isEmpty {
                    Button(selectedModels.count == models.count ? "取消全选" : "全选") {
                        if selectedModels.count == models.count {
                            selectedModels.removeAll()
                        } else {
                            selectedModels = Set(models.map(\.id))
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
                
                Button {
                    fetchModels()
                } label: {
                    Label("获取模型", systemImage: "arrow.down.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(canFetch ? .accentColor : .secondary)
                .disabled(!canFetch || fetchState == .running)
                .help(canFetch ? "调用模型列表接口，自动发现可用模型" : "请先填写 API Key 和接口地址")
            }
            
            fetchStatusRow
            
            if models.isEmpty {
                Text("可以点「获取模型」自动拉取，或直接添加后在详情里手动填写。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(models, id: \.id) { item in
                            HStack(spacing: 8) {
                                Image(systemName: selectedModels.contains(item.id) ? "checkmark.square.fill" : "square")
                                    .foregroundColor(selectedModels.contains(item.id) ? .accentColor : .secondary)
                                Text(item.name)
                                    .font(.system(size: 12.5))
                                Spacer()
                                Text(item.id)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(item.id) }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 150)
                
                Text("已选 \(selectedModels.count)/\(models.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加") { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 470)
        .onAppear { apply(template: template) }
    }
    
    @ViewBuilder
    private var fetchStatusRow: some View {
        switch fetchState {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.5)
                Text("正在获取模型…").font(.caption2).foregroundColor(.secondary)
            }
        case .ok(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.green)
                .lineLimit(2)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundColor(.orange)
                .lineLimit(3)
        }
    }
    
    private func apply(template newTemplate: ProviderCatalog.Template) {
        name = newTemplate.category == .custom ? "" : newTemplate.name
        apiURL = newTemplate.apiURL
        models = newTemplate.models
        selectedModels = Set(newTemplate.models.map(\.id))
        fetchState = .idle
    }
    
    /// 用「临时的 Provider」去调模型列表接口，拉回来的结果合并进候选列表
    private func fetchModels() {
        let draft = Provider(
            id: UUID(),
            name: name.isEmpty ? template.name : name,
            type: template.type,
            apiURL: apiURL,
            apiKey: apiKey,
            isEnabled: true,
            models: []
        )
        
        fetchState = .running
        
        Task {
            do {
                let discovered = try await ModelDiscovery.fetchModels(for: draft)
                let existing = Set(models.map(\.id))
                let fresh = discovered.filter { !existing.contains($0.id) }
                models = (models + fresh).sorted { $0.id < $1.id }
                selectedModels.formUnion(fresh.map(\.id))
                fetchState = .ok(fresh.isEmpty
                    ? "获取到 \(discovered.count) 个模型，都已在列表中"
                    : "获取到 \(discovered.count) 个模型，新增 \(fresh.count) 个并已勾选")
            } catch {
                fetchState = .failed(error.localizedDescription)
            }
        }
    }
    
    private var canAdd: Bool {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if isCustom { return !apiURL.isEmpty }
        return true
    }
    
    private func toggle(_ id: String) {
        if selectedModels.contains(id) {
            selectedModels.remove(id)
        } else {
            selectedModels.insert(id)
        }
    }
    
    private func add() {
        let picked = models
            .filter { selectedModels.contains($0.id) }
            .map { ProviderModel(id: UUID(), name: $0.name, modelName: $0.id, isEnabled: true) }
        
        onAdd(Provider(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            type: template.type,
            apiURL: apiURL,
            apiKey: apiKey,
            isEnabled: true,
            models: picked
        ))
        dismiss()
    }
}

// MARK: - 获取模型弹窗（已有服务商）

/// 调用服务商的模型列表接口，勾选后追加为模型。
/// 参考 CC Switch 的「获取模型」，失败时按状态码给可操作的提示。
struct FetchModelsSheet: View {
    let provider: Provider
    let onAdd: ([ProviderCatalog.ModelTemplate]) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var state: LoadState = .loading
    @State private var candidates: [ProviderCatalog.ModelTemplate] = []
    @State private var selected: Set<String> = []
    
    private enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("获取模型 · \(provider.name)")
                .font(.headline)
            
            switch state {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6)
                    Text("正在调用模型列表接口…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
                
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("可以关掉这个窗口，改用「手动添加」。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
                
            case .loaded:
                if candidates.isEmpty {
                    Text("该服务商返回的模型都已在列表里了。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
                } else {
                    HStack {
                        Text("发现 \(candidates.count) 个新模型")
                            .font(.subheadline)
                        Spacer()
                        Button(selected.count == candidates.count ? "取消全选" : "全选") {
                            if selected.count == candidates.count {
                                selected.removeAll()
                            } else {
                                selected = Set(candidates.map(\.id))
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(candidates, id: \.id) { item in
                                HStack(spacing: 8) {
                                    Image(systemName: selected.contains(item.id) ? "checkmark.square.fill" : "square")
                                        .foregroundColor(selected.contains(item.id) ? .accentColor : .secondary)
                                    Text(item.name)
                                        .font(.system(size: 12.5))
                                    Spacer()
                                    Text(item.id)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if selected.contains(item.id) {
                                        selected.remove(item.id)
                                    } else {
                                        selected.insert(item.id)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(height: 220)
                }
            }
            
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                if case .loaded = state, !candidates.isEmpty {
                    Button("添加 \(selected.count) 个") {
                        onAdd(candidates.filter { selected.contains($0.id) })
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 470)
        .task { await load() }
    }
    
    private func load() async {
        do {
            let discovered = try await ModelDiscovery.fetchModels(for: provider)
            let existing = Set(provider.models.map(\.modelName))
            candidates = discovered.filter { !existing.contains($0.id) }
            selected = Set(candidates.map(\.id))
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
