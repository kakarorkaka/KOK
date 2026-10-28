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
import ApplicationServices

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
    /// 松手后的短暂收尾：等最终转写 + 抓选区，这段时间仍显示语音 HUD
    @Published var isTranscribing = false
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
    private var voiceFinalizeTask: Task<Void, Never>?
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
        
        // 结果历史的变化同样要转发给视图（工具栏的历史按钮、弹窗）
        resultStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        
        // 消息有变化就按需落盘（开关关着时是空操作）
        $messages
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleConversationSave() }
            .store(in: &cancellables)
        
        if let saved = UserDefaults.standard.string(forKey: "image_gen_size"),
           let size = ImageGenSize(rawValue: saved) {
            imageSize = size
        }
        
        if let saved = UserDefaults.standard.string(forKey: directionKey),
           let stored = TranslateDirection(rawValue: saved) {
            direction = stored
        }
        
        restoreConversationIfEnabled()
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
    /// 自动路由生图时的提示词（进结果历史用）
    private var pendingImagePrompt: String?
    private var streamFinished = false
    /// 每条流式请求的标识：被取消的旧任务不允许再改新请求的状态
    private var activeStreamId: UUID?
    
    /// 送入模型的最大历史条数（约 10 轮）
    private let maxContextMessages = 20
    
    /// v5：生图从产品主路径移除。保留代码，但不再暴露入口，
    /// 也不再让模型通过标记块自动路由到生图。
    private static let imageGenerationEnabled = false
    
    // MARK: - 变换（零输入动作：选中 → 翻译 / 总结 / 润色）
    
    /// 翻译方向（只在「翻译」动作下出现）
    @Published var direction: TranslateDirection = .auto
    
    /// 结果历史（翻译 / 总结 / 润色 / 生图）。真正的存储与淘汰策略在 ResultStore。
    let resultStore = ResultStore.shared
    var history: [ResultStore.Record] { resultStore.records }
    
    private let translationService = UnifiedTranslationService()
    private var transformTask: Task<Void, Never>?
    /// 正在流式输出、还没出结果的那张变换卡片。
    /// 换动作 / 停止时要把这张卡收尾，否则会留一张永远「正在处理…」的僵尸卡片。
    private var runningTransformCardId: UUID?
    /// 最近一次抓取时的来源 App（「替换」时切回它再粘贴）
    private var lastSourceApp: NSRunningApplication?
    private let directionKey = "translation_direction"
    
    /// 可选的对话持久化（默认关；开关在设置 ▸ 通用）
    private let conversationStore = ConversationStore.shared
    private static let keepConversationKey = "keep_conversation"
    private var conversationSaveTask: Task<Void, Never>?
    
    var selectedEngineName: String {
        activeAction.usesTranslationPath
            ? engineManager.selectedEngine?.name ?? "选择引擎"
            : engineManager.selectedChatEngine?.name ?? "选择引擎"
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
    
    // MARK: - 变换动作（⌘2 开场：抓取选中 → 立即翻译）
    
    /// 最近一张变换卡片（可能还在流式输出，也可能是失败后的空卡片）
    private var lastTransformCard: ChatMessage? {
        messages.last(where: { $0.transformSource != nil })
    }
    
    var canReplace: Bool {
        !isStreaming && !(lastTransformCard?.content.isEmpty ?? true)
    }
    
    /// ⌘C 复制最近一条有内容的助手消息（翻译卡片或问答回答）
    private var lastCopyableMessage: ChatMessage? {
        messages.last(where: {
            $0.role == .assistant
                && !$0.hidden
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
    }
    
    var canCopyResult: Bool {
        !isStreaming && lastCopyableMessage != nil
    }
    
    var canRetranslate: Bool {
        !isStreaming && lastTransformCard?.transformSource != nil
    }
    
    /// ⌘C：复制最近一条回答/译文
    func copyLastResult() {
        guard let message = lastCopyableMessage else { return }
        copy(message.content)
    }
    
    /// ⌘R：用同一段原文重新翻译。传 cardId 时只重跑那一张卡片。
    func retranslate(cardId: UUID? = nil) {
        let card = cardId.flatMap { id in messages.first { $0.id == id } } ?? lastTransformCard
        guard let card, let source = card.transformSource else { return }
        runTransform(text: source, action: card.transformAction ?? .translate)
    }
    
    /// ⌘2 入口：抓取当前选中文本，立即翻译（v5：不再让「当前动作」决定入口）
    func beginTransform() {
        activeAction = .translate
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
                // 没授权辅助功能时，模拟 ⌘C 抓不到选中内容，给出可操作的引导
                if !AXIsProcessTrusted() {
                    self.errorMessage = "读取选中文字需要「辅助功能」权限：设置 ▸ 权限 ▸ 去授权，勾选 KoK 后重试"
                } else {
                    self.errorMessage = "未检测到选中的文本，请先选中要处理的文字"
                }
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
            
            // 变换路径自己的看门狗：服务端无响应时别让卡片一直转圈
            let watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    guard self.activeStreamId == streamId else { return }
                    let idle = Date().timeIntervalSince(self.lastStreamActivity)
                    guard idle > Self.streamStallTimeout else { continue }
                    Diagnostics.log("transform: 看门狗超时 \(Int(idle))s 无响应，中止本次请求")
                    self.errorMessage = "模型服务 \(Int(Self.streamStallTimeout)) 秒没有响应，已中止这次请求。可以点「重试」，或换个引擎。"
                    self.markTransformFailed(cardId: cardId, message: "超时中止")
                    self.transformTask?.cancel()
                    return
                }
            }
            defer { watchdog.cancel() }
            
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
                    let message = ServiceError.emptyResponse(config.name).localizedDescription
                    self.errorMessage = message
                    self.markTransformFailed(cardId: cardId, message: "没有返回内容")
                    self.retryable = .transform(text: text, action: action)
                    self.runningTransformCardId = nil
                    return
                }
                
                // 三种零输入动作的结果都进「结果历史」，方便回看与复用
                if !Task.isCancelled {
                    self.addResult(
                        kind: Self.resultKind(for: action),
                        source: text,
                        output: self.content(of: cardId).trimmingCharacters(in: .whitespacesAndNewlines),
                        engine: config.name
                    )
                }
                self.retryable = nil
                self.runningTransformCardId = nil
            } catch {
                guard self.activeStreamId == streamId else { return }
                self.isStreaming = false
                self.runningTransformCardId = nil
                if !Task.isCancelled {
                    self.errorMessage = "\(action.title)失败：\(error.localizedDescription)"
                    self.markTransformFailed(cardId: cardId, message: "处理失败")
                    self.retryable = .transform(text: text, action: action)
                }
            }
        }
    }
    
    /// 变换卡片还没写出内容就失败时，把「正在处理…」换成一句明确的话，避免永远转圈
    private func markTransformFailed(cardId: UUID, message: String) {
        guard let index = messages.firstIndex(where: { $0.id == cardId }) else { return }
        if messages[index].content.isEmpty {
            messages[index].parts = [.text("（\(message)）")]
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
    
    /// 替换选中文本：切回来源 App，用结果覆盖原文。
    ///
    /// v5 的两个细节：
    /// - 先激活、确认来源 App 真的回到前台，再隐藏并粘贴，避免结果落到别的窗口；
    /// - 粘贴前后保存/恢复剪贴板，不让用户原来复制的东西被这次操作弄丢。
    func replaceSelection(cardId: UUID? = nil) {
        let card = cardId.flatMap { id in messages.first { $0.id == id } } ?? lastTransformCard
        guard let card,
              card.transformSource != nil,
              !isStreaming
        else { return }
        
        let result = card.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return }
        
        guard let sourceApp = lastSourceApp, !sourceApp.isTerminated else {
            copy(result)
            errorMessage = "来源 App 已关闭或找不到，译文已复制到剪贴板"
            return
        }
        
        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(result, forType: .string)
        let resultChangeCount = pasteboard.changeCount
        
        errorMessage = nil
        Diagnostics.log("replace: 切回 \(sourceApp.localizedName ?? "?") 并粘贴  长度=\(result.count)")
        
        // 面板先让位，再激活来源 App；否则面板仍持有 key window，激活可能失败
        onRequestHide?()
        sourceApp.activate()
        pasteBack(to: sourceApp, snapshot: snapshot, resultChangeCount: resultChangeCount)
    }
    
    /// 等来源 App 真正回到前台再粘贴；最多等约 0.6s。
    /// 激活失败时不盲粘，保留结果并让面板带着错误提示回来。
    private func pasteBack(
        to sourceApp: NSRunningApplication,
        snapshot: ClipboardSnapshot,
        resultChangeCount: Int,
        attempts: Int = 0
    ) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == sourceApp.processIdentifier {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                SelectionProvider.simulatePaste()
                
                // 给目标 App 一点时间消费剪贴板，再恢复用户原来的内容；
                // 若这期间用户又复制了别的东西，就不覆盖。
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    snapshot.restoreIfUnchanged(expected: resultChangeCount)
                }
            }
            return
        }
        
        guard attempts < 6 else {
            errorMessage = "来源 App 没有回到前台，译文已复制到剪贴板，请手动粘贴"
            onNeedsForeground?()
            return
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.pasteBack(
                to: sourceApp,
                snapshot: snapshot,
                resultChangeCount: resultChangeCount,
                attempts: attempts + 1
            )
        }
    }
    
    // MARK: - 结果历史（翻译 / 总结 / 润色 / 生图）
    
    /// 记一条结果。`imageFile` 只有生图结果才有（images/ 下的文件名）。
    func addResult(kind: ResultStore.Kind, source: String, output: String, engine: String, imageFile: String? = nil) {
        resultStore.add(
            ResultStore.Record(
                id: UUID(),
                kind: kind,
                sourceText: source,
                outputText: output,
                engineName: engine,
                timestamp: Date(),
                imageFile: imageFile
            )
        )
    }
    
    func clearHistory() {
        resultStore.clear()
    }
    
    func deleteHistoryRecord(_ id: UUID) {
        resultStore.delete(id)
    }
    
    /// 点击历史条目：文字结果重新跑一遍对应动作
    func reuseHistoryRecord(_ record: ResultStore.Record) {
        guard !record.sourceText.isEmpty else { return }
        runTransform(text: record.sourceText, action: action(for: record.kind))
    }
    
    /// 历史条目对应的动作（生图没有零输入动作，点了只能复制/打开）
    private func action(for kind: ResultStore.Kind) -> ChatAction {
        switch kind {
        case .translate: return .translate
        case .summarize: return .summarize
        case .polish: return .polish
        case .image: return .chat
        }
    }
    
    /// ChatAction → 历史记录类型
    private static func resultKind(for action: ChatAction) -> ResultStore.Kind {
        switch action {
        case .translate: return .translate
        case .summarize: return .summarize
        case .polish: return .polish
        case .chat: return .summarize
        }
    }
    
    func copyHistoryRecord(_ record: ResultStore.Record) {
        let text = record.outputText.isEmpty ? record.sourceText : record.outputText
        copy(text)
    }
    
    // MARK: - 可选的对话持久化（默认关，开关在设置 ▸ 通用）
    
    var keepsConversation: Bool {
        UserDefaults.standard.bool(forKey: Self.keepConversationKey)
    }
    
    /// 消息变化后延迟保存：流式输出每来一段都会触发，抖一下再写盘
    private func scheduleConversationSave() {
        guard keepsConversation else { return }
        conversationSaveTask?.cancel()
        conversationSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            self.conversationStore.save(self.messages.compactMap(Self.storableMessage))
        }
    }
    
    /// ChatMessage → 可落盘的形态。刻意丢掉输入图片（截图/参考图）
    private static func storableMessage(_ message: ChatMessage) -> ConversationStore.StoredMessage? {
        let text = message.content
        let imageFile = message.parts.compactMap { part -> String? in
            if case .generatedImage(let image) = part { return image.fileURL.lastPathComponent }
            return nil
        }.first
        
        // 全空的消息没必要存
        guard !text.isEmpty || imageFile != nil else { return nil }
        
        return ConversationStore.StoredMessage(
            role: message.role.rawValue,
            text: text,
            hidden: message.hidden,
            transformSource: message.transformSource,
            transformActionId: message.transformActionId,
            generatedImageFile: imageFile
        )
    }
    
    private func restoreConversationIfEnabled() {
        guard keepsConversation else { return }
        let stored = conversationStore.load()
        guard !stored.isEmpty else { return }
        
        messages = stored.compactMap { item -> ChatMessage? in
            guard let role = ChatMessage.Role(rawValue: item.role) else { return nil }
            var parts: [MessagePart] = []
            if let file = item.generatedImageFile,
               let image = GeneratedImage.fromStoredFile(named: file, in: resultStore.imagesDirectory) {
                parts.append(.generatedImage(image))
            }
            if !item.text.isEmpty {
                parts.append(.text(item.text))
            }
            guard !parts.isEmpty else { return nil }
            return ChatMessage(
                role: role,
                parts: parts,
                hidden: item.hidden,
                transformSource: item.transformSource,
                transformActionId: item.transformActionId
            )
        }
        Diagnostics.log("conversation: 已恢复 \(messages.count) 条消息")
    }
    
    /// 删除已保存的对话（点「新对话」或关掉开关时调用）
    func discardSavedConversation() {
        conversationSaveTask?.cancel()
        conversationStore.delete()
    }
    
    /// 每次面板重新打开时调用（⌘2 / ⌘3 各自的开场由控制器决定）
    func prepareForNewOpening() {
        // 上一次语音还在录 / 还在收尾时，按 ⌘2 应该直接开始翻译，
        // 不能让那条语音过一会儿又自己发出来。
        if isListening || isTranscribing {
            cancelVoice()
        }
        errorMessage = nil
        voiceError = nil
        context = nil
    }
    
    func send() {
        // v5：生图已从主界面移除，输入框只走问答
        isImageMode = false
        
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
        guard !isListening, !isTranscribing else { return }
        
        voiceError = nil
        errorMessage = nil
        isListening = true
        isTranscribing = false
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
                    // 权限失败时把面板提到前台，否则错误只挂在一个没有焦点的浮层上
                    self.onNeedsForeground?()
                    return
                }
            }
            
            guard !Task.isCancelled else { return }
            
            // 把引擎/模型名作为识别提示词，改善「这个 API 的 error」这类中英混说
            let engineTerms = self.engineManager.providers.flatMap { provider in
                [provider.name] + provider.models.map(\.name)
            }
            
            do {
                try self.voice.start(
                    localeIdentifier: self.engineManager.voiceLocale,
                    contextualStrings: Array(engineTerms.prefix(24))
                )
            } catch {
                self.voiceError = error.localizedDescription
                self.isListening = false
                self.onNeedsForeground?()
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
        isTranscribing = true
        voiceTimeoutTask?.cancel()
        voiceTimeoutTask = nil
        
        let shouldCapture = wantsSelection
        wantsSelection = false
        
        voiceFinalizeTask?.cancel()
        voiceFinalizeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isTranscribing = false
                self.voiceFinalizeTask = nil
            }
            
            // 等录音真正开始（可能刚才在弹权限对话框）
            await self.voiceStartTask?.value
            self.voiceStartTask = nil
            guard !Task.isCancelled else { return }
            
            // 启动阶段已经报过错（权限被拒、没有输入设备），就不要再覆盖成「没听清」
            guard self.voiceError == nil else {
                self.onNeedsForeground?()
                return
            }
            
            Diagnostics.log("voice: 松开  准备抓选中内容=\(shouldCapture)")
            
            // 抓选区和等最终转写并行，别让用户松手后再等两个串行的超时。
            async let capturedResult: SelectionProvider.Capture? = {
                guard shouldCapture else { return nil }
                // 松手后等一下再抓：让 ⌥ 彻底松开，
                // 否则合成出来的是 ⌥⌘C，很多 App 不认
                try? await Task.sleep(nanoseconds: 80_000_000)
                return await SelectionProvider.capture()
            }()
            async let spokenResult: String = self.voice.finish()
            
            let captured = await capturedResult
            let spoken = await spokenResult
            guard !Task.isCancelled else { return }
            
            if let captured {
                self.lastSourceApp = captured.sourceApp
                if !captured.isEmpty {
                    self.context = captured
                    Diagnostics.log("voice: 附带上下文  文本=\(captured.text?.count ?? 0)字  图片=\(captured.image != nil ? "有" : "无")")
                } else {
                    Diagnostics.log("voice: 没有拿到上下文，只发语音指令")
                }
            }
            
            // 抓取已完成，现在可以安全地把面板提到前台
            self.onNeedsForeground?()
            
            let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                self.voiceError = "没听清，再按住说一次"
                self.requestFocus()
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
    
    /// 取消当前录音 / 收尾（点按误判、用户改主意等），不留任何痕迹
    func cancelVoice() {
        voice.cancel()
        isListening = false
        isTranscribing = false
        voiceTimeoutTask?.cancel()
        voiceTimeoutTask = nil
        voiceStartTask?.cancel()
        voiceStartTask = nil
        voiceFinalizeTask?.cancel()
        voiceFinalizeTask = nil
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
        guard Self.imageGenerationEnabled else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGeneratingImage, !isStreaming else { return }
        
        input = ""
        let reference = context?.image
        context = nil
        generateImage(prompt: text, reference: reference)
    }
    
    /// 生图的完整入口：校验 → 用户消息（含参考图）→ 占位消息 → 真正执行。
    /// `sendImagePrompt` 与「重试」共用。
    private func generateImage(prompt: String, reference: ImageAttachment?) {
        guard Self.imageGenerationEnabled else { return }
        let manager = engineManager
        guard !manager.imageGenAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "还没有配置生图服务：设置 ▸ 通用 ▸ 生图，填入 API Key"
            return
        }
        
        var parts: [MessagePart] = []
        if let image = reference { parts.append(.image(image)) }
        parts.append(.text(prompt))
        messages.append(ChatMessage(role: .user, parts: parts))
        messages.append(ChatMessage(role: .assistant, content: ""))
        let placeholderId = messages[messages.count - 1].id
        
        startImageGeneration(prompt: prompt, reference: reference, placeholderId: placeholderId, manager: manager)
    }
    
    /// 真正执行生图（手动 sendImagePrompt 与「重试」共用）。结果贴到 placeholderId 上。
    private func startImageGeneration(
        prompt: String,
        reference: ImageAttachment?,
        placeholderId: UUID,
        manager: EngineManager
    ) {
        guard Self.imageGenerationEnabled else { return }
        errorMessage = nil
        isGeneratingImage = true
        retryable = .imagePrompt(text: prompt, reference: reference)
        
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
                guard !Task.isCancelled else { return }
                self.attachGeneratedImage(result, to: placeholderId, prompt: prompt)
                self.retryable = nil
            } catch {
                if !Task.isCancelled {
                    self.errorMessage = "生图失败：\(error.localizedDescription)"
                    // 占位消息还没内容：撤掉，别留一个空的「正在生成图片…」
                    self.discardEmptyPlaceholder(placeholderId)
                }
            }
            self.isGeneratingImage = false
        }
    }
    
    /// 把生成结果贴到占位消息上；占位已被清掉时单独发一条
    private func attachGeneratedImage(_ image: GeneratedImage, to id: UUID, prompt: String) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].parts.append(.generatedImage(image))
        } else {
            messages.append(ChatMessage(role: .assistant, parts: [.generatedImage(image)]))
        }
        addResult(
            kind: .image,
            source: prompt,
            output: "",
            engine: engineManager.imageGenModel,
            imageFile: image.fileURL.lastPathComponent
        )
        Diagnostics.log("imagegen: 图片已贴到消息  \(image.dimensionText) \(image.sizeText)")
    }
    
    func regenerate() {
        guard !isStreaming, let config = engineManager.selectedChatEngine else { return }
        if messages.last?.role == .assistant { messages.removeLast() }
        guard messages.contains(where: { $0.role == .user }) else { return }
        
        errorMessage = nil
        startStreaming(using: config)
    }
    
    // MARK: - 重试（按失败类型回到正确的入口，而不是一律走对话引擎）
    
    /// 最近一次失败的可重试操作。错误条的「重试」据此分发。
    private enum Retryable {
        case transform(text: String, action: ChatAction)
        case chat
        case imagePrompt(text: String, reference: ImageAttachment?)
    }
    private var retryable: Retryable?
    
    func retry() {
        let op = retryable
        retryable = nil
        errorMessage = nil
        switch op {
        case .transform(let text, let action):
            runTransform(text: text, action: action)
        case .imagePrompt(let text, let reference):
            isImageMode = true
            generateImage(prompt: text, reference: reference)
        case .chat, nil:
            regenerate()
        }
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
        isGeneratingImage = false
    }
    
    func clear() {
        stop()
        messages.removeAll()
        errorMessage = nil
        retryable = nil
        discardSavedConversation()
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

                    // v5：生图路由关闭时，模型输出什么就显示什么，
                    // 不再解析标记块，也不再把「画一张…」偷偷送去生图。
                    guard Self.imageGenerationEnabled else {
                        self.append(chunk, to: placeholderId)
                        continue
                    }

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

                if Self.imageGenerationEnabled {
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
                }

                guard self.activeStreamId == streamId else {
                    // 这条流已被新请求取代：别留一个空占位在时间线上
                    self.discardEmptyPlaceholder(placeholderId)
                    return
                }
                self.isStreaming = false
                if !received, !Task.isCancelled {
                    self.errorMessage = ServiceError.emptyResponse(config.name).localizedDescription
                    self.retryable = .chat
                    self.discardEmptyPlaceholder(placeholderId)
                }
                self.streamFinished = true
                self.flushPendingIfReady()
            } catch {
                guard self.activeStreamId == streamId else {
                    self.discardEmptyPlaceholder(placeholderId)
                    return
                }
                self.isStreaming = false
                self.discardEmptyPlaceholder(placeholderId)
                if !Task.isCancelled {
                    self.errorMessage = error.localizedDescription
                    self.retryable = .chat
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
        guard Self.imageGenerationEnabled else { return }
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
                self.pendingImagePrompt = prompt
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
        addResult(
            kind: .image,
            source: pendingImagePrompt ?? "",
            output: "",
            engine: engineManager.imageGenModel,
            imageFile: image.fileURL.lastPathComponent
        )
        pendingImagePrompt = nil
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
            if Self.imageGenerationEnabled,
               !engineManager.imageGenAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
