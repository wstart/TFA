# Mux — Design System (DESIGN.md)

> The single source of truth for how Mux looks and behaves visually. Tokens live in
> `Sources/Mux/Theme.swift`; this doc is the rationale + rules. When you touch UI, read this first
> and reach for tokens (`Theme.Space.*`, `Theme.Font.*`, `TerminalStatus`) instead of raw numbers.

## What Mux is

A **native macOS workspace** for managing many local + remote tmux sessions — one terminal = one
tmux session. It is an App‑UI (tool), not a landing page. So the bar is **macOS HIG fidelity**:
quiet, dense-but-legible, system-native, and trustworthy. Aesthetic goal: *"feels like Apple
shipped a terminal manager"* — not a themed/branded toy, not generic AI slop.

## Principles

1. **Native first.** System materials, `List(.sidebar)`, SF Symbols, system accent for interactive
   controls. Don't repaint what the OS already styles well.
2. **State is never color‑only.** Every connection state is a **shape + color + label**
   (`TerminalStatus`) so it reads for color‑blind users and in VoiceOver. (Fixes the old red/green
   dot.)
3. **One signal, one place.** Status, spacing, and type come from `Theme`/`TerminalStatus` and are
   rendered by shared views (`StatusIndicator`). The sidebar row and header can't drift apart.
4. **Earn the pixels.** The header shows context the row doesn't (status, host, grid, reconnect) —
   never a duplicate of the row.
5. **Scales to many terminals.** Filter + ⌘K quick‑switch + activity dots are first‑class, not
   afterthoughts.
6. **Restrained identity.** A single brand tint (`Theme.brand`, a **terminal teal-green**)
   marks the app and is applied as the app accent (`.tint`), so controls adopt the brand color too.

## Tokens (`Theme.swift`)

**Spacing** — 4‑pt grid: `xxs 2 · xs 4 · sm 6 · md 8 · lg 12 · xl 16 · xxl 24 · xxxl 40`.
Row padding = `xs`/`sm`; header padding = `lg`×`sm`; empty‑state gaps = `lg`.

**Radius** — `sm 5 · md 8 · lg 12`. Cards/sheets `md`; pills/fields `sm`.

**Type roles** — semantic, mapped to system text styles (Dynamic Type):
`rowTitle` (callout/medium) · `rowSubtitle` (caption) · `headerTitle` (callout/semibold) ·
`headerMeta` (caption) · `emptyTitle` (title2/semibold) · `emptyBody` (callout).

**Brand** — `Theme.brand` = `rgb(0.16, 0.71, 0.56)` (a **terminal teal-green**, ~`#29B58E`).
Used for the connected terminal glyph, the empty‑state mark, the **session‑name watermark**, the
**terminal caret**, and the **typing‑combo** counter/particles. It is also applied as the app accent
via `.tint(Theme.brand)` on the root view, so interactive controls adopt the green too. The terminal
surface stays a fixed dark theme; only the accent/brand is green, and it reads well on the dark bg.

## Terminal theme

- **Session‑name watermark** — a large, light (brand @ ~9%), non‑interactive name scaled to fill the
  pane, drawn faintly on top of the opaque terminal. It tells you *which* terminal you're in at a
  glance when many are open; it never eats input (`allowsHitTesting(false)`) and stays faint so live
  text reads on top. (Going truly transparent‑behind is avoided: SwiftTerm fills cells source‑over,
  so a clear background would ghost.)
- **Caret** — tinted `Theme.brand` so the cursor carries the app's identity.

## Status model (`TerminalStatus`)

Priority **reconnecting → failed → connected → connecting** (active recovery outranks a stale
error). Each case maps to:

| state | glyph (SF Symbol) | color | label | busy? |
|---|---|---|---|---|
| connected | `checkmark.circle.fill` | green | "Connected" | no |
| reconnecting | `arrow.triangle.2.circlepath` | orange | "Reconnecting" | spinner |
| connecting | `circle.dotted` | secondary | "Connecting" | spinner |
| failed | `exclamationmark.triangle.fill` | red | "Connection failed" | no |

Render it ONLY via `StatusIndicator` (spinner while busy, else glyph) — it carries the
`accessibilityLabel`/`help` for free.

## Components

- **Sidebar row** — leading terminal glyph (brand when connected, secondary otherwise), title +
  optional current‑command subtitle, an **activity dot** when a background terminal has new output,
  and a trailing `StatusIndicator`. Full‑row `accessibilityLabel` = name + status + command.
- **Active header** — `StatusIndicator` + title, then *meta* (host · grid `W×H`) and, when failed,
  a **Reconnect** button. Not a copy of the row.
- **Filter field** — sidebar‑top search that live‑filters by name/command, with a result count.
- **⌘K quick‑switch** — keyboard‑first fuzzy palette over all terminals (name + command).
- **Empty state** — brand mark + friendly title + one‑line guidance + shortcut hints (⌘T / network).
- **Error banner** — a single non‑blocking strip (`lastError`), dismissible.

## Accessibility

Status by shape+label (above); `accessibilityLabel` on every icon‑only button and row; list is
arrow‑navigable; `.help(...)` tooltips mirror the VoiceOver text.

## Out of scope (this app)

Landing‑page visuals, drag‑layout editing, multi‑pane tiling, broadcast input. (See UX‑REVIEW.md.)
