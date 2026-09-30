//
//  ImageGenerationService.swift
//  KoK
//
//  生图：腾讯混元 wand 接口（tokenhub.tencentmaas.com）。
//
//  实测（2026-09-30，混元 v3.5）：
//  - 纯文本提示词：HTTP 200，约 20s，1344×1792 PNG
//  - 参考图模式：image_url 支持 **data URI**（本地截图直接 base64，无需公网 URL）
//  - 计费按 tokenhub_usage.total_tokens（每次 15000）
//  - 响应里是 COS 签名 URL（有时效），所以要立刻下载到本地
//

import AppKit

/// 生成好的图片：全尺寸原图已下载到本地
struct GeneratedImage: Equatable {
    let fileURL: URL
    let width: Int
    let height: Int
    let byteCount: Int
    
    var dimensionText: String { "\(width)×\(height)" }
    
    var sizeText: String {
        if byteCount < 1024 * 1024 {
            return "\(max(1, byteCount / 1024)) KB"
        }
        return String(format: "%.1f MB", Double(byteCount) / 1024 / 1024)
    }
}

/// 生成尺寸。auto 不传 size，由模型按 prompt 语义与面积档位自行决定；
/// 其余按腾讯文档：宽高 ∈ [256, 8192]，面积 ≤ 16777216（4K）。
enum ImageGenSize: String, CaseIterable, Identifiable {
    case auto
    case square1k = "1024x1024"
    // 实测：非 16 倍数的尺寸会被模型吸附（1920x1080 → 1920x1072），
    // 所以预设都用 16 的倍数，保证出来就是想要的尺寸
    case landscape = "2560x1440"
    case portrait = "1440x2560"
    case k4 = "4096x4096"
    case k4landscape = "3840x2160"
    case k4portrait = "2160x3840"
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .auto: return "自动"
        case .square1k: return "1K 方形"
        case .landscape: return "2K 横版"
        case .portrait: return "2K 竖版"
        case .k4: return "4K 方形"
        case .k4landscape: return "4K 横版"
        case .k4portrait: return "4K 竖版"
        }
    }
    
    /// 传给接口的 size 参数；auto 返回 nil
    var sizeParam: String? {
        self == .auto ? nil : rawValue
    }
}

/// 生图服务：请求构造、响应解析、图片落地。
/// 与 LLMClient 分开——wand 协议和 chat completions 完全不是一回事。
final class ImageGenerationService {
    
    static let defaultURL = "https://tokenhub.tencentmaas.com/v1/wand/hunyuan-image/v35-generation"
    static let defaultModel = "hy-image-v3.5-preview"
    
    /// - Parameter reference: 可选参考图（已压缩的本地图片），走 data URI 上送
    func generate(
        prompt: String,
        reference: ImageAttachment?,
        url urlString: String,
        apiKey: String,
        model: String,
        size: String? = nil
    ) async throws -> GeneratedImage {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceError.missingAPIKey("生图服务")
        }
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        
        // ── 请求 ──────────────────────────────────────────────
        var content: [[String: Any]] = [
            ["type": "text", "text": prompt],
        ]
        if let reference {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:\(reference.mimeType);base64,\(reference.base64)"],
            ])
        }
        
        var body: [String: Any] = [
            "model": model,
            "session": "kok-\(UUID().uuidString)",
            "messages": [
                ["role": "user", "content": content],
            ],
        ]
        if let size, !size.isEmpty {
            body["size"] = size
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = String(data: data, encoding: .utf8) ?? "未知错误"
            throw ServiceError.apiError("生图服务", String(detail.prefix(300)))
        }
        
        // ── 解析 choices[0].delta.image.url ───────────────────
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable {
                    struct ImageRef: Decodable { let url: String }
                    let image: ImageRef?
                }
                let delta: Delta?
            }
            let choices: [Choice]?
        }
        
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let imageURLString = decoded.choices?.first?.delta?.image?.url,
              let imageURL = URL(string: imageURLString)
        else {
            throw ServiceError.emptyResponse("生图服务")
        }
        
        Diagnostics.log("imagegen: 出图 \(imageURLString.prefix(80))")
        
        // ── 立刻下载（COS 签名 URL 会过期，不能留给用户自己去点）──
        let (imageData, _) = try await URLSession.shared.data(from: imageURL)
        guard !imageData.isEmpty else { throw ServiceError.emptyResponse("生图服务") }
        
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KoK-gen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("\(UUID().uuidString).png")
        try imageData.write(to: fileURL)
        
        var width = 0, height = 0
        if let rep = NSBitmapImageRep(data: imageData) {
            width = rep.pixelsWide
            height = rep.pixelsHigh
        }
        
        return GeneratedImage(
            fileURL: fileURL,
            width: width,
            height: height,
            byteCount: imageData.count
        )
    }
}
