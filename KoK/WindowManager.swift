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

/// 翻译面板控制器。
/// 面板创建、定位、点击外部/Esc 关闭等通用行为都在 `PanelController` 基类里。
@MainActor
final class WindowManager: PanelController {
    static let shared = WindowManager()
    
    var viewModel = TranslationViewModel()
    
    private override init() {
        super.init()
        setupPanel()
    }
    
    private func setupPanel() {
        makePanel()
        
        var contentView = TranslationView(viewModel: viewModel)
        
        contentView.onHeightChange = { [weak self] newHeight in
            self?.updateWindowFrame(height: newHeight)
        }
        
        contentView.onReplace = { [weak self] in
            self?.replaceSelection()
        }
        
        contentView.onDismiss = { [weak self] in
            self?.hideWindow()
        }
        
        installContent(contentView)
        
        // 与对话面板互斥
        onWillShow = {
            ChatPanelController.shared.hideWindow()
        }
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
    
    /// 复制当前选中文本并翻译。#9: 若面板已显示，再次触发则关闭
    func toggleTranslation() {
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
