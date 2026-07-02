import AppKit
import SwiftUI

/// The app's single design source of truth (see DESIGN.md). Centralizes spacing, radii, type, and
/// the status palette so the look stays consistent and is changed in ONE place — replacing the
/// scattered magic numbers and the duplicated, color-only status logic the design review flagged.
enum Theme {

    // MARK: - DESIGN.md palette (Claude letterpress · warm light system)
    //
    // The whole app chrome follows DESIGN.md: a warm ivory canvas under near-black ink, taupe linen
    // hairline borders instead of shadows, nearly monochrome with ONE chromatic accent (Dust Blue).
    // Emphasis is carried by ink/charcoal (not a saturated brand color); see `brand` below.
    enum Colors {
        static let ivory = Color(.sRGB, red: 0.980, green: 0.976, blue: 0.961, opacity: 1)   // #faf9f5 main content
        static let cream = Color(.sRGB, red: 0.957, green: 0.949, blue: 0.918, opacity: 1)    // #f4f2ea chrome (sidebar / titlebar / quiet chips)
        static let white = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 1)                // #ffffff card
        static let parchment = Color(.sRGB, red: 0.941, green: 0.933, blue: 0.902, opacity: 1)// #f0eee6 secondary surface
        static let ink = Color(.sRGB, red: 0.078, green: 0.078, blue: 0.075, opacity: 1)      // #141413 primary text
        static let charcoal = Color(.sRGB, red: 0.122, green: 0.118, blue: 0.114, opacity: 1) // #1f1e1d emphasis / filled
        static let slate = Color(.sRGB, red: 0.239, green: 0.239, blue: 0.227, opacity: 1)    // #3d3d3a tertiary text
        static let stone = Color(.sRGB, red: 0.451, green: 0.447, blue: 0.424, opacity: 1)    // #73726c muted text
        static let pewter = Color(.sRGB, red: 0.612, green: 0.604, blue: 0.573, opacity: 1)   // #9c9a92 subtle icons
        static let linen = Color(.sRGB, red: 0.871, green: 0.863, blue: 0.820, opacity: 1)    // #dedcd1 hairline border
        static let mist = Color(.sRGB, red: 0.788, green: 0.776, blue: 0.741, opacity: 1)     // #c9c6bd faintest tone (dormant dot / off-track)
        static let coolStone = Color(.sRGB, red: 0.718, green: 0.718, blue: 0.710, opacity: 1)// #b7b7b5 nav-level border
        static let dustBlue = Color(.sRGB, red: 0.800, green: 0.859, blue: 0.910, opacity: 1) // #ccdbe8 sole accent
    }

    // MARK: - Semantic surfaces & text (use these in views, not raw NSColors)
    //
    // DESIGN.md v2 is a three-tier warm paper stack: cream chrome (sidebar/titlebar) frames an ivory
    // main content, with white cards floating on top. The tiers must stay distinct — that layering IS
    // the "editorial workbench" identity.
    static let canvas = Colors.ivory          // main content background
    static let chrome = Colors.cream          // sidebar / titlebar / quiet chips — one tier warmer than canvas
    static let surface = Colors.white         // cards, inputs, elevated containers
    static let surface2 = Colors.cream        // toggle tracks, hover washes, quiet chips (#f4f2ea)
    static let border = Colors.linen          // hairline card/divider borders
    static let borderStrong = Colors.coolStone// nav-level interactive borders only
    static let textPrimary = Colors.ink
    static let textSecondary = Colors.slate
    static let textTertiary = Colors.stone

    // MARK: - Terminal surface (the 终端主题)
    //
    // Deliberately KEPT dark even though the chrome is light: terminal programs (vim, claude, ls
    // colors, TUIs) emit ANSI palettes tuned for a dark background, so a cream terminal would make
    // much output illegible. A dark "screen" inset in the cream letterpress frame also reads well.
    // Fixed sRGB (independent of system appearance) so a freshly created pane never flashes a
    // mismatched band (the old dynamic-textBackgroundColor bug).
    static let terminalBackgroundNS = NSColor(srgbRed: 0.114, green: 0.125, blue: 0.149, alpha: 1) // #1D2026
    static let terminalForegroundNS = NSColor(srgbRed: 0.859, green: 0.871, blue: 0.898, alpha: 1) // #DBDEE5
    static var terminalBackground: Color { Color(nsColor: terminalBackgroundNS) }
    static var terminalForeground: Color { Color(nsColor: terminalForegroundNS) }

    // MARK: - Spacing scale (DESIGN.md base unit 8px; finer steps for dense terminal UI)
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

    // MARK: - Corner radii (DESIGN.md: 9.6 interactive · 16 cards · 24 containers · NO pills)
    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 9.6   // the defining corner — buttons / inputs / nav / toggles
        static let lg: CGFloat = 16    // cards
        static let card: CGFloat = 16
        static let container: CGFloat = 24
    }

    // MARK: - Type roles
    //
    // The SYSTEM font (SF + PingFang for CJK) — NOT a serif. DESIGN.md's Anthropic Serif is a Latin
    // editorial face; macOS's `.serif` (New York) has no matching CJK companion, so Chinese falls
    // back to a different serif at a mismatched optical size — mixed 中英 labels look uneven. This
    // UI is Chinese-heavy, so consistency wins: the letterpress identity lives in the paper canvas,
    // hairline borders, and monochrome ink palette, not in a serif that can't render CJK evenly.
    enum Font {
        static let rowTitle = SwiftUI.Font.callout.weight(.medium)
        static let rowSubtitle = SwiftUI.Font.caption
        static let headerTitle = SwiftUI.Font.callout.weight(.semibold)
        static let headerMeta = SwiftUI.Font.caption
        static let sectionHeader = SwiftUI.Font.caption.weight(.semibold)
        static let groupHeader = SwiftUI.Font.system(size: 14, weight: .semibold)
        static let emptyTitle = SwiftUI.Font.title2.weight(.semibold)
        static let emptyBody = SwiftUI.Font.callout
    }

    // MARK: - Emphasis & status palette
    //
    // DESIGN.md is nearly monochrome: emphasis is INK/CHARCOAL, not a saturated hue ("color appears
    // only as deliberate annotation"). `brand` is therefore repointed to charcoal so the dozens of
    // existing accent usages (active wash, working indicator, focus, filled buttons via .tint) read
    // as editorial ink. `accent` (Dust Blue) is the SOLE chromatic accent — links / soft washes /
    // the terminal cursor. Status keeps two FUNCTIONAL chromatic exceptions (error, attention) muted
    // into the warm palette, since those alerts must stand out; routine states stay monochrome and
    // lean on distinct glyph SHAPES (see TerminalStatus).
    static let brand = Colors.charcoal
    static let accent = Colors.dustBlue

    // Semantic STATE-INTENT palette — the single standard every domain maps onto (connection,
    // activity, tunnels, task board). Principle: color signals "needs your eye". Idle stays neutral
    // gray; in-progress leans on the spinner SHAPE, not color; "all good" gets one restrained sage
    // green; the two alerts (attention amber, error brick) are the only warm hues.
    enum Status {
        static let neutral = Colors.stone                                    // idle / dormant / stopped / todo
        static let pending = Colors.stone                                    // connecting / reconnecting / retrying (+ spinner)
        static let positive = Color(.sRGB, red: 0.357, green: 0.490, blue: 0.408, opacity: 1) // #5b7d68 muted sage — connected / running / done
        static let active = Colors.charcoal                                  // live working (equalizer) — ink emphasis
        static let attention = Color(.sRGB, red: 0.722, green: 0.451, blue: 0.180, opacity: 1) // #b8732e warm amber (needs you)
        static let error = Color(.sRGB, red: 0.639, green: 0.251, blue: 0.180, opacity: 1)     // #a3402e muted brick (failed / blocked)
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
        case .connected: return Theme.Status.positive
        case .failed: return Theme.Status.error
        case .reconnecting: return Theme.Status.pending
        case .connecting: return Theme.Status.pending
        case .dormant: return Theme.Status.neutral
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
