//
//  PromptTemplate.swift
//  KoK
//
//  提示词变量替换。
//
//  只认一种写法太苛刻了：用户很自然会写 `{target_lang}`，结果变量静默不生效、
//  原样发给模型。这里兼容大小写与单双括号四种写法。
//

import Foundation

enum PromptTemplate {
    
    /// 支持的变量（仅翻译提示词）
    enum Variable: String, CaseIterable {
        case targetLang = "TARGET_LANG"
        case sourceLang = "SOURCE_LANG"
        
        /// 推荐写法
        var display: String { "{{\(rawValue)}}" }
        
        var explanation: String {
            switch self {
            case .targetLang: return "目标语言"
            case .sourceLang: return "源语言"
            }
        }
    }
    
    /// 把模板里的变量替换成实际语言名。
    ///
    /// 兼容 `{{TARGET_LANG}}`、`{TARGET_LANG}`、`{{target_lang}}`、`{target_lang}`。
    /// 双括号必须排在单括号前面替换，否则 `{TARGET_LANG}` 会先把 `{{TARGET_LANG}}` 拆成
    /// 半个花括号加变量名，留下残余的 `{`。
    static func fill(_ template: String, targetLang: String) -> String {
        // App 判断出的翻译方向：中文原文 → 译成英文，其余 → 译成中文
        let isChineseTarget = (targetLang == "ZH")
        let values: [Variable: String] = [
            .targetLang: isChineseTarget ? "Simplified Chinese" : "English",
            .sourceLang: isChineseTarget ? "English" : "Simplified Chinese",
        ]
        
        var result = template
        for variable in Variable.allCases {
            guard let value = values[variable] else { continue }
            for alias in aliases(for: variable) {
                result = result.replacingOccurrences(of: alias, with: value)
            }
        }
        return result
    }
    
    /// 找出模板里出现、但 KoK 不会替换的占位符，用于在界面上提醒用户。
    /// 静默失效比报错更糟：用户会以为变量生效了。
    static func unresolvedPlaceholders(in template: String) -> [String] {
        let pattern = "\\{\\{?[A-Za-z_][A-Za-z0-9_]*\\}?\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        
        let known = Set(Variable.allCases.flatMap { aliases(for: $0) })
        let text = template as NSString
        let matches = regex.matches(in: template, range: NSRange(location: 0, length: text.length))
        
        var unknown: [String] = []
        for match in matches {
            let placeholder = text.substring(with: match.range)
            if !known.contains(placeholder), !unknown.contains(placeholder) {
                unknown.append(placeholder)
            }
        }
        return unknown
    }
    
    private static func aliases(for variable: Variable) -> [String] {
        let upper = variable.rawValue
        let lower = upper.lowercased()
        // 双括号在前
        return ["{{\(upper)}}", "{{\(lower)}}", "{\(upper)}", "{\(lower)}"]
    }
}
