# KoK

一个 macOS 状态栏效率工具，目前有两件事：

- **划词翻译**：选中任意文本，按快捷键在浮动面板中看译文；
- **快速问答**：按快捷键弹出对话面板，直接打字问问题，流式返回。

两者共用同一套引擎配置与 API Key。支持多引擎（DeepL / Gemini / 任意 OpenAI 兼容服务）、
翻译历史、全局与单引擎自定义提示词。

## 功能

- **多引擎**：数据驱动的引擎配置，可自由添加 / 编辑 / 删除引擎
  - `DeepL` 专用协议（仅翻译）
  - `Gemini`（Google Generative Language）
  - `OpenAI 兼容`：OpenAI、腾讯云 Token Plan、DeepSeek、通义千问、Moonshot、智谱等
- **批量添加**：内置腾讯云 / OpenAI / DeepSeek / 智谱 / Moonshot 预设模板
- **提示词**：翻译与对话各自独立的系统提示词；翻译支持 `{{TARGET_LANG}}` 变量与每引擎单独提示词
- **体验**：面板可拖拽调整大小、`Esc` 关闭、复制反馈、失败重试、切换引擎自动重译
- **历史记录**：保留翻译历史
- **快速问答**：独立快捷键唤出，流式输出、可中断 / 重生成 / 新对话，代码块自动分块并可复制
- **状态栏**：左键打开设置，右键菜单可打开对话 / 开关机自启动 / 退出
- **开机自启动**：基于 `SMAppService`

## 快捷键

| 动作 | 默认键 | 说明 |
|---|---|---|
| 翻译 | `⌥D` | 读取当前选中文本（需要「辅助功能」权限） |
| 快速问答 | `⌥K` | 直接弹出输入框，**不需要**辅助功能权限 |

两者都可在「设置 ▸ 通用」里重新录制。

### ⚠️ 快捷键冲突（重要）

macOS 的 `RegisterEventHotKey` 在组合被别的 App 占用时**不会返回错误**，事件会静默地
被先注册方吃掉，表现就是「按了完全没反应」。

已知 **iShot** 会占用 `⌥A`、`⌥B`、`⌥D`、`⌥E`、`⌥F`、`⌥G`、`⌥H`、`⌥O`、`⌥P`、`⌥Q`、
`⌥R`、`⌥S`、`⌥T`、`⌥W`、`⌥X`、`⌥Z`。所以默认键避开了这些组合。

设置页每个快捷键旁边都有 **「测试」** 按钮：点一下，然后按下该快捷键——

- 显示 **生效** → 组合可用；
- 显示 **未收到，可能被其它 App 占用** → 换一个组合重试。

> 换个组合后建议顺手在占用方 App 里确认一下，避免两边抢同一个键。

## 环境要求

| 项 | 版本 |
|---|---|
| macOS | 15.7 及以上 |
| Xcode | 26.x（项目使用 Xcode 同步文件夹与 Swift 5 语言模式） |

## 依赖

- [soffes/HotKey](https://github.com/soffes/HotKey) —— 通过 SwiftPM 引入，版本锁定在 `Package.resolved`。

> ⚠️ 该依赖目前指向分支 `main`（revision `a3cf605`）而非版本 tag。若要长期稳定，建议在 Xcode 中改为
> 「Up to Next Major / Exact Version」并重新提交 `Package.resolved`。

## 构建与安装

### 用 Xcode

1. 打开 `KoK.xcodeproj`
2. 选择 scheme `KoK`，目标 `My Mac`
3. `Product ▸ Archive`（会产出 universal 二进制：`arm64` + `x86_64`）
4. 在 Organizer 中 `Distribute App ▸ Copy App`，把 `KoK.app` 拖到 `/Applications`

### 命令行

```bash
xcodebuild -project KoK.xcodeproj -scheme KoK \
  -configuration Release -derivedDataPath build/dd \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build

# 产物：build/dd/Build/Products/Release/KoK.app
```

安装（会先退出正在运行的实例）：

```bash
osascript -e 'quit app "KoK"' 2>/dev/null
rm -rf /Applications/KoK.app
cp -R build/dd/Build/Products/Release/KoK.app /Applications/
open /Applications/KoK.app
```

## API Key 配置

**源码与仓库中不包含任何真实密钥。** 每个引擎的 Key 按以下顺序解析（见
`KoK/TranslationService.swift` 的 `EngineConfig.resolvedAPIKey`）：

1. 「设置」面板中为该引擎保存的 Key（保存到用户偏好 `Translator-App.KoK.plist`）；
2. 环境变量 `KOK_API_KEY_<引擎名>`：引擎名转大写，非字母数字字符替换为下划线。

例如：

| 引擎名 | 环境变量 |
|---|---|
| `Qwen` | `KOK_API_KEY_QWEN` |
| `DeepL` | `KOK_API_KEY_DEEPL` |
| `我的通义千问` | `KOK_API_KEY_我的通义千问` |

> 环境变量方式主要用于命令行 / Xcode scheme 中调试。从 Finder 启动的 App 读取不到 shell
> 环境变量，这种情况下请在「设置」面板里填写。

若两者都没有配置，翻译时会提示「请在设置中填入 <引擎名> 的 API Key」。

### 安全须知

- 不要把真实 Key 写进源码、`Info.plist` 或任何会被提交的文件。
- 建议提交前自查：

  ```bash
  git grep -nE 'sk-[A-Za-z0-9]{16,}|AIza[A-Za-z0-9_-]{20,}|apiKey: "[^"]+"'
  ```

- 用户手动填写的 Key 目前以**明文**保存在
  `~/Library/Preferences/Translator-App.KoK.plist`（文件权限 `600`）。如需更强保护，
 可改为存入 Keychain。

## 版本号规则

`KoK.xcodeproj` 中的两处设置同时维护（Debug / Release 都要改）：

| 设置 | 含义 | 递增规则 |
|---|---|---|
| `MARKETING_VERSION` | 用户可见版本（`CFBundleShortVersionString`） | 功能更新 `+0.1`；重大重构 / 不兼容变更 `+1.0` |
| `CURRENT_PROJECT_VERSION` | 构建号（`CFBundleVersion`） | **每次 Archive 或分发都 `+1`**，只增不减 |

当前为 `2.0 (3)`：`1.0` 为 2025-12 的最初版本，`2.0` 为 2026-04 的多引擎重构。

## 目录结构

```
KoK.xcodeproj/           # Xcode 工程
KoK/                     # 源码（Xcode 同步文件夹）
├── KoKApp.swift         # App 入口 + AppDelegate（状态栏、开机自启动）
├── HotKeyManager.swift  # 多动作全局快捷键（含自检钩子与旧配置迁移）
├── PanelController.swift# 悬浮面板基类：定位、点击外部 / Esc 关闭
├── FloatingPanel.swift  # 无边框可缩放 NSPanel
├── WindowManager.swift  # 翻译面板控制器
├── ChatPanelController.swift    # 对话面板控制器（与翻译面板互斥）
├── TranslationService.swift     # 引擎配置模型 + 翻译协议实现 + 错误类型
├── ChatService.swift    # 对话协议实现（OpenAI 兼容 / Gemini，SSE 流式 + 降级）
├── TranslationViewModel.swift   # 翻译状态与历史记录
├── ChatViewModel.swift  # 对话状态（内存态，不落盘）
├── SettingsView.swift   # 设置界面（引擎管理、提示词、快捷键）
├── TranslationView.swift# 翻译面板界面
├── ChatView.swift       # 对话面板界面 + 轻量 Markdown / 代码块
└── Assets.xcassets/     # 图标与配色
```

> ⚠️ `KoK/` 是 **Xcode 同步文件夹**（`PBXFileSystemSynchronizedRootGroup`）：目录下的所有文件
> 默认都会被打进 App 包。**不要把构建产物、旧版本 `.app`、临时文件放进 `KoK/`**，否则会被
> 打包进 `KoK.app/Contents/Resources/`。例外文件需在 target 的
> `PBXFileSystemSynchronizedBuildFileExceptionSet` 中登记（目前仅 `Info.plist`）。

## 快速问答的边界

为了保持轻量，以下都是**刻意不做**的：

- 对话**不落盘**：只存在内存里，关掉面板保留、点「新对话」清空、退出 App 即消失；
- 只保留最近 20 条消息（约 10 轮）作为上下文，避免 token 与费用失控；
- 不引入 Markdown / 网络 / 状态管理第三方库，代码块分块用约 60 行手写解析；
- 不支持多模态、文件上传、Agent 工具调用。

## 已知限制

- 无自动化测试。
- 应用未做 Developer ID 签名 / 公证，仅适合本机自用。
- `NSAccessibility` 权限：**只有翻译**读取选中文本需要授予「辅助功能」权限，首次使用时按提示在
  「系统设置 ▸ 隐私与安全性 ▸ 辅助功能」中勾选 KoK。**快速问答不需要该权限。**
- 部分 OpenAI 兼容服务不支持 `stream`，此时会自动降级为一次性返回；若仍失败，面板会显示
  可重试的错误条。
