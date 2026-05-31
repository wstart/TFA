import SwiftUI

/// Drives the playful "typing combo" effect (rebuild.md #5): each keystroke bumps `count` and fires
/// a particle burst at the cursor; after 3 seconds with no typing the combo resets to 0. The UI
/// observes `count` (the top-right counter), `burst` (a monotonic trigger so the same point can
/// re-fire), and `burstPoint` (normalized cursor location within the terminal area).
@MainActor
@Observable
final class TypingCombo {
    private(set) var count = 0
    /// Changes on every keystroke so the burst view replays even at the same location.
    private(set) var burst = 0
    /// Normalized (0…1) location of the most recent burst within the terminal pane.
    private(set) var burstPoint = CGPoint(x: 0.5, y: 0.5)

    @ObservationIgnored private var resetTask: Task<Void, Never>?

    /// Seconds of no typing after which the combo "breaks" and resets.
    static let idleReset: Double = 3

    /// Register one keystroke (optionally at a normalized cursor point).
    func bump(at point: CGPoint?) {
        count += 1
        burst &+= 1
        if let point { burstPoint = point }
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleReset * 1_000_000_000))
            guard !Task.isCancelled else { return }
            count = 0
        }
    }

    /// Reset immediately (e.g. when switching terminals).
    func reset() {
        resetTask?.cancel()
        resetTask = nil
        if count != 0 { count = 0 }
    }
}
