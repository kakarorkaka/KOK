//
//  ChatViewModel.swift
//  KoK
//
//  快速问答面板的状态：消息列表、流式输出、发送 / 停止 / 重生成。
//  对话只保存在内存里，关掉就重来，不落盘。
//

import SwiftUI
import Combine
import AppKit

// MARK: - 自动生图路由

/// 模型在回复里携带标记块，客户端解析后自动调用生图服务（合并判断方案）。
/// 模型想在回复最开头输出 `<kok-image-gen>提示词</kok-image-gen>`，
/// 客户端把标记块从显示文本里剥掉，拿提示词去生图，图出来后贴到同一条消息上。
enum ImageGenIntentMarker {
    static let open = "<kok-image-gen>"
    static let close = "</kok-image-gen>"
    
    /// 附加到对话系统提示词末尾的路由规则（生图服务已配置时才附加）
    static let routingInstruction = """
    [自动路由规则]
    当用户明确要求现在生成一张图片时（例如“生成/画/做一张…”“帮我做一张海报”，或结合对话中已有的参考图生成新图），你必须严格在回复最开头输出一个标记块，块内是把用户需求改写成的完整英文提示词（画面内容、风格、构图、光照都要写全）：

    <kok-image-gen>
    你的英文提示词写在这里
    </kok-image-gen>

    标记块之后另起一段，用与用户相同的语言简短说明你将要生成的内容。图片随后会自动出现。
    其余情况（提问、分析、翻译、闲聊，以及“描述/分析这张图”这类看图任务）一律禁止输出该标记。
    """
    
    /// 流式阶段：剥掉标记区，返回当前应该显示的文字。
    /// 前缀未决（可能是标记的开头）或标记未闭合时返回空串。
    static func visiblePrefix(_ buffer: String) -> String {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if open.hasPrefix(trimmed) || trimmed.hasPrefix(open) {
            guard let closeRange = trimmed.range(of: close) else { return "" }
            return String(trimmed[closeRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return buffer
    }
    
    /// 流式阶段：开头标记已闭合时返回其中的提示词（原始内容，未清洗）
    static func promptIfClosed(_ buffer: String) -> String? {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(open) else { return nil }
        let afterOpen = trimmed.index(trimmed.startIndex, offsetBy: open.count)
        guard let closeRange = trimmed.range(of: close, range: afterOpen..<trimmed.endIndex) else { return nil }
        return String(trimmed[afterOpen..<closeRange.lowerBound])
    }
    
    /// 流结束后兜底：标记出现在任意位置也认。
    /// 返回 (去掉标记块后的干净文本, 标记内的原始提示词)。
    static func extractFull(_ text: String) -> (clean: String, prompt: String)? {
        guard let openRange = text.range(of: open) else { return nil }
        guard let closeRange = text.range(of: close, range: openRange.upperBound..<text.endIndex) else { return nil }
        let prompt = String(text[openRange.upperBound..<closeRange.lowerBound])
        var clean = text
        clean.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        return (clean.trimmingCharacters(in: .whitespacesAndNewlines), prompt)
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input: String = ""
    @Published var isStreaming: Bool = false
    @Published var errorMessage: String?
    @Published var copyFeedback: Bool = false
    
    /// 每次面板弹出时自增，视图据此把焦点交给输入框
    @Published var focusRequest: Int = 0
    
    /// 本次要附带的选中内容（文本 / 图片）
    @Published var context: SelectionProvider.Capture?
    /// 是否正在录音
    @Published var isListening = false
    /// 生图模式：输入框的内容当提示词，截图/图片上下文当参考图
    @Published var isImageMode = false
    /// 当前动作（临时状态：下一条消息按它处理，发完回到默认「问答」）
    @Published var activeAction: ChatAction = .chat
    /// 是否正在生图
    @Published var isGeneratingImage = false
    /// 生成尺寸（auto 时不传 size，由模型决定）
    @Published var imageSize: ImageGenSize = .auto
    /// 语音相关错误（权限、没听清等）
    @Published var voiceError: String?
    /// 正在预览的附件图（点缩略图打开；Esc / 点背景 / 关闭按钮退出）
    @Published var previewImage: ImageAttachment?
    
    let voice = VoiceInputService()
    private var voiceTimeoutTask: Task<Void, Never>?
    private var voiceStartTask: Task<Void, Never>?
    /// 本次录音是否需要抓取选中内容
    private var wantsSelection = false
    
    /// 「把面板提到前台」的回调。
    /// 语音与截图都会先以不抢焦点的方式工作（否则抓不到原 App 的选中内容），
    /// 拿到结果后再统一交给控制器把面板显示出来。
    var onNeedsForeground: (() -> Void)?
    /// 「收起面板」的回调（替换选中文本时要把面板让开）
    var onRequestHide: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // voice 是内层 ObservableObject，它自己的变化不会触发外层视图刷新，
        // 这里把它的变更转发出去，聆听时的实时转写才能显示出来。
        voice.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        
        if let saved = UserDefaults.standard.string(forKey: "image_gen_size"),
           let size = ImageGenSize(rawValue: saved) {
            imageSize = size
        }
        
        loadHistory()
    }
    
    func selectImageSize(_ size: ImageGenSize) {
        imageSize = size
        UserDefaults.standard.set(size.rawValue, forKey: "image_gen_size")
    }
    
    let engineManager = EngineManager.shared
    
    private let service = LLMClient()
    private var streamTask: Task<Void, Never>?
    /// 自动路由触发的生图任务（与 ✨ 手动模式共用 isGeneratingImage 状态）
    private var imageGenTask: Task<Void, Never>?
    /// 生图完成但流还没结束时先挂在这里，流结束后再贴到消息上
    private var pendingGenerated: GeneratedImage?
    private var pendingForId: UUID?
    private var streamFinished = false
    /// 每条流式请求的标识：被取消的旧任务不允许再改新请求的状态
    private var activeStreamId: UUID?
    
    /// 送入模型的最大历史条数（约 10 轮）
    private let maxContextMessages = 20
    
    // MARK: - 变换（零输入动作：选中 → 翻译 / 总结 / 润色）
    
    /// 翻译方向（只在「翻译」动作下出现）
    @Published var direction: TranslateDirection = .auto
    /// 翻译历史
    @Published var history: [TranslationRecord] = []
    
    private let translationService = UnifiedTranslationService()
    private var transformTask: Task<Void, Never>?
    /// 正在流式输出、还没出结果的那张变换卡片。
    /// 换动作 / 停止时要把这张卡收尾，否则会留一张永远「正在处理…」的僵尸卡片。
    private var runningTransformCardId: UUID?
    /// 最近一次抓取时的来源 App（「替换」时切回它再粘贴）
    private var lastSourceApp: NSRunningApplication?
    private let historyKey = "translation_history"
    private let directionKey = "translation_direction"
    private let maxHistoryCount = 50
    
    var selectedEngineName: String {
        activeAction.usesTranslationPath
            ? engineManager.selectedEngine?.name ?? "未选择"
            : engineManager.selectedChatEngine?.name ?? "未选择"
    }
    
    var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming && !isGeneratingImage
    }
    
    // MARK: - 外部动作
    
    func requestFocus() {
        focusRequest += 1
    }
    
    /// 引擎列表随动作切换：翻译用翻译引擎（可能是 DeepL），其余用对话引擎
    func selectEngine(id: UUID) {
        if activeAction.usesTranslationPath {
            engineManager.selectEngine(id: id)
        } else {
            engineManager.selectChatEngine(id: id)
        }
    }
    
    /// 选一个动作：只对下一条消息生效，发完自动回到默认「问答」。
    /// 零输入动作（翻译/总结/润色）点一下就立刻处理——优先用上一次的原文，
    /// 其次用输入框里的内容。
    func selectAction(_ action: ChatAction) {
        let previous = activeAction
        activeAction = action
        guard !action.needsInput else {
            requestFocus()
            return
        }
        
        if let source = lastTransformSource {
            runTransform(text: source, action: action)
        } else if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            input = ""
            runTransform(text: text, action: action)
        } else if previous != action {
            errorMessage = "先选中一段文本再来（选中后按 ⌘2 最顺手）"
        }
    }
    
    // MARK: - 变换动作（⌘2 开场：抓取选中 → 立即执行）
    
    /// 最近一次变换的原文
    var lastTransformSource: String? {
        messages.last(where: { $0.transformSource != nil })?.transformSource
    }
    
    /// ⌘2 入口：抓取当前选中文本，用当前动作立即处理
    func beginTransform() {
        transformTask?.cancel()
        transformTask = Task { [weak self] in
            guard let self else { return }
            self.prepareForNewOpening()
            
            // 等一下让快捷键的修饰键先松开，否则 ⌘C 会和它叠加
            try? await Task.sleep(nanoseconds: 50_000_000)
            
            let capture = await SelectionProvider.capture()
            guard !Task.isCancelled else { return }
            
            self.lastSourceApp = capture.sourceApp
            
            if let text = capture.text, !text.isEmpty {
                self.runTransform(text: text, action: self.activeAction)
            } else if self.messages.isEmpty {
                self.errorMessage = "未检测到选中的文本，请先选中要处理的文字"
            }
            // 抓不到就不打扰：面板上还留着上一轮的结果
            
            self.onNeedsForeground?()
        }
    }
    
    /// 零输入动作：把文本交给动作对应的引擎，结果做成一张「变换卡片」
    func runTransform(text: String, action: ChatAction) {
        let config = action.usesTranslationPath ? engineManager.selectedEngine : engineManager.selectedChatEngine
        guard let config else {
            errorMessage = action.usesTranslationPath
                ? "请先在设置中添加并选择一个翻译引擎"
                : "没有可用于「\(action.title)」的对话引擎，请先在设置中添加并启用一个"
            return
        }
        
        // 上一张还没出结果：直接撤掉，别留一张转圈的僵尸卡片
        discardRunningTransformCard()
        // 正在流式输出的对话也让位：用户已经切去用动作处理了
        streamTask?.cancel()
        streamTask = nil
        
        errorMessage = nil
        voiceError = nil
        activeAction = action
        isImageMode = false
        
        // 原文放进一条隐藏的 user 消息：卡片自己会显示原文，但上下文里要有它
        messages.append(ChatMessage(role: .user, parts: [.text(text)], hidden: true))
        var card = ChatMessage(role: .assistant, content: "")
        card.transformSource = text
        card.transformActionId = action.rawValue
        messages.append(card)
        let cardId = card.id
        runningTransformCardId = cardId
        
        isStreaming = true
        streamFinished = false
        lastStreamActivity = Date()
        let streamId = UUID()
        activeStreamId = streamId
        
        transformTask?.cancel()
        transformTask = Task { [weak self] in
            guard let self else { return }
            var received = false
            
            do {
                let chunks: AsyncThrowingStream<String, Error>
                if action.usesTranslationPath {
                    chunks = self.translationService.translateStream(
                        text: text,
                        to: self.makeTarget(for: text),
                        using: config
                    )
                } else {
                    chunks = self.service.stream(
                        messages: [
                            ChatMessage(role: .system, content: action.systemPrompt),
                            ChatMessage(role: .user, content: text),
                        ],
                        using: config
                    )
                }
                
                for try await chunk in chunks {
                    if Task.isCancelled { break }
                    received = true
                    self.lastStreamActivity = Date()
                    self.append(chunk, to: cardId)
                }
                
                guard self.activeStreamId == streamId else { return }
                self.isStreaming = false
                
                if !received, !Task.isCancelled {
                    self.errorMessage = ServiceError.emptyResponse(config.name).localizedDescription
                    return
                }
                
                // 只有翻译进历史；总结 / 润色不污染翻译历史
                if action.usesTranslationPath, !Task.isCancelled {
                    self.addToHistory(
                        source: text,
                        translated: self.content(of: cardId).trimmingCharacters(in: .whitespacesAndNewlines),
                        engine: config.name
                    )
                }
                self.runningTransformCardId = nil
            } catch {
                guard self.activeStreamId == streamId else { return }
                self.isStreaming = false
                self.runningTransformCardId = nil
                if !Task.isCancelled {
                    self.errorMessage = "\(action.title)失败：\(error.localizedDescription)"
                }
            }
        }
    }
    
    /// 撤掉正在跑但还没出结果的那张卡片（连带它前面那条隐藏的原文消息）
    private func discardRunningTransformCard() {
        transformTask?.cancel()
        transformTask = nil
        
        guard let id = runningTransformCardId,
              let index = messages.firstIndex(where: { $0.id == id })
        else {
            runningTransformCardId = nil
            return
        }
        
        messages.remove(at: index)
        if index > 0, messages[index - 1].hidden {
            messages.remove(at: index - 1)
        }
        runningTransformCardId = nil
    }
    
    private func content(of id: UUID) -> String {
        messages.first(where: { $0.id == id })?.content ?? ""
    }
    
    // MARK: - 翻译方向 / 历史 / 替换
    
    private func makeTarget(for text: String) -> TranslationTarget {
        let sourceIsChinese = text.range(of: "\\p{Han}", options: .regularExpression) != nil
        let sourceName = sourceIsChinese ? "Simplified Chinese" : "English"
        
        switch direction {
        case .auto:
            return TranslationTarget(
                code: sourceIsChinese ? "EN-US" : "ZH",
                languageName: sourceIsChinese ? "English" : "Simplified Chinese",
                sourceName: sourceName
            )
        default:
            return TranslationTarget(
                code: direction.code,
                languageName: direction.targetName,
                sourceName: sourceName
            )
        }
    }
    
    /// 换方向：把最后一张翻译卡片重跑一遍
    func selectDirection(_ newDirection: TranslateDirection) {
        guard direction != newDirection else { return }
        direction = newDirection
        UserDefaults.standard.set(newDirection.rawValue, forKey: directionKey)
        
        guard let index = messages.lastIndex(where: { $0.transformAction == .translate }),
              let source = messages[index].transformSource
        else { return }
        
        messages.remove(at: index)
        // 连带丢掉它前面那条隐藏的原文消息
        if index > 0, messages[index - 1].hidden {
            messages.remove(at: index - 1)
        }
        runTransform(text: source, action: .translate)
    }
    
    /// 替换选中文本：切回来源 App，用结果覆盖原文
    func replaceSelection() {
        guard let index = messages.lastIndex(where: { $0.transformAction != nil }) else { return }
        let result = messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result, forType: .string)
        
        Diagnostics.log("replace: 切回 \(lastSourceApp?.localizedName ?? "?") 并粘贴  长度=\(result.count)")
        
        // 面板让位，否则粘贴会打在 KoK 自己身上
        onRequestHide?()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.lastSourceApp?.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                SelectionProvider.simulatePaste()
            }
        }
    }
    
    // MARK: - 翻译历史
    
    func addToHistory(source: String, translated: String, engine: String) {
        history.insert(TranslationRecord(sourceText: source, translatedText: translated, engineName: engine), at: 0)
        if history.count > maxHistoryCount {
            history = Array(history.prefix(maxHistoryCount))
        }
        saveHistory()
    }
    
    func clearHistory() {
        history.removeAll()
        saveHistory()
    }
    
    func translateFromHistory(_ record: TranslationRecord) {
        runTransform(text: record.sourceText, action: .translate)
    }
    
    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }
    
    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([TranslationRecord].self, from: data) {
            history = decoded
        }
        if let saved = UserDefaults.standard.string(forKey: directionKey),
           let stored = TranslateDirection(rawValue: saved) {
            direction = stored
        }
    }
    
    /// 每次面板重新打开时调用（⌘2 / ⌘3 各自的开场由控制器决定）
    func prepareForNewOpening() {
        errorMessage = nil
        voiceError = nil
        context = nil
    }
    
    func send() {
        if isImageMode {
            sendImagePrompt()
            return
        }
        
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, !isGeneratingImage else { return }
        guard let config = engineManager.selectedChatEngine else {
            errorMessage = "没有可用于对话的引擎，请先在设置中添加 OpenAI 兼容或 Gemini 引擎"
            return
        }
        
        input = ""
        errorMessage = nil
        messages.append(userMessage(text: text, context: context))
        context = nil
        startStreaming(using: config)
        // 动作是临时形态：这条已经发出去了，下一条回到默认「问答」
        activeAction = .chat
    }
    
    /// 把选中内容拼进用户消息：图片作为独立片段，文本带个前缀标明来源
    private func userMessage(text: String, context: SelectionProvider.Capture?) -> ChatMessage {
        var parts: [MessagePart] = []
        
        if let image = context?.image {
            parts.append(.image(image))
        }
        if let selected = context?.text, !selected.isEmpty {
            let note = context?.truncated == true ? "（已截断）" : ""
            parts.append(.text("【选中内容\(note)】\n\(selected)\n\n"))
        }
        
        parts.append(.text(text))
        return ChatMessage(role: .user, parts: parts)
    }
    
    // MARK: - 按住说话
    
    /// 按下快捷键：立刻开录（用户已经在说话了），抓选中内容并行进行
    /// - Parameter captureSelection: 是否顺带抓取当前选中内容。
    ///   只有全局快捷键那条路径该传 true——从面板里点麦克风时，
    ///   焦点已经在 KoK 自己身上，抓到的会是输入框里的文字。
    func beginVoice(captureSelection: Bool = true) {
        guard !isListening else { return }
        
        voiceError = nil
        errorMessage = nil
        isListening = true
        wantsSelection = captureSelection
        
        Diagnostics.log("voice: 按下  录音权限(麦克风=\(VoiceInputService.microphoneAuthorized) 语音=\(VoiceInputService.speechAuthorized))")
        
        // 首次使用会在这里弹系统权限对话框，所以录音启动是异步的；
        // endVoiceAndSend 会等这个任务结束再收尾。
        voiceStartTask?.cancel()
        voiceStartTask = Task { [weak self] in
            guard let self else { return }
            
            if VoiceInputService.needsPermission {
                let granted = await VoiceInputService.requestPermissions()
                guard granted.microphone && granted.speech else {
                    self.voiceError = granted.microphone
                        ? VoiceInputService.VoiceError.speechDenied.localizedDescription
                        : VoiceInputService.VoiceError.microphoneDenied.localizedDescription
                    self.isListening = false
                    return
                }
            }
            
            guard !Task.isCancelled else { return }
            
            do {
                try self.voice.start(localeIdentifier: self.engineManager.voiceLocale)
            } catch {
                self.voiceError = error.localizedDescription
                self.isListening = false
            }
        }
        
        // 兜底：万一「松开」事件丢了，录音也不能一直开着
        voiceTimeoutTask?.cancel()
        voiceTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(VoiceInputService.maxRecordingSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.endVoiceAndSend()
        }
    }
    
    /// 松开快捷键：结束录音，带上选中内容一起发出去
    func endVoiceAndSend() {
        guard isListening else { return }
        isListening = false
        voiceTimeoutTask?.cancel()
        voiceTimeoutTask = nil
        
        let shouldCapture = wantsSelection
        wantsSelection = false
        
        Task { [weak self] in
            guard let self else { return }
            
            // 等录音真正开始（可能刚才在弹权限对话框）
            await self.voiceStartTask?.value
            self.voiceStartTask = nil
            
            // 启动阶段已经报过错（权限被拒、没有输入设备），就不要再覆盖成「没听清」
            guard self.voiceError == nil else { return }
            
            Diagnostics.log("voice: 松开  准备抓选中内容=\(shouldCapture)")
            
            var captured: SelectionProvider.Capture?
            if shouldCapture {
                // 松手后等一下再抓：让 ⌥ 彻底松开，
                // 否则合成出来的是 ⌥⌘C，很多 App 不认
                try? await Task.sleep(nanoseconds: 80_000_000)
                captured = await SelectionProvider.capture()
            }
            
            let spoken = await self.voice.finish()
            
            // 抓取已完成，现在可以安全地把面板提到前台
            self.onNeedsForeground?()
            
            if let captured, !captured.isEmpty {
                self.context = captured
                Diagnostics.log("voice: 附带上下文  文本=\(captured.text?.count ?? 0)字  图片=\(captured.image != nil ? "有" : "无")")
            } else {
                Diagnostics.log("voice: 没有拿到上下文，只发语音指令")
            }
            
            let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                self.voiceError = "没听清，再按一次试试"
                return
            }
            
            self.input = text
            self.send()
        }
    }
    
    func removeContext() {
        context = nil
    }
    
    // MARK: - 附件预览
    
    func preview(_ image: ImageAttachment) {
        previewImage = image
    }
    
    func closePreview() {
        previewImage = nil
    }
    
    /// 取消当前录音（点按误判、用户改主意等），不留任何痕迹
    func cancelVoice() {
        voice.cancel()
        isListening = false
        voiceTimeoutTask?.cancel()
        voiceTimeoutTask = nil
        voiceStartTask?.cancel()
        voiceStartTask = nil
        wantsSelection = false
    }
    
    /// 从翻译面板追问：把原文 + 译文作为上下文带进来，用户接着打字即可
    func followUp(source: String, translated: String) {
        context = SelectionProvider.Capture(
            text: "【原文】\n\(source)\n\n【译文】\n\(translated)",
            label: "原文 + 译文"
        )
        onNeedsForeground?()
    }
    
    // MARK: - 生图
    
    /// 生图：输入是提示词，上下文里的图片（截图/复制）作为参考图。
    /// 生成结果作为 assistant 消息里的 generatedImage 展示。
    func sendImagePrompt() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGeneratingImage, !isStreaming else { return }
        
        let manager = engineManager
        guard !manager.imageGenAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "还没有配置生图服务：设置 ▸ 通用 ▸ 生图，填入 API Key"
            return
        }
        
        input = ""
        errorMessage = nil
        
        var parts: [MessagePart] = []
        if let image = context?.image {
            parts.append(.image(image))
        }
        parts.append(.text(text))
        messages.append(ChatMessage(role: .user, parts: parts))
        
        let reference = context?.image
        context = nil
        
        isGeneratingImage = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await ImageGenerationService().generate(
                    prompt: text,
                    reference: reference,
                    url: manager.imageGenURL,
                    apiKey: manager.imageGenAPIKey,
                    model: manager.imageGenModel,
                    size: self.imageSize.sizeParam
                )
                self.messages.append(ChatMessage(role: .assistant, parts: [.generatedImage(result)]))
            } catch {
                if !Task.isCancelled {
                    self.errorMessage = error.localizedDescription
                }
            }
            self.isGeneratingImage = false
        }
    }
    
    // MARK: - 截图
    
    /// 框选屏幕区域，作为上下文。之后可以打字或按住 ⌥V 说话再一起发出。
    func captureScreenshot() {
        voiceError = nil
        errorMessage = nil
        
        Task { [weak self] in
            guard let self else { return }
            
            do {
                let image = try await ScreenshotCapture.captureInteractive()
                self.context = SelectionProvider.Capture(text: nil, image: image)
            } catch ScreenshotCapture.CaptureError.cancelled {
                return   // 用户按 Esc 取消，不打扰
            } catch {
                self.voiceError = error.localizedDescription
            }
            
            self.onNeedsForeground?()
        }
    }
    
    func regenerate() {
        guard !isStreaming, let config = engineManager.selectedChatEngine else { return }
        if messages.last?.role == .assistant { messages.removeLast() }
        guard messages.contains(where: { $0.role == .user }) else { return }
        
        errorMessage = nil
        startStreaming(using: config)
    }
    
    func stop() {
        discardRunningTransformCard()
        streamTask?.cancel()
        streamTask = nil
        imageGenTask?.cancel()
        imageGenTask = nil
        pendingGenerated = nil
        pendingForId = nil
        streamFinished = false
        isStreaming = false
    }
    
    func clear() {
        stop()
        messages.removeAll()
        errorMessage = nil
    }
    
    func copy(_ text: String) {
        guard !text.isEmpty else { return }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        copyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyFeedback = false
        }
    }
    
    // MARK: - 流式
    
    /// 看门狗：这么久没收到任何新内容就认为请求已经死了。
    /// 机器睡眠/换网之后 socket 可能悄悄失效，请求会一直挂着不报错——
    /// 结果是面板永远停在「Thinking…」、发送按钮永久禁用（实测遇到过）。
    private static let streamStallTimeout: TimeInterval = 90
    /// 最近一次收到流内容的时间
    private var lastStreamActivity = Date()
    
    private func startStreaming(using config: EngineConfig) {
        // 先组装请求再插入占位消息，否则空回答也会被发给模型
        let payload = buildPayload()
        messages.append(ChatMessage(role: .assistant, content: ""))
        let placeholderId = messages[messages.count - 1].id
        isStreaming = true
        streamFinished = false
        lastStreamActivity = Date()
        let streamId = UUID()
        activeStreamId = streamId

        // 参考图取上下文里最近的一张（刚发出的用户消息里若有图，就是它）
        let reference = latestReferenceImage()

        // 看门狗：定期检查有没有新内容，卡住就中止并给出可重试的错误
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard self.isStreaming, self.activeStreamId == streamId else { return }
                let idle = Date().timeIntervalSince(self.lastStreamActivity)
                guard idle > Self.streamStallTimeout else { continue }
                Diagnostics.log("stream: 看门狗超时 \(Int(idle))s 无响应，中止本次请求")
                self.errorMessage = "模型服务 \(Int(Self.streamStallTimeout)) 秒没有响应，已中止这次请求。可以点「重试」，或换个引擎。"
                self.streamTask?.cancel()
                return
            }
        }

        streamTask = Task { [weak self] in
            defer { watchdog.cancel() }
            guard let self else { return }
            var received = false
            var buffer = ""
            var flushedLength = 0
            var generationStarted = false

            do {
                for try await chunk in self.service.stream(messages: payload, using: config) {
                    if Task.isCancelled { break }
                    received = true
                    self.lastStreamActivity = Date()
                    buffer += chunk

                    // 展示部分：把标记块从流里剥掉，只吐出干净文字
                    let visible = ImageGenIntentMarker.visiblePrefix(buffer)
                    if visible.count > flushedLength {
                        self.append(String(visible.dropFirst(flushedLength)), to: placeholderId)
                        flushedLength = visible.count
                    }

                    // 标记在开头且已闭合 → 立刻开始生图，文字继续流
                    if !generationStarted, let raw = ImageGenIntentMarker.promptIfClosed(buffer) {
                        generationStarted = true
                        let prompt = self.resolveImagePrompt(raw, fallbackUserText: self.lastUserText())
                        Diagnostics.log("auto-gen: 标记命中（流中）  提示词=\(prompt.prefix(80))")
                        self.startAutoGeneration(
                            prompt: prompt,
                            placeholderId: placeholderId,
                            reference: reference
                        )
                    }
                }

                // 兜底 1：标记没在开头（模型先说了一句话才给标记），流结束后全文再找一遍
                if !generationStarted, let result = ImageGenIntentMarker.extractFull(buffer) {
                    generationStarted = true
                    self.replacePlaceholderText(result.clean, placeholderId: placeholderId)
                    let prompt = self.resolveImagePrompt(result.prompt, fallbackUserText: self.lastUserText())
                    Diagnostics.log("auto-gen: 标记命中（流后兜底）  提示词=\(prompt.prefix(80))")
                    self.startAutoGeneration(
                        prompt: prompt,
                        placeholderId: placeholderId,
                        reference: reference
                    )
                }

                // 兜底 2：模型输出了一个没闭合/写错的标记，整段文字被剥掉没显示出来 → 原样恢复
                if !generationStarted,
                   let index = self.messages.firstIndex(where: { $0.id == placeholderId }),
                   self.messages[index].content.isEmpty, !buffer.isEmpty {
                    self.replacePlaceholderText(
                        buffer.trimmingCharacters(in: .whitespacesAndNewlines),
                        placeholderId: placeholderId
                    )
                }

                guard self.activeStreamId == streamId else { return }
                self.isStreaming = false
                if !received, !Task.isCancelled {
                    self.errorMessage = ServiceError.emptyResponse(config.name).localizedDescription
                }
                self.streamFinished = true
                self.flushPendingIfReady()
            } catch {
                guard self.activeStreamId == streamId else { return }
                self.isStreaming = false
                self.discardEmptyPlaceholder(placeholderId)
                if !Task.isCancelled {
                    self.errorMessage = error.localizedDescription
                }
                self.streamFinished = true
                self.flushPendingIfReady()
            }
        }
    }

    // MARK: - 自动路由生图

    /// 把模型给的原始提示词清洗成最终提示词；
    /// 模型把示例里的占位文案原样抄回来时，退回用户的原话。
    private func resolveImagePrompt(_ raw: String?, fallbackUserText: String) -> String {
        let fallback = fallbackUserText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw else { return fallback }
        let prompt = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !prompt.contains("写在这里"), prompt.count <= 4000 else {
            return fallback
        }
        return prompt
    }

    private func lastUserText() -> String {
        messages.last(where: { $0.role == .user })?.content ?? ""
    }

    /// 上下文里最近的一张输入图（发给生图服务当参考图）
    private func latestReferenceImage() -> ImageAttachment? {
        for message in messages.reversed() {
            for part in message.parts.reversed() {
                if case .image(let image) = part { return image }
            }
        }
        return nil
    }

    /// 自动路由触发的生图：结果先挂到 pending，等流结束再贴到占位消息上
    /// （保证「文字在前、图片在后」的顺序不会被并发打乱）
    private func startAutoGeneration(prompt: String, placeholderId: UUID, reference: ImageAttachment?) {
        let manager = engineManager
        guard !manager.imageGenAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "模型想生成图片，但还没有配置生图服务：设置 ▸ 通用 ▸ 生图，填入 API Key"
            return
        }

        isGeneratingImage = true
        imageGenTask?.cancel()
        imageGenTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await ImageGenerationService().generate(
                    prompt: prompt,
                    reference: reference,
                    url: manager.imageGenURL,
                    apiKey: manager.imageGenAPIKey,
                    model: manager.imageGenModel,
                    size: self.imageSize.sizeParam
                )
                self.pendingGenerated = result
                self.pendingForId = placeholderId
                self.flushPendingIfReady()
            } catch {
                if !Task.isCancelled {
                    self.errorMessage = "生图失败：\(error.localizedDescription)"
                }
            }
            self.isGeneratingImage = false
        }
    }

    /// 流结束后把挂着的生成结果贴到消息上；占位消息已被移除时单独发一条
    private func flushPendingIfReady() {
        guard streamFinished, let image = pendingGenerated, let id = pendingForId else { return }
        pendingGenerated = nil
        pendingForId = nil
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].parts.append(.generatedImage(image))
        } else {
            messages.append(ChatMessage(role: .assistant, parts: [.generatedImage(image)]))
        }
        Diagnostics.log("auto-gen: 图片已贴到消息  \(image.dimensionText) \(image.sizeText)")
    }

    private func replacePlaceholderText(_ text: String, placeholderId: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == placeholderId }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        messages[index].parts = trimmed.isEmpty ? [] : [.text(trimmed)]
    }
    
    private func append(_ chunk: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].appendText(chunk)
    }
    
    private func discardEmptyPlaceholder(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].content.isEmpty
        else { return }
        messages.remove(at: index)
    }
    
    /// 当前动作对应的系统提示词。
    /// 问答用设置里的对话提示词（生图服务可用时附加路由规则）；
    /// 总结 / 润色用动作自带的提示词。
    private func activeSystemPrompt() -> String {
        if activeAction == .chat {
            var prompt = engineManager.chatSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            // 生图服务可用时才附加路由规则，避免没有生图 Key 时模型白打标记
            if !engineManager.imageGenAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prompt = prompt.isEmpty
                    ? ImageGenIntentMarker.routingInstruction
                    : prompt + "\n\n" + ImageGenIntentMarker.routingInstruction
            }
            return prompt
        }
        return activeAction.systemPrompt
    }
    
    /// 请求体 = 动作提示词 + 最近若干轮，且保证以 user 开头
    private func buildPayload() -> [ChatMessage] {
        var payload: [ChatMessage] = []
        
        let systemPrompt = activeSystemPrompt().trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty {
            payload.append(ChatMessage(role: .system, content: systemPrompt))
        }
        
        var recent = messages.suffix(maxContextMessages)
        while let first = recent.first, first.role != .user {
            recent = recent.dropFirst()
        }
        payload.append(contentsOf: recent)
        
        return payload
    }
}
