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

class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()
    
    // 定义属性（不直接赋初值，留给 init 处理）
    private var hotKey: HotKey?
    
    @Published var currentKey: Key?
    @Published var currentModifiers: NSEvent.ModifierFlags?
    
    var onTrigger: (() -> Void)?
    
    private init() {
        // 1. 【关键步骤】必须先给所有存储属性赋值
        // 即使是 nil，也必须显式写出来，告诉编译器“初始化完成了”
        self.hotKey = nil
        self.currentKey = nil
        self.currentModifiers = nil
        self.onTrigger = nil
        
        // 2. 现在 self 已经完全初始化，可以安全调用实例方法了
        self.loadShortcut()
    }
    
    // 注册/更新快捷键
    func register(key: Key, modifiers: NSEvent.ModifierFlags) {
        // 1. 清除旧的
        hotKey = nil
        
        // 2. 创建新的
        hotKey = HotKey(key: key, modifiers: modifiers)
        
        // 3. 绑定回调
        hotKey?.keyDownHandler = { [weak self] in
            print("HotKey Triggered!")
            self?.onTrigger?()
        }
        
        // 4. 更新内存状态
        self.currentKey = key
        self.currentModifiers = modifiers
        
        // 5. 持久化保存
        saveShortcut(key: key, modifiers: modifiers)
    }
    
    // 暂停监听 (在录制时防止冲突)
    func pause() {
        hotKey?.isPaused = true
    }
    
    // 恢复监听
    func resume() {
        hotKey?.isPaused = false
    }
    
    // MARK: - Persistence (UserDefaults)
    
    private func saveShortcut(key: Key, modifiers: NSEvent.ModifierFlags) {
        UserDefaults.standard.set(Int(key.carbonKeyCode), forKey: "shortcut_keycode")
        UserDefaults.standard.set(modifiers.rawValue, forKey: "shortcut_modifiers")
    }
    
    private func loadShortcut() {
        let keyCode = UserDefaults.standard.integer(forKey: "shortcut_keycode")
        let modifierRaw = UserDefaults.standard.integer(forKey: "shortcut_modifiers")
        
        // 检查是否有保存的记录
        // 注意：如果 modifierRaw 为 0，说明可能没存过（因为通常快捷键会有修饰键）
        // 或者用户真的设置了单键（极少见），这里为了简单，假设 0 就是没存过
        if keyCode != 0 || modifierRaw != 0 {
            if let key = Key(carbonKeyCode: UInt32(keyCode)) {
                let modifiers = NSEvent.ModifierFlags(rawValue: UInt(modifierRaw))
                register(key: key, modifiers: modifiers)
                return
            }
        }
        
        // 默认快捷键: Option + D
        register(key: .d, modifiers: [.option])
    }
}
