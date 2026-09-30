//
//  KoKApp.swift
//  KoK
//
//  Created by Kakar on 2025/12/3.
//

import SwiftUI
import HotKey
import ServiceManagement
import ApplicationServices

@main
struct KoKApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    
    var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var onboardingPopover: NSPopover?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 引擎配置必须立刻加载：它负责把旧版扁平结构迁移成「服务商 → 模型」，
        //    越早跑越不容易和用户的首次操作撞上。实测耗时 < 10ms。
        _ = EngineManager.shared
        
        // 2. 注册全局快捷键（每个动作一个）
        HotKeyManager.shared.handlers[.translate] = {
            WindowManager.shared.toggleTranslation()
        }
        HotKeyManager.shared.handlers[.chat] = {
            ChatPanelController.shared.toggleChat()
        }
        // 按住说话：按下开录，松开发送
        HotKeyManager.shared.handlers[.voice] = {
            ChatPanelController.shared.beginVoice()
        }
        HotKeyManager.shared.releaseHandlers[.voice] = {
            ChatPanelController.shared.endVoice()
        }
        HotKeyManager.shared.handlers[.screenshot] = {
            ChatPanelController.shared.captureScreenshot()
        }
        
        // 3. 初始化状态栏
        setupStatusBar()
        
        // 3.5 首次启动引导
        showOnboardingIfNeeded()
        
        // 4. 面板预热：两个面板是「预创建 + 只做 Show/Hide」，
        //    创建一次实测约 420ms（对话面板 361ms + 翻译面板 62ms），之后唤出只要几毫秒。
        //    放到启动完成之后再异步做，状态栏就不会被这段开销拖慢；
        //    等用户第一次按下快捷键时，面板早已就绪。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            _ = WindowManager.shared
            _ = ChatPanelController.shared
        }
    }
    
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        guard let button = statusItem?.button else {
            return
        }
        
        // #4: 使用翻译相关图标
        button.image = NSImage(systemSymbolName: "character.book.closed.fill", accessibilityDescription: "KoK Translator")
        
        button.action = #selector(mouseClickHandler)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    
    @objc func mouseClickHandler(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        
        if event.type == .rightMouseUp {
            let menu = NSMenu()
            
            let chatItem = NSMenuItem(title: "打开对话", action: #selector(openChat), keyEquivalent: "")
            menu.addItem(chatItem)
            
            let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
            menu.addItem(settingsItem)
            
            menu.addItem(NSMenuItem.separator())
            
            let launchItem = NSMenuItem(title: "开机自启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            launchItem.state = isLaunchAtLoginEnabled() ? .on : .off
            menu.addItem(launchItem)
            
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            // 左键 → 打开对话（最高频动作）；设置收进右键菜单
            ChatPanelController.shared.toggleChat()
        }
    }
    
    /// 首次启动：在状态栏旁弹一个引导卡片，只出现一次
    private func showOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "onboarding_shown") else { return }
        UserDefaults.standard.set(true, forKey: "onboarding_shown")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let button = self.statusItem?.button else { return }
            
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(
                rootView: OnboardingView(
                    onOpenSettings: { [weak self] in
                        self?.onboardingPopover?.close()
                        self?.openSettings()
                    },
                    onDismiss: { [weak self] in
                        self?.onboardingPopover?.close()
                    }
                )
            )
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.onboardingPopover = popover
        }
    }
    
    @objc func openChat() {
        ChatPanelController.shared.toggleChat()
    }
    
    @objc func openSettings() {
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "KoK 设置"
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        
        settingsWindow = window
    }
    
    // #12: 开机自启动
    @objc func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if service.status == .enabled {
                    try service.unregister()
                } else {
                    try service.register()
                }
            } catch {
                print("开机自启动设置失败: \(error)")
            }
        }
    }
    
    func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }
    
    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

