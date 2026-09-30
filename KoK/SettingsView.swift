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
    @AppStorage("voice_locale") private var voiceLocale = VoiceLocale.chinese.rawValue
    
    @State private var launchAtLogin: Bool = {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }()
    
    @State private var voiceAuthorized = false
    @State private var screenRecordingAuthorized = false
    
    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(action: action)
                    }
                }
            } header: {
                Text("快捷键")
            } footer: {
                Text("翻译读取选中文字，对话开输入框，语音按住说话，截图框选屏幕。没反应时点「测试」。")
            }
            
            Section {
                Picker("识别语言", selection: $voiceLocale) {
                    ForEach(VoiceLocale.allCases) { locale in
                        Text(locale.title).tag(locale.rawValue)
                    }
                }
                
                if !voiceAuthorized {
                    permissionRow("需要麦克风与语音识别权限") {
                        requestVoicePermission()
                    }
                }
                
                if !screenRecordingAuthorized {
                    permissionRow("需要屏幕录制权限（截图用）") {
                        ScreenshotCapture.requestPermission()
                        refreshPermissions()
                    }
                }
            } header: {
                Text("语音与截图")
            } footer: {
                Text("语音识别在本机完成，录音不出设备。")
            }
            
            Section {
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
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshPermissions() }
    }
    
    @ViewBuilder
    private func permissionRow(_ title: String, request: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
            Spacer()
            Button("去授权", action: request)
                .controlSize(.small)
        }
    }
    
    private func refreshPermissions() {
        voiceAuthorized = VoiceInputService.microphoneAuthorized && VoiceInputService.speechAuthorized
        screenRecordingAuthorized = ScreenshotCapture.hasPermission
    }
    
    private func requestVoicePermission() {
        Task {
            _ = await VoiceInputService.requestPermissions()
            refreshPermissions()
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
                    Label("未收到", systemImage: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .help("这个组合可能被其它 App 占用了，换一个再试")
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
