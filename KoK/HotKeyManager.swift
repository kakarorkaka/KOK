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
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .translate: return "翻译"
        case .chat: return "对话"
        }
    }
    
    /// 未设置过时的默认快捷键
    ///
    /// 注意：不要用 ⌥A。macOS 上 `RegisterEventHotKey` 遇到冲突**不会报错**，
    /// 事件会被先注册方（如 iShot 等截图工具）吃掉，表现为快捷键完全没反应。
    /// ⌥A 是 iShot 的快速截图默认键，⌥B/D/E/F/G/H/O/P/Q/R/S/T/W/X/Z 也已被其占用。
    var defaultShortcut: (key: Key, modifiers: NSEvent.ModifierFlags) {
        switch self {
        case .translate: return (.d, [.option])
        case .chat: return (.k, [.option])
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
    
    /// 每个动作的触发回调
    var handlers: [HotKeyAction: () -> Void] = [:]
    
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
    }
    
    private init() {
        HotKeyAction.allCases.forEach { loadShortcut(for: $0) }
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
        
        // 迁移 2.0 早期版本的对话默认值：⌥A 被截图工具抢占，统一换成新的默认值
        if action == .chat,
           keyCode == Int(Key.a.carbonKeyCode),
           modifierRaw == Int(NSEvent.ModifierFlags.option.rawValue) {
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
