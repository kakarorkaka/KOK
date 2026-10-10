//
//  ChatAction.swift
//  KoK
//
//  「动作」= 处理上下文的一种配方。翻译面板与对话面板共用同一个引擎
//  （抓取 → 组装上下文 → 调模型 → 呈现），动作只决定这次用什么提示词、
//  要不要输入、要不要语言方向、走翻译专线还是对话引擎。
//
//  形态分层：
//  - 默认形态：每个面板有自己的默认动作（翻译面板=翻译，对话面板=问答）
//  - 预设形态：下面的 4 个内置动作，点胶囊一键切换
//  - 自定义形态：以后可扩展为用户自建动作，挂在同一排胶囊上
//

import Foundation
import SwiftUI

enum ChatAction: String, CaseIterable, Identifiable {
    case translate
    case summarize
    case polish
    case chat
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .translate: return "翻译"
        case .summarize: return "总结"
        case .polish: return "润色"
        case .chat: return "问答"
        }
    }
    
    var icon: String {
        switch self {
        case .translate: return "character.book.closed"
        case .summarize: return "text.alignleft"
        case .polish: return "paintbrush"
        case .chat: return "bubble.left.and.text.bubble.right"
        }
    }
    
    /// 需输入型：要用户打字（或语音）说明意图；其余是零输入型，抓到文本立即执行
    var needsInput: Bool { self == .chat }
    
    /// 语言方向选择只对翻译有意义
    var supportsDirection: Bool { self == .translate }
    
    /// 走翻译专线（翻译引擎 + 方向 + 历史），而不是对话引擎
    var usesTranslationPath: Bool { self == .translate }
    
    /// 动作自带的系统提示词。翻译/问答两个动作没有自带的——
    /// 它们复用设置里的翻译提示词 / 对话提示词（用户可以改）。
    var systemPrompt: String {
        switch self {
        case .summarize:
            return "你是内容总结助手。把用户提供的文本浓缩成要点，语言与原文保持一致。直接输出要点（可用简短的 Markdown 列表），不要任何额外说明。"
        case .polish:
            return "你是文字润色助手。润色用户提供的文本：保持原意、事实与语气基调不变，让表达更专业、自然、流畅。直接输出润色后的文本，不要任何解释、引号或前后缀。"
        case .translate, .chat:
            return ""
        }
    }
    
    /// 对话面板展示的动作（翻译是翻译面板的专属动作，在对话里没有意义）
    static let chatPanelActions: [ChatAction] = [.chat, .summarize, .polish]
}

// MARK: - 胶囊按钮（两个面板共用）

struct ActionCapsule: View {
    let title: String
    let icon: String
    let isActive: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button { onTap() } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isActive ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("用「\(title)」处理：仅对这一次生效")
    }
}
