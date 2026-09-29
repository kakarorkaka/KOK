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
    @State private var promptDraft = ""
    @State private var showingAddModel = false
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
                    
                    Button {
                        showingAddModel = true
                    } label: {
                        Label("添加模型", systemImage: "plus")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                } header: {
                    Text("模型")
                } footer: {
                    Text("勾选的模型会出现在「翻译引擎 / 对话引擎」的选择列表里。\n「译」「聊」用来指定该模型作为哪个用途的默认。")
                }
            }
            
            // ── 高级 ──────────────────────────────────────────
            Section {
                DisclosureGroup("高级") {
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
                    
                    LabeledContent("接口地址") {
                        TextField("", text: $urlDraft)
                            .onChange(of: urlDraft) { _, value in
                                guard value != provider.apiURL else { return }
                                mutate { $0.apiURL = value }
                                testState = .idle
                            }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("专属提示词（留空则用全局提示词）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $promptDraft)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 64)
                            .border(Color.secondary.opacity(0.25))
                            .onChange(of: promptDraft) { _, value in
                                guard value != provider.systemPrompt else { return }
                                mutate { $0.systemPrompt = value }
                            }
                    }
                    
                    LabeledContent("Gemini 地址占位符") {
                        Text("{{MODEL}}")
                            .font(.system(size: 11, design: .monospaced))
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
        promptDraft = provider.systemPrompt
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
            systemPrompt: provider.systemPrompt,
            isEnabled: true
        )
        
        testState = .running
        
        Task {
            do {
                if provider.type == .deepL {
                    let result = try await UnifiedTranslationService()
                        .translate(text: "hello", to: "ZH", using: config)
                    testState = .ok("翻译正常：\(result.text.prefix(24))")
                } else {
                    let text = try await ChatService().complete(
                        messages: [ChatMessage(role: .user, content: "Reply with the single word: pong")],
                        using: config
                    )
                    testState = .ok("连接正常：\(text.prefix(24))")
                }
            } catch {
                testState = .failed(error.localizedDescription)
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
    @State private var selectedModels: Set<String> = []
    
    private var isCustom: Bool { template.id == ProviderCatalog.custom.id }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加服务商")
                .font(.headline)
            
            // 预设选择
            LabeledContent("服务商") {
                Picker("", selection: $template) {
                    ForEach(ProviderCatalog.all) { item in
                        Label(item.name, systemImage: item.symbol).tag(item)
                    }
                }
                .labelsHidden()
            }
            .onChange(of: template) { _, newValue in
                name = newValue.name == ProviderCatalog.custom.name ? "" : newValue.name
                apiURL = newValue.apiURL
                selectedModels = Set(newValue.models.map(\.id))
            }
            
            LabeledContent("名称") {
                TextField("给这个服务商起个名", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            
            LabeledContent("API Key") {
                SecureField(template.keyPlaceholder, text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }
            
            if isCustom {
                LabeledContent("接口地址") {
                    TextField("https://.../chat/completions", text: $apiURL)
                        .textFieldStyle(.roundedBorder)
                }
            } else if let note = template.note {
                Text(note)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            if !template.models.isEmpty {
                Divider()
                
                HStack {
                    Text("选择要启用的模型")
                        .font(.subheadline)
                    Spacer()
                    Button(selectedModels.count == template.models.count ? "取消全选" : "全选") {
                        if selectedModels.count == template.models.count {
                            selectedModels.removeAll()
                        } else {
                            selectedModels = Set(template.models.map(\.id))
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(template.models, id: \.id) { item in
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
                
                Text("已选 \(selectedModels.count)/\(template.models.count)")
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
        .frame(width: 460)
        .onAppear {
            name = template.name == ProviderCatalog.custom.name ? "" : template.name
            apiURL = template.apiURL
            selectedModels = Set(template.models.map(\.id))
        }
    }
    
    private var canAdd: Bool {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if isCustom { return !apiURL.isEmpty }
        return template.models.isEmpty || !selectedModels.isEmpty
    }
    
    private func toggle(_ id: String) {
        if selectedModels.contains(id) {
            selectedModels.remove(id)
        } else {
            selectedModels.insert(id)
        }
    }
    
    private func add() {
        let models: [ProviderModel]
        if isCustom {
            models = [ProviderModel(id: UUID(), name: name, modelName: name, isEnabled: true)]
        } else {
            models = template.models
                .filter { selectedModels.contains($0.id) }
                .map { ProviderModel(id: UUID(), name: $0.name, modelName: $0.id, isEnabled: true) }
        }
        
        onAdd(Provider(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            type: template.type,
            apiURL: apiURL,
            apiKey: apiKey,
            systemPrompt: "",
            isEnabled: true,
            models: models
        ))
        dismiss()
    }
}
