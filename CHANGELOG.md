# Changelog

本文件记录 TFA 的重要变更。格式参考 [Keep a Changelog](https://keepachangelog.com)，
版本遵循 [语义化版本](https://semver.org)。

## [0.2.0] — 2026-05-31

### 新增
- **懒加载 attach**：启动和切换 host 时，发现的 tmux 会话先以**休眠占位行**出现（状态 = Idle，
  月亮图标），只有在**首次被选中**时才真正建立 `tmux -CC` 连接。会话很多时，启动 / 切 host 不再
  一次性拉起几十个连接，瞬间完成、占用更省。

### 变更
- **AsyncStream 流控**：连接时启用 tmux 暂停模式（`refresh-client -f pause-after=1`）。某个终端
  疯狂输出（如 `yes`、大日志）时，不再无上限堆积内存、也不再拖垮整个界面——tmux 会缓冲并暂停，
  积压以 `%extended-output` 流式送达，TFA 渲染后回 `continue` 恢复实时。对过旧、不支持流控的
  tmux 会**静默降级**（不报错）。

### 说明
- 休眠（尚未打开过）的终端没有活动连接，因此它的后台「活动指示点」要等首次打开后才会亮起——
  这是懒加载的固有取舍。

## [0.1.0] — 2026-05-31

首个公开版本。

- 原生 macOS（SwiftUI）封装真实 tmux 控制模式（`tmux -CC`）：一个终端 = 一个会话。
- 断线自动重连（detach-safe）、失败态 + 重试、断线非阻断 toast。
- 本地 + SSH 远程（交互式登录：密码 / 主机指纹 / 2FA）、保存的服务器。
- 管理“很多”终端：侧边栏过滤、⌘K 快速切换、活动指示点、⌘] 跳到下一个有新输出的终端、
  跨终端搜索（⌘F）、可拖拽分组。
- 原生设计系统、色盲友好的状态指示、设置窗口（⌘,，含快捷键速查）、app 图标。

[0.2.0]: https://github.com/wstart/TFA/releases/tag/v0.2.0
[0.1.0]: https://github.com/wstart/TFA/releases/tag/v0.1.0
