//
//  PromptSettingsView.swift
//  KoK
//
//  设置 ▸ 提示词：翻译与对话两套系统提示词。
//  拆成独立文件，便于单独预览，也和 EngineSettingsView 的组织方式一致。
//

import SwiftUI

// MARK: - Tab 3: 提示词设置

struct PromptSettingsTab: View {
    @ObservedObject var manager = EngineManager.shared
    
    var body: some View {
        Form {
            // ── 翻译提示词 ─────────────────────────────────────
            Section {
                TextEditor(text: $manager.globalSystemPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 150)
                
                unresolvedWarning(for: manager.globalSystemPrompt)
            } header: {
                sectionHeader(
                    "翻译系统提示词",
                    isDefault: manager.globalSystemPrompt == EngineConfig.defaultSystemPrompt
                ) {
                    manager.globalSystemPrompt = EngineConfig.defaultSystemPrompt
                }
            } footer: {
                Text("应用于所有 LLM 翻译引擎（DeepL 除外）。留空则回退到内置默认提示词。\n"
                     + "可用变量：\(PromptTemplate.Variable.targetLang.display) 目标语言、"
                     + "\(PromptTemplate.Variable.sourceLang.display) 源语言（大小写与单双括号均可识别）。\n"
                     + "改动会自动保存。")
            }
            
            // ── 对话提示词 ─────────────────────────────────────
            Section {
                TextEditor(text: $manager.chatSystemPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 110)
                
                unresolvedWarning(for: manager.chatSystemPrompt)
            } header: {
                sectionHeader(
                    "对话系统提示词",
                    isDefault: manager.chatSystemPrompt == EngineConfig.defaultChatSystemPrompt
                ) {
                    manager.chatSystemPrompt = EngineConfig.defaultChatSystemPrompt
                }
            } footer: {
                Text("仅用于快速问答面板，与翻译提示词互不影响。对话不做变量替换。\n改动会自动保存。")
            }
        }
        .formStyle(.grouped)
    }
    
    /// 两个区块用同一种标题样式：左边标题，右边「恢复默认」
    @ViewBuilder
    private func sectionHeader(
        _ title: String,
        isDefault: Bool,
        restore: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("恢复默认", action: restore)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(.caption)
                .disabled(isDefault)
        }
    }
    
    /// 提示词里出现了 KoK 不会替换的占位符时提醒，避免静默失效
    @ViewBuilder
    private func unresolvedWarning(for template: String) -> some View {
        let unknown = PromptTemplate.unresolvedPlaceholders(in: template)
        if !unknown.isEmpty {
            Label(
                "KoK 不会替换这些占位符：\(unknown.joined(separator: "、"))",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundColor(.orange)
        }
    }
}
