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
                if appModel.tasksSelected {
                    TasksHeaderBar()
                    Divider()
                    TaskBoardView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appModel.claudeMdSelected {
                    ClaudeMdHeaderBar()
                    Divider()
                    ClaudeMdView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appModel.skillsSelected {
                    SkillsHeaderBar()
                    Divider()
                    SkillsView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appModel.labSelected {
                    LabHeaderBar()
                    Divider()
                    LabView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appModel.tunnelsSelected {
                    TunnelsHeaderBar()
                    Divider()
                    TunnelsView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ActiveTerminalHeader(connection: appModel.selectedConnection)
                    Divider()
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
        .animation(.easeInOut(duration: 0.22), value: appModel.sidebarCollapsed)
        .tint(Theme.brand) // app accent → brand green; buttons/controls adopt the brand tint
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
    let connection: ConnectionSession?

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
                StatusIndicator(status: TerminalStatus.of(conn))
                Text(conn.title)
                    .font(Theme.Font.headerTitle)
                    .lineLimit(1)
                    .layoutPriority(1)

                if let host = conn.host { metaChip("network", host) }
                if let g = conn.grid { metaChip("squareshape.split.2x2", "\(g.cols)×\(g.rows)") }

                if let path = conn.currentPath { pathChip(displayPath(path, remote: conn.host != nil)) }

                Spacer(minLength: Theme.Space.md)

                if TerminalStatus.of(conn) == .failed {
                    Button { conn.retry() } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Reconnect terminal")
                }
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 9, height: 9)
                Text("No terminal")
                    .font(Theme.Font.headerTitle)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The active pane's working directory, rendered as a flexible middle-truncating chip — the
    /// header's main "where am I" cue. Takes the slack between the title and the trailing controls.
    private func pathChip(_ text: String) -> some View {
        HStack(spacing: Theme.Space.xxs) {
            Image(systemName: "folder").font(.system(size: 10))
            Text(text)
                .font(Theme.Font.headerMeta)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, Theme.Space.xxs)
        .background(.quaternary, in: Capsule())
        .help(text)
        .accessibilityLabel("当前路径 \(text)")
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
        .background(.quaternary, in: Capsule())
        .accessibilityLabel("\(text)")
    }
}

/// Shown when no `tmux` binary was found — turns a dependency gap from a connection-FAILURE page into
/// an up-front, fixable hint with a one-click copy of the install command.
private struct TmuxMissingBanner: View {
    @State private var copied = false
    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.reconnecting)
            Text("未检测到 tmux —— TFA 需要它来运行终端。").lineLimit(1)
            Text("brew install tmux").font(.caption.monospaced())
                .padding(.horizontal, Theme.Space.sm).padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            Button(copied ? "已复制" : "复制") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString("brew install tmux", forType: .string)
                copied = true
            }
            .controlSize(.small)
            Spacer(minLength: 0)
        }
        .font(Theme.Font.headerMeta)
        .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.md)
        .background(Theme.Status.reconnecting.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Status.failed)
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
        .background(Theme.Status.failed.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Slim header for the task board detail pane.
private struct TasksHeaderBar: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Button { appModel.toggleSidebar() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help(appModel.sidebarCollapsed ? "Show sidebar (⌘\\)" : "Hide sidebar (⌘\\)")
            .accessibilityLabel(appModel.sidebarCollapsed ? "Show sidebar" : "Hide sidebar")

            Image(systemName: "checklist").foregroundStyle(Theme.brand)
            Text("任务看板").font(Theme.Font.headerTitle).lineLimit(1)
            // Glance stats live HERE (the board view no longer repeats a title row).
            let tasks = appModel.taskBoard.board.tasks
            let doing = tasks.filter { $0.status == .doing }.count
            let blocked = tasks.filter { $0.status == .blocked }.count
            let waiting = tasks.filter { $0.comments.last?.kind == "question" }.count
            if doing > 0 { headerStat("进行中", doing, Theme.brand) }
            if blocked > 0 { headerStat("受阻", blocked, Theme.Status.failed) }
            if waiting > 0 { headerStat("待回复", waiting, Color(red: 0.95, green: 0.62, blue: 0.16)) }
            Spacer()
            if !tasks.isEmpty { Text("共 \(tasks.count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit() }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func headerStat(_ label: String, _ n: Int, _ tint: Color) -> some View {
        (Text("\(label) ").font(.caption).foregroundStyle(.secondary) + Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(tint))
            .monospacedDigit()
    }
}

/// Slim header for the CLAUDE.md detail pane — mirrors `LabHeaderBar`'s chrome.
private struct ClaudeMdHeaderBar: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Button { appModel.toggleSidebar() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help(appModel.sidebarCollapsed ? "Show sidebar (⌘\\)" : "Hide sidebar (⌘\\)")
            .accessibilityLabel(appModel.sidebarCollapsed ? "Show sidebar" : "Hide sidebar")

            Image(systemName: "text.book.closed").foregroundStyle(Theme.brand)
            Text("CLAUDE.md · 全局规则").font(Theme.Font.headerTitle).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Slim header for the Skills detail pane — mirrors `LabHeaderBar`'s chrome so switching between a
/// terminal, the Lab, and Skills feels consistent.
private struct SkillsHeaderBar: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Button { appModel.toggleSidebar() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help(appModel.sidebarCollapsed ? "Show sidebar (⌘\\)" : "Hide sidebar (⌘\\)")
            .accessibilityLabel(appModel.sidebarCollapsed ? "Show sidebar" : "Hide sidebar")

            Image(systemName: "wand.and.stars").foregroundStyle(Theme.brand)
            Text("Skills 管理").font(Theme.Font.headerTitle).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Slim header for the Lab detail pane — mirrors `ActiveTerminalHeader`'s chrome (sidebar toggle +
/// title) so switching between a terminal and the Lab feels consistent.
private struct LabHeaderBar: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Button { appModel.toggleSidebar() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help(appModel.sidebarCollapsed ? "Show sidebar (⌘\\)" : "Hide sidebar (⌘\\)")
            .accessibilityLabel(appModel.sidebarCollapsed ? "Show sidebar" : "Hide sidebar")

            Image(systemName: "flask").foregroundStyle(Theme.brand)
            Text("实验室 · 系统监控").font(Theme.Font.headerTitle).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Slim header for the SSH reverse-tunnel manager pane.
private struct TunnelsHeaderBar: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Button { appModel.toggleSidebar() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help(appModel.sidebarCollapsed ? "Show sidebar (⌘\\)" : "Hide sidebar (⌘\\)")
            .accessibilityLabel(appModel.sidebarCollapsed ? "Show sidebar" : "Hide sidebar")

            Image(systemName: "network.badge.shield.half.filled").foregroundStyle(Theme.brand)
            Text("SSH 反向转发 · 隧道管理").font(Theme.Font.headerTitle).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
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
