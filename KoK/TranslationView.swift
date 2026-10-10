//
//  TranslationView.swift
//  KoK
//
//  Created by Kakar on 2025/12/3.
//
//  动作系统：顶部一排胶囊（翻译 / 总结 / 润色 / 问答）。
//  翻译 / 总结 / 润色是零输入型——抓到文本立即执行；
//  问答是需输入型——显示输入框，可打字或语音。
//

import SwiftUI

struct ViewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct TranslationView: View {
    @ObservedObject var viewModel: TranslationViewModel
    
    var onHeightChange: ((CGFloat) -> Void)?
    var onReplace: (() -> Void)?
    var onFollowUp: (() -> Void)?
    var onDismiss: (() -> Void)?
    
    @State private var dragOffset: CGPoint? = nil
    @State private var showingHistory = false
    @FocusState private var questionFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            capsuleRow
            toolbar
            Divider()
            contentArea
            bottomBar
        }
        .frame(width: 400)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .onPreferenceChange(ViewHeightKey.self) { newHeight in
            // 胶囊行约34 + 工具栏约45 + 问答输入区约46 + 底部按钮栏约42
            let inputExtra: CGFloat = viewModel.action.needsInput ? 46 : 0
            let hasButtons = !viewModel.translatedText.isEmpty && !viewModel.isLoading
            let totalHeight = newHeight + 34 + 45 + inputExtra + (hasButtons ? 42 : 0)
            onHeightChange?(totalHeight)
        }
        .onChange(of: viewModel.focusRequest) { _, _ in
            questionFocused = true
        }
    }
    
    // MARK: - 动作胶囊（临时形态：仅对这一次生效，下次打开回到翻译）
    
    private var capsuleRow: some View {
        HStack(spacing: 6) {
            ForEach(ChatAction.allCases) { act in
                ActionCapsule(
                    title: act.title,
                    icon: act.icon,
                    isActive: viewModel.action == act
                ) {
                    viewModel.selectAction(act)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
    
    // MARK: - 顶部工具栏（引擎 / 方向 / 历史 / 关闭，可拖拽）
    
    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "translate")
                .foregroundColor(.blue)
            
            engineMenu
            
            // 语言方向只对翻译动作有意义
            if viewModel.action.supportsDirection {
                directionMenu
            }
            
            Spacer()
            
            Button(action: { showingHistory.toggle() }) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("翻译历史")
            .popover(isPresented: $showingHistory) {
                HistoryPopover(viewModel: viewModel, isPresented: $showingHistory)
            }
            
            Button(action: { onDismiss?() }) {
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
    
    /// 翻译动作用翻译引擎列表，其余动作用对话引擎列表
    private var engineMenu: some View {
        Menu {
            EngineMenuContent(
                groups: viewModel.engineManager.engineGroups(chatOnly: !viewModel.action.usesTranslationPath),
                selectedId: viewModel.action.usesTranslationPath
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
    
    // MARK: - 内容区域（原文 / 问答输入 / 结果）
    
    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !viewModel.sourceText.isEmpty {
                Text(viewModel.sourceText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            
            if viewModel.action.needsInput {
                questionInputRow
            }
            
            if let error = viewModel.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                    
                    if !viewModel.sourceText.isEmpty {
                        Button(action: { viewModel.retry() }) {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } else if let voiceError = viewModel.voiceError {
                Text(voiceError)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .textSelection(.enabled)
            } else if viewModel.isLoading && viewModel.translatedText.isEmpty {
                HStack {
                    ProgressView().scaleEffect(0.5)
                    Text("Thinking...").font(.caption).foregroundColor(.secondary)
                }
            } else if !viewModel.translatedText.isEmpty {
                Text(viewModel.translatedText)
                    .font(.system(size: 13, weight: .regular))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: ViewHeightKey.self, value: geometry.size.height)
        })
    }
    
    /// 问答动作的输入区（打字 / 语音）
    private var questionInputRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if viewModel.isListening {
                Text(viewModel.voice.transcript.isEmpty
                     ? "正在聆听…（再点一次麦克风结束）"
                     : viewModel.voice.transcript)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
            
            HStack(spacing: 8) {
                TextField("就选中的内容提问…（↵ 发送）", text: $viewModel.questionInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...4)
                    .focused($questionFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(8)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        viewModel.submitQuestion()
                        return .handled
                    }
                
                Button { viewModel.toggleVoice() } label: {
                    Image(systemName: viewModel.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 16))
                        .foregroundColor(viewModel.isListening ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .help(viewModel.isListening ? "结束并发送" : "语音提问")
                
                Button { viewModel.submitQuestion() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(viewModel.canSubmitQuestion ? .accentColor : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSubmitQuestion)
                .help("发送 (↵)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
    
    // MARK: - 底部按钮栏
    
    @ViewBuilder
    private var bottomBar: some View {
        if !viewModel.translatedText.isEmpty && !viewModel.isLoading {
            Divider()
            HStack(spacing: 16) {
                Spacer()
                
                Button(action: { viewModel.copyTranslation() }) {
                    Label(
                        viewModel.copyFeedback ? "已复制" : "复制",
                        systemImage: viewModel.copyFeedback ? "checkmark" : "doc.on.doc"
                    )
                    .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(viewModel.copyFeedback ? .green : .secondary)
                .animation(.easeInOut(duration: 0.2), value: viewModel.copyFeedback)
                
                // 追问：把原文和结果带进对话面板继续聊（只有翻译提供）
                if viewModel.action == .translate {
                    Button(action: { onFollowUp?() }) {
                        Label("追问", systemImage: "bubble.left.and.bubble.right")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.purple)
                    .help("把原文和译文带进对话面板继续聊")
                }
                
                // 替换选中文本：零输入型动作都是「原文 → 结果」的变换，替换才有意义
                if !viewModel.action.needsInput {
                    Button(action: { onReplace?() }) {
                        Label("替换", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                    .help("切回来源应用，用结果覆盖选中的原文（选区已丢失时会粘贴在光标处）")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.02))
        }
    }
}

// MARK: - 翻译历史弹出框

struct HistoryPopover: View {
    @ObservedObject var viewModel: TranslationViewModel
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
