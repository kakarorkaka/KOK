//
//  ChatView.swift
//  KoK
//
//  快速问答面板界面：工具栏 + 消息区 + 自适应输入框。
//

import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    var onDismiss: (() -> Void)?
    
    @FocusState private var inputFocused: Bool
    @State private var dragOffset: CGPoint?
    
    private let bottomAnchor = "chat-bottom"
    
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            transcript
            if let error = viewModel.errorMessage {
                Divider()
                errorBanner(error)
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
    }
    
    // MARK: - 工具栏
    
    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundColor(.purple)
            
            Menu {
                if viewModel.availableEngines.isEmpty {
                    Text("没有支持对话的引擎")
                } else {
                    ForEach(viewModel.availableEngines) { engine in
                        Button {
                            viewModel.selectEngine(id: engine.id)
                        } label: {
                            HStack {
                                Text(engine.name)
                                if engine.id == viewModel.engineManager.selectedChatEngine?.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(viewModel.selectedEngineName)
                        .font(.system(size: 12))
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
            
            if viewModel.copyFeedback {
                Text("已复制")
                    .font(.caption2)
                    .foregroundColor(.green)
                    .transition(.opacity)
            }
            
            Spacer()
            
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
    
    // MARK: - 消息区
    
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if viewModel.messages.isEmpty {
                        emptyHint
                    }
                    
                    ForEach(viewModel.messages) { message in
                        MessageRow(
                            message: message,
                            isStreaming: viewModel.isStreaming,
                            onCopy: { viewModel.copy($0) }
                        )
                    }
                    
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: viewModel.messages) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
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
            TextField("问点什么…（↵ 发送，⇧↵ 换行）", text: $viewModel.input, axis: .vertical)
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
            
            Button { viewModel.send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(viewModel.canSend ? .accentColor : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSend)
            .help("发送 (↵)")
        }
        .padding(12)
        .background(Color.primary.opacity(0.02))
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
    let onCopy: (String) -> Void
    
    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.content)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.16))
                    .cornerRadius(10)
            }
            
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if message.content.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.5)
                        Text("Thinking…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
        case .system:
            EmptyView()
        }
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
