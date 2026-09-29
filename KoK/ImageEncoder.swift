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

enum ImageEncoder {
    static let maxDimension: CGFloat = 1024
    static let jpegQuality: CGFloat = 0.8
    
    static func encode(_ image: NSImage) -> ImageAttachment? {
        guard let tiff = image.tiffRepresentation,
              let source = NSBitmapImageRep(data: tiff)
        else { return nil }
        
        let target = downscaled(source)
        guard let jpeg = target.representation(
            using: .jpeg,
            properties: [.compressionFactor: jpegQuality]
        ) else { return nil }
        
        return ImageAttachment(
            base64: jpeg.base64EncodedString(),
            mimeType: "image/jpeg",
            width: target.pixelsWide,
            height: target.pixelsHigh,
            byteCount: jpeg.count
        )
    }
    
    static func encode(data: Data) -> ImageAttachment? {
        guard let image = NSImage(data: data) else { return nil }
        return encode(image)
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
