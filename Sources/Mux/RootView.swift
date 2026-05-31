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
                if let error = model.lastError {
                    ErrorBanner(message: error) { model.lastError = nil }
                }
                if let notice = model.detachedNotice {
                    DetachToast(message: notice,
                                onUndo: { model.undoDetach() },
                                onDismiss: { model.dismissDetachNotice() })
                }
                ActiveTerminalHeader(connection: appModel.selectedConnection)
                Divider()
                TerminalAreaView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // Primary actions live in the left panel now (SidebarHeader) — title stays on the right.
        .sheet(isPresented: $model.isShowingSearch) {
            SearchView()
        }
        .sheet(isPresented: $model.isShowingQuickSwitch) {
            QuickSwitchView()
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

                if let host = conn.host { metaChip("network", host) }
                if let g = conn.grid { metaChip("squareshape.split.2x2", "\(g.cols)×\(g.rows)") }

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
