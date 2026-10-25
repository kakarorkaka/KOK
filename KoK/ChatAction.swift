//
//  ChatAction.swift
//  KoK
//
//  「动作」= 处理上下文的一种配方。翻译面板与对话面板共用同一个引擎
//  （抓取 → 组装上下文 → 调模型 → 呈现），动作只决定这次用什么提示词、
//  要不要输入、要不要语言方向、走翻译专线还是对话引擎。
//
//  v5 的形态：
//  - 翻译是一键主动作（⌘2 → 抓取 → 立即翻译）
//  - 其余能力走语音/文字提问，不再做成一排需要先选的动作胶囊
//  - 总结/润色保留在枚举里，只为兼容旧结果历史的解码与「重用」
//

import Foundation
import SwiftUI

enum ChatAction: String, Identifiable {
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
    
}

