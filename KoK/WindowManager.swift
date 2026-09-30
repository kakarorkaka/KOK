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
    private var captureTask: Task<Void, Never>?
    
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
        
        contentView.onFollowUp = { [weak self] in
            guard let self else { return }
            ChatPanelController.shared.viewModel.followUp(
                source: self.viewModel.sourceText,
                translated: self.viewModel.translatedText
            )
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
    
    /// 复制当前选中文本并翻译。面板已显示时再次触发则关闭。
    func toggleTranslation() {
        if isVisible {
            hideWindow()
            return
        }
        
        if !checkAccessibilityPermissions() {
            print("缺少辅助功能权限")
            return
        }
        
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            guard let self else { return }
            
            // 等一下让快捷键的修饰键先松开，否则 ⌘C 会和它叠加
            try? await Task.sleep(nanoseconds: 50_000_000)
            
            let capture = await SelectionProvider.capture()
            
            guard !Task.isCancelled else { return }
            
            if let text = capture.text {
                self.viewModel.translate(text: text)
            } else {
                // 选中的是图片，或者根本没选中
                self.viewModel.showNoTextError()
            }
            self.showWindow()
        }
    }
    
    private func checkAccessibilityPermissions() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        return accessEnabled
    }
    
    // MARK: - 键盘模拟（替换原文用）
    
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
