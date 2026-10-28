//
//  ScreenshotCapture.swift
//  KoK
//
//  独立截图：框选屏幕区域，直接把原图放进剪贴板。
//
//  为什么用系统的交互式截图（⇧⌘4 那套 UI）：用户已经会用了；
//  不自己造选择框，也不把截图先塞进提问面板。
//
//  截图原图不经过「送模型前压缩」那条链路——粘贴到别的 App 时应该保持原始分辨率。
//

import AppKit
import CoreGraphics

@MainActor
enum ScreenshotCapture {
    
    enum CaptureError: LocalizedError {
        case permissionDenied
        case cancelled
        case failed(String)
        
        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "需要「屏幕录制」权限：系统设置 ▸ 隐私与安全性 ▸ 屏幕录制，勾选 KoK 后重开 App"
            case .cancelled:
                return "已取消截图"
            case .failed(let detail):
                return "截图失败：\(detail)"
            }
        }
    }
    
    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }
    
    /// 弹系统对话框并跳到「屏幕录制」设置页
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }
    
    /// 调系统的交互式截图；用户框选或按 Esc 取消。
    /// 返回原始 PNG 数据，不做缩放。
    static func captureInteractivePNG() async throws -> Data {
        guard hasPermission else {
            requestPermission()
            throw CaptureError.permissionDenied
        }
        
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("kok-shot-\(UUID().uuidString).png")
            .path
        defer { try? FileManager.default.removeItem(atPath: path) }
        
        // screencapture 会一直等到用户框完或按 Esc，不能占着主线程
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                // -i 交互式框选，-x 不发声，-t png 明确格式
                process.arguments = ["-i", "-x", "-t", "png", path]
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: CaptureError.failed(error.localizedDescription))
                }
            }
        }
        
        // 取消时 screencapture 不会产出文件，靠这个区分「取消」和「失败」
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
            throw CaptureError.cancelled
        }
        
        return data
    }
    
    /// 框选后直接复制到剪贴板：不打开面板、不进入对话。
    static func copyInteractiveToPasteboard() async throws {
        let data = try await captureInteractivePNG()
        
        guard let image = NSImage(data: data) else {
            throw CaptureError.failed("无法解析截到的图")
        }
        
        // 同时给 PNG 和 TIFF：大多数 App 吃 PNG，少数老 App / 设计工具认 TIFF。
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        if let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw CaptureError.failed("写入剪贴板失败")
        }
        
        Diagnostics.log("screenshot: 已复制到剪贴板  \(Int(image.size.width))×\(Int(image.size.height))")
    }
}
