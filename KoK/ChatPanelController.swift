//
//  ChatPanelController.swift
//  KoK
//
//  统一面板的窗口控制器。
//
//  v5 的两个入口，同一个面板：
//  - ⌘2 → 抓取选中内容，立即翻译（唯一的零输入主动作）
//  - ⌘3 → 点按打开提问；按住说话（同一个键的点按/按住语义）
//
//  高度随形态切换：翻译卡片紧凑，语音是 HUD，提问再展开。
//

import AppKit
import SwiftUI
import Combine

@MainActor
final class ChatPanelController: PanelController {
    static let shared = ChatPanelController()
    
    let viewModel = ChatViewModel()
    
    override var preferredWidth: CGFloat { 460 }
    override var persistenceKey: String { "chat" }
    override var wantsSizePersistence: Bool { true }
    override var preferredHeight: CGFloat { 420 }
    override var minimumSize: NSSize { NSSize(width: 360, height: 220) }
    override var maximumSize: NSSize { NSSize(width: 1000, height: 1000) }
    
    /// 翻译卡片只需要一张紧凑的卡；语音聆听再收成 HUD；提问/追问展开。
    private let compactHeight: CGFloat = 240
    private let voiceHeight: CGFloat = 320
    private let conversationHeight: CGFloat = 420
    private var cancellables = Set<AnyCancellable>()
    
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
        
        viewModel.onRequestHide = { [weak self] in
            self?.hideWindow()
        }
        
        // Esc：录音中先取消录音；有图片预览先关预览；否则收面板
        onEscape = { [weak self] in
            guard let self else { return }
            if self.viewModel.isListening || self.viewModel.isTranscribing {
                self.viewModel.cancelVoice()
                self.hideWindow()
            } else if self.viewModel.previewImage != nil {
                self.viewModel.closePreview()
            } else {
                self.hideWindow()
            }
        }
        
        onKeyDown = { [weak self] event in
            self?.handlePanelShortcut(event) ?? false
        }
        
        // 从翻译卡片开始打字 / 进入提问时，把面板展开到对话高度；
        // 已经更大的用户尺寸则保留。
        viewModel.$activeAction
            .dropFirst()
            .sink { [weak self] action in
                guard action == .chat else { return }
                self?.resizeForConversation()
            }
            .store(in: &cancellables)
        
        // 语音收尾成功、已经把问题发出去之后，再从 HUD 展开成对话面板。
        viewModel.$isTranscribing
            .dropFirst()
            .sink { [weak self] transcribing in
                guard !transcribing, let self else { return }
                guard self.viewModel.messages.contains(where: { $0.role == .user }) else { return }
                self.resizeForConversation()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - 高度
    
    private func resizeForTranslation() {
        setPanelHeight(compactHeight, animated: panel?.isVisible == true)
    }
    
    private func resizeForVoice() {
        setPanelHeight(voiceHeight, animated: panel?.isVisible == true)
    }
    
    private func resizeForConversation() {
        let current = panel?.frame.height ?? conversationHeight
        setPanelHeight(max(current, conversationHeight), animated: panel?.isVisible == true)
    }
    
    // MARK: - 面板内快捷键
    
    /// ⌘↩ 替换 / ⌘C 复制 / ⌘R 重译。
    /// 输入框里已经选中文字时，⌘C 让给系统复制，不抢用户的操作。
    private func handlePanelShortcut(_ event: NSEvent) -> Bool {
        guard panel?.isKeyWindow == true,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        else { return false }
        
        switch event.keyCode {
        case 36, 76: // Return / Enter
            guard viewModel.canReplace else { return false }
            viewModel.replaceSelection()
            return true
        case 8: // C
            guard !hasTextSelection else { return false }
            guard viewModel.canCopyResult else { return false }
            viewModel.copyLastResult()
            return true
        case 15: // R
            guard viewModel.canRetranslate else { return false }
            viewModel.retranslate()
            return true
        default:
            return false
        }
    }
    
    private var hasTextSelection: Bool {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return textView.selectedRange().length > 0
    }
    
    // MARK: - 入口一：⌘2（抓取 → 立即处理）
    
    /// 抓取选中内容并按当前动作处理。抓取期间不主动显示面板，
    /// 免得把面板自己截进选区，也免得抢走原 App 的焦点。
    func triggerTransform() {
        // 面板开着的时候按 ⌘2，先让位，否则模拟 ⌘C 会打在 KoK 自己身上
        if isVisible { hideWindow() }
        resizeForTranslation()
        viewModel.prepareForNewOpening()
        viewModel.activeAction = .translate
        viewModel.beginTransform()
    }
    
    // MARK: - 入口二：⌘3（点按打开 / 按住说话）
    
    /// 打开面板并聚焦输入框。已可见时只聚焦、不关闭——
    /// 否则「按住问完 → 点按追问」会变成把面板关了。
    func openChat() {
        viewModel.activeAction = .chat
        resizeForConversation()
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
        
        resizeForConversation()
        showWindow(activate: false, makeKey: false)
        
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.holdThreshold * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isHolding = true
            self?.viewModel.activeAction = .chat
            // 先让 activeAction 的展开跑完，再把面板收成聆听 HUD
            self?.resizeForVoice()
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
    
    /// 独立截图：框选后直接放进剪贴板，不打开提问面板、不抢焦点。
    func captureScreenshot() {
        Task { @MainActor in
            do {
                try await ScreenshotCapture.copyInteractiveToPasteboard()
            } catch ScreenshotCapture.CaptureError.cancelled {
                // 用户按 Esc / 取消，不打扰
            } catch ScreenshotCapture.CaptureError.permissionDenied {
                // requestPermission 已经弹了系统引导
            } catch {
                NSSound.beep()
                Diagnostics.log("screenshot: 失败 \(error.localizedDescription)")
            }
        }
    }
    
    #if DEBUG
    /// 调试用：离屏渲染三种面板状态，方便在没有录屏权限时检查布局。
    func debugRenderPreview() {
        let sampleSource = "Hello world. This is a sample translation."
        let sampleResult = "你好，世界。这是一段示例译文。"
        
        let translateVM = ChatViewModel()
        translateVM.prepareForNewOpening()
        translateVM.activeAction = .translate
        translateVM.messages = [
            ChatMessage(role: .user, parts: [.text(sampleSource)], hidden: true),
            ChatMessage(
                role: .assistant,
                parts: [.text(sampleResult)],
                transformSource: sampleSource,
                transformActionId: ChatAction.translate.rawValue
            ),
        ]
        renderPreview(
            ChatView(viewModel: translateVM),
            height: compactHeight,
            to: "/tmp/kok-preview-translate.png"
        )
        
        let emptyVM = ChatViewModel()
        emptyVM.prepareForNewOpening()
        emptyVM.activeAction = .translate
        renderPreview(
            ChatView(viewModel: emptyVM),
            height: compactHeight,
            to: "/tmp/kok-preview-empty.png"
        )
        
        let chatEmptyVM = ChatViewModel()
        chatEmptyVM.prepareForNewOpening()
        chatEmptyVM.activeAction = .chat
        renderPreview(
            ChatView(viewModel: chatEmptyVM),
            height: conversationHeight,
            to: "/tmp/kok-preview-chat-empty.png"
        )
        
        let voiceVM = ChatViewModel()
        voiceVM.prepareForNewOpening()
        voiceVM.activeAction = .chat
        voiceVM.isListening = true
        voiceVM.voice.debugConfigure(transcript: "这个 API 的 error 怎么解？", level: 0.62)
        renderPreview(
            ChatView(viewModel: voiceVM),
            height: voiceHeight,
            to: "/tmp/kok-preview-voice.png"
        )
        
        Diagnostics.log("debug: panel previews rendered")
    }
    
    private func renderPreview<V: View>(_ view: V, height: CGFloat, to path: String) {
        let size = NSSize(width: preferredWidth, height: height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        Diagnostics.log("debug: rendered \(path)")
    }
    #endif
}
