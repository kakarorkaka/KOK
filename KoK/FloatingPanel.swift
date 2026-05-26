//
//  FloatingPanel.swift
//  KoK
//
//  Created by Kakar on 2025/12/4.
//

import AppKit

class FloatingPanel: NSPanel {
    
    private let resizeEdgeThreshold: CGFloat = 6
    private var resizeDirection: ResizeDirection = .none
    private var initialMouseLocation: NSPoint = .zero
    private var initialFrame: NSRect = .zero
    
    enum ResizeDirection {
        case none
        case left, right, top, bottom
        case topLeft, topRight, bottomLeft, bottomRight
    }
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    
    // MARK: - 检测鼠标位置对应的 resize 方向
    
    private func resizeDirectionForEvent(_ event: NSEvent) -> ResizeDirection {
        let loc = event.locationInWindow
        let bounds = NSRect(origin: .zero, size: frame.size)
        let t = resizeEdgeThreshold
        
        let onLeft   = loc.x < t
        let onRight  = loc.x > bounds.width - t
        let onBottom = loc.y < t
        let onTop    = loc.y > bounds.height - t
        
        if onTop && onLeft     { return .topLeft }
        if onTop && onRight    { return .topRight }
        if onBottom && onLeft  { return .bottomLeft }
        if onBottom && onRight { return .bottomRight }
        if onLeft   { return .left }
        if onRight  { return .right }
        if onTop    { return .top }
        if onBottom { return .bottom }
        return .none
    }
    
    // MARK: - 鼠标光标
    
    override func mouseMoved(with event: NSEvent) {
        updateCursor(for: resizeDirectionForEvent(event))
        super.mouseMoved(with: event)
    }
    
    private func updateCursor(for direction: ResizeDirection) {
        switch direction {
        case .left, .right:
            NSCursor.resizeLeftRight.set()
        case .top, .bottom:
            NSCursor.resizeUpDown.set()
        case .topLeft, .bottomRight:
            NSCursor.crosshair.set() // macOS 没有对角线光标，用 crosshair 代替
        case .topRight, .bottomLeft:
            NSCursor.crosshair.set()
        case .none:
            NSCursor.arrow.set()
        }
    }
    
    // MARK: - 拖拽 resize
    
    override func mouseDown(with event: NSEvent) {
        resizeDirection = resizeDirectionForEvent(event)
        if resizeDirection != .none {
            initialMouseLocation = NSEvent.mouseLocation
            initialFrame = frame
        } else {
            super.mouseDown(with: event)
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard resizeDirection != .none else {
            super.mouseDragged(with: event)
            return
        }
        
        let currentMouse = NSEvent.mouseLocation
        let dx = currentMouse.x - initialMouseLocation.x
        let dy = currentMouse.y - initialMouseLocation.y
        
        var newFrame = initialFrame
        
        switch resizeDirection {
        case .right:
            newFrame.size.width = max(minSize.width, initialFrame.width + dx)
        case .left:
            let newWidth = max(minSize.width, initialFrame.width - dx)
            newFrame.origin.x = initialFrame.maxX - newWidth
            newFrame.size.width = newWidth
        case .top:
            newFrame.size.height = max(minSize.height, initialFrame.height + dy)
        case .bottom:
            let newHeight = max(minSize.height, initialFrame.height - dy)
            newFrame.origin.y = initialFrame.maxY - newHeight
            newFrame.size.height = newHeight
        case .topRight:
            newFrame.size.width = max(minSize.width, initialFrame.width + dx)
            newFrame.size.height = max(minSize.height, initialFrame.height + dy)
        case .topLeft:
            let newWidth = max(minSize.width, initialFrame.width - dx)
            newFrame.origin.x = initialFrame.maxX - newWidth
            newFrame.size.width = newWidth
            newFrame.size.height = max(minSize.height, initialFrame.height + dy)
        case .bottomRight:
            newFrame.size.width = max(minSize.width, initialFrame.width + dx)
            let newHeight = max(minSize.height, initialFrame.height - dy)
            newFrame.origin.y = initialFrame.maxY - newHeight
            newFrame.size.height = newHeight
        case .bottomLeft:
            let newWidth = max(minSize.width, initialFrame.width - dx)
            newFrame.origin.x = initialFrame.maxX - newWidth
            newFrame.size.width = newWidth
            let newHeight = max(minSize.height, initialFrame.height - dy)
            newFrame.origin.y = initialFrame.maxY - newHeight
            newFrame.size.height = newHeight
        case .none:
            break
        }
        
        // 限制最大尺寸
        newFrame.size.width = min(newFrame.size.width, maxSize.width)
        newFrame.size.height = min(newFrame.size.height, maxSize.height)
        
        setFrame(newFrame, display: true)
    }
    
    override func mouseUp(with event: NSEvent) {
        if resizeDirection != .none {
            resizeDirection = .none
            NSCursor.arrow.set()
        } else {
            super.mouseUp(with: event)
        }
    }
    
    // MARK: - 启用鼠标移动追踪（用于更新光标）
    
    override func orderFront(_ sender: Any?) {
        super.orderFront(sender)
        self.acceptsMouseMovedEvents = true
    }
}
