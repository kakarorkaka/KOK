//
//  ResultStore.swift
//  KoK
//
//  结果历史：翻译 / 总结 / 润色 / 生图 的产出都留一条，方便回看和复用。
//
//  为什么不继续用 UserDefaults：
//  - 生图结果是大文件（1–3 MB），必须单独存文件，记录里只留文件名
//  - 记录条数一多，plist 会变得很重、读写都慢
//  所以统一放 ~/Library/Application Support/KoK/：
//  - results.json   记录列表（上限 maxRecords 条，超出淘汰最旧的）
//  - images/*.png   生图原图（记录被淘汰 / 清空时一并删除）
//

import Foundation
import AppKit
import Combine

@MainActor
final class ResultStore: ObservableObject {
    static let shared = ResultStore()
    
    // MARK: - 记录模型
    
    enum Kind: String, Codable {
        case translate, summarize, polish, image
        
        var title: String {
            switch self {
            case .translate: return "翻译"
            case .summarize: return "总结"
            case .polish: return "润色"
            case .image: return "生图"
            }
        }
        
        var icon: String {
            switch self {
            case .translate: return "character.book.closed"
            case .summarize: return "text.alignleft"
            case .polish: return "paintbrush"
            case .image: return "photo"
            }
        }
    }
    
    struct Record: Identifiable, Codable, Equatable {
        let id: UUID
        let kind: Kind
        let sourceText: String
        let outputText: String
        let engineName: String
        let timestamp: Date
        /// 生图结果：images/ 下的文件名
        var imageFile: String?
        
        var isImage: Bool { kind == .image }
        
        /// 历史列表里显示的一行摘要
        var summary: String {
            outputText.isEmpty ? sourceText : outputText
        }
    }
    
    @Published private(set) var records: [Record] = []
    
    /// 记录上限：超出后淘汰最旧的（连同它的图片文件）
    private let maxRecords = 100
    
    let directory: URL
    let imagesDirectory: URL
    private let storeURL: URL
    private let legacyHistoryKey = "translation_history"
    
    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        directory = base.appendingPathComponent("KoK", isDirectory: true)
        imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)
        storeURL = directory.appendingPathComponent("results.json")
        
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        load()
        migrateLegacyHistoryIfNeeded()
    }
    
    // MARK: - 增删查
    
    func add(_ record: Record) {
        records.insert(record, at: 0)
        trim()
        save()
    }
    
    func delete(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        removeImageFile(of: records[index])
        records.remove(at: index)
        save()
    }
    
    func clear() {
        records.forEach { removeImageFile(of: $0) }
        records.removeAll()
        save()
    }
    
    func imageURL(for record: Record) -> URL? {
        guard let file = record.imageFile else { return nil }
        return imagesDirectory.appendingPathComponent(file)
    }
    
    /// 生图服务写入图片时用的文件名
    func newImageFileName() -> String { "\(UUID().uuidString).png" }
    
    // MARK: - 内部
    
    private func trim() {
        guard records.count > maxRecords else { return }
        records[maxRecords...].forEach { removeImageFile(of: $0) }
        records = Array(records.prefix(maxRecords))
    }
    
    private func removeImageFile(of record: Record) {
        guard let url = imageURL(for: record) else { return }
        try? FileManager.default.removeItem(at: url)
    }
    
    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: storeURL, options: .atomic)
        } catch {
            Diagnostics.log("results: 保存失败 \(error.localizedDescription)")
        }
    }
    
    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([Record].self, from: data) else { return }
        records = decoded
    }
    
    /// 把 3.x 存在 UserDefaults 里的翻译历史迁过来（只做一次）
    private func migrateLegacyHistoryIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: legacyHistoryKey),
              let legacy = try? JSONDecoder().decode([TranslationRecord].self, from: data),
              !legacy.isEmpty
        else { return }
        
        records.append(contentsOf: legacy.map {
            Record(
                id: $0.id,
                kind: .translate,
                sourceText: $0.sourceText,
                outputText: $0.translatedText,
                engineName: $0.engineName,
                timestamp: $0.timestamp,
                imageFile: nil
            )
        })
        records.sort { $0.timestamp > $1.timestamp }
        trim()
        save()
        UserDefaults.standard.removeObject(forKey: legacyHistoryKey)
        Diagnostics.log("results: 迁移旧翻译历史 \(legacy.count) 条")
    }
}
