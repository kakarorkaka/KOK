//
//  ChatPanelController.swift
//  KoK
//
//  快速问答面板的窗口控制器。面板行为全部复用 `PanelController` 基类。
//

import AppKit
import SwiftUI

@MainActor
final class ChatPanelController: PanelController {
    static let shared = ChatPanelController()
    
    let viewModel = ChatViewModel()
    
    override var preferredWidth: CGFloat { 460 }
    override var preferredHeight: CGFloat { 420 }
    override var minimumSize: NSSize { NSSize(width: 360, height: 240) }
    override var maximumSize: NSSize { NSSize(width: 1000, height: 1000) }
    
    private override init() {
        super.init()
        setupPanel()
    }
    
    private func setupPanel() {
        makePanel()
        
        var contentView = ChatView(viewModel: viewModel)
        contentView.onDismiss = { [weak self] in
            self?.hideWindow()
        }
        installContent(contentView)
        
        onWillShow = { [weak self] in
            // 与翻译面板互斥，并把焦点交给输入框
            WindowManager.shared.hideWindow()
            self?.viewModel.requestFocus()
        }
    }
    
    func toggleChat() {
        toggle()
    }
}
