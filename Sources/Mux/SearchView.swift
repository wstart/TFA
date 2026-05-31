import SwiftUI
import SwiftTerm
import TmuxKit

/// One matching line from a cross-terminal search.
struct SearchResult: Identifiable, Hashable, Sendable {
    let id = UUID()
    let connectionID: UUID
    let terminalTitle: String
    let paneID: TmuxPaneID
    let line: String
}

/// Cross-terminal search: captures every terminal's text concurrently and lists lines that
/// contain the query (case-insensitive). Clicking a result selects that terminal and highlights
/// the match in its live view.
struct SearchView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = appModel
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search across all terminals…", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { runSearch() }
                if model.isSearching { ProgressView().controlSize(.small) }
                Button("Search") { runSearch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Done") { dismiss() }
            }
            .padding(12)
            Divider()

            if model.searchResults.isEmpty {
                ContentUnavailableView(
                    model.isSearching ? "Searching…" : "No results",
                    systemImage: "text.magnifyingglass",
                    description: Text(model.isSearching
                        ? "Capturing every terminal's scrollback."
                        : "Type a query and press Search to scan every terminal.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(groupedResults, id: \.key) { group in
                        Section(group.key) {
                            ForEach(group.value) { result in
                                ResultRow(result: result, query: model.searchQuery) {
                                    open(result)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private var groupedResults: [(key: String, value: [SearchResult])] {
        Dictionary(grouping: appModel.searchResults, by: \.terminalTitle)
            .sorted { $0.key < $1.key }
    }

    // MARK: - Searching

    private func runSearch() {
        let query = appModel.searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        appModel.isSearching = true
        appModel.searchResults = []

        var refs: [SearchRef] = []
        var controllers: [UUID: TmuxController] = [:]
        for conn in appModel.connections {
            controllers[conn.id] = conn.controller
            if let pane = conn.primaryPane {
                refs.append(SearchRef(connectionID: conn.id, title: conn.title, paneID: pane.id))
            }
        }

        Task { @MainActor in
            var collected: [SearchResult] = []
            await withTaskGroup(of: [SearchResult].self) { group in
                for ref in refs {
                    guard let controller = controllers[ref.connectionID] else { continue }
                    group.addTask { @MainActor in
                        // capture-pane MUST stay on the main actor (TmuxController is main-actor
                        // isolated). Only the heavy part — splitting + case-insensitive scanning a
                        // multi-thousand-line scrollback — is offloaded to a detached task so it
                        // never competes with typing/UI on the main thread.
                        let text = await controller.capturePaneText(ref.paneID)
                        return await Task.detached { Self.matches(in: text, query: query, ref: ref) }.value
                    }
                }
                for await partial in group { collected.append(contentsOf: partial) }
            }
            appModel.searchResults = collected
            appModel.isSearching = false
        }
    }

    /// A terminal to scan: connection id, display title, primary pane id. Sendable so it can cross
    /// into the detached matching task.
    private struct SearchRef: Sendable {
        let connectionID: UUID
        let title: String
        let paneID: TmuxPaneID
    }

    /// Pure, main-actor-free line matcher: every line of `text` containing `query` (case-insensitive)
    /// becomes a `SearchResult`. Runs OFF the main actor (see runSearch) so large scrollbacks can't jank.
    private nonisolated static func matches(in text: String, query: String, ref: SearchRef) -> [SearchResult] {
        var out: [SearchResult] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true)
        where rawLine.range(of: query, options: .caseInsensitive) != nil {
            out.append(SearchResult(
                connectionID: ref.connectionID,
                terminalTitle: ref.title,
                paneID: ref.paneID,
                line: String(rawLine).trimmingCharacters(in: .whitespaces)
            ))
        }
        return out
    }

    private func open(_ result: SearchResult) {
        guard let conn = appModel.connection(result.connectionID) else { return }
        // reveal switches to the result's host if it differs and selects the terminal, so the
        // host-scoped sidebar follows along — otherwise we'd jump to a terminal invisible in the
        // current sidebar and lose the user's place.
        appModel.reveal(result.connectionID)
        let term = conn.terminal(for: result.paneID)
        _ = term.view.findNext(appModel.searchQuery, options: SearchOptions(), scrollToResult: true)
        dismiss()
    }
}

private struct ResultRow: View {
    let result: SearchResult
    let query: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(highlighted)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var highlighted: AttributedString {
        var attr = AttributedString(result.line)
        if let range = attr.range(of: query, options: .caseInsensitive) {
            attr[range].backgroundColor = .yellow.opacity(0.4)
            attr[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return attr
    }
}
