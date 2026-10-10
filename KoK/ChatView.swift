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
    /// 内容高度变化（面板据此自适应高度：只有一张卡片时保持紧凑）
    var onContentHeightChange: ((CGFloat) -> Void)?
    
    @FocusState private var inputFocused: Bool
    @State private var dragOffset: CGPoint?
    @State private var showingHistory = false
    
    private let bottomAnchor = "chat-bottom"
    
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            actionCapsules
            transcript
            if let error = viewModel.errorMessage {
                Divider()
                errorBanner(error)
            }
            if let voiceError = viewModel.voiceError {
                Divider()
                voiceErrorBanner(voiceError)
            }
            if viewModel.isListening || viewModel.context != nil {
                Divider()
                contextBar
            }
            Divider()
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .onAppear { focusInput() }
        .onChange(of: viewModel.focusRequest) { _, _ in focusInput() }
        .onChange(of: viewModel.input) { _, newValue in
            // 开始打字 = 在追问：胶囊自动回到「问答」，行为自解释
            if !newValue.isEmpty, viewModel.activeAction != .chat {
                viewModel.activeAction = .chat
            }
        }
        .onPreferenceChange(ViewHeightKey.self) { contentHeight in
            // 工具栏 45 + 胶囊行 34 + 输入区 52 ≈ 131
            onContentHeightChange?(contentHeight + 131)
        }
        .overlay {
            if let image = viewModel.previewImage {
                ImagePreviewOverlay(image: image) { viewModel.closePreview() }
            }
        }
    }
    
    // MARK: - 工具栏
    
    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: viewModel.activeAction.icon)
                .foregroundColor(.purple)
            
            engineMenu
            
            // 语言方向只对翻译动作有意义
            if viewModel.activeAction.supportsDirection {
                directionMenu
            }
            
            if viewModel.copyFeedback {
                Text("已复制")
                    .font(.caption2)
                    .foregroundColor(.green)
                    .transition(.opacity)
            }
            
            Spacer()
            
            if !viewModel.history.isEmpty {
                Button { showingHistory.toggle() } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("翻译历史")
                .popover(isPresented: $showingHistory) {
                    HistoryPopover(viewModel: viewModel, isPresented: $showingHistory)
                }
            }
            
            if viewModel.isStreaming {
                Button { viewModel.stop() } label: {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("停止生成")
            }
            
            Button { viewModel.clear() } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("新对话")
            .disabled(viewModel.messages.isEmpty)
            
            Button { onDismiss?() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭 (Esc)")
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
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
    
    // MARK: - 动作胶囊
    
    /// 引擎列表随动作切换：翻译用翻译引擎（可能是 DeepL），其余用对话引擎
    private var engineMenu: some View {
        Menu {
            EngineMenuContent(
                groups: viewModel.engineManager.engineGroups(chatOnly: !viewModel.activeAction.usesTranslationPath),
                selectedId: viewModel.activeAction.usesTranslationPath
                    ? viewModel.engineManager.selectedEngineId
                    : viewModel.engineManager.selectedChatEngine?.id
            ) { id in
                viewModel.selectEngine(id: id)
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.selectedEngineName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06))
            .cornerRadius(6)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
    
    private var directionMenu: some View {
        Menu {
            ForEach(TranslateDirection.allCases) { dir in
                Button(action: { viewModel.selectDirection(dir) }) {
                    HStack {
                        Text(dir.title)
                        if dir == viewModel.direction {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 9))
                Text(viewModel.direction.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06))
            .cornerRadius(6)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
    
    /// 临时形态：点一下，这一次按这个动作处理。零输入动作点完立即执行。
    private var actionCapsules: some View {
        HStack(spacing: 6) {
            ForEach(ChatAction.allCases) { act in
                ActionCapsule(
                    title: act.title,
                    icon: act.icon,
                    isActive: viewModel.activeAction == act
                ) {
                    viewModel.selectAction(act)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
    
    // MARK: - 消息区
    
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if visibleMessages.isEmpty {
                        emptyHint
                    }
                    
                    ForEach(visibleMessages) { message in
                        MessageRow(
                            message: message,
                            isStreaming: viewModel.isStreaming,
                            isGeneratingImage: viewModel.isGeneratingImage,
                            onCopy: { viewModel.copy($0) },
                            onPreview: { viewModel.preview($0) },
                            onReplace: { viewModel.replaceSelection() }
                        )
                    }
                    
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ViewHeightKey.self, value: geometry.size.height)
                })
            }
            .onChange(of: viewModel.messages) { _, _ in
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
    
    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("问点什么")
                .font(.system(size: 13, weight: .medium))
            Text("直接输入问题，回车发送。对话只保存在内存中，点右上角图标即可开始新对话。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
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
            
            Button { viewModel.regenerate() } label: {
                Text("重试").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(.blue)
        }
        .foregroundColor(.red)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }
    
    // MARK: - 输入区
    
    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // 生图模式开关
            Button {
                viewModel.isImageMode.toggle()
            } label: {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 17))
                    .foregroundColor(viewModel.isImageMode ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(viewModel.isImageMode ? "退出生图模式" : "生图模式：输入当提示词，图片上下文当参考图")
            
            if viewModel.isImageMode {
                Menu {
                    ForEach(ImageGenSize.allCases) { size in
                        Button { viewModel.selectImageSize(size) } label: {
                            HStack {
                                Text(size.title)
                                if size == viewModel.imageSize {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "aspectratio")
                            .font(.system(size: 10))
                        Text(viewModel.imageSize.title)
                            .font(.system(size: 11))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            
            TextField(
                viewModel.isImageMode ? "描述你想生成的图片…" : "问点什么…（↵ 发送，⇧↵ 换行）",
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
                if viewModel.isListening {
                    viewModel.endVoiceAndSend()
                } else {
                    // 从面板里点麦克风时不能再抓选中内容——焦点已经在 KoK 自己身上了
                    viewModel.beginVoice(captureSelection: false)
                }
            } label: {
                Image(systemName: viewModel.isListening ? "mic.fill" : "mic")
                    .font(.system(size: 17))
                    .foregroundColor(viewModel.isListening ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help(viewModel.isListening ? "结束并发送" : "语音输入")
            
            Button { viewModel.send() } label: {
                Image(systemName: viewModel.isImageMode ? "sparkles" : "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(viewModel.canSend ? .accentColor : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSend)
            .help(viewModel.isImageMode ? "生成图片 (↵)" : "发送 (↵)")
        }
        .padding(12)
        .background(Color.primary.opacity(0.02))
    }
    
    // MARK: - 上下文 / 聆听
    
    private var contextBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.isListening {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                    
                    Text(viewModel.voice.transcript.isEmpty ? "正在聆听…" : viewModel.voice.transcript)
                        .font(.system(size: 12))
                        .foregroundColor(viewModel.voice.transcript.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                    
                    Spacer(minLength: 0)
                    
                    Text("松开即发送")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
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
                        .buttonStyle(.plain)
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
                    .buttonStyle(.plain)
                    .help("移除上下文")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(viewModel.isListening ? Color.red.opacity(0.07) : Color.accentColor.opacity(0.06))
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

// MARK: - 单条消息

struct MessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool
    let isGeneratingImage: Bool
    let onCopy: (String) -> Void
    let onPreview: (ImageAttachment) -> Void
    let onReplace: () -> Void
    
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
                        .padding(.vertical, 7)
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
    
    private var transformCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: message.transformAction?.icon ?? "wand.and.stars")
                    .font(.system(size: 10))
                Text(message.transformAction?.title ?? "处理")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundColor(.secondary)
            
            if let source = message.transformSource {
                Text(source)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.3))
                            .frame(width: 2)
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
                    HStack(spacing: 14) {
                        Spacer(minLength: 0)
                        
                        Button { onCopy(message.content) } label: {
                            Label("复制", systemImage: "doc.on.doc")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        
                        Button { onReplace() } label: {
                            Label("替换", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.blue)
                        .help("切回来源应用，用结果覆盖选中的原文（选区已丢失时会粘贴在光标处）")
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
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
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
                            Button { onCopy(message.content) } label: {
                                Label("复制", systemImage: "doc.on.doc")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                        }
                    }
                    
                    let images = message.parts.compactMap { part -> GeneratedImage? in
                        if case .generatedImage(let image) = part { return image }
                        return nil
                    }
                    ForEach(Array(images.enumerated()), id: \.element.fileURL) { _, image in
                        GeneratedImageView(image: image)
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
                .buttonStyle(.plain)
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
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("复制到剪贴板")
                    
                    Button { saveImage() } label: {
                        Label("保存", systemImage: "square.and.arrow.down").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("另存为…")
                    
                    Button { openImage() } label: {
                        Label("打开", systemImage: "arrow.up.forward.app").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("用默认应用打开")
                    
                    Button { onClose() } label: {
                        Label("关闭", systemImage: "xmark").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let nsImage = NSImage(contentsOf: image.fileURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 340, maxHeight: 340)
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
            
            HStack(spacing: 12) {
                Text("\(image.dimensionText) · \(image.sizeText)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button { copyToPasteboard() } label: {
                    Label("复制", systemImage: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("复制原图到剪贴板")
                
                Button { saveToDownloads() } label: {
                    Label("保存", systemImage: "square.and.arrow.down").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("保存到「下载」文件夹")
                
                Button {
                    NSWorkspace.shared.open(image.fileURL)
                } label: {
                    Label("打开", systemImage: "eye").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("用默认应用打开原图")
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

// MARK: - 内容高度测量（面板自适应高度用）

struct ViewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - 翻译历史弹出框

struct HistoryPopover: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("翻译历史")
                    .font(.headline)
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
                    Text("暂无翻译记录")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.history) { record in
                            Button(action: {
                                viewModel.translateFromHistory(record)
                                isPresented = false
                            }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.sourceText)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .foregroundColor(.primary)
                                    Text(record.translatedText)
                                        .font(.system(size: 11))
                                        .lineLimit(1)
                                        .foregroundColor(.secondary)
                                    HStack {
                                        Text(record.engineName)
                                            .font(.caption2)
                                            .foregroundColor(.blue)
                                        Spacer()
                                        Text(record.timestamp, style: .relative)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .frame(width: 320, height: 300)
    }
}
