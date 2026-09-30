//
//  PanelController.swift
//  KoK
//
//  悬浮面板控制器基类：面板创建、鼠标附近定位、点击外部与 Esc 关闭。
//  翻译面板（WindowManager）与对话面板（ChatPanelController）共用这套逻辑。
//

import AppKit
import SwiftUI

@MainActor
class PanelController: NSObject, NSWindowDelegate {
    
    var panel: NSPanel?
    
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    
    var isVisible: Bool { panel?.isVisible ?? false }
    
    // MARK: - 子类可覆盖的尺寸
    
    var preferredWidth: CGFloat { 400 }
    var preferredHeight: CGFloat { 100 }
    var minimumSize: NSSize { NSSize(width: 300, height: 100) }
    var maximumSize: NSSize { NSSize(width: 800, height: 800) }
    
    /// 持久化用键名，子类覆盖避免互相覆盖
    var persistenceKey: String { "panel" }
    
    /// 是否记住用户拖出来的大小（翻译面板宽度固定，只有对话面板需要）
    var wantsSizePersistence: Bool { false }
    
    /// Esc 键行为，默认直接隐藏
    var onEscape: (() -> Void)?
    
    /// 即将显示时调用，用于与其它面板互斥
    var onWillShow: (() -> Void)?
    
    // MARK: - 构建
    
    func makePanel() {
        var initialSize = NSSize(width: preferredWidth, height: preferredHeight)
        if wantsSizePersistence, let saved = Self.restoredSize(for: persistenceKey) {
            initialSize = saved
        }
        
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.minSize = minimumSize
        panel.maxSize = maximumSize
        panel.delegate = self
        
        self.panel = panel
    }
    
    // MARK: - 大小记忆
    
    private func saveSize() {
        guard wantsSizePersistence, let panel else { return }
        let size = panel.frame.size
        UserDefaults.standard.set(
            "\(Int(size.width.rounded())),\(Int(size.height.rounded()))",
            forKey: "panel_size_\(persistenceKey)"
        )
    }
    
    private static func restoredSize(for key: String) -> NSSize? {
        guard let raw = UserDefaults.standard.string(forKey: "panel_size_\(key)") else { return nil }
        let parts = raw.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 100, parts[1] > 100 else { return nil }
        return NSSize(width: parts[0], height: parts[1])
    }
    
    func installContent<V: View>(_ view: V) {
        panel?.contentView = NSHostingView(rootView: view)
    }
    
    // MARK: - 显示 / 隐藏
    
    /// 显示在鼠标附近，并自动避免超出屏幕。
    /// - Parameter activate: 是否把 App 提到前台。语音场景要传 false——
    ///   一旦抢走焦点，模拟 ⌘C 就抓不到原来那个 App 里选中的内容了。
    func showWindow(activate: Bool = true, makeKey: Bool = true) {
        guard let panel = panel, let screen = NSScreen.main else { return }
        onWillShow?()
        
        let mouseLoc = NSEvent.mouseLocation
        let screenFrame = screen.visibleFrame
        let panelWidth = panel.frame.width
        let panelHeight = max(panel.frame.height, minimumSize.height)
        
        var x = mouseLoc.x + 10
        var y = mouseLoc.y - panelHeight
        
        // 右侧超出 → 弹到左边
        if x + panelWidth > screenFrame.maxX { x = mouseLoc.x - panelWidth - 10 }
        // 左侧超出 → 贴左边
        if x < screenFrame.minX { x = screenFrame.minX + 5 }
        // 底部超出 → 弹到上方
        if y < screenFrame.minY { y = mouseLoc.y + 10 }
        // 顶部超出
        if y + panelHeight > screenFrame.maxY { y = screenFrame.maxY - panelHeight }
        
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        if makeKey {
            panel.makeKeyAndOrderFront(nil)
        } else {
            // 只显示、不成为 key window：让原 App 继续持有键盘焦点，
            // 否则接下来模拟的 ⌘C 会打到我们自己身上，抓不到它的选中内容
            panel.orderFrontRegardless()
        }
        if activate {
            NSApp.activate()
        }
        Diagnostics.log("panel: 显示  activate=\(activate)  makeKey=\(makeKey)")
        
        startMonitors()
    }
    
    func hideWindow() {
        saveSize()
        panel?.orderOut(nil)
        stopMonitors()
    }
    
    func toggle() {
        isVisible ? hideWindow() : showWindow()
    }
    
    // MARK: - 事件监听
    
    private func startMonitors() {
        stopMonitors()
        
        // 点击面板外部关闭
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hideWindow()
        }
        
        // Esc 关闭
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            if let onEscape = self.onEscape {
                onEscape()
            } else {
                self.hideWindow()
            }
            return nil
        }
    }
    
    func windowDidResize(_ notification: Notification) {
        saveSize()
    }
    
    func stopMonitors() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
