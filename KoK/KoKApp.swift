//
//  KoKApp.swift
//  KoK
//
//  Created by Kakar on 2025/12/3.
//

import SwiftUI
import HotKey
import ServiceManagement

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
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 注册全局快捷键（每个动作一个）
        HotKeyManager.shared.handlers[.translate] = {
            WindowManager.shared.toggleTranslation()
        }
        HotKeyManager.shared.handlers[.chat] = {
            ChatPanelController.shared.toggleChat()
        }
        
        // 2. 初始化状态栏
        setupStatusBar()
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
            // 左键点击 → 打开设置
            openSettings()
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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
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
