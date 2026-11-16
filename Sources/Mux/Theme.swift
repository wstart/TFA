import AppKit
import SwiftUI

/// The app's single design source of truth (see DESIGN.md). Centralizes spacing, radii, type, and
/// the status palette so the look stays consistent and is changed in ONE place — replacing the
/// scattered magic numbers and the duplicated, color-only status logic the design review flagged.
enum Theme {

    /// Helper for adaptive light/dark semantic colors backed by AppKit's dynamic `NSColor`.
    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat), alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: alpha)
        })
    }

    // MARK: - Workbench palette (Refined warm light + sleek dark workbench)
    enum Colors {
        static let ivory = dynamic(light: (0.976, 0.976, 0.969), dark: (0.086, 0.094, 0.114))      // #f9f9f7 / #16181d main canvas
        static let cream = dynamic(light: (0.949, 0.945, 0.929), dark: (0.071, 0.078, 0.094))      // #f2f1ec / #121418 sidebar chrome
        static let white = dynamic(light: (1.000, 1.000, 1.000), dark: (0.118, 0.129, 0.157))      // #ffffff / #1e2128 elevated surface
        static let parchment = dynamic(light: (0.918, 0.914, 0.890), dark: (0.149, 0.165, 0.200))  // #eae9e3 / #262a33 quiet chip / track
        static let ink = dynamic(light: (0.086, 0.086, 0.082), dark: (0.925, 0.933, 0.949))        // #161615 / #eceef2 primary text
        static let charcoal = dynamic(light: (0.102, 0.102, 0.098), dark: (0.925, 0.933, 0.949))   // #1a1a19 / #eceef2 high emphasis
        static let slate = dynamic(light: (0.290, 0.286, 0.271), dark: (0.643, 0.671, 0.722))      // #4a4945 / #a4abb8 secondary text
        static let stone = dynamic(light: (0.478, 0.471, 0.447), dark: (0.435, 0.467, 0.522))      // #7a7872 / #6f7785 muted text
        static let pewter = dynamic(light: (0.612, 0.604, 0.576), dark: (0.365, 0.396, 0.455))     // #9c9a93 / #5d6574 subtle icons
        static let linen = dynamic(light: (0.886, 0.878, 0.847), dark: (0.169, 0.188, 0.231))      // #e2e0d8 / #2b303b hairline border
        static let mist = dynamic(light: (0.788, 0.780, 0.749), dark: (0.255, 0.282, 0.341))       // #c9c7bf / #414857 faintest tone
        static let coolStone = dynamic(light: (0.776, 0.769, 0.737), dark: (0.239, 0.263, 0.322))  // #c6c4bc / #3d4352 nav border
        static let dustBlue = dynamic(light: (0.800, 0.859, 0.910), dark: (0.243, 0.388, 0.686))   // #ccdbe8 / #3e63af accent
    }

    // MARK: - Semantic surfaces & text
    static let canvas = Colors.ivory          // main content background
    static let chrome = Colors.cream          // sidebar / titlebar / quiet chips
    static let surface = Colors.white         // cards, inputs, elevated containers
    static let surface2 = Colors.parchment    // toggle tracks, hover washes, segmented wells
    static let border = Colors.linen          // hairline card/divider borders
    static let borderStrong = Colors.coolStone// nav-level interactive borders
    static let textPrimary = Colors.ink
    static let textSecondary = Colors.slate
    static let textTertiary = Colors.stone

    /// Foreground color on top of a `Theme.brand` filled surface (white on dark ink in light mode; dark ink on light fill in dark mode).
    static let onBrand = dynamic(light: (1.0, 1.0, 1.0), dark: (0.078, 0.086, 0.102))

    /// AppKit/SwiftUI `.tint` for `.borderedProminent` buttons so AppKit always renders legible white label text in both modes.
    static let controlTint = dynamic(light: (0.102, 0.102, 0.098), dark: (0.231, 0.408, 0.910))

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
        static let positive = dynamic(light: (0.267, 0.514, 0.365), dark: (0.345, 0.714, 0.494))   // #44835d / #58b67e sage green
        static let active = Colors.charcoal                                  // live working (equalizer) — ink emphasis
        static let attention = dynamic(light: (0.745, 0.439, 0.125), dark: (0.941, 0.659, 0.251))  // #be7020 / #f0a840 warm amber
        static let error = dynamic(light: (0.710, 0.235, 0.188), dark: (0.925, 0.408, 0.365))      // #b53c30 / #ec685d brick red
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
    case ended               // session gone (crash / kill / reboot) — kept as a recoverable record

    @MainActor
    static func of(_ conn: ConnectionSession) -> TerminalStatus {
        if conn.isEnded { return .ended }                        // recoverable record, nothing running
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
        case .ended: return "arrow.counterclockwise.circle"
        }
    }

    var tint: Color {
        switch self {
        case .connected: return Theme.Status.positive
        case .failed: return Theme.Status.error
        case .reconnecting: return Theme.Status.pending
        case .connecting: return Theme.Status.pending
        case .dormant: return Theme.Status.neutral
        case .ended: return Theme.Status.neutral
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
        case .ended: return "已断开 — 可恢复"
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

/// What a terminal is running, for the sidebar's small kind badge and the header/footer label.
/// Derived from the pane's current command (an ended record: from its restore command).
enum TerminalKind {
    case axisClaude, antigravity, claude, codex, ssh, shell

    @MainActor
    static func of(_ conn: ConnectionSession) -> TerminalKind {
        let command = (conn.isEnded ? conn.restoreCommand ?? "" : conn.subtitle).lowercased()
        if command.contains("axis-claude") { return .axisClaude }
        if AgentPlatform.isAgyCommand(command) { return .antigravity }
        if command.contains("claude") { return .claude }
        if command.contains("codex") { return .codex }
        return conn.host != nil ? .ssh : .shell
    }

    /// Agents get the solid charcoal badge — the one place a row is "loud" by default.
    var isAgent: Bool { self == .axisClaude || self == .antigravity || self == .claude || self == .codex }

    var symbol: String {
        switch self {
        case .axisClaude: return "cpu"
        case .antigravity: return "sparkles"
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .ssh: return "network"
        case .shell: return "terminal"
        }
    }

    var label: String {
        switch self {
        case .axisClaude: return "axis-claude"
        case .antigravity: return "Antigravity"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .ssh: return "ssh"
        case .shell: return "终端"
        }
    }
}

/// The small rounded-square kind badge at the head of a terminal row: solid charcoal for agents,
/// a quiet linen square for shells. Ended records fade.
struct KindBadge: View {
    let kind: TerminalKind
    var dimmed = false
    /// On a prominent (accent-filled) selection the charcoal/white badge would vanish into it;
    /// then it becomes a translucent light chip instead.
    var prominent = false

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(prominent ? Color.white : (kind.isAgent ? Theme.onBrand : Theme.textSecondary))
            .frame(width: 22, height: 22)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if !kind.isAgent && !prominent {
                    RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1)
                }
            }
            .opacity(dimmed ? 0.45 : 1)
            .accessibilityHidden(true)
    }

    private var fill: Color {
        if prominent { return Color.white.opacity(kind.isAgent ? 0.22 : 0.14) }
        return kind.isAgent ? Theme.brand : Theme.surface
    }
}

/// A small state tag (运行中 / 需要你 / 空闲 …) for the terminal header.
struct StateTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
    }
}
