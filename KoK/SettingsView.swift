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
import ApplicationServices

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

// MARK: - 分组表单的说明文字

/// 统一左对齐：默认的 footer 会被带到右侧那一列，看起来参差不齐
struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }
    
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tab 1: 通用设置

struct GeneralSettingsTab: View {
    @AppStorage("voice_locale") private var voiceLocale = VoiceLocale.chinese.rawValue
    @AppStorage("keep_conversation") private var keepConversation = false
    
    @State private var launchAtLogin: Bool = {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }()
    
    @State private var voiceAuthorized = false
    @State private var screenRecordingAuthorized = false
    @State private var axTrusted = false
    
    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent(action.title) {
                            ShortcutRecorder(action: action)
                        }
                        if let hint = action.hint {
                            Text(hint)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("快捷键")
            } footer: {
                SettingsFooter("翻译是主入口：选中文字按一下直接翻译；对话是合并键——点按打开、按住说话。没反应时点「测试」。")
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
                
                if !axTrusted {
                    permissionRow("需要「辅助功能」权限（读取选中文字）") {
                        requestAXPermission()
                    }
                }
            } header: {
                Text("权限")
            } footer: {
                SettingsFooter("语音识别在本机完成，录音不出设备。")
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
            
            Section {
                Toggle("退出后保留当前对话", isOn: $keepConversation)
                    .onChange(of: keepConversation) { _, newValue in
                        if !newValue {
                            ConversationStore.shared.delete()
                        }
                    }
            } header: {
                Text("对话记录")
            } footer: {
                SettingsFooter("默认关闭：对话只存在内存里。打开后存到本机，下次启动恢复；"
                     + "点「新对话」或关掉开关即删除（截图 / 参考图不会被保存）。")
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
        axTrusted = AXIsProcessTrusted()
    }
    
    private func requestVoicePermission() {
        Task {
            _ = await VoiceInputService.requestPermissions()
            refreshPermissions()
        }
    }
    
    /// 弹系统的辅助功能授权框；已经弹过仍没授权时，降级为打开系统设置
    private func requestAXPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        refreshPermissions()
        if !trusted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
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
        return shortcut.displayString
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
