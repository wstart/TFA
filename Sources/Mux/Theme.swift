import AppKit
import SwiftUI

/// The app's single design source of truth (see DESIGN.md). Centralizes spacing, radii, type, and
/// the status palette so the look stays consistent and is changed in ONE place — replacing the
/// scattered magic numbers and the duplicated, color-only status logic the design review flagged.
enum Theme {

    // MARK: - Terminal surface (the 终端主题)
    //
    // A FIXED dark terminal theme, deliberately independent of the system light/dark appearance.
    // Two reasons: (1) a cohesive, identifiable terminal look; (2) it removes a real bug — the
    // dynamic `NSColor.textBackgroundColor` SwiftTerm used resolves under whatever appearance is
    // current when the off-window view is created (often light → white), so a freshly created pane
    // showed a white band on top and the dark container below until it resized. Fixed sRGB colors
    // resolve identically everywhere, and the pane container is painted the SAME color, so no strip
    // can ever mismatch. (Foreground is pinned light to stay legible on the dark bg in BOTH modes.)
    static let terminalBackgroundNS = NSColor(srgbRed: 0.114, green: 0.125, blue: 0.149, alpha: 1) // #1D2026
    static let terminalForegroundNS = NSColor(srgbRed: 0.859, green: 0.871, blue: 0.898, alpha: 1) // #DBDEE5
    static var terminalBackground: Color { Color(nsColor: terminalBackgroundNS) }
    static var terminalForeground: Color { Color(nsColor: terminalForegroundNS) }

    // MARK: - Spacing scale (4-pt grid)
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 40
    }

    // MARK: - Corner radii
    enum Radius {
        static let sm: CGFloat = 5
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
    }

    // MARK: - Type roles (system fonts → Dynamic Type + native feel)
    enum Font {
        static let rowTitle = SwiftUI.Font.callout.weight(.medium)
        static let rowSubtitle = SwiftUI.Font.caption
        static let headerTitle = SwiftUI.Font.callout.weight(.semibold)
        static let headerMeta = SwiftUI.Font.caption
        static let sectionHeader = SwiftUI.Font.caption.weight(.semibold)
        /// Group / section title in the sidebar — deliberately LARGER + bolder than a row title
        /// (`rowTitle` is callout/12) so a group reads as a header, not a dimmer sub-item.
        static let groupHeader = SwiftUI.Font.system(size: 14, weight: .bold)
        static let emptyTitle = SwiftUI.Font.title2.weight(.semibold)
        static let emptyBody = SwiftUI.Font.callout
    }

    // MARK: - Brand & status palette
    //
    // A single restrained brand tint gives the app an identity without fighting the user's chosen
    // system accent (interactive controls still use `.accentColor`). Status colors are paired with
    // DISTINCT SHAPES/LABELS (see TerminalStatus) so they read without relying on color alone.
    static let brand = Color(red: 0.16, green: 0.71, blue: 0.56) // terminal teal-green ~#29B58E

    enum Status {
        static let connected = Color.green
        static let reconnecting = Color.orange
        static let connecting = Color.secondary
        static let failed = Color.red
    }
}

/// The connection state of a terminal, distilled to ONE model so the sidebar row and the active
/// header render it identically — symbol + tint + label (never color alone). This is the single
/// place the error > reconnecting > connected > connecting priority lives.
enum TerminalStatus: Equatable {
    case dormant             // lazy-attach placeholder: discovered but not yet connected
    case connecting          // first attach in progress
    case reconnecting        // dropped; auto-retrying
    case connected
    case failed              // connectError set and not (yet) recovering

    @MainActor
    static func of(_ conn: ConnectionSession) -> TerminalStatus {
        if conn.isDormant { return .dormant }                    // not attached yet (lazy)
        if conn.isReconnecting { return .reconnecting }          // actively recovering wins
        if conn.connectError != nil, !conn.state.connected { return .failed }
        if conn.state.connected { return .connected }
        return .connecting
    }

    /// True when the right visual is an indeterminate spinner rather than a static glyph.
    var isBusy: Bool { self == .connecting || self == .reconnecting }

    /// SF Symbol used when not showing a spinner. Shapes are deliberately distinct (a check vs a
    /// warning triangle) so the meaning survives without color.
    var symbol: String {
        switch self {
        case .connected: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .connecting: return "circle.dotted"
        case .dormant: return "moon.zzz"
        }
    }

    var tint: Color {
        switch self {
        case .connected: return Theme.Status.connected
        case .failed: return Theme.Status.failed
        case .reconnecting: return Theme.Status.reconnecting
        case .connecting: return Theme.Status.connecting
        case .dormant: return Theme.Status.connecting // muted/secondary, like connecting
        }
    }

    /// VoiceOver / tooltip text.
    var label: String {
        switch self {
        case .connected: return "Connected"
        case .failed: return "Connection failed"
        case .reconnecting: return "Reconnecting"
        case .connecting: return "Connecting"
        case .dormant: return "Idle — select to connect"
        }
    }
}

/// One reusable status indicator — a spinner while busy, otherwise a shape+color glyph — with an
/// accessibility label baked in. Used by both the sidebar row and the active-terminal header so the
/// two can never drift apart again (the design review found them implemented twice, differently).
struct StatusIndicator: View {
    let status: TerminalStatus
    var size: CGFloat = 11

    var body: some View {
        Group {
            if status.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: status.symbol)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(status.tint)
            }
        }
        .accessibilityLabel(status.label)
        .help(status.label)
    }
}
