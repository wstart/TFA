import SwiftUI
import TmuxKit

/// A keyboard-first command palette for jumping between terminals when the flat list gets long
/// (⌘K). Type to fuzzy-match name + current command; ↑/↓ to move, ↵ to jump, esc to dismiss.
struct QuickSwitchView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var highlighted = 0
    /// Last reported hover location. Used to distinguish a real mouse *move* from the list merely
    /// scrolling under a stationary cursor — only an actual move should steal keyboard highlight.
    @State private var lastHover: CGPoint?
    @FocusState private var fieldFocused: Bool

    private var results: [ConnectionSession] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return appModel.connections }
        return appModel.connections.filter {
            Self.fuzzy(q, in: "\($0.title) \($0.subtitle)".lowercased())
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Query field
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Switch to terminal…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { choose(highlighted) }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.lg)

            Divider()

            // Results
            if results.isEmpty {
                VStack(spacing: Theme.Space.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text(appModel.connections.isEmpty ? "No terminals open" : "No matches")
                        .font(Theme.Font.emptyBody)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: Theme.Space.xxs) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { idx, conn in
                                QuickRow(conn: conn, isHighlighted: idx == highlighted)
                                    .id(idx)
                                    .contentShape(Rectangle())
                                    .onTapGesture { choose(idx) }
                                    // Only a genuine cursor move should grab highlight. When ↑/↓
                                    // scroll a row under a stationary mouse the location is
                                    // unchanged, so we leave the keyboard highlight intact.
                                    .onContinuousHover(coordinateSpace: .local) { phase in
                                        switch phase {
                                        case .active(let location):
                                            if location != lastHover {
                                                lastHover = location
                                                highlighted = idx
                                            }
                                        case .ended:
                                            break
                                        }
                                    }
                            }
                        }
                        .padding(Theme.Space.sm)
                    }
                    .onChange(of: highlighted) { _, h in
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(h, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: 540, height: 400)
        .background(.regularMaterial)
        .onAppear { fieldFocused = true; highlighted = 0 }
        .onChange(of: query) { _, _ in highlighted = 0 }
        // Single-line TextField doesn't use ↑/↓, so they bubble up here as move commands.
        .onMoveCommand { direction in
            switch direction {
            case .up: highlighted = max(0, highlighted - 1)
            case .down: highlighted = min(results.count - 1, highlighted + 1)
            default: break
            }
        }
        // Page/Home/End jumps. The single-line query TextField swallows Home/End for cursor
        // movement when focused, so those may not reach us; Page Up/Down aren't used for text
        // editing and come through reliably. We clamp every target so an empty result set is safe.
        .onKeyPress(.pageUp) { jump(to: highlighted - 8); return .handled }
        .onKeyPress(.pageDown) { jump(to: highlighted + 8); return .handled }
        .onKeyPress(.home) { jump(to: 0); return .handled }
        .onKeyPress(.end) { jump(to: results.count - 1); return .handled }
        .onExitCommand { dismiss() }
    }

    /// Clamp `target` into the valid result range and move the highlight there. No-op when there
    /// are no results, so Home/End/Page keys are always safe to press.
    private func jump(to target: Int) {
        guard !results.isEmpty else { return }
        highlighted = min(max(0, target), results.count - 1)
    }

    private func choose(_ index: Int) {
        guard results.indices.contains(index) else { return }
        // reveal switches to the target's host if it differs and selects it, keeping the
        // host-scoped sidebar in sync — a plain selectedConnectionID set could land on a terminal
        // that isn't visible in the current sidebar.
        appModel.reveal(results[index].id)
        dismiss()
    }

    /// Subsequence ("fuzzy") match: every char of `needle` appears in `haystack`, in order.
    static func fuzzy(_ needle: String, in haystack: String) -> Bool {
        var i = needle.startIndex
        guard i != needle.endIndex else { return true }
        for c in haystack {
            if c == needle[i] {
                i = needle.index(after: i)
                if i == needle.endIndex { return true }
            }
        }
        return false
    }
}

private struct QuickRow: View {
    let conn: ConnectionSession
    let isHighlighted: Bool

    var body: some View {
        let status = TerminalStatus.of(conn)
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(status == .connected ? Theme.brand : Color.secondary)
            Text(conn.title)
                .font(Theme.Font.rowTitle)
                .lineLimit(1)
            if !conn.subtitle.isEmpty {
                Text(conn.subtitle)
                    .font(Theme.Font.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.sm)
            StatusIndicator(status: status, size: 10)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(isHighlighted ? Color.accentColor.opacity(0.18) : .clear)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(conn.title), \(status.label)")
        .accessibilityAddTraits(isHighlighted ? [.isSelected] : [])
    }
}
