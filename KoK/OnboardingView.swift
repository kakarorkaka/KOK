//
//  OnboardingView.swift
//  KoK
//
//  首次启动的引导卡片：列出现有的快捷键与缺失的权限。
//  快捷键显示的是**当前实际注册**的键，而不是写死的默认值。
//

import SwiftUI
import HotKey
import ApplicationServices

// MARK: - 首次启动引导

/// 只出现一次的引导卡片：列出现有的快捷键与缺失的权限。
/// 快捷键显示的是**当前实际注册**的键，而不是写死的默认值。
struct OnboardingView: View {
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void
    
    private func shortcut(for action: HotKeyAction) -> String {
        HotKeyManager.shared.shortcut(for: action)?.displayString ?? "未设置"
    }
    
    private var missingPermissions: [String] {
        var missing: [String] = []
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            missing.append("辅助功能")
        }
        if VoiceInputService.needsPermission {
            missing.append("麦克风与语音")
        }
        if !ScreenshotCapture.hasPermission {
            missing.append("屏幕录制")
        }
        return missing
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "character.book.closed.fill")
                    .foregroundColor(.blue)
                Text("欢迎使用 KoK")
                    .font(.headline)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                shortcutRow(shortcut(for: .translate), "翻译选中文字")
                shortcutRow(shortcut(for: .chat), "打开对话")
                shortcutRow(shortcut(for: .voice), "按住说话（带选中内容）")
                shortcutRow(shortcut(for: .screenshot), "框选截图作为上下文")
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)
            
            if missingPermissions.isEmpty {
                Label("权限齐全", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Label("还差权限：\(missingPermissions.joined(separator: "、"))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            
            HStack {
                Button("打开设置") { onOpenSettings() }
                Spacer()
                Button("知道了") { onDismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
    
    private func shortcutRow(_ key: String, _ description: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.blue)
                .frame(width: 48, alignment: .leading)
            Text(description)
                .font(.system(size: 12))
        }
    }
}
