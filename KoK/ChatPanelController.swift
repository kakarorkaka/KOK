//
//  ChatPanelController.swift
//  KoK
//
//  快速问答面板的窗口控制器。面板行为全部复用 `PanelController` 基类。
//

import AppKit
import SwiftUI

@MainActor
final class ChatPanelController: PanelController {
    static let shared = ChatPanelController()
    
    let viewModel = ChatViewModel()
    
    override var preferredWidth: CGFloat { 460 }
    override var preferredHeight: CGFloat { 420 }
    override var minimumSize: NSSize { NSSize(width: 360, height: 240) }
    override var maximumSize: NSSize { NSSize(width: 1000, height: 1000) }
    
    private override init() {
        super.init()
        setupPanel()
    }
    
    private func setupPanel() {
        makePanel()
        
        var contentView = ChatView(viewModel: viewModel)
        contentView.onDismiss = { [weak self] in
            self?.hideWindow()
        }
        installContent(contentView)
        
        viewModel.onVoiceReadyToSend = { [weak self] in
            self?.activatePanel()
        }
        
        onWillShow = {
            // 只做与翻译面板的互斥。焦点交给输入框放在 toggleChat 里做——
            // 语音路径不能抢焦点，否则模拟 ⌘C 抓不到原 App 选中的内容。
            WindowManager.shared.hideWindow()
        }
    }
    
    func toggleChat() {
        if isVisible {
            hideWindow()
            return
        }
        showWindow(activate: true)
        viewModel.requestFocus()
    }
    
    // MARK: - 按住说话
    
    /// 按下快捷键：面板以「不抢焦点」的方式弹出（否则模拟 ⌘C 会抓不到原 App 的选中内容），
    /// 同时立刻开始录音——用户按下时已经在说话了。
    func beginVoice() {
        // 不激活 App：原 App 保持焦点，稍后模拟 ⌘C 才能抓到它的选中内容
        showWindow(activate: false)
        viewModel.beginVoice(captureSelection: true)
    }
    
    /// 松开快捷键：结束录音，连同选中内容一起发送
    func endVoice() {
        viewModel.endVoiceAndSend()
    }
    
    /// 把面板提到前台（只在选中内容已经抓完之后调用）
    private func activatePanel() {
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
