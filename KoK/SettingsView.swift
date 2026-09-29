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
        .frame(width: 720, height: 520)
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
                ShortcutRecorder(action: .translate)
            }
            
            HStack {
                Text("对话快捷键:")
                Spacer()
                ShortcutRecorder(action: .chat)
            }
            
            Text("点击上方按钮，然后按下你想要的快捷键组合。\n翻译会读取当前选中的文本；对话会直接弹出输入框。\n若快捷键没反应，多半是被 iShot 等工具占用，换一个组合后点「测试」验证。")
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

// MARK: - Tab 3: 提示词设置

struct PromptSettingsTab: View {
    @ObservedObject var manager = EngineManager.shared
    @State private var showSaved = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // --- 翻译提示词 ---
                Text("翻译系统提示词")
                    .font(.headline)
                
                Text("此提示词将应用于所有 LLM 翻译引擎（DeepL 除外）。\n留空则回退到内置默认提示词。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextEditor(text: $manager.globalSystemPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 110)
                    .border(Color.gray.opacity(0.3))
                
                HStack {
                    Text("可用变量: {{TARGET_LANG}} = 目标语言名称")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Button("恢复默认") {
                        manager.globalSystemPrompt = EngineConfig.defaultSystemPrompt
                    }
                    .font(.caption)
                }
                
                Divider()
                
                // --- 对话提示词 ---
                Text("对话系统提示词")
                    .font(.headline)
                
                Text("仅用于快速问答面板，与上面的翻译提示词互不影响。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextEditor(text: $manager.chatSystemPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 90)
                    .border(Color.gray.opacity(0.3))
                
                HStack {
                    Spacer()
                    
                    if showSaved {
                        Text("已保存")
                            .font(.caption)
                            .foregroundColor(.green)
                            .transition(.opacity)
                    }
                    
                    Button("恢复默认") {
                        manager.chatSystemPrompt = EngineConfig.defaultChatSystemPrompt
                    }
                    .font(.caption)
                    
                    Button("保存") {
                        // 两个提示词都通过 Combine sink 自动持久化，这里只是给个反馈
                        UserDefaults.standard.set(manager.globalSystemPrompt, forKey: "global_system_prompt")
                        UserDefaults.standard.set(manager.chatSystemPrompt, forKey: "chat_system_prompt")
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
}

// MARK: - 快捷键录制器

struct ShortcutRecorder: View {
    var action: HotKeyAction = .translate
    
    @ObservedObject var manager = HotKeyManager.shared
    @State private var isRecording = false
    @State private var testState: TestState = .idle
    
    private enum TestState: Equatable {
        case idle
        case waiting
        case passed
        case failed
    }
    
    var keyString: String {
        guard let shortcut = manager.shortcut(for: action) else {
            return "未设置"
        }
        return "\(modifiersString(shortcut.modifiers))\(keyName(for: shortcut.key))"
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Button(action: {
                startRecording()
            }) {
                Text(isRecording ? "请输入快捷键..." : keyString)
                    .frame(width: 140)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .blue : .primary)
            .background(KeyMonitor(isRecording: $isRecording, action: action))
            
            Button("测试") { startTest() }
                .font(.caption)
                .disabled(isRecording || testState == .waiting)
            
            Group {
                switch testState {
                case .idle:
                    EmptyView()
                case .waiting:
                    Text("请按下快捷键…")
                        .foregroundColor(.secondary)
                case .passed:
                    Label("生效", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                case .failed:
                    Label("未收到，可能被其它 App 占用", systemImage: "xmark.circle.fill")
                        .foregroundColor(.red)
                }
            }
            .font(.caption)
        }
    }
    
    /// macOS 不提供「快捷键是否被别的 App 占用」的查询接口，
    /// 注册冲突时也不会报错，所以只能让用户按一次来实测。
    private func startTest() {
        testState = .waiting
        
        HotKeyManager.shared.testObserver = { triggered in
            guard triggered == action else { return }
            HotKeyManager.shared.testObserver = nil
            testState = .passed
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if HotKeyManager.shared.testObserver != nil {
                HotKeyManager.shared.testObserver = nil
                testState = .failed
            }
        }
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
    var action: HotKeyAction = .translate
    
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
                    HotKeyManager.shared.register(action, key: key, modifiers: modifiers)
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
