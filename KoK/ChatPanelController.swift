//
//  ChatPanelController.swift
//  KoK
//
//  统一面板的窗口控制器（4.0：翻译面板与对话面板合并成一个）。
//
//  两个入口，同一个面板：
//  - ⌘2 → 抓取选中内容，按当前动作立即处理（翻译 / 总结 / 润色）
//  - ⌘3 → 点按打开面板问问题；按住说话（同一个键的点按/按住语义）
//
//  面板高度自适应内容：只有一张卡片时保持紧凑，聊起来才变高。
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
    override var minimumSize: NSSize { NSSize(width: 360, height: 260) }
    override var maximumSize: NSSize { NSSize(width: 1000, height: 1000) }
    
    /// 自适应高度的下限：再紧凑也要留出「一张卡片 + 输入栏」的余量
    private static let minAutoHeight: CGFloat = 260
    /// 内容高度还没测出来时的开场高度
    private static let defaultHeight: CGFloat = 420
    
    /// 点按与按住的分界。快速点按通常 50–150ms，刻意按住一般超过 250ms。
    private static let holdThreshold: TimeInterval = 0.18
    
    /// 「刚过阈值就松手」的宽限：录了不到这么久且没识别到内容，按慢速点按处理
    private static let slowTapGrace: TimeInterval = 0.5
    
    private var holdTask: Task<Void, Never>?
    private var isHolding = false
    
    /// 自适应高度的上限 = 用户手动拖到过的最大高度
    private var heightLimit: CGFloat = 560
    /// 最近一次由内容驱动的目标高度（用来区分「自动变高」和「用户拖动」）
    private var lastAppliedHeight: CGFloat?
    private var lastContentHeight: CGFloat?
    
    private static let heightLimitKey = "panel_height_limit_chat"
    
    private override init() {
        super.init()
        if let stored = UserDefaults.standard.object(forKey: Self.heightLimitKey) as? Double {
            heightLimit = CGFloat(stored)
        }
        heightLimit = max(heightLimit, Self.minAutoHeight)
        setupPanel()
    }
    
    private func setupPanel() {
        makePanel()
        
        var contentView = ChatView(viewModel: viewModel)
        contentView.onDismiss = { [weak self] in
            self?.hideWindow()
        }
        contentView.onContentHeightChange = { [weak self] height in
            self?.applyContentHeight(height)
        }
        installContent(contentView)
        
        viewModel.onNeedsForeground = { [weak self] in
            // 抓取阶段结束后再显示并激活面板：
            // 显示早了会被截进图里，激活早了会抢走原 App 的焦点
            self?.showWindow(activate: true)
        }
        
        viewModel.onRequestHide = { [weak self] in
            self?.hideWindow()
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
    
    // MARK: - 入口一：⌘2（抓取 → 立即处理）
    
    /// 抓取选中内容并按当前动作处理。抓取期间不主动显示面板，
    /// 免得把面板自己截进选区，也免得抢走原 App 的焦点。
    func triggerTransform() {
        viewModel.prepareForNewOpening()
        viewModel.activeAction = .translate
        viewModel.beginTransform()
    }
    
    // MARK: - 入口二：⌘3（点按打开 / 按住说话）
    
    /// 打开面板并聚焦输入框。已可见时只聚焦、不关闭——
    /// 否则「按住问完 → 点按追问」会变成把面板关了。
    func openChat() {
        viewModel.activeAction = .chat
        if !isVisible {
            showWindow(activate: true)
        } else {
            panel?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        viewModel.requestFocus()
    }
    
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
            self?.viewModel.activeAction = .chat
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
    
    // MARK: - 内容自适应高度
    
    /// 视图报上来的自然高度：窗口高度 = clamp(内容高度, 最小, 用户拖到过的上限)
    private func applyContentHeight(_ contentHeight: CGFloat) {
        lastContentHeight = contentHeight
        guard let panel, panel.isVisible else { return }
        resizeToFit(contentHeight: contentHeight, animate: true)
    }
    
    private func resizeToFit(contentHeight: CGFloat, animate: Bool) {
        guard let panel else { return }
        let target = max(Self.minAutoHeight, min(contentHeight.rounded(), heightLimit))
        guard abs(panel.frame.height - target) > 2 else { return }
        
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = target
        frame.origin.y = top - target      // 顶部锚定，视觉上不跳
        
        lastAppliedHeight = target
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
    
    override func showWindow(activate: Bool = true, makeKey: Bool = true) {
        // 显示前先摆好高度：有测量值就按内容，没有就给一个舒服的默认高度，
        // 避免「先开得很矮、内容出来再长高」的跳动
        if let panel {
            let target = max(
                Self.minAutoHeight,
                min(lastContentHeight ?? Self.defaultHeight, heightLimit)
            )
            var frame = panel.frame
            frame.size.height = target
            frame.origin.y = frame.maxY - target
            lastAppliedHeight = target
            panel.setFrame(frame, display: true)
        }
        super.showWindow(activate: activate, makeKey: makeKey)
    }
    
    override func windowDidResize(_ notification: Notification) {
        guard let panel else { return }
        let height = panel.frame.height
        // 自动变高不算「用户调整」：只有差得明显才更新上限
        if let applied = lastAppliedHeight, abs(height - applied) <= 2 {
            super.windowDidResize(notification)
            return
        }
        heightLimit = max(height, Self.minAutoHeight)
        UserDefaults.standard.set(Double(heightLimit), forKey: Self.heightLimitKey)
        super.windowDidResize(notification)
    }
}
