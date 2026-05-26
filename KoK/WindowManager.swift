//
//  WindowManager.swift
//  KoK
//
//  Created by Kakar on 2025/12/3.
//

import AppKit
import SwiftUI
import Carbon
import ServiceManagement

@MainActor
class WindowManager: NSObject {
    static let shared = WindowManager()
    
    var panel: NSPanel?
    var viewModel = TranslationViewModel()
    
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var isVisible: Bool { panel?.isVisible ?? false }
    
    private override init() {
        super.init()
        setupPanel()
    }
    
    func setupPanel() {
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel?.level = .floating
        panel?.backgroundColor = .clear
        panel?.isOpaque = false
        panel?.hasShadow = true
        panel?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel?.hidesOnDeactivate = false
        panel?.minSize = NSSize(width: 300, height: 100)
        panel?.maxSize = NSSize(width: 800, height: 800)
        
        var contentView = TranslationView(viewModel: viewModel)
        
        contentView.onHeightChange = { [weak self] newHeight in
            self?.updateWindowFrame(height: newHeight)
        }
        
        contentView.onReplace = { [weak self] in
            self?.replaceSelection()
        }
        
        // #1: 关闭按钮回调
        contentView.onDismiss = { [weak self] in
            self?.hideWindow()
        }
        
        panel?.contentView = NSHostingView(rootView: contentView)
    }
    
    func updateWindowFrame(height: CGFloat) {
        guard let panel = panel else { return }
        let currentFrame = panel.frame
        let constrainedHeight = min(height, 600)
        let newY = currentFrame.origin.y + (currentFrame.height - constrainedHeight)
        let newFrame = NSRect(x: currentFrame.origin.x, y: newY, width: currentFrame.width, height: constrainedHeight)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().setFrame(newFrame, display: true)
        }
    }
    
    func replaceSelection() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(viewModel.translatedText, forType: .string)
        
        panel?.orderOut(nil)
        stopMonitors()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.simulatePasteCommand()
        }
    }
    
    // MARK: - 核心逻辑
    
    func toggleTranslation() {
        // #9: 如果面板已显示，再次触发快捷键则关闭
        if isVisible {
            hideWindow()
            return
        }
        
        // 1. 检查辅助功能权限
        if !checkAccessibilityPermissions() {
            print("缺少辅助功能权限")
            return
        }

        // 2. 记录旧的 changeCount
        let pasteboard = NSPasteboard.general
        let oldChangeCount = pasteboard.changeCount
        
        // 3. 模拟复制
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.simulateCopyCommand()
            self.checkClipboardChange(oldChangeCount: oldChangeCount, attempt: 0)
        }
    }
    
    private func checkAccessibilityPermissions() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        return accessEnabled
    }
    
    private func checkClipboardChange(oldChangeCount: Int, attempt: Int) {
        let pasteboard = NSPasteboard.general
        
        if pasteboard.changeCount != oldChangeCount {
            if let copiedText = pasteboard.string(forType: .string), !copiedText.isEmpty {
                self.viewModel.translate(text: copiedText)
                self.showWindow()
            }
            return
        }
        
        // #5: 超时后在面板中显示友好提示
        if attempt > 20 {
            self.viewModel.showNoTextError()
            self.showWindow()
            return
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.checkClipboardChange(oldChangeCount: oldChangeCount, attempt: attempt + 1)
        }
    }
    
    // #8: 智能定位，防止超出屏幕
    func showWindow() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let mouseLoc = NSEvent.mouseLocation
        let screenFrame = screen.visibleFrame
        let panelWidth: CGFloat = 400
        let panelHeight: CGFloat = max(panel.frame.height, 100)
        
        var x = mouseLoc.x + 10
        var y = mouseLoc.y - panelHeight
        
        // 右侧超出 → 弹到左边
        if x + panelWidth > screenFrame.maxX {
            x = mouseLoc.x - panelWidth - 10
        }
        // 左侧超出 → 贴左边
        if x < screenFrame.minX {
            x = screenFrame.minX + 5
        }
        // 底部超出 → 弹到上方
        if y < screenFrame.minY {
            y = mouseLoc.y + 10
        }
        // 顶部超出
        if y + panelHeight > screenFrame.maxY {
            y = screenFrame.maxY - panelHeight
        }
        
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        
        startMonitors()
    }
    
    func hideWindow() {
        panel?.orderOut(nil)
        stopMonitors()
    }
    
    // MARK: - 事件监听
    
    private func startMonitors() {
        stopMonitors()
        
        // 全局点击关闭
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hideWindow()
        }
        
        // #1: Esc 键关闭
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.hideWindow()
                return nil
            }
            return event
        }
    }
    
    private func stopMonitors() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
    
    // MARK: - 键盘模拟
    
    private func simulateCopyCommand() {
        let source = CGEventSource(stateID: .hidSystemState)
        let cmdKey: CGKeyCode = 0x37
        let cKey: CGKeyCode = 0x08
        
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true) else { return }
        cmdDown.flags = .maskCommand
        cmdDown.post(tap: .cghidEventTap)
        
        guard let cDown = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true) else { return }
        cDown.flags = .maskCommand
        cDown.post(tap: .cghidEventTap)
        
        guard let cUp = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false) else { return }
        cUp.flags = .maskCommand
        cUp.post(tap: .cghidEventTap)
        
        guard let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false) else { return }
        cmdUp.flags = []
        cmdUp.post(tap: .cghidEventTap)
    }
    
    private func simulatePasteCommand() {
        let source = CGEventSource(stateID: .hidSystemState)
        let cmdKey: CGKeyCode = 0x37
        let vKey: CGKeyCode = 0x09
        
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true)
        cmdDown?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        vDown?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        vUp?.flags = .maskCommand
        vUp?.post(tap: .cghidEventTap)
        
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)
        cmdUp?.flags = []
        cmdUp?.post(tap: .cghidEventTap)
    }
}
