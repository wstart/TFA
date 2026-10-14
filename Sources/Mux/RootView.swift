import SwiftUI
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
                    ToolHeaderBar(icon: "cpu", title: "模型", subtitle: "本机 axis-model 服务：安装、启停、切换模型。axis-claude 用的就是它。")
                    Divider()
                    AxisModelView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appModel.claudeMdSelected {
                    ToolHeaderBar(icon: "text.book.closed", title: "规则", subtitle: "Claude Code / Codex 的全局规则文件，保存后对新对话生效。")
                    Divider()
                    ClaudeMdView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appModel.skillsSelected {
                    ToolHeaderBar(icon: "wand.and.stars", title: "Skills", subtitle: "管理 Claude Code / Codex 的 Skills，点开编辑 SKILL.md。")
                    Divider()
                    SkillsView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appModel.labSelected {
                    ToolHeaderBar(icon: "flask", title: "实验室", subtitle: "系统监控、Token 用量与 PTY 进程。")
                    Divider()
                    LabView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appModel.tunnelsSelected {
                    ToolHeaderBar(icon: "network.badge.shield.half.filled", title: "隧道", subtitle: "把本机端口送到远程服务器，或打通一个临时公网地址。断线会自己重连。")
                    Divider()
                    TunnelsView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appModel.groupNoteSelected, let gid = appModel.groupNoteID {
                    GroupNoteView(groupID: gid)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ActiveTerminalHeader(connection: appModel.selectedConnection)
                    Divider()
                    TerminalAreaView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let conn = appModel.selectedConnection {
                        Divider()
                        TerminalFooter(connection: conn)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                FontSizeHUD(size: appModel.fontSize, pulse: appModel.fontPulse)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas) // ivory page canvas under everything (DESIGN.md)
        .preferredColorScheme(.light) // DESIGN.md is a warm LIGHT system — never invert under system dark
        .animation(.easeInOut(duration: 0.22), value: appModel.sidebarCollapsed)
        .tint(Theme.brand) // emphasis = ink/charcoal → prominent buttons read as DESIGN.md "Primary Dark Button"
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
            // One-click sidebar collapse/expand (also ⌘\).
            Button { appModel.toggleSidebar() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help(appModel.sidebarCollapsed ? "Show sidebar (⌘\\)" : "Hide sidebar (⌘\\)")
            .accessibilityLabel(appModel.sidebarCollapsed ? "Show sidebar" : "Hide sidebar")

            if let conn = connection {
                Text(conn.title)
                    .font(Theme.Font.headerTitle)
                    .lineLimit(1)
                    .layoutPriority(1)
                let state = stateTag(conn)
                StateTag(text: state.0, tint: state.1)

                if let host = conn.host { metaChip("network", host) }
                // Grid size only matters while it's changing — surface it briefly after a resize
                // instead of announcing a constant nobody reads (dsh: on-demand, don't announce).
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
                // History viewer: scroll back through this pane's scrollback even when it's on the
                // alternate screen (claude / vim / less), where the live view can't scroll.
                Button { appModel.showHistoryViewer() } label: {
                    Label("历史", systemImage: "clock.arrow.circlepath")
                }
                .help("查看历史(⌘⇧H)")
                Button {
                    if let p = conn.currentPath { openWindow(value: URL(fileURLWithPath: p)) }
                } label: {
                    Label("文件", systemImage: "folder")
                }
                .disabled(conn.host != nil || conn.currentPath == nil)
                .help(conn.host != nil ? "暂不支持远程会话" : "文件管理器")
                Button { appModel.isShowingQuickSwitch = true } label: {
                    Text("⌘K")
                }
                .help("快速切换终端")
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 9, height: 9)
                Text("未选择终端")
                    .font(Theme.Font.headerTitle)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: 40)
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

    /// The header's state tag: what this terminal needs from you, in priority order.
    private func stateTag(_ conn: ConnectionSession) -> (String, Color) {
        switch TerminalStatus.of(conn) {
        case .failed: return ("连接失败", Theme.Status.error)
        case .ended: return ("已断开", Theme.Status.neutral)
        case .reconnecting: return ("重连中", Theme.Status.pending)
        case .connecting: return ("连接中", Theme.Status.pending)
        case .dormant: return ("未连接", Theme.Status.neutral)
        case .connected:
            if conn.needsAttention { return ("需要你", Theme.Status.attention) }
            return appModel.isWorking(conn) ? ("运行中", Theme.Status.positive) : ("空闲", Theme.Status.neutral)
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

/// The slim line under the terminal: what is running and where, plus the shortcuts that matter.
private struct TerminalFooter: View {
    let connection: ConnectionSession

    var body: some View {
        let kind = TerminalKind.of(connection)
        HStack(spacing: Theme.Space.lg) {
            Label(kind.label, systemImage: kind.symbol)
            Text(connection.host.map { "ssh · \($0)" } ?? "本机 · tmux")
            Spacer(minLength: Theme.Space.md)
            hint("⌘]", "下一个有动静")
            hint("⌘K", "快速切换")
            hint("⌘F", "搜索全部")
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textTertiary)
        .lineLimit(1)
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: 24)
        .background(Theme.canvas)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).fontWeight(.semibold).foregroundStyle(Theme.textSecondary)
            Text(label)
        }
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
private struct ToolHeaderBar: View {
    @Environment(AppModel.self) private var appModel
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Button { appModel.toggleSidebar() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help(appModel.sidebarCollapsed ? "Show sidebar (⌘\\)" : "Hide sidebar (⌘\\)")
            .accessibilityLabel(appModel.sidebarCollapsed ? "Show sidebar" : "Hide sidebar")
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
        Text("\(Int(size)) pt")
            .font(.system(.title3, design: .rounded).weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.sm)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.brand.opacity(0.4)))
            .opacity(visible ? 1 : 0)
            .padding(.top, Theme.Space.xl)
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
