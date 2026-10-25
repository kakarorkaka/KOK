//
//  ChatView.swift
//  KoK
//
//  快速问答面板界面：工具栏 + 消息区 + 自适应输入框。
//

import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    var onDismiss: (() -> Void)?
    
    /// 空状态里显示真实快捷键（用户可能在设置里改过）
    @ObservedObject private var hotKeys = HotKeyManager.shared
    
    @FocusState private var inputFocused: Bool
    @State private var dragOffset: CGPoint?
    @State private var showingHistory = false
    /// 是否停在底部（仅供用户滑动时判定）
    @State private var isAtBottom = true
    /// 是否跟随最新内容：只有用户主动往上滑才会关掉，
    /// 这样出图 / 流式追加这类「内容增长」不会让新结果落在视野外
    @State private var followTail = true
    /// 用户是否正在自己滑动
    @State private var userScrolling = false
    @State private var lastMessageCount = 0
    
    private let bottomAnchor = "chat-bottom"
    
    var body: some View {
        Group {
            if viewModel.isListening || viewModel.isTranscribing {
                listeningView
            } else {
                VStack(spacing: 0) {
                    toolbar
                    if visibleMessages.isEmpty {
                        emptyState
                    } else {
                        transcript
                    }
                    if let error = viewModel.errorMessage {
                        errorBanner(error)
                    }
                    if let voiceError = viewModel.voiceError {
                        voiceErrorBanner(voiceError)
                    }
                    if viewModel.context != nil {
                        contextBar
                    }
                    inputBar
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .onAppear { focusInput() }
        .onChange(of: viewModel.focusRequest) { _, _ in focusInput() }
        .onChange(of: viewModel.input) { _, newValue in
            // 开始打字 = 从「翻译」切到「提问」。翻译是主入口，
            // 但只要用户开始打字，就是在追问，不需要再点别的东西。
            if !newValue.isEmpty, viewModel.activeAction != .chat {
                viewModel.activeAction = .chat
            }
        }
        .overlay {
            if let image = viewModel.previewImage {
                ImagePreviewOverlay(image: image) { viewModel.closePreview() }
            }
        }
        .overlay(alignment: .top) {
            if viewModel.copyFeedback {
                Text("已复制")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    .padding(.top, 54)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: viewModel.copyFeedback)
    }

    // MARK: - 语音 HUD

    /// 按住说话时，整个面板收成一张安静的「聆听卡」：
    /// 真实音量条 + 实时转写，不显示输入框和工具栏。
    private var listeningView: some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.isListening ? Color.red : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(viewModel.isListening ? "正在听" : "正在整理")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    viewModel.cancelVoice()
                    onDismiss?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(IconButtonStyle())
                .help("取消这次语音（不发送）")
            }

            Spacer(minLength: 0)

            VoiceLevelView(level: viewModel.voice.audioLevel)
                .opacity(viewModel.isListening ? 1 : 0.45)

            Text(viewModel.voice.transcript.isEmpty
                 ? (viewModel.isListening ? "说吧，松开就发送" : "正在整理…")
                 : viewModel.voice.transcript)
                .font(.system(size: 16, weight: .medium))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .foregroundColor(viewModel.voice.transcript.isEmpty ? .secondary : .primary)
                .padding(.horizontal, 28)
                .animation(.easeOut(duration: 0.12), value: viewModel.voice.transcript)

            Text(viewModel.isListening ? "选中内容会一起带上 · 松开即发送" : "正在把这句话发出去…")
                .font(.caption2)
                .foregroundColor(.secondary)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.red.opacity(0.03))
    }
        
    // MARK: - 工具栏
    
    private var toolbar: some View {
        HStack(spacing: 8) {
            engineMenu
            
            Spacer()
            
            // 历史按钮常驻（没记录时禁用），避免工具栏按钮左右跳动
            Button { showingHistory.toggle() } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(IconButtonStyle())
            .disabled(viewModel.history.isEmpty)
            .help(viewModel.history.isEmpty ? "暂无结果历史" : "结果历史")
            .popover(isPresented: $showingHistory) {
                HistoryPopover(viewModel: viewModel, isPresented: $showingHistory)
            }
            
            // 「新对话」只在提问形态出现：翻译卡片不需要这个按钮
            if viewModel.activeAction == .chat {
                Button { viewModel.clear() } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(IconButtonStyle())
                .help("新对话")
                .disabled(viewModel.messages.isEmpty)
            }
            
            Button { onDismiss?() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(IconButtonStyle())
            .help("关闭 (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in
                    guard let window = NSApp.keyWindow else { return }
                    let currentLocation = NSEvent.mouseLocation
                    if dragOffset == nil {
                        dragOffset = CGPoint(
                            x: currentLocation.x - window.frame.origin.x,
                            y: currentLocation.y - window.frame.origin.y
                        )
                    }
                    if let offset = dragOffset {
                        window.setFrameOrigin(CGPoint(
                            x: currentLocation.x - offset.x,
                            y: currentLocation.y - offset.y
                        ))
                    }
                }
                .onEnded { _ in dragOffset = nil }
        )
    }
    
    // MARK: - 工具栏菜单
    
    /// 一个菜单同时管引擎和翻译方向，工具栏不再并排两个下拉。
    private var engineMenu: some View {
        Menu {
            if viewModel.activeAction.supportsDirection {
                Section("翻译方向") {
                    ForEach(TranslateDirection.allCases) { dir in
                        Button {
                            viewModel.selectDirection(dir)
                        } label: {
                            HStack {
                                Text(dir.title)
                                if dir == viewModel.direction {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
            
            Section("引擎") {
                EngineMenuContent(
                    groups: viewModel.engineManager.engineGroups(chatOnly: !viewModel.activeAction.usesTranslationPath),
                    selectedId: viewModel.activeAction.usesTranslationPath
                        ? viewModel.engineManager.selectedEngineId
                        : viewModel.engineManager.selectedChatEngine?.id
                ) { id in
                    viewModel.selectEngine(id: id)
                }
            }
        } label: {
            Text(toolbarMenuTitle)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.vertical, 3)
                .frame(maxWidth: 240, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
    }
    
    private var toolbarMenuTitle: String {
        viewModel.activeAction.supportsDirection
            ? "\(viewModel.selectedEngineName) · \(viewModel.direction.title)"
            : viewModel.selectedEngineName
    }
    
    // MARK: - 消息区
    
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, message in
                        MessageRow(
                            message: message,
                            // 只有「正在流式的那一条」才算流式：否则一有请求在跑，
                            // 历史消息上的复制 / 替换按钮会全部消失
                            isStreaming: viewModel.isStreaming && index == visibleMessages.count - 1,
                            isGeneratingImage: viewModel.isGeneratingImage,
                            // 只有最后一条才显示「正在生成图片」：文字已经流完了，
                            // 不提示的话用户会以为这句话就到此为止
                            isImagePending: viewModel.isGeneratingImage && index == visibleMessages.count - 1,
                            onCopy: { viewModel.copy($0) },
                            onPreview: { viewModel.preview($0) },
                            onReplace: { viewModel.replaceSelection(cardId: message.id) },
                            onRetranslate: { viewModel.retranslate(cardId: message.id) }
                        )
                    }
                    
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollPhaseChange { _, phase in
                // 只有「用户自己在滑」时才重新判定要不要跟随，
                // 程序滚动 / 内容增长引起的几何变化不算（否则流式输出会把跟随关掉）
                switch phase {
                case .tracking, .interacting, .decelerating:
                    userScrolling = true
                default:
                    userScrolling = false
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // 距底部 40pt 以内算「贴着底」
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height < 40
            } action: { _, atBottom in
                isAtBottom = atBottom
                if userScrolling { followTail = atBottom }
            }
            .onChange(of: viewModel.messages) { _, newValue in
                let isNewMessage = newValue.count != lastMessageCount
                lastMessageCount = newValue.count
                // 用户自己发了新消息：无论之前在哪，都跟到底
                if isNewMessage, newValue.last?.role == .user { followTail = true }
                guard followTail else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
    }
    
    /// 「变换卡片」的原文是一条隐藏消息（内容已经显示在卡片里了），不渲染
    private var visibleMessages: [ChatMessage] {
        viewModel.messages.filter { !$0.hidden }
    }
    
    /// 空面板不铺一串说明，只在中间放一句此刻最有用的话。
    private var emptyState: some View {
        VStack(spacing: 6) {
            if viewModel.activeAction == .chat {
                Text("直接输入问题，或按住 \(chatShortcutText) 说话")
                    .font(.system(size: 14, weight: .medium))
                Text("选中文字会一起带上")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                Text("选中文字，按 \(translateShortcutText) 翻译")
                    .font(.system(size: 14, weight: .medium))
                Text("译文可 ⌘↩ 替换回原处")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var translateShortcutText: String {
        hotKeys.shortcut(for: .translate)?.displayString ?? "⌘2"
    }
    
    private var chatShortcutText: String {
        hotKeys.shortcut(for: .chat)?.displayString ?? "⌘3"
    }
    
    // MARK: - 错误条
    
    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
            Text(text)
                .font(.caption)
                .textSelection(.enabled)
            
            Spacer(minLength: 0)
            
            Button { viewModel.retry() } label: {
                Text("重试").font(.caption)
            }
            .buttonStyle(IconButtonStyle())
            .foregroundColor(.blue)
        }
        .foregroundColor(.red)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }
    
    // MARK: - 输入区
    
    /// 正在生成（文字流式或出图）：此时发送键变成停止键
    private var isBusy: Bool {
        viewModel.isStreaming || viewModel.isGeneratingImage
    }
    
    private var sendButtonIcon: String {
        isBusy ? "stop.fill" : "arrow.up.circle.fill"
    }
    
    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                "问点什么…",
                text: $viewModel.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($inputFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(8)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    viewModel.send()
                    return .handled
                }
            
            Button {
                // 从面板里点麦克风时不能再抓选中内容——焦点已经在 KoK 自己身上了
                viewModel.beginVoice(captureSelection: false)
            } label: {
                Image(systemName: "mic")
                    .font(.system(size: 17))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(IconButtonStyle())
            .help("语音输入")
            
            Button {
                if isBusy {
                    viewModel.stop()
                } else {
                    viewModel.send()
                }
            } label: {
                Image(systemName: sendButtonIcon)
                    .font(.system(size: 20))
                    .foregroundColor(isBusy ? .secondary : (viewModel.canSend ? .accentColor : Color.secondary.opacity(0.4)))
            }
            .buttonStyle(IconButtonStyle())
            .disabled(!isBusy && !viewModel.canSend)
            .help(isBusy ? "停止生成" : "发送 (↵)")
        }
        .padding(12)
    }
    
    // MARK: - 上下文 / 聆听
    
    private var contextBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let context = viewModel.context {
                HStack(spacing: 6) {
                    if let image = context.image {
                        Button { viewModel.preview(image) } label: {
                            HStack(spacing: 6) {
                                AttachmentThumbnail(image: image, maxSide: 34)
                                Text("图片 \(image.dimensionText) · \(image.sizeText)")
                                    .font(.system(size: 11))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.08))
                            .cornerRadius(6)
                        }
                        .buttonStyle(IconButtonStyle())
                        .help("点击预览这张图片")
                    }
                    if let text = context.text {
                        contextChip(
                            icon: "doc.text",
                            text: context.label ?? "选中文本 \(text.count) 字\(context.truncated ? "（已截断）" : "")"
                        )
                    }
                    
                    Spacer(minLength: 0)
                    
                    Button { viewModel.removeContext() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("移除上下文")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
    }
    
    private func contextChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 11))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.08))
        .cornerRadius(6)
    }
    
    @ViewBuilder
    private func voiceErrorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "mic.slash.fill").font(.system(size: 11))
            Text(text).font(.caption).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }
    
    private func focusInput() {
        DispatchQueue.main.async {
            inputFocused = true
        }
    }
}

// MARK: - 语音音量条

/// 真实麦克风电平驱动的五根小竖条。比转圈更能让人确认「它在听」。
private struct VoiceLevelView: View {
    let level: CGFloat

    private let factors: [CGFloat] = [0.45, 0.8, 1.0, 0.65, 0.4]

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(factors.enumerated()), id: \.offset) { _, factor in
                Capsule()
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 3, height: 6 + 30 * clamped * factor)
            }
        }
        .frame(height: 38)
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }

    private var clamped: CGFloat {
        min(1, max(0, level))
    }
}

// MARK: - 图标按钮样式

/// 面板里的自定义按钮统一用它。
/// macOS 用户靠 hover 判断「这里能不能点」，而 `.plain` 在毛玻璃背景上
/// 完全没有反馈，看起来像静态文本。
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration)
    }
    
    private struct Highlight: View {
        let configuration: Configuration
        @State private var hovering = false
        
        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (hovering ? 0.08 : 0)))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - 单条消息

struct MessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool
    let isGeneratingImage: Bool
    /// 这条消息下面正在出图（文字已经流完，但图还没回来）
    let isImagePending: Bool
    let onCopy: (String) -> Void
    let onPreview: (ImageAttachment) -> Void
    let onReplace: () -> Void
    let onRetranslate: () -> Void
    
    /// 就地反馈：点哪个按钮就在哪个按钮上显示「已复制」
    @State private var copied = false
    /// 变换卡片的原文默认折叠 3 行，长文本可展开
    @State private var sourceExpanded = false
    
    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 4) {
                let attachments = message.parts.compactMap { part -> ImageAttachment? in
                    if case .image(let image) = part { return image }
                    return nil
                }
                ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                    VStack(alignment: .trailing, spacing: 3) {
                        AttachmentThumbnail(image: attachment, maxSide: 190) {
                            onPreview(attachment)
                        }
                        Text("参考图 \(attachment.dimensionText) · \(attachment.sizeText)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.16))
                        .cornerRadius(10)
                }
                }
            }
            
        case .assistant:
            if message.transformSource != nil {
                transformCard
            } else {
                assistantRow
            }
            
        case .system:
            EmptyView()
        }
    }
    
    // MARK: - 变换卡片（原文 → 结果，带复制 / 替换）
    
    /// 就地反馈的复制按钮：点哪个就在哪个上显示「已复制」
    private func copyButton(_ text: String) -> some View {
        Button {
            onCopy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copied = false
            }
        } label: {
            Label(copied ? "已复制" : "复制",
                  systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
        }
        .buttonStyle(IconButtonStyle())
        .foregroundColor(copied ? .green : .secondary)
        .animation(.easeInOut(duration: 0.15), value: copied)
    }
    
    private var transformCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(message.transformAction?.title ?? "处理")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundColor(.secondary)
            
            if let source = message.transformSource {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(sourceExpanded ? nil : 3)
                        .textSelection(.enabled)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.3))
                                .frame(width: 2)
                        }
                    
                    if source.count > 120 {
                        Button(sourceExpanded ? "收起" : "展开原文") {
                            withAnimation(.easeInOut(duration: 0.15)) { sourceExpanded.toggle() }
                        }
                        .buttonStyle(IconButtonStyle())
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)
                        .padding(.leading, 8)
                    }
                }
            }
            
            if message.content.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.5)
                    Text("正在处理…").font(.caption).foregroundColor(.secondary)
                }
            } else {
                Text(message.content)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                if !isStreaming {
                    // 「替换」是翻译的主动作，放第一位；复制和重译次之。
                    HStack(spacing: 12) {
                        Button { onReplace() } label: {
                            Label("替换", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(IconButtonStyle())
                        .foregroundColor(.accentColor)
                        .help("替换回原处（⌘↩）；可在来源 App 按 ⌘Z 撤销")
                        
                        copyButton(message.content)
                        
                        Button { onRetranslate() } label: {
                            Label("重译", systemImage: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(IconButtonStyle())
                        .foregroundColor(.secondary)
                        .help("重新翻译这段（⌘R）")
                        
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
    
    // MARK: - 普通助手回复
    
    private var assistantRow: some View {
            VStack(alignment: .leading, spacing: 6) {
                if message.content.isEmpty && !message.hasGeneratedImage {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.5)
                        Text(isGeneratingImage ? "正在生成图片…（约 10–20 秒）" : "Thinking…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    if !message.content.isEmpty {
                        MarkdownText(raw: message.content)
                        
                        if !isStreaming {
                            copyButton(message.content)
                        }
                    }
                    
                    let images = message.parts.compactMap { part -> GeneratedImage? in
                        if case .generatedImage(let image) = part { return image }
                        return nil
                    }
                    ForEach(Array(images.enumerated()), id: \.element.fileURL) { _, image in
                        GeneratedImageView(image: image)
                    }
                    
                    // 文字已经流完、图还在路上：明确告诉用户还在生成
                    if isImagePending && !message.hasGeneratedImage {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.5)
                            Text("正在生成图片…（约 10–20 秒）")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 轻量 Markdown（代码块 + 行内格式）

struct MarkdownText: View {
    let raw: String
    
    private enum Block {
        case text(String)
        case code(language: String?, content: String)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    Text(attributed(text))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                case .code(let language, let content):
                    CodeBlock(language: language, content: content)
                }
            }
        }
    }
    
    private func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
    
    /// 按 ``` 围栏切块。流式输出时围栏可能还没闭合，此时按代码块处理。
    private var blocks: [Block] {
        var result: [Block] = []
        var buffer = ""
        var code = ""
        var language: String?
        var inCode = false
        
        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    result.append(.code(language: language, content: code))
                    code = ""
                    language = nil
                    inCode = false
                } else {
                    if !buffer.isEmpty {
                        result.append(.text(buffer))
                        buffer = ""
                    }
                    let lang = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = lang.isEmpty ? nil : lang
                    inCode = true
                }
                continue
            }
            
            if inCode {
                code += line + "\n"
            } else {
                buffer += line + "\n"
            }
        }
        
        if inCode {
            result.append(.code(language: language, content: code))
        } else if !buffer.isEmpty {
            result.append(.text(buffer))
        }
        
        return result
    }
}

// MARK: - 代码块

struct CodeBlock: View {
    let language: String?
    let content: String
    
    @State private var copied = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(content, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(IconButtonStyle())
                .foregroundColor(copied ? .green : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05))
            
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - 附件缩略图 + 预览

/// 上下文里那张图的小缩略图。onTap 为 nil 时不可点（嵌在别的可点区域里时用）。
struct AttachmentThumbnail: View {
    let image: ImageAttachment
    var maxSide: CGFloat = 160
    var onTap: (() -> Void)?
    
    @State private var nsImage: NSImage?
    
    var body: some View {
        Group {
            if let onTap {
                base
                    .onTapGesture { onTap() }
                    .help("点击预览这张图片")
            } else {
                base
            }
        }
        .onAppear { if nsImage == nil { nsImage = image.previewImage } }
    }
    
    private var base: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    )
            }
        }
        .frame(maxWidth: maxSide, maxHeight: maxSide)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// 附件大图预览：盖在面板上，点背景 / Esc / 关闭按钮退出。
/// 面板本身拿不到系统的 Quick Look，这里自己实现一个够用的版本。
struct ImagePreviewOverlay: View {
    let image: ImageAttachment
    let onClose: () -> Void
    
    @State private var nsImage: NSImage?
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
            
            VStack(spacing: 10) {
                Group {
                    if let nsImage {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView().scaleEffect(0.6)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                HStack(spacing: 12) {
                    Text("\(image.dimensionText) · \(image.sizeText)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Spacer(minLength: 0)
                    
                    Button { copyImage() } label: {
                        Label("复制", systemImage: "doc.on.doc").font(.system(size: 11))
                    }
                    .buttonStyle(IconButtonStyle())
                    .foregroundColor(.secondary)
                    .help("复制到剪贴板")
                    
                    Button { saveImage() } label: {
                        Label("保存", systemImage: "square.and.arrow.down").font(.system(size: 11))
                    }
                    .buttonStyle(IconButtonStyle())
                    .foregroundColor(.secondary)
                    .help("另存为…")
                    
                    Button { openImage() } label: {
                        Label("打开", systemImage: "arrow.up.forward.app").font(.system(size: 11))
                    }
                    .buttonStyle(IconButtonStyle())
                    .foregroundColor(.secondary)
                    .help("用默认应用打开")
                    
                    Button { onClose() } label: {
                        Label("关闭", systemImage: "xmark").font(.system(size: 11))
                    }
                    .buttonStyle(IconButtonStyle())
                    .foregroundColor(.secondary)
                    .help("关闭预览 (Esc)")
                }
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
            .padding(18)
        }
        .onAppear { nsImage = image.previewImage }
    }
    
    private func copyImage() {
        guard let data = image.pngData ?? image.rawData else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }
    
    private func saveImage() {
        guard let data = image.rawData else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "kok-附件-\(Int(Date().timeIntervalSince1970)).\(image.fileExtension)"
        let ext = image.fileExtension
        if let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }
    
    /// 写一份到临时目录再用默认应用打开——附件只在内存里，没有现成文件路径
    private func openImage() {
        guard let data = image.rawData else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kok-attachment-\(UUID().uuidString).\(image.fileExtension)")
        guard (try? data.write(to: url)) != nil else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 生成结果图片卡片

struct GeneratedImageView: View {
    let image: GeneratedImage
    
    /// 缩略显示尺寸：按图片真实宽高比算出来，**不用 maxWidth 的容器**。
    /// 之前用 `.frame(maxWidth: 340, maxHeight: 340)`，竖版图会被塞进 340pt 宽的框里、
    /// 右边留出一条空白，看起来像布局坏了。
    private var displaySize: CGSize {
        let maxSide: CGFloat = 340
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return CGSize(width: maxSide, height: maxSide) }
        let scale = min(maxSide / w, maxSide / h, 1)   // 只缩小，不放大
        return CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let nsImage = NSImage(contentsOf: image.fileURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: displaySize.width, height: displaySize.height)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                    .onTapGesture {
                        NSWorkspace.shared.open(image.fileURL)
                    }
                    .help("点击用默认应用打开原图")
            } else {
                Text("图片加载失败")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // 操作按钮左对齐（与变换卡片的「复制 / 替换」在同一条基线），
            // 尺寸信息放到右侧
            HStack(spacing: 12) {
                Button { copyToPasteboard() } label: {
                    Label("复制", systemImage: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(IconButtonStyle())
                .foregroundColor(.secondary)
                .help("复制原图到剪贴板")
                
                Button { saveToDownloads() } label: {
                    Label("保存", systemImage: "square.and.arrow.down").font(.system(size: 11))
                }
                .buttonStyle(IconButtonStyle())
                .foregroundColor(.secondary)
                .help("保存到「下载」文件夹")
                
                Button {
                    NSWorkspace.shared.open(image.fileURL)
                } label: {
                    Label("打开", systemImage: "eye").font(.system(size: 11))
                }
                .buttonStyle(IconButtonStyle())
                .foregroundColor(.secondary)
                .help("用默认应用打开原图")
                
                Spacer(minLength: 0)
                
                Text("\(image.dimensionText) · \(image.sizeText)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func copyToPasteboard() {
        guard let data = try? Data(contentsOf: image.fileURL) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }
    
    private func saveToDownloads() {
        guard let data = try? Data(contentsOf: image.fileURL) else { return }
        
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "kok-\(Int(Date().timeIntervalSince1970)).png"
        panel.allowedContentTypes = [.png]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }
}

// MARK: - 翻译历史弹出框

struct HistoryPopover: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("结果历史")
                    .font(.headline)
                Text("最近 100 条")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                if !viewModel.history.isEmpty {
                    Button("清空") {
                        viewModel.clearHistory()
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            Divider()
            
            if viewModel.history.isEmpty {
                VStack {
                    Spacer()
                    Text("还没有结果")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text("处理过的内容会自动留在这里")
                        .foregroundColor(.secondary)
                        .font(.caption2)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.history) { record in
                            HistoryRow(record: record, viewModel: viewModel) {
                                isPresented = false
                            }
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .frame(width: 340, height: 320)
    }
}

/// 一条结果：点一下「重用」（文字结果重新跑一遍）；右键或按钮可复制 / 删除
struct HistoryRow: View {
    let record: ResultStore.Record
    @ObservedObject var viewModel: ChatViewModel
    let onDismiss: () -> Void
    
    @State private var copied = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: record.kind.icon)
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
                .frame(width: 14)
                .padding(.top, 2)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(record.sourceText.isEmpty ? "（无原文）" : record.sourceText)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundColor(.primary)
                
                if record.isImage {
                    Text("点击预览 · 右键可在访达中显示")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    Text(record.outputText)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 6) {
                    Text(record.kind.title)
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                    Text(record.engineName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(record.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                openRecord()
            }
            
            Button {
                viewModel.copyHistoryRecord(record)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundColor(copied ? .green : .secondary)
            }
            .buttonStyle(IconButtonStyle())
            .help("复制结果")
            
            Button {
                viewModel.deleteHistoryRecord(record.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(IconButtonStyle())
            .help("删除这条")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    /// 文字结果：重新跑一遍；生图结果：打开原图
    private func openRecord() {
        if record.isImage {
            guard let url = viewModel.resultStore.imageURL(for: record) else { return }
            NSWorkspace.shared.open(url)
        } else {
            viewModel.reuseHistoryRecord(record)
            onDismiss()
        }
    }
}
