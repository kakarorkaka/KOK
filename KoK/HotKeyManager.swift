//
//  HotKeyManager.swift
//  KoK
//
//  Created by Kakar on 2025/12/4.
//

import SwiftUI
import HotKey
import Carbon
import Combine

// MARK: - 快捷键动作

/// 一个动作对应一个全局快捷键。新增功能只需在这里加一个 case。
enum HotKeyAction: String, CaseIterable, Identifiable {
    case translate
    case chat
    /// 按住说话：按下开始录音、松开结束并发送
    case voice
    /// 框选屏幕区域作为上下文
    case screenshot
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .translate: return "翻译"
        case .chat: return "对话"
        case .voice: return "语音"
        case .screenshot: return "截图"
        }
    }
    
    /// 说明文字，用在设置页的注释里
    var hint: String? {
        switch self {
        case .voice: return "按住说话，松开后连同选中内容一起发送"
        case .screenshot: return "框选屏幕区域，作为上下文"
        default: return nil
        }
    }
    
    /// 未设置过时的默认快捷键。
    ///
    /// 选键原则：避开 iShot 等工具常占用的 ⌥ 组合（iShot 默认就占了
    /// ⌥A/B/D/E/F/G/H/O/P/Q/R/S/T/W/X/Z）。注意 macOS 上 `RegisterEventHotKey`
    /// 遇到冲突**不会报错**，事件会被先注册方静默吃掉，表现为「按了完全没反应」。
    var defaultShortcut: (key: Key, modifiers: NSEvent.ModifierFlags) {
        switch self {
        case .translate: return (.d, [.option])
        case .chat: return (.one, [.command])
        case .voice: return (.v, [.option])
        // ⌥S / ⌥A 都被 iShot 占了（区域截图 / 快速截图）
        case .screenshot: return (.c, [.option])
        }
    }
}

// MARK: - 快捷键管理

/// 管理多个全局快捷键。
///
/// 与 1.x 的差异：过去只支持单个快捷键（`onTrigger`），现在按 `HotKeyAction` 注册多个。
/// 旧的 `shortcut_keycode` / `shortcut_modifiers` 会被自动迁移到 `.translate`，用户设置不丢。
class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()
    
    /// 每个动作的按下回调
    var handlers: [HotKeyAction: () -> Void] = [:]
    
    /// 每个动作的松开回调（只有「按住说话」需要）
    var releaseHandlers: [HotKeyAction: () -> Void] = [:]
    
    /// 设置页自检用：安装后，快捷键触发只回调这里，不执行真实动作。
    /// 系统不提供「这个组合是否被别的 App 占用」的查询接口，只能实测。
    var testObserver: ((HotKeyAction) -> Void)?
    
    @Published private(set) var shortcuts: [HotKeyAction: Shortcut] = [:]
    
    private var hotKeys: [HotKeyAction: HotKey] = [:]
    
    struct Shortcut {
        let key: Key
        let modifiers: NSEvent.ModifierFlags
        
        /// 只比较用户可感知的部分（忽略设备相关标志位）
        func isSame(as other: Shortcut) -> Bool {
            key.carbonKeyCode == other.key.carbonKeyCode
                && normalized(modifiers) == normalized(other.modifiers)
        }
        
        private func normalized(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
            flags.intersection(.deviceIndependentFlagsMask)
        }
        
        /// 给人看的写法，如 ⌘1、⌥V。设置页与首次引导共用。
        var displayString: String {
            var result = ""
            let flags = normalized(modifiers)
            if flags.contains(.control) { result += "⌃" }
            if flags.contains(.option) { result += "⌥" }
            if flags.contains(.shift) { result += "⇧" }
            if flags.contains(.command) { result += "⌘" }
            result += Self.keyName(for: key)
            return result
        }
        
        static func keyName(for key: Key) -> String {
            let mapping: [Key: String] = [
                .a: "A", .b: "B", .c: "C", .d: "D", .e: "E", .f: "F",
                .g: "G", .h: "H", .i: "I", .j: "J", .k: "K", .l: "L",
                .m: "M", .n: "N", .o: "O", .p: "P", .q: "Q", .r: "R",
                .s: "S", .t: "T", .u: "U", .v: "V", .w: "W", .x: "X",
                .y: "Y", .z: "Z",
                .zero: "0", .one: "1", .two: "2", .three: "3", .four: "4",
                .five: "5", .six: "6", .seven: "7", .eight: "8", .nine: "9",
                .space: "Space", .return: "Return", .tab: "Tab", .escape: "Esc",
                .delete: "Delete", .forwardDelete: "Fwd Del",
                .upArrow: "↑", .downArrow: "↓", .leftArrow: "←", .rightArrow: "→",
                .f1: "F1", .f2: "F2", .f3: "F3", .f4: "F4", .f5: "F5",
                .f6: "F6", .f7: "F7", .f8: "F8", .f9: "F9", .f10: "F10",
                .f11: "F11", .f12: "F12",
            ]
            return mapping[key] ?? String(describing: key).uppercased()
        }
    }
    
    private init() {
        HotKeyAction.allCases.forEach { loadShortcut(for: $0) }
        // 完成迁移后再落版本号，保证迁移只发生一次
        UserDefaults.standard.set(Self.defaultsVersion, forKey: Self.defaultsVersionKey)
    }
    
    // MARK: - 默认值迁移
    
    /// 内置默认值版本。每次更换默认键就 +1。
    private static let defaultsVersionKey = "shortcut_defaults_version"
    private static let defaultsVersion = 1
    
    /// 历史上作为默认值发布过、现已废弃的组合。
    /// 用户保存的值命中这里，说明他从没手动改过，就跟着新默认一起升级。
    private static let deprecatedDefaults: [HotKeyAction: [(Key, NSEvent.ModifierFlags)]] = [
        .chat: [(.a, [.option]), (.k, [.option])]
    ]
    
    private static func isDeprecatedDefault(_ action: HotKeyAction, key: Key, modifierRaw: Int) -> Bool {
        guard let candidates = deprecatedDefaults[action] else { return false }
        return candidates.contains { candidate in
            candidate.0.carbonKeyCode == key.carbonKeyCode
                && Int(candidate.1.rawValue) == modifierRaw
        }
    }
    
    // MARK: - 注册
    
    /// 注册（或替换）某个动作的快捷键。旧实例释放时会自动注销。
    func register(_ action: HotKeyAction, key: Key, modifiers: NSEvent.ModifierFlags) {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        
        let hotKey = HotKey(key: key, modifiers: modifiers)
        
        hotKey.keyDownHandler = { [weak self] in
            guard let self else { return }
            // 自检期间吞掉真实动作，避免触发翻译/弹窗
            if let observer = self.testObserver {
                observer(action)
                return
            }
            self.handlers[action]?()
        }
        
        // 「按住说话」靠它判断松手
        hotKey.keyUpHandler = { [weak self] in
            self?.releaseHandlers[action]?()
        }
        
        hotKeys[action] = hotKey
        shortcuts[action] = Shortcut(key: key, modifiers: modifiers)
        save(action, key: key, modifiers: modifiers)
    }
    
    func shortcut(for action: HotKeyAction) -> Shortcut? {
        shortcuts[action]
    }
    
    /// 录制快捷键时暂停所有监听，避免误触发
    func pause() {
        hotKeys.values.forEach { $0.isPaused = true }
    }
    
    func resume() {
        hotKeys.values.forEach { $0.isPaused = false }
    }
    
    // MARK: - 持久化
    
    private func keyCodeKey(_ action: HotKeyAction) -> String {
        "shortcut_\(action.rawValue)_keycode"
    }
    
    private func modifiersKey(_ action: HotKeyAction) -> String {
        "shortcut_\(action.rawValue)_modifiers"
    }
    
    private func save(_ action: HotKeyAction, key: Key, modifiers: NSEvent.ModifierFlags) {
        UserDefaults.standard.set(Int(key.carbonKeyCode), forKey: keyCodeKey(action))
        UserDefaults.standard.set(modifiers.rawValue, forKey: modifiersKey(action))
    }
    
    private func loadShortcut(for action: HotKeyAction) {
        var keyCode = UserDefaults.standard.integer(forKey: keyCodeKey(action))
        var modifierRaw = UserDefaults.standard.integer(forKey: modifiersKey(action))
        
        // 迁移 1.x 的单快捷键配置，保证老用户已设置的 ⌥D 不丢失
        if action == .translate, keyCode == 0, modifierRaw == 0 {
            keyCode = UserDefaults.standard.integer(forKey: "shortcut_keycode")
            modifierRaw = UserDefaults.standard.integer(forKey: "shortcut_modifiers")
        }
        
        // 内置默认值变更：仅当保存的组合恰好是「历史默认值」时才跟随升级，
        // 用户自己改过的组合不动。
        let storedVersion = UserDefaults.standard.integer(forKey: Self.defaultsVersionKey)
        if storedVersion < Self.defaultsVersion,
           let key = Key(carbonKeyCode: UInt32(keyCode)),
           Self.isDeprecatedDefault(action, key: key, modifierRaw: modifierRaw) {
            let fallback = action.defaultShortcut
            register(action, key: fallback.key, modifiers: fallback.modifiers)
            return
        }
        
        if (keyCode != 0 || modifierRaw != 0), let key = Key(carbonKeyCode: UInt32(keyCode)) {
            register(action, key: key, modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifierRaw)))
            return
        }
        
        let fallback = action.defaultShortcut
        register(action, key: fallback.key, modifiers: fallback.modifiers)
    }
}
