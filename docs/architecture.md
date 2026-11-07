# TFA 架构与实现要点

> 面向开发者。概览见 [README](../README.md)。

TFA 不是另写一个多路复用器，而是封装真实的 tmux：通过 tmux 的**控制模式**（`tmux -CC`）
与一个真正的 tmux server 通信。因此它保留了 tmux 的全部能力——会话持久、可脚本化、远程稳定——
同时提供一个原生、克制、可访问的图形界面。

## 设计原则

- **一个终端 = 一个 tmux 会话**，每个终端有自己独立的 `tmux -CC` 连接，各自实时流动；切换
  只是换显示，不需要 `switch-client`。
- **封装而非重写**：所有终端能力来自真实 tmux，TFA 只做可视化与管理。
- **断线不丢**：这正是 tmux 的意义所在。SSH 抖动、管道中断，只要会话还在，TFA 会自动重连。
- **分层、低耦合**：核心协议层 `TmuxKit` 不依赖任何 UI（仅 Foundation + Observation），便于复用或替换前端。

## 架构

```
┌──────────────────────────────────────────────────────────────┐
│ SwiftUI App  (target: Mux，依赖 SwiftTerm)                     │
│                                                               │
│  RootView ── 侧边栏(过滤/状态/活动点) │ 标题栏 │ 终端区 │ 搜索/⌘K │
│  AppModel ── 顶层状态：终端列表/选择/字号/搜索                  │
│  ConnectionSession ── 1 个连接 = 1 个终端 + 重连 + 窗格注册表    │
│  PaneTerminal ── 1 个 SwiftTerm 视图 + 水合 + 光标不变式         │
└───────────────────────────┬──────────────────────────────────┘
                            │  @Observable 绑定
        ┌───────────────────▼────────────────────────┐
        │ TmuxKit  (library，纯 Swift，无 UI 依赖)     │
        │                                             │
        │  TmuxController ── 应用事件流到 @Observable    │
        │                    TmuxState(会话/窗口/窗格)  │
        │  TmuxControlClient ── 协议解析 + FIFO 命令队列 │
        │  TmuxProtocolParser ── %output/%begin/%end/%  │
        │  PtyProcessTransport ─ 本地: `tmux -CC`        │
        │                     └ 远程: `ssh host tmux -CC`│
        │  LayoutParser / TmuxServer / Models           │
        └───────────────────┬─────────────────────────┘
                            │ PTY (raw) ← 控制协议字节流
                       真实 tmux server
```

- **每个 tmux 窗格（`%id`）** ↔ 一个 SwiftTerm 视图：把 `%output` 字节喂进去渲染，用户键盘输入经
  `send-keys -H`（十六进制，二进制安全）回传 tmux。窗格注册表**按连接隔离**（`%id` 只在单 server 内唯一）。
- **TmuxKit 零 UI 依赖**（仅 Foundation + Observation），便于将来替换前端；SwiftTerm 只在 app target 用到。

## 两个关键难点

### 1) 光标不变式
`capture-pane` 恢复屏幕文本但**不恢复光标**，且它与 CUP 都是相对 tmux **真实窗格尺寸**度量的。
若 SwiftTerm 引擎的网格与 tmux 窗格尺寸不一致（例如后台会话仍是默认 24 行，或被其它客户端
reconcile 成别的尺寸），光标就会落到错误的行。

**约束**：任何 capture / CUP 之前，必须先把引擎钉到 tmux 的 `paneSize`。该不变量收口在
`PaneTerminal.pinEngineToPaneSize()` **一处**——每条触碰光标的路径都必须经过它，重构时不会悄悄回归。

### 2) 断线自动重连
`ConnectionSession` 在非用户主动的断开时换上一个全新的 `TmuxController`（`attach-session`），
bump `generation` 触发重水合；退避策略 `backoffDelay(attempt:)` 是纯函数。语义保证：
**掉线 → 重连；kill → 只 finalize 一次，不死循环；用户主动 detach → 不重连**。

## 目录结构

```
Package.swift
Sources/
  TmuxKit/            # 核心：协议解析、模型、PTY 传输、状态控制器(无 UI 依赖)
    Transport.swift / ControlProtocol.swift / ControlClient.swift
    TmuxController.swift / TmuxState(Models.swift) / LayoutParser.swift
    TmuxServer.swift / Connection.swift / PTY.swift / Errors.swift
  AxisClaude/         # axis-claude 命令行编程助手（只依赖 Foundation）
  Mux/                # SwiftUI 应用
    MuxApp.swift / RootView.swift / SidebarView.swift / TerminalAreaView.swift
    AppModel.swift / ConnectionSession.swift / PaneTerminal.swift / TerminalPaneView.swift
    SearchView.swift / QuickSwitchView.swift / SettingsView.swift / Theme.swift
    Lab.swift（实验室：系统监控 / PTY 监控）/ Notifications.swift（输出完成通知）
    ClaudeMd.swift（全局 / 项目规则）/ Skills.swift（Skills 管理 + 语法高亮编辑器）
    Workspace.swift（项目工作区 / 待处理中心）/ EditorSafety.swift（编辑保护）
    AxisModel.swift（模型面板：axis-model 安装 / 状态 / 控制）
    CCUsage*.swift（Token 用量：ccusage 的 Swift 移植，Claude + Codex 两源）
docs/
  tmux-control-protocol.md     # tmux 控制协议规格（编码依据）
  swiftterm-integration.md     # SwiftTerm 集成规格
DESIGN.md             # 设计系统单一真源（token / 状态模型 / 组件 / 终端主题）
```

## 技术要点（均按真实 tmux 3.6a 字节验证）

- `tmux -CC` **必须真 PTY**（纯管道会 `tcgetattr failed`）→ `openpty` + `cfmakeraw`（关回显）+
  `posix_spawn(SETSID)`；输入 `send-keys -t %ID -H <hex>`，尺寸 `refresh-client -C WxH`。
- 协议：`%output` 八进制解码、`%begin/%end/%error` 帧、`%`-通知、DCS 握手；命令回复按
  `flags==1` 块 FIFO 配对（`ControlClient` 抛出真实 `%error`/`%exit` 文本，横幅显示真因）。
- 远程：`ssh -tt … env PATH=… tmux -CC`——一次性命令走 `shell -c` 不读登录配置，显式带上
  Homebrew / 系统 bin 目录，避免 macOS 远程主机找不到 `tmux`。
- SwiftTerm 1.13.0：`view.feed(byteArray:)` 喂字节；输入经 delegate `send(source:data:)`；
  Swift-6 需 `@MainActor TerminalViewDelegate`。
- 终端主题用**固定 sRGB 深色**前 / 背景（不随系统外观漂移），避免新建窗格首帧出现浅 / 深错色条带。
