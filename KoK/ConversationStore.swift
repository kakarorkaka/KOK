//
//  ConversationStore.swift
//  KoK
//
//  「退出后保留当前对话」——默认关闭的可选项。
//
//  打开后：当前这一轮对话（文字 + 生成结果）会存到
//  ~/Library/Application Support/KoK/conversation.json，下次启动恢复；
//  点「新对话」或关掉开关都会删除它。
//
//  刻意不保存「输入图片」（截图 / 参考图）：它们体积最大、多是临时上下文，
//  存下来收益低、隐私面大。这一点在设置页的说明里写清楚了。
//

import Foundation

@MainActor
final class ConversationStore {
    static let shared = ConversationStore()
    
    struct StoredMessage: Codable {
        var role: String
        var text: String
        var hidden: Bool
        var transformSource: String?
        var transformActionId: String?
        /// 生成结果的图片文件名（images/ 下）
        var generatedImageFile: String?
    }
    
    private let directory: URL
    private let fileURL: URL
    
    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        directory = base.appendingPathComponent("KoK", isDirectory: true)
        fileURL = directory.appendingPathComponent("conversation.json")
    }
    
    var storedURL: URL { fileURL }
    
    func save(_ messages: [StoredMessage]) {
        guard !messages.isEmpty else {
            delete()
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(messages).write(to: fileURL, options: .atomic)
        } catch {
            Diagnostics.log("conversation: 保存失败 \(error.localizedDescription)")
        }
    }
    
    func load() -> [StoredMessage] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([StoredMessage].self, from: data)) ?? []
    }
    
    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
