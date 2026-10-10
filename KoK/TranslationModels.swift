//
//  TranslationModels.swift
//  KoK
//
//  翻译方向与历史记录。原来放在 TranslationViewModel 里，
//  两个面板合并成一个「动作面板」之后，这两样东西被 ChatViewModel 直接使用。
//

import Foundation

/// 自动 = 原文含中文译成英文、其余译成中文；也可以手动指定目标语言
enum TranslateDirection: String, CaseIterable, Identifiable {
    case auto, zh, en, ja, ko
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .auto: return "自动"
        case .zh: return "中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        }
    }
    
    /// 目标语言名（提示词用）；auto 时由调用方按原文推导
    var targetName: String {
        switch self {
        case .zh: return "Simplified Chinese"
        case .en: return "English"
        case .ja: return "Japanese"
        case .ko: return "Korean"
        case .auto: return ""
        }
    }
    
    /// DeepL 语言代码
    var code: String {
        switch self {
        case .zh: return "ZH"
        case .en: return "EN-US"
        case .ja: return "JA"
        case .ko: return "KO"
        case .auto: return ""
        }
    }
}

// MARK: - 翻译历史记录

struct TranslationRecord: Identifiable, Codable {
    let id: UUID
    let sourceText: String
    let translatedText: String
    let engineName: String
    let timestamp: Date
    
    init(sourceText: String, translatedText: String, engineName: String) {
        self.id = UUID()
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.engineName = engineName
        self.timestamp = Date()
    }
}
