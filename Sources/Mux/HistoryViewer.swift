import AppKit
import SwiftTerm
import SwiftUI
import TmuxKit

/// A read-only terminal that renders a *snapshot* of a pane's tmux scrollback, so the user can scroll
/// back through history even when the live pane is on the alternate screen (claude / vim / less / man)
/// — the alternate screen has no scrollback of its own, so the live SwiftTerm view can't scroll there.
///
/// Built like `LoginTerminal` (a bare standalone `TerminalView`) but browse-only: a generous local
/// scrollback holds the whole capture, keystrokes are swallowed (except `Esc`, which closes), and the
/// content is fed once from `capturePaneANSI`.
@MainActor
final class HistoryTerminal {
    let view: TerminalView
    private let coordinator: Coordinator

    init(onClose: @escaping () -> Void) {
        let tv = TerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        // The capture is at most the pane's tmux history-limit (~2000 lines); 20k comfortably holds
        // it all so every captured line stays scrollable.
        tv.getTerminal().changeScrollback(20_000)
        tv.configureNativeColors()
        tv.nativeForegroundColor = Theme.terminalForegroundNS
        tv.nativeBackgroundColor = Theme.terminalBackgroundNS
        tv.layer?.backgroundColor = Theme.terminalBackgroundNS.cgColor
        tv.caretColor = .clear // browse-only snapshot: no caret
        let saved = UserDefaults.standard.double(forKey: AppModel.fontSizeKey)
        tv.font = NSFont.monospacedSystemFont(ofSize: saved == 0 ? CGFloat(AppModel.defaultFontSize) : CGFloat(saved),
                                              weight: .regular)
        self.view = tv

        let coord = Coordinator(onClose: onClose)
        self.coordinator = coord
        tv.terminalDelegate = coord
    }

    /// Paint the captured history once. SwiftTerm leaves the viewport at the live tail (bottom) after
    /// a one-shot feed, so the user lands where the pane currently is and scrolls UP into history —
    /// exactly the muscle memory of "scroll up to see the logs".
    func load(_ data: Data) {
        view.feed(byteArray: ArraySlice(data))
    }

    @MainActor
    final class Coordinator: NSObject, @MainActor TerminalViewDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }

        // Browse-only: every keystroke is swallowed so the snapshot can't be edited. The sole
        // exception is a lone Esc (0x1b) — since the terminal is first responder it eats the key
        // before SwiftUI's `.onExitCommand` could, so we close from here. Arrow/PageUp keys arrive as
        // multi-byte escape sequences (ESC [ …) and fall through harmlessly; the scroll wheel does the
        // actual scrolling.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            if data.count == 1, data.first == 0x1b { onClose() }
        }
        // Mirror the live terminal: ⌘C copies the current selection out of the history snapshot.
        func clipboardCopy(source: TerminalView, content: Data) {
            guard let s = String(data: Data(content), encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// Bridges the `HistoryTerminal`'s view into SwiftUI and makes it first responder so the scroll wheel
/// and keys (incl. our Esc-to-close) reach it. Mirrors `LoginTerminalView`'s focus handling.
struct HistoryTerminalView: NSViewRepresentable {
    let terminal: HistoryTerminal

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        attach(to: container, context: context)
        focusIfNeeded(context: context)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        attach(to: nsView, context: context)
        focusIfNeeded(context: context)
    }

    private func attach(to container: NSView, context: Context) {
        let tv = terminal.view
        if tv.superview !== container {
            tv.removeFromSuperview()
            container.subviews.forEach { $0.removeFromSuperview() }
            tv.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(tv)
            NSLayoutConstraint.activate([
                tv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                tv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                tv.topAnchor.constraint(equalTo: container.topAnchor),
                tv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        context.coordinator.terminalView = tv
        tv.needsDisplay = true
    }

    private func focusIfNeeded(context: Context) {
        let coordinator = context.coordinator
        func attempt(_ n: Int) {
            guard let tv = coordinator.terminalView else { return }
            if let window = tv.window, window.isKeyWindow {
                if window.firstResponder !== tv { window.makeFirstResponder(tv) }
            } else if n < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { attempt(n + 1) }
            }
        }
        DispatchQueue.main.async { attempt(0) }
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var terminalView: TerminalView?
    }
}

/// The history-viewer sheet: a light chrome header over the dark read-only terminal snapshot. Fetches
/// the active pane's scrollback via `capturePaneANSI` on appear and feeds it into the snapshot view.
struct HistoryViewerSheet: View {
    @Environment(AppModel.self) private var appModel
    let connection: ConnectionSession

    @State private var terminal: HistoryTerminal?
    @State private var loading = true
    @State private var empty = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                Theme.terminalBackground
                if let terminal {
                    HistoryTerminalView(terminal: terminal)
                }
                if loading {
                    ProgressView("正在读取历史…")
                        .controlSize(.small)
                        .padding(Theme.Space.lg)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                } else if empty {
                    Text("这个终端还没有可显示的历史。")
                        .font(Theme.Font.emptyBody)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 820, idealWidth: 1040, minHeight: 540, idealHeight: 720)
        .background(Theme.terminalBackground)
        .onExitCommand { appModel.closeHistoryViewer() }
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.brand)
            Text("历史 · \(connection.title)")
                .font(Theme.Font.headerTitle)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.md)
            Text("滚轮 / 拖选 上翻 · Esc 关闭")
                .font(Theme.Font.headerMeta)
                .foregroundStyle(.secondary)
            Button { appModel.closeHistoryViewer() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("关闭(Esc)")
            .accessibilityLabel("关闭历史")
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
        .background(Theme.canvas)
    }

    private func load() async {
        guard let paneID = connection.primaryPane?.id else { loading = false; empty = true; return }
        let term = HistoryTerminal { appModel.closeHistoryViewer() }
        terminal = term
        // tmux keeps ~2000 lines per pane (history-limit); capture them all with ANSI colors.
        let data = await connection.controller.capturePaneANSI(paneID, historyLines: 2000)
        loading = false
        if data.isEmpty {
            empty = true
        } else {
            term.load(data)
        }
    }
}
