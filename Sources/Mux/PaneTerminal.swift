import AppKit
import Foundation
import SwiftTerm
import SwiftUI
import TmuxKit

/// Owns exactly one `SwiftTerm.TerminalView` for a single tmux pane.
///
/// Responsibilities:
/// - Hydration: on creation, capture the pane's current ANSI content from tmux and feed it,
///   buffering any live bytes that arrive in the meantime, then flush the buffer — so we never
///   lose or duplicate output across the snapshot/live boundary.
/// - Input: forward keystrokes from the view's delegate to `controller.sendKeys`.
/// - Sizing: `sizeChanged` reports the view's frame grid to tmux (best-effort authority via
///   `setClientSize`), but the engine grid is pinned to tmux's ACTUAL pane size at hydrate/
///   syncCursor time via `applyModelSize(cols:rows:)` so the cursor maps 1:1.
///
/// Everything here runs on the main actor — `TerminalView`/`Terminal` are not `Sendable`.
@MainActor
final class PaneTerminal {
    let paneID: TmuxPaneID
    let view: TerminalView

    private weak var controller: TmuxController?
    private let coordinator: Coordinator

    /// Called once per user keystroke batch (every `Coordinator.send`). The UI sets this when the
    /// terminal is shown to drive the typing-combo effect; nil (default) means no observer.
    var onUserInput: (() -> Void)? {
        didSet { coordinator.onUserInput = onUserInput }
    }

    /// Pushes scroll state to the UI (PaneTerminal is intentionally NOT `@Observable`, so we drive
    /// SwiftUI via a plain callback the view stores in `@State`). `atBottom` is true when the
    /// viewport is pinned to the live tail; `unseenLines` counts output that arrived while the user
    /// was scrolled up (reset to 0 on return to bottom). The UI uses this to show a "jump to latest"
    /// pill. Set when the terminal is shown; nil (default) means no observer.
    var onScrollState: ((_ atBottom: Bool, _ unseenLines: Int) -> Void)? {
        didSet { coordinator.onScrollState = onScrollState }
    }

    /// While true, live bytes are buffered (not fed) until the snapshot is in place.
    private var hydrating = true
    private var hasHydrated = false
    private var pending = Data()
    /// Saved scrollback (a RESTORED session's pre-reboot history) to paint once at hydrate, above
    /// the fresh shell, as a dimmed read-only preamble. nil for normal terminals.
    private let historyPreamble: Data?

    init(paneID: TmuxPaneID, controller: TmuxController, historyPreamble: Data? = nil) {
        self.paneID = paneID
        self.controller = controller
        self.historyPreamble = historyPreamble

        let tv = TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        // Bounded local scrollback (决议 #6): 10k lines instead of SwiftTerm's 500-line default —
        // deep history for search/scroll, but still a hard cap so a day-long `tail -f` can't grow
        // memory without bound. tmux keeps its own history regardless.
        tv.getTerminal().changeScrollback(10_000)
        tv.configureNativeColors()
        // Terminal theme (see Theme.terminalBackgroundNS): pin a FIXED dark fg/bg so the pane never
        // flashes a light/dark-mismatched band (the dynamic textBackgroundColor resolved as white
        // off-window), and the cursor is brand-tinted. The backing layer is set too so any area not
        // yet covered by drawn cells matches.
        tv.nativeForegroundColor = Theme.terminalForegroundNS
        tv.nativeBackgroundColor = Theme.terminalBackgroundNS
        tv.layer?.backgroundColor = Theme.terminalBackgroundNS.cgColor
        tv.caretColor = NSColor(Theme.brand)
        // Start at the persisted font size (same key AppModel mirrors) so panes created at a
        // non-default size render correctly from the first frame.
        let saved = UserDefaults.standard.double(forKey: AppModel.fontSizeKey)
        let initialSize: CGFloat = saved == 0 ? CGFloat(AppModel.defaultFontSize) : CGFloat(saved)
        tv.font = NSFont.monospacedSystemFont(ofSize: initialSize, weight: .regular)
        self.view = tv

        let coord = Coordinator(paneID: paneID, controller: controller)
        self.coordinator = coord
        tv.terminalDelegate = coord
        coord.owner = self

        // When SwiftTerm's own frame-driven `sizeChanged` DOES fire (and the view is on a window),
        // funnel it through the SAME de-duped/authoritative push as the geometry-driven path so the
        // two never double-push or disagree. (See applyViewSizeToTmux for why the delegate alone is
        // not enough on first show.)
        coord.onGridChange = { [weak self] in self?.applyViewSizeToTmux() }

        // NOTE: hydration is deferred (see hydrateIfNeeded) until the view has been shown and its
        // size has settled — capturing before the show-time resize lands would snapshot the pane at
        // the wrong height and mis-place the cursor. `hydrating` stays true so live output buffers
        // until then.
    }

    // MARK: - Output

    /// Feed raw tmux output for this pane. Buffers during hydration, otherwise writes straight
    /// to the view (always on the main actor).
    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        if hydrating {
            pending.append(data)
        } else {
            view.feed(byteArray: ArraySlice(data))
            noteOutput(data)
        }
    }

    // MARK: - Scroll state (jump-to-latest)

    /// Live count of lines that streamed in while the user was scrolled up (cleared on return).
    private var unseenLines = 0

    /// True when the viewport is pinned to the live tail. SwiftTerm reports `scrollPosition == 0`
    /// at the bottom (yDisp <= 0) and 1.0 at the oldest scrollback line — so "at bottom" is simply
    /// position 0. Note: while scrolled up, fresh output does NOT auto-snap to the bottom (the
    /// engine preserves the user's `yDisp` unless `userScrolling`), so this stays accurate.
    private var atBottom: Bool {
        // `canScroll` is false when there's no scrollback yet (or the alternate buffer is active):
        // in that case the user is necessarily looking at the live content, i.e. at the bottom.
        guard view.canScroll else { return true }
        return view.scrollPosition <= 0.0001
    }

    /// Called after each live feed: if the user is scrolled up, accumulate the (approximate) number
    /// of new lines and notify. We count newline bytes in the chunk as a lightweight proxy for lines
    /// added — exact line accounting would require diffing SwiftTerm's internal buffer, which it
    /// doesn't expose. Good enough for a "N new" badge; the badge is advisory, the button is exact.
    private func noteOutput(_ data: Data) {
        guard !atBottom else {
            // Already (or back) at the tail: ensure any stale count is cleared and the UI knows.
            if unseenLines != 0 {
                unseenLines = 0
                onScrollState?(true, 0)
            }
            return
        }
        let newlines = data.reduce(into: 0) { count, byte in if byte == 0x0A { count += 1 } }
        unseenLines += max(newlines, 1) // at least 1 so any output bumps the badge
        onScrollState?(false, unseenLines)
    }

    /// Recompute & push scroll state after a user scroll. Driven by the Coordinator's `scrolled`
    /// delegate callback. Clears the unseen counter once the user is back at the live tail.
    fileprivate func handleScroll() {
        if atBottom {
            unseenLines = 0
            onScrollState?(true, 0)
        } else {
            onScrollState?(false, unseenLines)
        }
    }

    /// Snap the viewport back to the live tail and clear the unseen counter. `scroll(toPosition:)`
    /// takes 0…1 where 0 == bottom (latest output), so position 0 pins us to the tail.
    func scrollToBottom() {
        view.scroll(toPosition: 0)
        unseenLines = 0
        onScrollState?(true, 0)
    }

    /// Capture the pane and feed it into the view, exactly once, AFTER the view's size has settled
    /// (so tmux's pane height == this engine's height and the cursor maps 1:1). Idempotent.
    func hydrateIfNeeded() {
        guard !hasHydrated else { return }
        hasHydrated = true
        guard let controller else { hydrating = false; return }
        let pane = paneID
        // A RESTORED session: paint the saved pre-reboot history first (dimmed), then a separator,
        // so the fresh shell's prompt appears below readable history. Plain text, fed before the
        // live (empty) capture of the new shell.
        if let preamble = historyPreamble, !preamble.isEmpty {
            view.feed(byteArray: ArraySlice(Self.dim(preamble)))
            view.feed(byteArray: ArraySlice(Array("\u{1B}[0m\r\n\u{1B}[2m—— 以上为重启前的历史 ——\u{1B}[0m\r\n".utf8)))
        }
        Task { @MainActor in
            // THE CURSOR INVARIANT (see pinEngineToPaneSize): pin the engine to tmux's reconciled
            // pane size BEFORE capturing, so captureRows == engineRows == the screen cursor_y is
            // measured against, regardless of other attached clients.
            await self.pinEngineToPaneSize()
            // capture-pane restores the screen TEXT but not the cursor — query both in one
            // pipelined round-trip (FIFO control client), apply text first then cursor.
            async let snapshotTask = controller.capturePaneANSI(pane)
            async let cursorTask = controller.cursorPosition(pane)
            let snapshot = await snapshotTask
            let cursor = await cursorTask
            if !snapshot.isEmpty {
                view.feed(byteArray: ArraySlice(snapshot))
            }
            if let cursor {
                view.feed(byteArray: ArraySlice(Self.cup(x: cursor.x, y: cursor.y)))
            }
            // Flush anything that arrived live while we were capturing (continues from the cursor).
            if !pending.isEmpty {
                view.feed(byteArray: ArraySlice(pending))
                pending.removeAll(keepingCapacity: false)
            }
            hydrating = false
        }
    }

    /// Force a full repaint of the (always-live) engine buffer. Used when this terminal becomes
    /// visible again: SwiftTerm skips drawing while off-window, so its pixels can be stale even
    /// though the buffer — including the cursor — is current. `draw()` renders straight from
    /// `terminal.displayBuffer`, so a repaint restores exact content + cursor (no re-capture,
    /// which would lose the cursor position).
    func refreshDisplay() { view.needsDisplay = true }

    /// Re-assert the cursor from tmux's authoritative position. Called shortly after a terminal is
    /// shown, once its size has settled — the show-time resize/redraw race can otherwise leave the
    /// cursor off by a row on a freshly-activated (not-yet-shown) terminal. Only moves the cursor
    /// (no content), and is idempotent for already-correct terminals.
    func syncCursor() {
        guard let controller, !hydrating else { return }
        let pane = paneID
        let view = self.view
        Task { @MainActor in
            await self.pinEngineToPaneSize() // INVARIANT
            if let c = await controller.cursorPosition(pane) {
                view.feed(byteArray: ArraySlice(Self.cup(x: c.x, y: c.y)))
            }
        }
    }

    // MARK: - The cursor invariant (single source of truth)

    /// THE CURSOR INVARIANT — the most fragile contract in the app, in ONE place.
    ///
    /// `capture-pane` and the hydration/sync CUP are measured against tmux's ACTUAL pane grid.
    /// If the SwiftTerm engine's grid differs (e.g. a background-attached session still sits at
    /// the default 24 rows, or another client reconciled the window to a different size), the
    /// cursor maps to the wrong row — the worst bug this app has had. So: before ANY capture or
    /// CUP, pin the engine to tmux's reconciled `paneSize`. Every cursor-touching path MUST funnel
    /// through here — that is the single contract that keeps the cursor mapping 1:1.
    private func pinEngineToPaneSize() async {
        guard let controller else { return }
        if let size = await controller.paneSize(paneID) {
            applyModelSize(cols: size.cols, rows: size.rows)
        }
    }

    /// The single CUP (cursor-position) escape builder: absolute 1-based screen coordinates, so it
    /// lands correctly regardless of how capture-pane padded/trimmed trailing blank rows. tmux
    /// reports `cursor_x`/`cursor_y` 0-based, hence the `+ 1`.
    static func cup(x: Int, y: Int) -> [UInt8] {
        Array("\u{1B}[\(y + 1);\(x + 1)H".utf8)
    }

    /// Wrap saved scrollback in a dim SGR so restored history reads as muted, past context. The
    /// saved text is PLAIN (captured without `-e`), so a single leading `\u{1B}[2m` dims all of it.
    static func dim(_ text: Data) -> [UInt8] {
        Array("\u{1B}[2m".utf8) + Array(text) + Array("\u{1B}[0m".utf8)
    }

    // MARK: - Sizing

    /// Force the view's grid to match tmux's authoritative pane size. Frame-derived
    /// `sizeChanged` from the view is deliberately ignored for tmux purposes.
    /// Callers should prefer `pinEngineToPaneSize()` so the invariant stays centralized.
    func applyModelSize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        let term = view.getTerminal()
        if term.cols != cols || term.rows != rows {
            view.resize(cols: cols, rows: rows)
        }
    }

    /// The view's CURRENT grid as the SwiftTerm engine sees it (cols, rows). Reflects the laid-out
    /// frame ÷ cell size — i.e. how many cells actually fit the on-screen area right now.
    private var viewGrid: (cols: Int, rows: Int) {
        let term = view.getTerminal()
        return (term.cols, term.rows)
    }

    private var lastPushedGrid: (cols: Int, rows: Int)?

    /// AUTHORITATIVE size sync: push the view's CURRENT grid to tmux so the pane/window grows (or
    /// shrinks) to fill the on-screen area, then the engine follows tmux's reconciled `paneSize` so
    /// the pane visually fills the view.
    ///
    /// Why this exists (and `sizeChanged` alone isn't enough): SwiftTerm only fires `sizeChanged`
    /// when its grid CHANGES via a frame change, and on first show the view often isn't on a window
    /// yet (so `sizeChanged`'s `source.window != nil` guard drops the very first, full-size report);
    /// the grid is then already correct, so `sizeChanged` never fires again and tmux stays at its
    /// default 24 rows — leaving the pane stuck small. This method is geometry-driven (called when we
    /// KNOW the view is laid out), so it doesn't depend on that delegate firing.
    ///
    /// THE CURSOR INVARIANT is preserved: after `setClientSize` tmux reconciles `paneSize` to this
    /// grid, so the subsequent `pinEngineToPaneSize()` (in syncCursor/hydrate) pins the engine to the
    /// SAME grid — the cursor still maps 1:1. Idempotent: a no-op when the grid hasn't changed.
    /// Debounce in the caller; this also de-dupes to stay loop-free.
    func applyViewSizeToTmux() {
        guard let controller else { return }
        let grid = viewGrid
        guard grid.cols >= 2, grid.rows >= 2 else { return } // ignore not-yet-laid-out / degenerate frames
        if let last = lastPushedGrid, last == grid { return } // de-dupe: nothing changed
        lastPushedGrid = grid
        controller.setClientSize(cols: grid.cols, rows: grid.rows)
    }

    /// Change the rendered font size. Because the cell grid changes, per the cursor-fix INVARIANT
    /// we re-pin the engine to tmux's authoritative pane size and re-sync the cursor — `syncCursor()`
    /// does exactly that (applyModelSize → CUP) and its guards keep it safe before hydration.
    func setFont(size: Double) {
        view.font = NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
        view.needsDisplay = true
        syncCursor()
    }

    /// Best-effort caret position as a fraction (0…1) of the view, for the typing-combo burst.
    /// SwiftTerm's exact caret frame is internal, so we derive it from the PUBLIC engine cursor
    /// (col,row) and the current grid — accurate to within a cell, which is plenty for a spark pop.
    func caretFraction() -> CGPoint? {
        let term = view.getTerminal()
        let cols = term.cols, rows = term.rows
        guard cols > 0, rows > 0 else { return nil }
        let cur = term.getCursorLocation() // (x: col, y: row), 0-based, top-left origin
        let fx = (CGFloat(cur.x) + 0.5) / CGFloat(cols)
        let fy = (CGFloat(cur.y) + 0.5) / CGFloat(rows)
        return CGPoint(x: min(max(fx, 0), 1), y: min(max(fy, 0), 1))
    }

    // MARK: - Coordinator (TerminalViewDelegate)

    @MainActor
    final class Coordinator: NSObject, @MainActor TerminalViewDelegate {
        let paneID: TmuxPaneID
        weak var controller: TmuxController?

        /// Forwarded from `PaneTerminal.onUserInput`; fired once per `send` (one combo bump per
        /// keystroke batch). Optional so it costs nothing when no UI observer is attached.
        var onUserInput: (() -> Void)?

        /// Fired when the view's grid changed (frame/font) while on a window. Routed back into
        /// `PaneTerminal.applyViewSizeToTmux()` so frame-driven resizes share the de-duped push.
        var onGridChange: (() -> Void)?

        /// Forwarded from `PaneTerminal.onScrollState`; held here only so the property mirrors
        /// `onUserInput`'s wiring (the actual computation lives on `PaneTerminal.handleScroll`).
        var onScrollState: ((_ atBottom: Bool, _ unseenLines: Int) -> Void)?

        /// The PaneTerminal that owns this delegate, so `scrolled` can recompute scroll state at the
        /// single source of truth. Weak to avoid a retain cycle (PaneTerminal owns the coordinator).
        weak var owner: PaneTerminal?

        init(paneID: TmuxPaneID, controller: TmuxController) {
            self.paneID = paneID
            self.controller = controller
        }

        // User keystrokes (already in terminal wire form) → forward to tmux.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            controller?.sendKeys(to: paneID, bytes: data)
            onUserInput?() // drive the typing-combo effect (count once per keystroke batch)
        }

        // The view's grid changed (frame/font) → tell tmux to match. Only when the view is on a
        // window (so hidden/off-window terminals don't drive their session to a bogus size) and
        // the grid is sane. This is loop-free: tmux output never changes the view's grid (only its
        // frame does).
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols >= 2, newRows >= 2, source.window != nil else { return }
            // Route through PaneTerminal so the frame-driven and geometry-driven paths share one
            // de-duped, authoritative push (loop-free: tmux output never changes the view's grid —
            // only its frame does). Falls back to a direct push if no hook is wired.
            if let onGridChange { onGridChange() }
            else { controller?.setClientSize(cols: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        // SwiftTerm fires this whenever the viewport moves (wheel, drag, pageUp/Down, programmatic
        // scrollTo). Recompute & push scroll state from the single source of truth on PaneTerminal.
        func scrolled(source: TerminalView, position: Double) { owner?.handleScroll() }
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(s, forType: .string)
            }
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
