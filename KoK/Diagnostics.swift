//
//  Diagnostics.swift
//  KoK
//
//  轻量诊断日志。默认不写任何东西——只有存在开关文件时才记录。
//
//  用途：像「模拟 ⌘C 抓选中内容」这种依赖系统权限与焦点状态的链路，
//  出问题时靠猜没用，需要看到 changeCount、权限状态、焦点时序这些事实。
//
//  开启：touch ~/Library/Logs/KoK/diagnostics.enabled
//  查看：cat ~/Library/Logs/KoK/diagnostics.log
//

import Foundation

enum Diagnostics {
    
    private static let directory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/KoK", isDirectory: true)
    
    private static var logURL: URL { directory.appendingPathComponent("diagnostics.log") }
    
    private static var isEnabled: Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("diagnostics.enabled").path
        )
    }
    
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    /// 主线程心跳：每秒把时间戳覆盖写进 heartbeat.txt。
    ///
    /// 界面上冻住时，这个文件不再更新 —— 它的修改时间就是「最后还活着」的时刻。
    /// 和 diagnostics.log 的最后一行对照，就能锁定是哪个动作之后卡住的。
    /// 常开（不依赖 diagnostics.enabled），每次只写几十字节。
    static func heartbeat() {
        let stamp = formatter.string(from: Date())
        try? stamp.data(using: .utf8)?.write(to: heartbeatURL, options: .atomic)
    }
    
    private static var heartbeatURL: URL { directory.appendingPathComponent("heartbeat.txt") }
    
    static func log(_ message: String) {
        guard isEnabled else { return }
        
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}
