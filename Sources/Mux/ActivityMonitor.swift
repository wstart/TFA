import AppKit
import Foundation
import Observation
import TmuxKit

/// Polls every local tmux session (~1.5s) for live output activity — independent of whether this app
/// has the session attached/focused. Two signals per session: (1) is it producing output right now
/// (`#{window_activity}` within the last few seconds), and (2) the latest line its active pane printed
/// (`capture-pane`, cached by activity epoch so an unchanged session isn't re-captured).
///
/// Drives the sidebar's real-time activity effects. Sessions are keyed by name (which equals a local
/// terminal's `groupKey`). Remote sessions aren't polled here — their "working" cue falls back to the
/// attached controller's `outputPhase`.
@MainActor
@Observable
final class TerminalActivityMonitor {
    // Published state changes ONLY when its value changes: every sidebar row reads it, so a tick that
    // reassigned it unconditionally re-rendered the whole list every 1.5 s even when nothing moved.
    private(set) var working: Set<String> = []           // sessions that produced output within `activeWithin`
    private(set) var lastLine: [String: String] = [:]    // session name → latest non-empty line
    static let activeWithin = 5                           // "working" = produced output within this many seconds

    @ObservationIgnored private var lineCache: [String: (epoch: Int, line: String)] = [:]
    /// When false (sidebar hidden), skip the per-session `capture-pane` forks — the cheap
    /// `window_activity` poll still runs so `isWorking` stays correct (dispatch/board need it).
    @ObservationIgnored var captureEnabled = true

    /// ONE sampling round, called from the app's single scheduler heartbeat (no loop of its own).
    func tick() async {
        // Nobody can see the app (hidden / fully occluded) → skip the tmux forks entirely this
        // tick. Attached terminals still track `outputPhase` from the live -CC stream, so dispatch
        // stays safe; the sidebar effects refresh as soon as we're visible again.
        guard NSApp.occlusionState.contains(.visible) else { return }
        let within = Self.activeWithin
        let cache = self.lineCache
        let capture = self.captureEnabled
        let snap = await Task.detached(priority: .utility) { () -> (act: [String: Int], lines: [String: String]) in
            let act = TmuxServer.localWindowActivity()
            let now = Int(Date().timeIntervalSince1970)
            var lines: [String: String] = [:]
            if capture {
                var stale: [String] = []
                for (name, t) in act where now - t < within {
                    if let c = cache[name], c.epoch == t { lines[name] = c.line }          // reuse — no new output
                    else { stale.append(name) }
                }
                // Every session with new output in ONE tmux call (was one fork per busy session).
                lines.merge(TmuxServer.lastOutputLines(sessions: stale.sorted())) { _, new in new }
            }
            return (act, lines)
        }.value
        let now = Int(Date().timeIntervalSince1970)
        let workingNames = Set(snap.act.filter { now - $0.value < within }.map { $0.key })
        var cacheNext: [String: (epoch: Int, line: String)] = [:]
        for (name, line) in snap.lines { if let t = snap.act[name] { cacheNext[name] = (t, line) } }
        self.lineCache = cacheNext
        if workingNames != working { working = workingNames }
        if snap.lines != lastLine { lastLine = snap.lines }
    }

    /// True when this (local) session produced output within the last `activeWithin` seconds.
    func isWorking(name: String) -> Bool { working.contains(name) }
    /// The latest non-empty output line, if the session is currently active.
    func line(_ name: String) -> String? { lastLine[name] }
}
