//
//  SelectionProvider.swift
//  KoK
//
//  抓取当前选中的内容（文本或图片）。
//
//  macOS 没有「读取选中内容」的公开 API，只能模拟 ⌘C 再读剪贴板。
//  两个关键点：
//  1. 必须确认剪贴板**真的变了**才当作选中内容，否则什么都没选中时
//     会把上一次复制的旧内容当上下文塞给模型——比不带上下文更糟。
//  2. 剪贴板一变就立刻返回，不要固定轮询满超时（旧实现无选中时要空等 1 秒）。
//

import AppKit
import Carbon

@MainActor
enum SelectionProvider {
    
    struct Capture: Equatable {
        var text: String?
        var image: ImageAttachment?
        /// 文本被截断时置为 true，界面上要给用户提示
        var truncated = false
        
        var isEmpty: Bool { text == nil && image == nil }
    }
    
    /// 单选文本最多带这么多字符，避免一次全选把请求撑爆
    static let maxTextLength = 20_000
    
    /// 模拟 ⌘C 抓取选中内容；没选中任何东西时返回空 Capture。
    /// - Parameter timeout: 等待剪贴板变化的最长时间
    static func capture(timeout: TimeInterval = 0.6) async -> Capture {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        
        postCopyCommand()
        
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pasteboard.changeCount != before {
                return read(from: pasteboard)
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        
        return Capture()
    }
    
    // MARK: - 读取
    
    private static func read(from pasteboard: NSPasteboard) -> Capture {
        // 图片优先：复制图片 / 截图时剪贴板里是位图
        if let image = ImageEncoder.encode(pasteboard: pasteboard) {
            return Capture(text: nil, image: image)
        }
        
        // Finder 里复制图片文件：拿到的是文件路径
        if let fileImage = imageFromFileURL(on: pasteboard) {
            return Capture(text: nil, image: fileImage)
        }
        
        if let raw = pasteboard.string(forType: .string) {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if text.count > maxTextLength {
                    return Capture(text: String(text.prefix(maxTextLength)), truncated: true)
                }
                return Capture(text: text)
            }
        }
        
        return Capture()
    }
    
    private static func imageFromFileURL(on pasteboard: NSPasteboard) -> ImageAttachment? {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "webp", "bmp"]
        
        let urls: [URL]
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            urls = objects
        } else {
            urls = []
        }
        
        for url in urls where url.isFileURL {
            guard imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if let data = try? Data(contentsOf: url), let encoded = ImageEncoder.encode(data: data) {
                return encoded
            }
        }
        return nil
    }
    
    // MARK: - 模拟 ⌘C
    
    private static func postCopyCommand() {
        let source = CGEventSource(stateID: .hidSystemState)
        let cmdKey: CGKeyCode = 0x37
        let cKey: CGKeyCode = 0x08
        
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true),
              let cDown = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true),
              let cUp = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)
        else { return }
        
        cmdDown.flags = .maskCommand
        cDown.flags = .maskCommand
        cUp.flags = .maskCommand
        cmdUp.flags = []
        
        cmdDown.post(tap: .cghidEventTap)
        cDown.post(tap: .cghidEventTap)
        cUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
    }
}
