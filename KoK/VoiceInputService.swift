//
//  VoiceInputService.swift
//  KoK
//
//  按住说话：录音 + 系统语音识别。
//
//  用系统的 SFSpeechRecognizer 而不是自带模型——它零体积、零成本、
//  中文可离线，且带流式部分结果。要塞本地 Whisper 就得几百 MB，
//  和这个 App 的轻量前提冲突。
//

import Foundation
import AVFoundation
import Speech
import Combine

/// 可选的识别语言。只列实测在这台机器上支持**离线**识别的：
/// zh-TW / ja-JP 等虽然能识别，但没有本地资源，要走网络。
enum VoiceLocale: String, CaseIterable, Identifiable {
    case chinese = "zh-CN"
    case english = "en-US"
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "English"
        }
    }
}

@MainActor
final class VoiceInputService: ObservableObject {
    
    enum VoiceError: LocalizedError {
        case microphoneDenied
        case speechDenied
        case recognizerUnavailable(String)
        case audioEngineFailed(String)
        case noInputDevice
        
        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "没有麦克风权限：系统设置 ▸ 隐私与安全性 ▸ 麦克风，勾选 KoK"
            case .speechDenied:
                return "没有语音识别权限：系统设置 ▸ 隐私与安全性 ▸ 语音识别，勾选 KoK"
            case .recognizerUnavailable(let locale):
                return "暂时无法识别「\(locale)」，请稍后重试"
            case .audioEngineFailed(let detail):
                return "无法开始录音：\(detail)"
            case .noInputDevice:
                return "没有可用的麦克风"
            }
        }
    }
    
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?
    
    /// 兜底：万一「松开」事件丢了，录音也不会一直开着
    static let maxRecordingSeconds: TimeInterval = 60
    
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isTapInstalled = false
    private var isFinal = false
    private var startedAt: Date?
    
    // MARK: - 权限
    
    static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    
    static var speechAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }
    
    static var needsPermission: Bool {
        !microphoneAuthorized || !speechAuthorized
    }
    
    /// 依次申请麦克风与语音识别权限
    static func requestPermissions() async -> (microphone: Bool, speech: Bool) {
        let microphone = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        
        return (microphone, speech)
    }
    
    // MARK: - 录音
    
    func start(localeIdentifier: String) throws {
        guard !isRecording else { return }
        
        guard Self.microphoneAuthorized else { throw VoiceError.microphoneDenied }
        guard Self.speechAuthorized else { throw VoiceError.speechDenied }
        
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            throw VoiceError.recognizerUnavailable(localeIdentifier)
        }
        guard recognizer.isAvailable else {
            throw VoiceError.recognizerUnavailable(localeIdentifier)
        }
        
        transcript = ""
        errorMessage = nil
        isFinal = false
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // 有离线资源就走本地，既快又不出网
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request
        
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { throw VoiceError.noInputDevice }
        
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            request.append(buffer)
        }
        isTapInstalled = true
        
        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardownAudio()
            throw VoiceError.audioEngineFailed(error.localizedDescription)
        }
        
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal { self.isFinal = true }
                }
                if error != nil { self.isFinal = true }
            }
        }
        
        startedAt = Date()
        isRecording = true
    }
    
    /// 松开快捷键：停止录音，等最终转写（最多 1.2 秒）
    @discardableResult
    func finish() async -> String {
        guard isRecording else { return transcript }
        
        isRecording = false
        teardownAudio()
        request?.endAudio()
        
        // endAudio 之后通常还会补一个 isFinal 的结果，等它一下
        for _ in 0..<24 {
            if isFinal { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        
        task?.cancel()
        task = nil
        request = nil
        startedAt = nil
        
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func cancel() {
        isRecording = false
        teardownAudio()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        startedAt = nil
        transcript = ""
    }
    
    /// 已录了多久（用来把「刚过阈值就松手」识别成慢速点按）
    var recordingDuration: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }
    
    /// 录音超时（keyUp 丢失时的兜底判断）
    var isOverTimeLimit: Bool {
        guard let startedAt else { return false }
        return Date().timeIntervalSince(startedAt) > Self.maxRecordingSeconds
    }
    
    private func teardownAudio() {
        if engine.isRunning { engine.stop() }
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
    }
}
