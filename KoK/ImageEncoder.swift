//
//  ImageEncoder.swift
//  KoK
//
//  送进模型前的图片。
//
//  原图动辄几 MB，base64 之后会把首字延迟拖垮（正好抵消掉流式改造的收益），
//  所以统一缩放到最长边 1024 并转 JPEG，通常能压到 100–200 KB。
//

import AppKit

/// 一张已编码好的图片，可以直接塞进请求体
struct ImageAttachment: Equatable {
    let base64: String
    let mimeType: String
    let width: Int
    let height: Int
    let byteCount: Int
    
    /// 给人看的体积
    var sizeText: String {
        if byteCount < 1024 { return "\(byteCount) B" }
        if byteCount < 1024 * 1024 { return "\(byteCount / 1024) KB" }
        return String(format: "%.1f MB", Double(byteCount) / 1024 / 1024)
    }
    
    /// 给人看的尺寸
    var dimensionText: String { "\(width)×\(height)" }
}

/// 预览 / 导出时用得上的派生形式
extension ImageAttachment {
    
    /// 界面预览用（base64 → NSImage）。只在视图 onAppear 里调一次，避免重复解码。
    var previewImage: NSImage? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: data)
    }
    
    /// 原始编码数据（另存为 / 写临时文件用）
    var rawData: Data? { Data(base64Encoded: base64) }
    
    /// 按 mimeType 推断的文件扩展名
    var fileExtension: String {
        switch mimeType {
        case "image/png": return "png"
        case "image/heic": return "heic"
        case "image/gif": return "gif"
        default: return "jpg"
        }
    }
    
    /// 转成 PNG（复制到剪贴板用，兼容性最好）
    var pngData: Data? {
        guard let image = previewImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

enum ImageEncoder {
    static let maxDimension: CGFloat = 1024
    static let jpegQuality: CGFloat = 0.8
    
    /// 用 ImageIO 生成缩略图，而不是自己开离屏画布重绘。
    ///
    /// 之前用 `NSGraphicsContext(bitmapImageRep:)` + `draw(in:)` 手写缩放，
    /// 结果整张图变成纯黑——离屏绘制在后台上下文里静默失败了。
    /// ImageIO 是 Apple 推荐的缩放路径，顺带还能按 EXIF 自动纠正方向。
    static func encode(data: Data) -> ImageAttachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
        ]
        
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        
        let rep = NSBitmapImageRep(cgImage: thumbnail)
        guard let jpeg = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: jpegQuality]
        ) else { return nil }
        
        return ImageAttachment(
            base64: jpeg.base64EncodedString(),
            mimeType: "image/jpeg",
            width: thumbnail.width,
            height: thumbnail.height,
            byteCount: jpeg.count
        )
    }
    
    static func encode(_ image: NSImage) -> ImageAttachment? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return encode(data: tiff)
    }
    
    /// 从剪贴板取图片（用户复制图片 / 截图后都在这里）
    static func encode(pasteboard: NSPasteboard) -> ImageAttachment? {
        // 优先直接读位图数据，省一次 NSImage 往返
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let encoded = encode(data: data) {
                return encoded
            }
        }
        if let image = NSImage(pasteboard: pasteboard) {
            return encode(image)
        }
        return nil
    }
    
    /// 等比缩放到最长边不超过 maxDimension；本来就够小就原样返回
    private static func downscaled(_ source: NSBitmapImageRep) -> NSBitmapImageRep {
        let width = CGFloat(source.pixelsWide)
        let height = CGFloat(source.pixelsHigh)
        let longest = max(width, height)
        
        guard longest > maxDimension, longest > 0 else { return source }
        
        let scale = maxDimension / longest
        let newWidth = max(1, Int((width * scale).rounded()))
        let newHeight = max(1, Int((height * scale).rounded()))
        
        guard let target = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: newWidth,
            pixelsHigh: newHeight,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return source }
        
        target.size = NSSize(width: newWidth, height: newHeight)
        
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: newWidth, height: newHeight))
        NSGraphicsContext.restoreGraphicsState()
        
        return target
    }
}
