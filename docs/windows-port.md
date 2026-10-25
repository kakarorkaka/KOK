# KoK 的 Windows 兼容性路线

> **结论：现在不要为了 Windows 把 macOS 客户端改成跨平台 UI。**
> macOS 继续用 SwiftUI + AppKit 做原生体验；Windows 未来做一个独立 shell，
> 和 macOS 共享「核心契约」（提示词、服务商预设、请求/流式协议、历史 schema），
> 但不共享 UI。当前 v5 的界面收口没有新增跨平台债；真正要守住的是数据层和平台适配层的边界。

## 1. 现状：哪些能共享，哪些必须重写

| 层 | 现在的位置 | Windows 复用度 |
|---|---|---|
| 面板 / 设置 UI | `ChatView.swift`、`SettingsView.swift`（SwiftUI） | 0%，必须重写 |
| 窗口 / 浮层 / 定位 | `PanelController.swift`、`FloatingPanel.swift`（NSPanel） | 0% |
| 全局热键 | `HotKeyManager.swift`（Carbon / RegisterEventHotKey） | 0%，Windows 用 RegisterHotKey |
| 选区读取 | `SelectionProvider.swift`（Accessibility + 模拟 ⌘C） | 0%，Windows 用 UI Automation + 模拟 Ctrl+C |
| 剪贴板 | `NSPasteboard` | 0%，Windows 用 Clipboard API |
| 语音 | `VoiceInputService.swift`（AVAudioEngine + SFSpeechRecognizer） | 0%，Windows 用 WASAPI + 系统/云端识别 |
| 截图 | `ScreenshotCapture.swift`（系统交互式截图） | 0%，Windows 用 Windows.Graphics.Capture |
| 服务商 / 模型 / 预设 | `EngineStore.swift` + `EnginePicker.swift` | 60–80%，数据模型和预设可共享 |
| 提示词 / 变量替换 | `PromptTemplate.swift`、`TranslationService.swift` | 70–80%，逻辑可移植 |
| LLM 请求 / SSE 流式 | `LLMClient.swift` | 70–80%，协议和解析可共享 |
| 结果历史 | `ResultStore.swift` | 70–80%，JSON schema 可共享 |
| 设置存储 | `UserDefaults` | 0%，Windows 用 JSON / Registry |
| 开机自启 / 更新 | `SMAppService` | 0%，Windows 用 StartupTask / MSIX |

**所以「Windows 版」不是加一个编译开关，而是一个新的系统集成层 + 新 UI。**
粗估：Windows MVP 约 2–3 周，完整对齐语音/截图/替换约 1–2 个月（单人）。

## 2. 三条路线

| 路线 | 做法 | 优点 | 代价 |
|---|---|---|---|
| **A. 原生双壳 + 共享契约**（推荐） | macOS SwiftUI；Windows WinUI 3 / C#；两端共享提示词、provider 预设、JSON schema、SSE 约定 | 两端都原生；macOS 体验不被拖累；职责清晰 | 两套 UI；需要维护契约文档 |
| **B. Rust 核心 + 双壳** | 把 provider / 请求 / 流式 / 历史做成 Rust 本地 core（HTTP 或 IPC），两端只做薄 UI | 核心只写一次；易测试；未来可加 CLI | 多一个进程/打包层；起步成本高 |
| **C. 一套跨平台 UI** | Tauri / Flutter / Electron 重写整个界面 | 一套 UI；Windows 起量快 | macOS 失去原生感；选区/热键/语音/截图仍要平台插件；与当前 SwiftUI 代码不共享 |

**建议先走 A**。如果未来 Windows 成为主战场、并且你确定要长期双端，再把核心抽成 B 的 Rust 服务。
不建议现在选 C：它会把「更苹果」这个已经成立的差异点先牺牲掉。

## 3. 推荐架构

```
macOS shell (SwiftUI + AppKit)
        │
        ├── Core contract（平台无关）
        │     ├── Provider / ProviderModel / 预设 JSON
        │     ├── 提示词 + 变量替换规则
        │     ├── 请求体 / SSE 分片 / 错误码约定
        │     └── 历史记录 JSON（版本号 + 迁移）
        │
Windows shell (WinUI 3 / C#)
        │
        └── 平台适配层
              ├── 全局热键（RegisterHotKey）
              ├── 选区（UI Automation，失败回退 Ctrl+C）
              ├── 替换（剪贴板 + Ctrl+V）
              ├── 语音（WASAPI + 识别）
              ├── 截图（Windows.Graphics.Capture）
              └── 托盘 / 开机自启 / 更新
```

共享的是**契约和数据**，不是视图。两端的快捷键文案、权限流程、面板材质各自原生。

## 4. 现在就要守住的 6 条边界

1. **业务逻辑不写进 SwiftUI / AppKit。**
   引擎选择、提示词组装、翻译方向、历史淘汰规则应放在不 import AppKit 的类型里；
   视图只做展示和事件转发。
2. **配置和历史用版本化 JSON，不用 `UserDefaults` 当核心模型。**
   `UserDefaults` 只做 macOS 的存储适配器；核心类型应能 `Codable` 到 JSON。
3. **快捷键是抽象动作，不是字符串。**
   核心只定义 `translate / ask / apply`，显示层再格式化成 `⌘2` 或 `Ctrl+2`；
   不要把 `⌘` 写进核心文案。
4. **平台能力走适配器。**
   选区、剪贴板、语音、截图、窗口定位各定义一个协议；macOS 实现一套，Windows 实现一套。
5. **图片用 `Data + 尺寸`，不用 `NSImage` 当共享模型。**
   展示层再转成平台图像。
6. **提示词和服务商预设是数据，不是代码。**
   放 JSON / 资源文件，带 schema 版本；这样 Windows 端可以直接读同一份。

## 5. Windows MVP 的范围

**Phase 1（先能用，2–3 周）**
- 托盘应用 + 全局热键（翻译 / 提问）
- 选区：UI Automation 优先，失败回退模拟 Ctrl+C
- 翻译卡：流式、复制、替换回原处
- 提问：文字输入（语音先不做）
- 服务商 / Key / 模型设置（先支持 OpenAI 兼容 + 一个预设）
- 结果历史（最近 N 条）
- 开机自启可选

**Phase 2（再对齐体验）**
- 按住说话（WASAPI + 系统/云端识别）
- 框选截图（Windows.Graphics.Capture）
- 更完整的 provider 预设 / 模型发现
- 自动更新 / MSIX 打包

**Phase 3（可选）**
- 双端共享历史 / 配置同步
- 抽取 Rust core 或本地服务
- 插件 / 自定义动作（不建议早做）

**Windows MVP 刻意不做**：生图、复杂动作面板、对话持久化、截图 OCR、跨设备同步。
先把「选中 → 翻译 → 替换」做顺，和 macOS v5 的判断保持一致。

## 6. 技术选型建议

- **WinUI 3 + C#（Windows App SDK）**：最接近 Windows 原生；托盘、热键、UI Automation、
  Windows.Graphics.Capture 都是一等公民。适合「认真做 Windows 原生版」。
- **Tauri + Web 前端**：起量快、UI 迭代快、包体小；但面板材质、选区、热键、语音仍要 Rust 侧适配，
  且 macOS 端不会复用它。适合「先验证 Windows 需求」。
- **Flutter / Electron**：不推荐。前者非原生质感，后者太重；对一个小工具都不划算。
- **Swift on Windows**：Foundation 可用，但没有 SwiftUI / AppKit；UI 仍要换栈。不要为了「复用 Swift」而选它。

## 7. 现在做什么

- **不重构**。先把 macOS v5 跑稳、验证「翻译 + 语音」的真实使用频率。
- 下一次做 Windows 相关准备时，先产出 `docs/core-contract.md`：
  - `Provider` / `ProviderModel` / `ResultRecord` 的 JSON schema
  - 请求体与 SSE 分片约定
  - 提示词与变量规则
  - 平台适配器接口清单
- 然后选 WinUI 3 或 Tauri 做 Phase 1；不要在 macOS 里继续堆平台无关性不明的逻辑。

## 8. 什么时候真的开始

满足任意一条再投入：

- macOS 版已经稳定自用 2–4 周，核心链路（选区、替换、语音）没有大坑；
- 明确有一批 Windows 用户在问 / 愿意试用；
- 你愿意接受「Windows 首版只做翻译 + 提问，不做语音/截图」。

否则，先把 macOS 做深，比同时维护两个半成品更划算。
