//
//  SettingsView.swift
//  KoK
//
//  Created by Kakar on 2025/12/4.
//

import SwiftUI
import HotKey
import Carbon
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            // Tab 1: 通用
            GeneralSettingsTab()
                .tabItem { Label("通用", systemImage: "gear") }
            
            // Tab 2: 引擎管理
            EngineSettingsTab()
                .tabItem { Label("引擎", systemImage: "server.rack") }
            
            // Tab 3: 提示词
            PromptSettingsTab()
                .tabItem { Label("提示词", systemImage: "text.bubble") }
        }
        .frame(width: 560, height: 420)
    }
}

// MARK: - Tab 1: 通用设置

struct GeneralSettingsTab: View {
    @State private var launchAtLogin: Bool = {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("快捷键设置")
                .font(.headline)
            
            Divider()
            
            HStack {
                Text("翻译快捷键:")
                Spacer()
                ShortcutRecorder()
            }
            
            Text("点击上方按钮，然后按下你想要的快捷键组合。")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider()
            
            Toggle("开机自动启动", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    if #available(macOS 13.0, *) {
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            print("开机自启动设置失败: \(error)")
                            launchAtLogin = !newValue
                        }
                    }
                }
            
            Spacer()
        }
        .padding()
    }
}

// MARK: - Tab 2: 引擎管理

struct EngineSettingsTab: View {
    @ObservedObject var manager = EngineManager.shared
    @State private var selectedId: UUID?
    @State private var showingAddSheet = false
    @State private var showingBatchSheet = false
    
    var body: some View {
        HSplitView {
            // 左侧：引擎列表
            VStack(spacing: 0) {
                List(manager.engines, selection: $selectedId) { engine in
                    HStack {
                        Circle()
                            .fill(engine.isEnabled ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.name)
                                .font(.system(size: 13, weight: .medium))
                            Text(engine.type.rawValue)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if engine.id == manager.selectedEngineId {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.blue)
                                .font(.system(size: 12))
                        }
                    }
                    .tag(engine.id)
                    .contentShape(Rectangle())
                }
                .listStyle(.sidebar)
                
                Divider()
                
                // 底部操作栏
                HStack(spacing: 8) {
                    // 添加单个
                    Button(action: { showingAddSheet = true }) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    
                    // 批量添加
                    Button(action: { showingBatchSheet = true }) {
                        Image(systemName: "square.stack.3d.up")
                    }
                    .buttonStyle(.plain)
                    .help("批量添加（腾讯云等）")
                    
                    Button(action: deleteSelected) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedId == nil)
                    
                    Spacer()
                    
                    Button("设为默认") {
                        if let id = selectedId {
                            manager.selectEngine(id: id)
                        }
                    }
                    .font(.caption)
                    .disabled(selectedId == nil)
                }
                .padding(8)
            }
            .frame(minWidth: 180, maxWidth: 200)
            
            // 右侧：编辑区
            if let id = selectedId, let engine = manager.engines.first(where: { $0.id == id }) {
                EngineEditView(engine: engine)
            } else {
                VStack {
                    Spacer()
                    Text("选择或添加一个引擎")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddEngineSheet { newEngine in
                manager.addEngine(newEngine)
                selectedId = newEngine.id
            }
        }
        .sheet(isPresented: $showingBatchSheet) {
            BatchAddSheet { newEngines in
                for engine in newEngines {
                    manager.addEngine(engine)
                }
                selectedId = newEngines.first?.id
            }
        }
    }
    
    func deleteSelected() {
        guard let id = selectedId else { return }
        manager.deleteEngine(id: id)
        selectedId = manager.engines.first?.id
    }
}

// MARK: - 引擎编辑视图

struct EngineEditView: View {
    let engine: EngineConfig
    @ObservedObject var manager = EngineManager.shared
    
    @State private var name: String = ""
    @State private var type: EngineConfig.EngineType = .openAICompatible
    @State private var apiURL: String = ""
    @State private var apiKey: String = ""
    @State private var modelName: String = ""
    @State private var systemPrompt: String = ""
    @State private var isEnabled: Bool = true
    @State private var showSaved: Bool = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Group {
                    field("名称", text: $name)
                    
                    HStack {
                        Text("类型:")
                            .frame(width: 70, alignment: .trailing)
                        Picker("", selection: $type) {
                            ForEach(EngineConfig.EngineType.allCases, id: \.self) { t in
                                Text(t.rawValue).tag(t)
                            }
                        }
                        .labelsHidden()
                    }
                    
                    field("API URL", text: $apiURL)
                    secureField("API Key", text: $apiKey)
                    
                    if type != .deepL {
                        field("模型名", text: $modelName)
                    }
                }
                
                if type != .deepL {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自定义提示词（留空则使用全局提示词）:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $systemPrompt)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 70)
                            .border(Color.gray.opacity(0.3))
                    }
                    .padding(.leading, 74)
                    
                    Text("可用变量: {{TARGET_LANG}} = 目标语言")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.leading, 74)
                }
                
                HStack {
                    Toggle("启用", isOn: $isEnabled)
                    Spacer()
                    if showSaved {
                        Text("已保存")
                            .font(.caption)
                            .foregroundColor(.green)
                            .transition(.opacity)
                    }
                    Button("保存") { save() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.leading, 74)
            }
            .padding()
        }
        .onAppear { loadFromEngine() }
        .onChange(of: engine.id) { _, _ in loadFromEngine() }
    }
    
    func loadFromEngine() {
        name = engine.name
        type = engine.type
        apiURL = engine.apiURL
        apiKey = engine.apiKey
        modelName = engine.modelName
        systemPrompt = engine.systemPrompt
        isEnabled = engine.isEnabled
    }
    
    func save() {
        var updated = engine
        updated.name = name
        updated.type = type
        updated.apiURL = apiURL
        updated.apiKey = apiKey
        updated.modelName = modelName
        updated.systemPrompt = systemPrompt
        updated.isEnabled = isEnabled
        manager.updateEngine(updated)
        
        withAnimation { showSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { self.showSaved = false }
        }
    }
    
    @ViewBuilder
    func field(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text("\(title):")
                .frame(width: 70, alignment: .trailing)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
    
    @ViewBuilder
    func secureField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text("\(title):")
                .frame(width: 70, alignment: .trailing)
            SecureField("", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - 添加引擎弹窗

struct AddEngineSheet: View {
    var onAdd: (EngineConfig) -> Void
    @Environment(\.dismiss) var dismiss
    
    @State private var name = ""
    @State private var type: EngineConfig.EngineType = .openAICompatible
    @State private var apiURL = ""
    @State private var apiKey = ""
    @State private var modelName = ""
    
    // 根据类型提供 URL 占位提示
    var urlPlaceholder: String {
        switch type {
        case .deepL: return "https://api-free.deepl.com/v2/translate"
        case .openAICompatible: return "https://api.openai.com/v1/chat/completions"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/models/{{MODEL}}:generateContent"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加翻译引擎").font(.headline)
            
            HStack {
                Text("名称:").frame(width: 60, alignment: .trailing)
                TextField("如: GPT-4o / DeepSeek / 通义千问", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            
            HStack {
                Text("类型:").frame(width: 60, alignment: .trailing)
                Picker("", selection: $type) {
                    ForEach(EngineConfig.EngineType.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .labelsHidden()
            }
            
            HStack {
                Text("API URL:").frame(width: 60, alignment: .trailing)
                TextField(urlPlaceholder, text: $apiURL)
                    .textFieldStyle(.roundedBorder)
            }
            
            HStack {
                Text("API Key:").frame(width: 60, alignment: .trailing)
                SecureField("", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }
            
            if type != .deepL {
                HStack {
                    Text("模型名:").frame(width: 60, alignment: .trailing)
                    TextField("如: gpt-4o / deepseek-chat / qwen-turbo", text: $modelName)
                        .textFieldStyle(.roundedBorder)
                }
            }
            
            Text("OpenAI 兼容类型支持: OpenAI, 腾讯云 Token Plan, DeepSeek, 通义千问, Moonshot, 智谱 等\n腾讯云 Token Plan URL: api.lkeap.cloud.tencent.com/plan/v3/chat/completions")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加") {
                    let engine = EngineConfig(
                        id: UUID(),
                        name: name,
                        type: type,
                        apiURL: apiURL.isEmpty ? urlPlaceholder : apiURL,
                        apiKey: apiKey,
                        modelName: modelName,
                        systemPrompt: type == .deepL ? "" : EngineConfig.defaultSystemPrompt,
                        isEnabled: true
                    )
                    onAdd(engine)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || apiKey.isEmpty)
            }
        }
        .padding()
        .frame(width: 480)
    }
}

// MARK: - 批量添加引擎弹窗

struct BatchAddSheet: View {
    var onAdd: ([EngineConfig]) -> Void
    @Environment(\.dismiss) var dismiss
    
    @State private var apiKey = ""
    @State private var selectedProvider = Provider.tencentCloud
    @State private var selectedModels: Set<String> = []
    
    enum Provider: String, CaseIterable {
        case tencentCloud = "腾讯云 Token Plan"
        case openAI = "OpenAI"
        case deepSeek = "DeepSeek"
        case zhipu = "智谱 AI"
        case moonshot = "Moonshot"
    }
    
    // 预设平台信息
    struct ProviderInfo {
        let apiURL: String
        let models: [(name: String, displayName: String)]
    }
    
    var providerInfo: ProviderInfo {
        switch selectedProvider {
        case .tencentCloud:
            return ProviderInfo(
                apiURL: "https://api.lkeap.cloud.tencent.com/plan/v3/chat/completions",
                models: [
                    // 通用 Token Plan
                    ("tc-code-latest", "Auto（智能路由）"),
                    ("minimax-m2.5", "MiniMax M2.5"),
                    ("minimax-m2.7", "MiniMax M2.7"),
                    ("glm-5", "GLM-5"),
                    ("glm-5.1", "GLM-5.1"),
                    ("kimi-k2.5", "Kimi K2.5"),
                    ("hunyuan-2.0-instruct", "混元 2.0 Instruct"),
                    ("hunyuan-2.0-thinking", "混元 2.0 Think"),
                    ("hunyuan-t1", "混元 T1"),
                    ("hunyuan-turbo", "混元 TurboS"),
                    // Hy Token Plan
                    ("hy3-preview", "混元 Hy3 Preview"),
                ]
            )
        case .openAI:
            return ProviderInfo(
                apiURL: "https://api.openai.com/v1/chat/completions",
                models: [
                    ("gpt-4o", "GPT-4o"),
                    ("gpt-4o-mini", "GPT-4o Mini"),
                    ("gpt-4-turbo", "GPT-4 Turbo"),
                    ("gpt-3.5-turbo", "GPT-3.5 Turbo"),
                ]
            )
        case .deepSeek:
            return ProviderInfo(
                apiURL: "https://api.deepseek.com/chat/completions",
                models: [
                    ("deepseek-chat", "DeepSeek Chat (V3)"),
                    ("deepseek-reasoner", "DeepSeek Reasoner (R1)"),
                ]
            )
        case .zhipu:
            return ProviderInfo(
                apiURL: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
                models: [
                    ("glm-4-plus", "GLM-4 Plus"),
                    ("glm-4-flash", "GLM-4 Flash（免费）"),
                    ("glm-4", "GLM-4"),
                ]
            )
        case .moonshot:
            return ProviderInfo(
                apiURL: "https://api.moonshot.cn/v1/chat/completions",
                models: [
                    ("moonshot-v1-8k", "Moonshot V1 8K"),
                    ("moonshot-v1-32k", "Moonshot V1 32K"),
                    ("moonshot-v1-128k", "Moonshot V1 128K"),
                ]
            )
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("批量添加引擎").font(.headline)
            
            // 平台选择
            HStack {
                Text("平台:").frame(width: 60, alignment: .trailing)
                Picker("", selection: $selectedProvider) {
                    ForEach(Provider.allCases, id: \.self) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .labelsHidden()
            }
            .onChange(of: selectedProvider) { _, _ in
                selectedModels.removeAll()
            }
            
            // API Key
            HStack {
                Text("API Key:").frame(width: 60, alignment: .trailing)
                SecureField("填入你的 API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }
            
            Divider()
            
            // 模型勾选列表
            Text("选择要添加的模型:")
                .font(.subheadline)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // 全选按钮
                    HStack {
                        Button(selectAllTitle) {
                            if selectedModels.count == providerInfo.models.count {
                                selectedModels.removeAll()
                            } else {
                                selectedModels = Set(providerInfo.models.map { $0.name })
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundColor(.blue)
                        
                        Spacer()
                        
                        Text("已选 \(selectedModels.count)/\(providerInfo.models.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    ForEach(providerInfo.models, id: \.name) { model in
                        HStack {
                            Image(systemName: selectedModels.contains(model.name) ? "checkmark.square.fill" : "square")
                                .foregroundColor(selectedModels.contains(model.name) ? .blue : .secondary)
                            VStack(alignment: .leading) {
                                Text(model.displayName)
                                    .font(.system(size: 13))
                                Text(model.name)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedModels.contains(model.name) {
                                selectedModels.remove(model.name)
                            } else {
                                selectedModels.insert(model.name)
                            }
                        }
                    }
                }
            }
            .frame(height: 160)
            
            // 底部按钮
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加 \(selectedModels.count) 个引擎") {
                    let engines = providerInfo.models
                        .filter { selectedModels.contains($0.name) }
                        .map { model in
                            EngineConfig(
                                id: UUID(),
                                name: model.displayName,
                                type: .openAICompatible,
                                apiURL: providerInfo.apiURL,
                                apiKey: apiKey,
                                modelName: model.name,
                                systemPrompt: EngineConfig.defaultSystemPrompt,
                                isEnabled: true
                            )
                        }
                    onAdd(engines)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.isEmpty || selectedModels.isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }
    
    var selectAllTitle: String {
        selectedModels.count == providerInfo.models.count ? "取消全选" : "全选"
    }
}

// MARK: - Tab 3: 提示词设置

struct PromptSettingsTab: View {
    @ObservedObject var manager = EngineManager.shared
    @State private var showSaved = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("全局系统提示词")
                .font(.headline)
            
            Text("此提示词将应用于所有 LLM 引擎（DeepL 除外）。\n留空则使用各引擎自己的提示词。")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider()
            
            TextEditor(text: $manager.globalSystemPrompt)
                .font(.system(size: 12, design: .monospaced))
                .border(Color.gray.opacity(0.3))
            
            HStack {
                Text("可用变量: {{TARGET_LANG}} = 目标语言名称")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if showSaved {
                    Text("已保存")
                        .font(.caption)
                        .foregroundColor(.green)
                        .transition(.opacity)
                }
                
                Button("恢复默认") {
                    manager.globalSystemPrompt = EngineConfig.defaultSystemPrompt
                }
                .font(.caption)
                
                Button("保存") {
                    // globalSystemPrompt 通过 Combine sink 自动持久化，这里触发反馈
                    UserDefaults.standard.set(manager.globalSystemPrompt, forKey: "global_system_prompt")
                    withAnimation { showSaved = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { showSaved = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .font(.caption)
            }
        }
        .padding()
    }
}

// MARK: - 快捷键录制器

struct ShortcutRecorder: View {
    @ObservedObject var manager = HotKeyManager.shared
    @State private var isRecording = false
    
    var keyString: String {
        guard let key = manager.currentKey, let modifiers = manager.currentModifiers else {
            return "未设置"
        }
        return "\(modifiersString(modifiers))\(keyName(for: key))"
    }
    
    var body: some View {
        Button(action: {
            startRecording()
        }) {
            Text(isRecording ? "请输入快捷键..." : keyString)
                .frame(width: 140)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .blue : .primary)
        .background(KeyMonitor(isRecording: $isRecording))
    }
    
    func startRecording() {
        isRecording = true
        manager.pause()
    }
    
    func modifiersString(_ modifiers: NSEvent.ModifierFlags) -> String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result
    }
    
    func keyName(for key: Key) -> String {
        let mapping: [Key: String] = [
            .a: "A", .b: "B", .c: "C", .d: "D", .e: "E", .f: "F",
            .g: "G", .h: "H", .i: "I", .j: "J", .k: "K", .l: "L",
            .m: "M", .n: "N", .o: "O", .p: "P", .q: "Q", .r: "R",
            .s: "S", .t: "T", .u: "U", .v: "V", .w: "W", .x: "X",
            .y: "Y", .z: "Z",
            .zero: "0", .one: "1", .two: "2", .three: "3", .four: "4",
            .five: "5", .six: "6", .seven: "7", .eight: "8", .nine: "9",
            .space: "Space", .return: "Return", .tab: "Tab", .escape: "Esc",
            .delete: "Delete", .forwardDelete: "Fwd Del",
            .upArrow: "↑", .downArrow: "↓", .leftArrow: "←", .rightArrow: "→",
            .f1: "F1", .f2: "F2", .f3: "F3", .f4: "F4", .f5: "F5",
            .f6: "F6", .f7: "F7", .f8: "F8", .f9: "F9", .f10: "F10",
            .f11: "F11", .f12: "F12",
        ]
        return mapping[key] ?? String(describing: key).uppercased()
    }
}

// MARK: - 键盘事件监听器

struct KeyMonitor: NSViewRepresentable {
    @Binding var isRecording: Bool
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if isRecording {
            nsView.window?.makeFirstResponder(nsView)
            
            if let oldMonitor = context.coordinator.monitor {
                NSEvent.removeMonitor(oldMonitor)
                context.coordinator.monitor = nil
            }
            
            context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    return event
                }
                
                let keyCode = event.keyCode
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                
                if let key = Key(carbonKeyCode: UInt32(keyCode)) {
                    HotKeyManager.shared.register(key: key, modifiers: modifiers)
                }
                
                DispatchQueue.main.async {
                    self.isRecording = false
                }
                
                return nil
            }
        } else {
            if let monitor = context.coordinator.monitor {
                NSEvent.removeMonitor(monitor)
                context.coordinator.monitor = nil
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var monitor: Any?
    }
}
