//
//  TranslationView.swift
//  KoK
//
//  Created by Kakar on 2025/12/3.
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
    var onDismiss: (() -> Void)?
    
    @State private var dragOffset: CGPoint? = nil
    @State private var showingHistory = false
    
    var body: some View {
        VStack(spacing: 0) {
            // --- 顶部工具栏（固定） ---
            HStack(spacing: 8) {
                Image(systemName: "translate")
                    .foregroundColor(.blue)
                
                Menu {
                    ForEach(viewModel.availableEngines) { engine in
                        Button(action: {
                            viewModel.selectEngine(id: engine.id)
                        }) {
                            HStack {
                                Text(engine.name)
                                if engine.id == viewModel.engineManager.selectedEngineId {
                                    Image(systemName: "checkmark")
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
            
            Divider()
            
            // --- 内容区域 ---
            VStack(alignment: .leading, spacing: 12) {
                if !viewModel.sourceText.isEmpty {
                    Text(viewModel.sourceText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
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
            
            // --- 底部按钮栏（固定在底部）---
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
                    
                    Button(action: { onReplace?() }) {
                        Label("替换", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.02))
            }
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
            // 工具栏约45 + 底部按钮栏约40
            let hasButtons = !viewModel.translatedText.isEmpty && !viewModel.isLoading
            let totalHeight = newHeight + 45 + (hasButtons ? 42 : 0)
            onHeightChange?(totalHeight)
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
