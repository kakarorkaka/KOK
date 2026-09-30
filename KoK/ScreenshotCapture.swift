//
//  ScreenshotCapture.swift
//  KoK
//
//  框选屏幕区域作为上下文。
//
//  为什么需要它：macOS 的辅助功能 API 只暴露「选中的文本」，没有「选中的图片」。
//  图片只能靠各 App 自己把位图写进剪贴板，所以 PDF 阅读器、微信、部分 Electron
//  应用里根本抓不到。截图不依赖任何 App——像素由我们自己从屏幕上取。
//
//  用系统的交互式截图（⇧⌘4 那套 UI），不自己造选择框：用户已经会用了。
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
    
    /// 调系统的交互式截图；用户框选或按 Esc 取消
    static func captureInteractive() async throws -> ImageAttachment {
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
        
        guard let image = ImageEncoder.encode(data: data) else {
            throw CaptureError.failed("无法解析截到的图")
        }
        
        Diagnostics.log("screenshot: 成功  \(image.dimensionText)  \(image.sizeText)")
        return image
    }
}
