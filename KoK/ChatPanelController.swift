//
//  ChatPanelController.swift
//  KoK
//
//  快速问答面板的窗口控制器。面板行为全部复用 `PanelController` 基类。
//
//  快捷键语义：同一个键，点按打开面板，按住说话。
//

import AppKit
import SwiftUI

@MainActor
final class ChatPanelController: PanelController {
    static let shared = ChatPanelController()
    
    let viewModel = ChatViewModel()
    
    override var preferredWidth: CGFloat { 460 }
    override var persistenceKey: String { "chat" }
    override var wantsSizePersistence: Bool { true }
    override var preferredHeight: CGFloat { 420 }
    override var minimumSize: NSSize { NSSize(width: 360, height: 240) }
    override var maximumSize: NSSize { NSSize(width: 1000, height: 1000) }
    
    /// 点按与按住的分界。快速点按通常 50–150ms，刻意按住一般超过 250ms。
    private static let holdThreshold: TimeInterval = 0.18
    
    /// 「刚过阈值就松手」的宽限：录了不到这么久且没识别到内容，按慢速点按处理
    private static let slowTapGrace: TimeInterval = 0.5
    
    private var holdTask: Task<Void, Never>?
    private var isHolding = false
    
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
        
        viewModel.onNeedsForeground = { [weak self] in
            // 抓取阶段结束后再显示并激活面板：
            // 显示早了会被截进图里，激活早了会抢走原 App 的焦点
            self?.showWindow(activate: true)
        }
        
        onWillShow = {
            // 只做与翻译面板的互斥，焦点统一由 openChat / 语音流程处理
            WindowManager.shared.hideWindow()
        }
        
        // Esc：先关图片预览，没有预览才收面板
        onEscape = { [weak self] in
            guard let self else { return }
            if self.viewModel.previewImage != nil {
                self.viewModel.closePreview()
            } else {
                self.hideWindow()
            }
        }
    }
    
    // MARK: - 打开（点按 / 左键 / 菜单）
    
    /// 打开面板并聚焦输入框。已可见时只聚焦、不关闭——
    /// 否则「按住问完 → 点按追问」会变成把面板关了。
    func openChat() {
        if !isVisible {
            showWindow(activate: true)
        } else {
            panel?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        viewModel.requestFocus()
    }
    
    // MARK: - 合并键：点按 / 按住
    
    /// 按下：面板先以不抢焦点的方式弹出（按住时要模拟 ⌘C，焦点必须留在原 App），
    /// 同时启动判别计时器。
    func chatKeyDown() {
        guard !isHolding else { return }
        
        showWindow(activate: false, makeKey: false)
        
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.holdThreshold * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isHolding = true
            self?.viewModel.beginVoice(captureSelection: true)
        }
    }
    
    /// 松开：按住了就结束录音发送；没按住就是点按，补上焦点。
    func chatKeyUp() {
        if isHolding {
            isHolding = false
            
            // 刚过阈值就松手、又没识别到内容：其实是慢速点按，别弹「没听清」
            if viewModel.voice.transcript.isEmpty
                && viewModel.voice.recordingDuration < Self.slowTapGrace {
                viewModel.cancelVoice()
                focusPanel()
            } else {
                viewModel.endVoiceAndSend()
            }
        } else {
            holdTask?.cancel()
            holdTask = nil
            focusPanel()
        }
    }
    
    private func focusPanel() {
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        viewModel.requestFocus()
    }
    
    // MARK: - 截图
    
    /// 框选屏幕区域作为上下文。截图期间不显示面板，免得被截进去。
    func captureScreenshot() {
        viewModel.captureScreenshot()
    }
}
