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
    private(set) var activity: [String: Int] = [:]       // session name → last output epoch
    private(set) var lastLine: [String: String] = [:]    // session name → latest non-empty line
    private(set) var workingSince: [String: Int] = [:]   // session name → epoch it started its current burst
    private(set) var nowEpoch: Int = 0
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
                for (name, t) in act where now - t < within {
                    if let c = cache[name], c.epoch == t { lines[name] = c.line }          // reuse — no new output
                    else if let l = TmuxServer.lastOutputLine(session: name) { lines[name] = l }
                }
            }
            return (act, lines)
        }.value
        let now = Int(Date().timeIntervalSince1970)
        let workingNames = Set(snap.act.filter { now - $0.value < within }.map { $0.key })
        var since = self.workingSince
        for n in workingNames where since[n] == nil { since[n] = now }
        for k in Array(since.keys) where !workingNames.contains(k) { since[k] = nil }
        var cacheNext: [String: (epoch: Int, line: String)] = [:]
        for (name, line) in snap.lines { if let t = snap.act[name] { cacheNext[name] = (t, line) } }
        self.lineCache = cacheNext
        self.activity = snap.act; self.lastLine = snap.lines; self.workingSince = since; self.nowEpoch = now
    }

    /// True when this (local) session produced output within the last `activeWithin` seconds.
    func isWorking(name: String) -> Bool { activity[name].map { nowEpoch - $0 < Self.activeWithin } ?? false }
    /// The latest non-empty output line, if the session is currently active.
    func line(_ name: String) -> String? { lastLine[name] }
    /// Seconds the session has been continuously producing output (its current burst), if working.
    func workedSeconds(_ name: String) -> Int? { workingSince[name].map { max(0, nowEpoch - $0) } }
}
