import SwiftUI
import SuperagentCore
import TmuxKit

/// The app's root: a UNIFIED two-pane layout (no floating NavigationSplitView column). A solid,
/// resizable sidebar sits flush against the terminal area, separated by a draggable divider.
/// The terminal area is topped by a slim active-terminal header (title + status + command).
struct RootView: View {
    @Environment(AppModel.self) private var appModel

    /// Persisted sidebar width. Owned here (NOT by the sidebar's own frame) so the divider drag
    /// and @AppStorage stay the single source of truth across launches.
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 230

    private let minSidebar: Double = 190
    private let maxSidebar: Double = 420

    var body: some View {
        @Bindable var model = appModel
        HStack(spacing: 0) {
            if !appModel.sidebarCollapsed {
                SidebarView()
                    .frame(width: clampedSidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                SidebarDivider(
                    width: $sidebarWidth,
                    minWidth: minSidebar,
                    maxWidth: maxSidebar
                )
            }

            VStack(spacing: 0) {
                if appModel.tmuxMissing {
                    TmuxMissingBanner()
                }
                if let error = model.lastError {
                    ErrorBanner(message: error) { model.lastError = nil }
                }
                if let notice = model.detachedNotice {
                    DetachToast(message: notice,
                                onUndo: { model.undoDetach() },
                                onDismiss: { model.dismissDetachNotice() })
                }
                if appModel.axisSelected {
                    ToolHeaderBar(icon: "cpu", title: "本地模型", subtitle: "管理本机 axis-model 服务：安装、启停与模型切换。")
                    Divider()
                    AxisModelView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appModel.claudeMdSelected {
                    ToolHeaderBar(icon: "doc.text", title: "全局指令", subtitle: "编辑 Antigravity (GEMINI.md)、Claude Code 与 Codex 的全局指令。")
                    Divider()
                    ClaudeMdView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appModel.skillsSelected {
                    ToolHeaderBar(icon: "wand.and.stars", title: "Skills", subtitle: "浏览与编辑 Antigravity、Claude Code 与 Codex 的 Skills。")
                    Divider()
                    SkillsView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appModel.labSelected {
                    ToolHeaderBar(icon: "waveform.path.ecg", title: "系统监控", subtitle: "本机资源、Token 用量与活跃 PTY 进程。")
                    Divider()
                    LabView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appModel.tunnelsSelected {
                    ToolHeaderBar(icon: "network.badge.shield.half.filled", title: "隧道", subtitle: "SSH 反向端口转发与临时公网地址，断线自动重连。")
                    Divider()
                    TunnelsView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appModel.worklistSelected {
                    if appModel.worklistShowsSettings {
                        WorklistSettingsPage()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        WorklistView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if appModel.superagentSelected {
                    ToolHeaderBar(icon: "person.crop.rectangle.stack", title: "主管",
                                  subtitle: "在主管终端里用自然语言提需求；这里列出工单、问题和规则。")
                    Divider()
                    SuperagentPanel()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appModel.groupNoteSelected, let gid = appModel.groupNoteID {
                    GroupNoteView(groupID: gid)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ActiveTerminalHeader(connection: appModel.selectedConnection)
                    Divider()
                    if let conn = appModel.selectedConnection, let ticket = appModel.ticket(for: conn) {
                        TicketBar(view: ticket)
                        Divider()
                    }
                    TerminalAreaView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                FontSizeHUD(size: appModel.fontSize, pulse: appModel.fontPulse)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .preferredColorScheme(appModel.preferredColorScheme)
        .animation(.easeInOut(duration: 0.22), value: appModel.sidebarCollapsed)
        .tint(Theme.controlTint)
        .navigationTitle("TFA")
        // Host the per-session menu's sheets/alerts ONCE here, so right-clicking the sidebar row OR
        // the terminal area both work — even when the sidebar is collapsed.
        .sessionMenuHost(appModel.sessionMenu, appModel)
        // Primary actions live in the left panel now (SidebarHeader) — title stays on the right.
        .sheet(isPresented: $model.isShowingSearch) {
            SearchView()
        }
        .sheet(isPresented: $model.isShowingQuickSwitch) {
            QuickSwitchView()
        }
        .sheet(item: $model.historyViewer) { conn in
            HistoryViewerSheet(connection: conn)
                .environment(appModel)
        }
        .sheet(item: $model.ticketFeedback) { req in
            TicketFeedbackSheet(request: req)
                .environment(appModel)
        }
        .sheet(item: $model.taskFeedback) { req in
            TaskRejectSheet(request: req)
                .environment(appModel)
        }
        .sheet(isPresented: $model.isShowingNewSession) {
            NewSessionSheet()
                .environment(appModel)
        }
        .alert("从备份恢复 SSH 密码?", isPresented: $model.keychainRecoveryNeeded) {
            Button("恢复") { appModel.recoverPasswordsFromBackup() }
            Button("以后再说", role: .cancel) { appModel.dismissKeychainRecovery() }
        } message: {
            Text("钥匙串读取失败（通常是 App 重新签名 / 重装导致）。检测到本地加密备份中有 \(appModel.backupPasswordCount) 个已保存的 SSH 密码，是否恢复？恢复后会重新写入钥匙串。")
        }
        // 点「通过」却没能合并工单分支：在哪儿点的都能看到原因（工单条下面没有面板的横幅）。
        .alert("没有合并", isPresented: Binding(get: { appModel.superagent.mergeError != nil },
                                              set: { if !$0 { appModel.superagent.mergeError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(appModel.superagent.mergeError ?? "")
        }
    }

    private var clampedSidebarWidth: CGFloat {
        CGFloat(min(max(sidebarWidth, minSidebar), maxSidebar))
    }
}

/// A thin draggable divider that resizes the sidebar by mutating the persisted width.
/// macOS-14 caveat: HStack/Divider is not user-resizable on its own, so we drive the width
/// ourselves from a DragGesture and show a resize cursor on hover.
private struct SidebarDivider: View {
    @Binding var width: Double
    let minWidth: Double
    let maxWidth: Double

    var body: some View {
        Divider()
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let proposed = width + Double(value.translation.width)
                                width = min(max(proposed, minWidth), maxWidth)
                            }
                    )
            )
            .accessibilityHidden(true) // decorative drag handle
    }
}

/// Slim bar above the terminal area. Unlike the sidebar row (name + command), this carries the
/// *active* terminal's status and the context the row can't show — host, live grid size — plus a
/// Reconnect affordance when it has failed. (Shared `StatusIndicator` keeps it consistent.)
private struct ActiveTerminalHeader: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    let connection: ConnectionSession?
    /// Grid chip visibility: shown for a few seconds after the grid actually changes, then fades.
    @State private var showGrid = false
    @State private var gridHideTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Button { appModel.toggleSidebar() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help(appModel.sidebarCollapsed ? "显示侧栏 (⌘\\)" : "隐藏侧栏 (⌘\\)")
            .accessibilityLabel(appModel.sidebarCollapsed ? "Show sidebar" : "Hide sidebar")

            if let conn = connection {
                let isRouter = conn.id == appModel.routerConnection?.id
                let kind = TerminalKind.of(conn)

                Text(conn.title)
                    .font(Theme.Font.headerTitle)
                    .lineLimit(1)
                    .layoutPriority(1)

                if let state = abnormalStateTag(conn) {
                    StateTag(text: state.0, tint: state.1)
                } else if kind.isAgent {
                    metaChip(kind.symbol, kind.label)
                }

                if let host = conn.host { metaChip("network", host) }
                if let g = conn.grid, showGrid { metaChip("squareshape.split.2x2", "\(g.cols)×\(g.rows)") }

                if let path = conn.currentPath {
                    let shown = displayPath(path, remote: conn.host != nil)
                    Text(shown)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(shown)
                        .accessibilityLabel("当前路径 \(shown)")
                }

                Spacer(minLength: Theme.Space.md)

                if TerminalStatus.of(conn) == .failed {
                    Button { conn.retry() } label: {
                        Label("重新连接", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel("Reconnect terminal")
                }

                if isRouter {
                    let needs = appModel.superagent.tasksNeedingYou.count
                    Button { appModel.openWorklist() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "list.bullet.clipboard")
                            Text(needs > 0 ? "我的清单 · \(needs)" : "我的清单")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(needs > 0 ? Theme.Status.attention : Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(needs > 0 ? Theme.Status.attention.opacity(0.12) : Theme.surface2,
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("打开我的清单")

                    Button { appModel.restartRouter() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("按当前设置重启主管")
                    .accessibilityLabel("重启主管")
                }

                HStack(spacing: 2) {
                    headerIconButton("clock.arrow.circlepath", help: "查看历史回滚 (⌘⇧H)") {
                        appModel.showHistoryViewer()
                    }
                    headerIconButton("folder", help: conn.host != nil ? "暂不支持远程会话" : "打开文件管理器",
                                     disabled: conn.host != nil || conn.currentPath == nil) {
                        if let p = conn.currentPath { openWindow(value: URL(fileURLWithPath: p)) }
                    }
                    headerIconButton("magnifyingglass", help: "搜索全部终端 (⌘F)") {
                        appModel.isShowingSearch = true
                    }
                    headerIconButton("command", help: "快速切换终端 (⌘K)") {
                        appModel.isShowingQuickSwitch = true
                    }
                }
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
                Text("未选择终端")
                    .font(Theme.Font.headerTitle)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            AppearanceMenuButton()
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.canvas)
        .onChange(of: gridText) { _, new in
            guard new != nil else { showGrid = false; return }
            withAnimation(.easeInOut(duration: 0.15)) { showGrid = true }
            gridHideTask?.cancel()
            gridHideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.3)) { showGrid = false }
            }
        }
    }

    private func headerIconButton(_ symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(help)
    }

    /// Only surface a state tag when something is non-routine (disconnected / connecting / needs attention).
    private func abnormalStateTag(_ conn: ConnectionSession) -> (String, Color)? {
        switch TerminalStatus.of(conn) {
        case .failed: return ("连接失败", Theme.Status.error)
        case .ended: return ("已断开", Theme.Status.neutral)
        case .reconnecting: return ("重连中", Theme.Status.pending)
        case .connecting: return ("连接中", Theme.Status.pending)
        case .dormant: return ("未连接", Theme.Status.neutral)
        case .connected:
            return conn.needsAttention ? ("需要你", Theme.Status.attention) : nil
        }
    }

    /// The grid as a compare-friendly string (tuples aren't Equatable for onChange); nil = no grid.
    private var gridText: String? {
        connection?.grid.map { "\($0.cols)×\($0.rows)" }
    }

    /// Abbreviate a LOCAL path's home prefix to `~`. Remote paths are left as-is (the home that
    /// matters is the remote machine's, which we can't assume matches this Mac's).
    private func displayPath(_ path: String, remote: Bool) -> String {
        guard !remote else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func metaChip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: Theme.Space.xxs) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(text).font(Theme.Font.headerMeta).monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, Theme.Space.xxs)
        .background(Theme.surface2, in: Capsule())
        .accessibilityLabel("\(text)")
    }
}

/// Quick appearance menu button in headers so users can toggle System / Light / Dark anytime in one click.
struct AppearanceMenuButton: View {
    @Environment(AppModel.self) private var appModel

    private var icon: String {
        switch appModel.appearanceMode {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var body: some View {
        @Bindable var model = appModel
        Menu {
            Picker("外观", selection: $model.appearanceMode) {
                ForEach(AppModel.AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 24, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("切换外观：\(appModel.appearanceMode.label)")
        .accessibilityLabel("切换外观")
    }
}

/// Shown when no `tmux` binary was found — turns a dependency gap from a connection-FAILURE page into
/// an up-front, fixable hint with a one-click copy of the install command.
private struct TmuxMissingBanner: View {
    @State private var copied = false
    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.pending)
            Text("未检测到 tmux —— TFA 需要它来运行终端。").lineLimit(1)
            Text("brew install tmux").font(.caption.monospaced())
                .padding(.horizontal, Theme.Space.sm).padding(.vertical, 2)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            Button(copied ? "已复制" : "复制") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString("brew install tmux", forType: .string)
                copied = true
            }
            .controlSize(.small)
            Spacer(minLength: 0)
        }
        .font(Theme.Font.headerMeta)
        .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.md)
        .background(Theme.Status.pending.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Status.error)
            Text(message)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .font(Theme.Font.headerMeta)
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        .background(Theme.Status.error.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Header for a tool pane (模型 / 规则 / Skills / 实验室 / 隧道): sidebar toggle, accent icon and
/// title, and one line underneath saying what the pane is for.
struct ToolHeaderBar<Leading: View, Trailing: View>: View {
    @Environment(AppModel.self) private var appModel
    let icon: String
    let title: String
    let subtitle: String
    /// Between the sidebar toggle and the title (e.g. a「‹ 我的清单」back button on a task card).
    @ViewBuilder let leading: () -> Leading
    /// Right-aligned controls (search, a prominent「+ 任务」).
    @ViewBuilder let trailing: () -> Trailing

    init(icon: String, title: String, subtitle: String,
         @ViewBuilder leading: @escaping () -> Leading = { EmptyView() },
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.icon = icon; self.title = title; self.subtitle = subtitle
        self.leading = leading; self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Button { appModel.toggleSidebar() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help(appModel.sidebarCollapsed ? "Show sidebar (⌘\\)" : "Hide sidebar (⌘\\)")
            .accessibilityLabel(appModel.sidebarCollapsed ? "Show sidebar" : "Hide sidebar")
            .padding(.top, 2)

            leading()
                .buttonStyle(.borderless)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: icon).foregroundStyle(Theme.brand)
                    Text(title).font(Theme.Font.headerTitle).lineLimit(1)
                }
                Text(subtitle)
                    .font(Theme.Font.headerMeta)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: Theme.Space.sm) {
                trailing()
                AppearanceMenuButton()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.canvas)
    }
}

/// Non-blocking toast for a just-detached terminal: makes clear the tmux session SURVIVES (unlike
/// Kill) and offers a one-click Undo (re-attach). Mirrors `ErrorBanner`'s layout but brand-tinted.
private struct DetachToast: View {
    let message: String
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "rectangle.portrait.and.arrow.right")
                .foregroundStyle(Theme.brand)
            Text(message)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("撤销", action: onUndo)
                .buttonStyle(.link)
                .accessibilityLabel("Undo detach — re-attach the session")
            Button { onDismiss() } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .font(Theme.Font.headerMeta)
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        .background(Theme.brand.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A brief "13 pt" flash whenever the font size changes (driven by `AppModel.fontPulse`), so ⌘+/−/0
/// gives visible feedback — including a no-op press at the 9–28 clamp boundary. Non-interactive.
private struct FontSizeHUD: View {
    let size: Double
    let pulse: Int
    @State private var visible = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        // Mounted only while showing: a material keeps re-blurring whatever is behind it, so an
        // always-present (opacity 0) HUD over the live terminal re-rendered continuously.
        ZStack {
            if visible {
                Text("\(Int(size)) pt")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, Theme.Space.lg)
                    .padding(.vertical, Theme.Space.sm)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.brand.opacity(0.4)))
                    .padding(.top, Theme.Space.xl)
                    .transition(.opacity)
            }
        }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .animation(.easeOut(duration: 0.12), value: visible)
            .onChange(of: pulse) {
                visible = true
                hideTask?.cancel()
                hideTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.25)) { visible = false }
                }
            }
    }
}
