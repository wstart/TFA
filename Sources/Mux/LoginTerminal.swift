import AppKit
import SwiftTerm
import SwiftUI
import TmuxKit

/// A bare interactive terminal for the ssh LOGIN phase — password, host-key confirmation, 2FA —
/// shown BEFORE tmux control mode starts. Unlike `PaneTerminal` there's no pane, hydration, or
/// cursor invariant: it just renders the raw login bytes and forwards the user's keystrokes straight
/// to the ssh process via `onInput`.
@MainActor
final class LoginTerminal {
    let view: TerminalView
    private let coordinator: Coordinator

    init(onInput: @escaping (Data) -> Void) {
        let tv = TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        tv.configureNativeColors()
        tv.nativeForegroundColor = Theme.terminalForegroundNS
        tv.nativeBackgroundColor = Theme.terminalBackgroundNS
        tv.layer?.backgroundColor = Theme.terminalBackgroundNS.cgColor
        tv.caretColor = NSColor(Theme.brand)
        let saved = UserDefaults.standard.double(forKey: AppModel.fontSizeKey)
        tv.font = NSFont.monospacedSystemFont(ofSize: saved == 0 ? CGFloat(AppModel.defaultFontSize) : CGFloat(saved),
                                              weight: .regular)
        self.view = tv

        let coord = Coordinator(onInput: onInput)
        self.coordinator = coord
        tv.terminalDelegate = coord
    }

    func feed(_ data: Data) { view.feed(byteArray: ArraySlice(data)) }

    @MainActor
    final class Coordinator: NSObject, @MainActor TerminalViewDelegate {
        let onInput: (Data) -> Void
        init(onInput: @escaping (Data) -> Void) { self.onInput = onInput }

        // Keystrokes go RAW to the ssh process (the password is never echoed locally).
        func send(source: TerminalView, data: ArraySlice<UInt8>) { onInput(Data(data)) }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// Bridges the `LoginTerminal`'s view into SwiftUI and makes it first responder so the user can type
/// the password. Mirrors `TerminalPaneView`'s focus handling (the embedded NSView won't become first
/// responder on its own).
struct LoginTerminalView: NSViewRepresentable {
    let login: LoginTerminal

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        attach(to: container, context: context)
        let click = NSClickGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.focusTerminal))
        click.delaysPrimaryMouseButtonEvents = false
        container.addGestureRecognizer(click)
        focusIfNeeded(context: context)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        attach(to: nsView, context: context)
        focusIfNeeded(context: context)
    }

    private func attach(to container: NSView, context: Context) {
        let tv = login.view
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

        @objc func focusTerminal() {
            if let tv = terminalView, let window = tv.window {
                window.makeFirstResponder(tv)
            }
        }
    }
}
