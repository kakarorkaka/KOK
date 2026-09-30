//
//  EnginePicker.swift
//  KoK
//
//  引擎选择菜单的内容：按服务商分节。
//  翻译与对话面板共用；一个服务商时不分节，保持简洁。
//

import SwiftUI

struct EngineMenuContent: View {
    let groups: [EngineManager.EngineGroup]
    let selectedId: UUID?
    let onSelect: (UUID) -> Void
    
    var body: some View {
        if groups.isEmpty {
            Text("没有可用的引擎")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        } else if groups.count == 1 {
            ForEach(groups[0].engines) { engine in
                row(engine)
            }
        } else {
            ForEach(groups) { group in
                Section(group.providerName) {
                    ForEach(group.engines) { engine in
                        row(engine)
                    }
                }
            }
        }
    }
    
    private func row(_ engine: EngineConfig) -> some View {
        Button {
            onSelect(engine.id)
        } label: {
            HStack {
                Text(engine.name)
                if engine.id == selectedId {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}
