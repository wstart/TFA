import SwiftUI
import SwiftTerm
import TmuxKit

/// Bridges a pane's `PaneTerminal.view` (a stable `SwiftTerm.TerminalView`) into SwiftUI.
///
/// The view is NOT created here — it is fetched from the connection's pane registry so its
/// identity (and the engine/scrollback it owns) is stable across SwiftUI re-renders.
///
/// Critically, it also makes the `TerminalView` the window's first responder. Embedded inside a
/// SwiftUI `NavigationSplitView`, the NSView never becomes first responder on its own, so it
/// would receive no key events and the user couldn't type. We force focus once the view is in a
/// window, and again whenever SwiftUI swaps in a different pane (the representable is recreated
/// per `(connection, pane)` via `.id`, so the coordinator's `didFocus` resets).
struct TerminalPaneView: NSViewRepresentable {
    let connection: ConnectionSession
    let paneID: TmuxPaneID

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        attach(to: container, context: context)
        // Reliable click-to-focus without subclassing SwiftTerm's view: a non-delaying click
        // recognizer that makes the terminal first responder (the terminal still gets its own
        // mouse events for cursor/selection because we don't delay them).
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

    /// Pin the registry's TerminalView inside the container (re-attaching if SwiftUI reused the
    /// container for a different pane).
    private func attach(to container: NSView, context: Context) {
        let tv = connection.terminal(for: paneID).view
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
        tv.needsDisplay = true // repaint the live buffer now that we're on-window again
    }

    /// Make the terminal the first responder so it receives key events. Runs on attach and on
    /// every update (so switching terminals re-focuses the newly shown one). Only steals focus
    /// when our window is key — this avoids yanking focus away from the search sheet / rename
    /// alert (which live in their own key window). Retries briefly until the view is in a window.
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
