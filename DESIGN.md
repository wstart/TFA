# TFA — Design System
> Letterpress chrome around a dark screen. TFA wears a warm ivory, ink-on-paper identity on all its
> chrome — sidebar, panels, sheets, boards — while the terminal itself stays a calm dark "screen"
> inset in the cream frame. A native macOS terminal manager that reads like a printed workbench.

**Theme:** light chrome + fixed-dark terminal · **Platform:** native macOS (SwiftUI + AppKit) · **Source of truth:** `Sources/Mux/Theme.swift`

TFA adapts Anthropic's letterpress aesthetic to a desktop terminal app. The chrome is a warm ivory
canvas (`#faf9f5`) under near-black ink (`#141413`), framed by taupe linen hairlines instead of drop
shadows — flat, border-defined, tactile like printed paper. The system is almost achromatic: emphasis
is carried by **ink/charcoal**, and the single chromatic accent is a dusty blue used only as
deliberate annotation (links, the terminal cursor). The one place that deliberately breaks the light
identity is the **terminal pane**, which stays dark so program output (ANSI colors, TUIs) renders the
way those programs expect.

This document is TFA-specific: it records not just the palette but the decisions that make the system
work for a Chinese-heavy, dense, long-running terminal UI.

---

## 1. The surface model (TFA's defining decision)

TFA is a **three-tier warm paper stack** in the light chrome, plus one fixed-dark terminal — every
styling choice respects which tier it's in. The tiers must stay visibly distinct: that layering IS the
"editorial workbench" identity (v2).

| World | Background | Foreground | Where | Why |
|-------|-----------|-----------|-------|-----|
| **Chrome** (cream) | Cream `#f4f2ea` | Ink `#141413` | Sidebar, titlebar, tool dock, quiet chips | One tier warmer than canvas — frames the workspace |
| **Chrome** (canvas) | Ivory `#faf9f5` | Ink `#141413` | Main content: terminal header, task board, tunnels, lab | The neutral working ground |
| **Chrome** (cards) | White `#ffffff` | Ink `#141413` | Cards, inputs, list rows, host pill, sheets | Elevated surfaces floating on canvas |
| **Terminal** (fixed dark) | `#1D2026` | `#DBDEE5` | The terminal pane only | ANSI/TUI palettes are tuned for dark; a cream terminal makes `ls` colors, vim, claude TUIs illegible |

The dark terminal is **not** system-appearance-driven — it's a fixed sRGB color so a freshly-created
pane never flashes a mismatched band (the old `NSColor.textBackgroundColor`-resolves-to-white bug).
Accents that sit **on** the dark terminal (cursor, the big session-name watermark) must therefore use
light/accent colors, never ink — see §6.

The whole app is pinned to **light appearance** (`.preferredColorScheme(.light)` + `NSApp.appearance
= .aqua`) so the chrome never inverts under macOS dark mode; the dark terminal is the only dark surface.

---

## 2. Tokens — Colors

All defined in `Theme.Colors` (SwiftUI `Color`, sRGB). Semantic aliases (`Theme.canvas`, `Theme.border`…)
are what views actually reference — never raw `NSColor.windowBackgroundColor` etc.

| Name | Value | Semantic alias | Role |
|------|-------|----------------|------|
| Ivory Canvas | `#faf9f5` | `canvas` | Main-content background — the neutral working ground |
| Cream Chrome | `#f4f2ea` | `chrome` / `surface2` | Sidebar / titlebar / tool dock / quiet chips — one tier warmer than canvas |
| Pure White | `#ffffff` | `surface` | Cards, input fields, list/board rows, host pill, elevated containers |
| Warm Parchment | `#f0eee6` | — | Legacy quiet fill (kept; new washes use Cream) |
| Ink Black | `#141413` | `textPrimary` | Primary text, high-emphasis labels |
| Charcoal | `#1f1e1d` | `brand` / emphasis | Filled buttons, active emphasis, focus — the monochrome "annotation" weight |
| Warm Slate | `#3d3d3a` | `textSecondary` | Secondary text; the calm "connected" status tint |
| Stone Gray | `#73726c` | `textTertiary` | Muted helper text, captions, inactive/quiet states |
| Pewter | `#9c9a92` | — | Subtle icons, low-emphasis strokes |
| Linen Border | `#dedcd1` | `border` | Hairline borders, card outlines, dividers — defines surfaces without harshness |
| Mist | `#c9c6bd` | — | Faintest tone: dormant dots, off-switch tracks |
| Cool Stone | `#b7b7b5` | `borderStrong` | Nav-level interactive borders only — never on content cards |
| Dust Blue | `#ccdbe8` | `accent` | The sole chromatic accent: links, soft washes, the terminal cursor |
| Terminal BG | `#1D2026` | `terminalBackground` | The dark terminal pane only |
| Terminal FG | `#DBDEE5` | `terminalForeground` | Terminal text + on-terminal watermark (faded) |

**Emphasis model:** there is **no saturated brand color**. `Theme.brand` is repointed to Charcoal —
so the dozens of "accent" usages (active row wash, working indicator, focus ring, filled buttons via
`.tint`) read as editorial ink. Dust Blue is reserved for the few genuinely chromatic moments.

---

## 3. Tokens — Typography

**Font: the system font (SF + PingFang for CJK). Not a serif.**

> TFA's UI is Chinese-heavy (session names like `Youtube转文章`, `TFA_主程`, mixed 中英 everywhere).
> Anthropic Serif is a Latin editorial face; macOS's `.serif` (New York) has **no matching CJK
> companion**, so Chinese falls back to a different serif at a mismatched optical size and mixed
> 中英 labels look uneven. Consistency wins: the letterpress identity lives in the **paper canvas,
> hairline borders, and monochrome ink palette** — not in a serif that can't render CJK evenly.
> This is a deliberate, documented divergence from the generic Anthropic spec.

Type roles (`Theme.Font`, all system sans, semantic Dynamic-Type sizes so CJK + Latin share metrics):

| Role | Font | Use |
|------|------|-----|
| `rowTitle` | callout · medium | Sidebar terminal name, list item title, card title |
| `rowSubtitle` | caption | Row subtitle: cwd / live output line / hint |
| `headerTitle` | callout · semibold | Panel header titles, dialog/sheet titles |
| `headerMeta` | caption | Header metadata (path, grid size) |
| `sectionHeader` | caption · semibold | Small section labels |
| `groupHeader` | 14 · semibold | Sidebar group (folder) name |
| `emptyTitle` | title2 · semibold | Empty-state headline |
| `emptyBody` | callout | Empty-state body |

Terminal text is monospaced (SwiftTerm, persisted font size via `AppModel.fontSize`).

---

## 4. Tokens — Spacing & Radius

**Spacing** (`Theme.Space`) — a fine-grained scale for dense terminal UI (denser than DESIGN's 8px base):

| Token | Value | | Token | Value |
|-------|-------|---|-------|-------|
| `xxs` | 2 | | `xl` | 16 |
| `xs` | 4 | | `xxl` | 24 |
| `sm` | 6 | | `xxxl` | 40 |
| `md` | 8 | | | |
| `lg` | 12 | | | |

**Radius** (`Theme.Radius`) — DESIGN.md corners; no pills:

| Token | Value | Use |
|-------|-------|-----|
| `sm` | 8 | small chips, inner fills |
| `md` | 9.6 | the defining corner — buttons, inputs, nav, toggles |
| `lg` / `card` | 16 | cards, board cards, tunnel rows, sheets |
| `container` | 24 | large containers / hero panels |

---

## 5. Accent & emphasis model

- **Filled / primary actions** → Charcoal (`#1f1e1d`) fill, white text. The app's global `.tint` is
  Charcoal, so `.borderedProminent` buttons become DESIGN.md "Primary Dark Buttons" automatically.
- **Active / selected / focus** → a charcoal *wash* (`brand.opacity(0.06–0.12)`) + Linen border, or a
  Warm Parchment fill — never a saturated highlight.
- **Links / soft accent / terminal cursor** → Dust Blue (`#ccdbe8`), the only chromatic accent.
- Keep it nearly monochrome: do not introduce extra hues. The two exceptions are *functional* status
  colors (§7), muted to fit the warm palette.

---

## 6. Status & activity language — the state-color standard

One semantic **state-intent palette** (`Theme.Status`) is THE standard; every domain (connection,
activity, tunnels, task board) maps onto it. Communicated **shape-first, color-second** (color-blind
safe, quiet in a long list). Guiding rule: **color signals "needs your eye"** — idle stays neutral
gray, in-progress leans on the spinner *shape*, "all good" gets one restrained sage, and only the two
alerts are warm.

### Intent tokens (`Theme.Status`)

| Intent | Token | Value | Meaning |
|--------|-------|-------|---------|
| Neutral | `neutral` | Stone `#73726c` | idle / dormant / stopped / todo |
| Pending | `pending` | Stone `#73726c` + spinner | connecting / reconnecting / retrying — motion, not color |
| Positive | `positive` | **Sage `#5b7d68`** | connected / running / done — the one restrained success hue |
| Active | `active` | Charcoal `#1f1e1d` | live working (equalizer) — ink emphasis |
| Attention | `attention` | **Amber `#b8732e`** | needs you / agent asked / blocked-awaiting |
| Error | `error` | **Brick `#a3402e`** | failed / blocked |

Exactly **three chromatic hues** total — sage (good), amber (attention), brick (error); everything
else is monochrome ink/stone. Never add a fourth status color.

### Domain mappings

| Domain | neutral | pending | positive | active | attention | error |
|--------|---------|---------|----------|--------|-----------|-------|
| **Connection** | dormant | connecting · reconnecting | connected | — | — | failed |
| **Tunnel** | stopped | connecting | running | — | retrying | — |
| **Task board** | todo | — | done | doing | needs-takeover | blocked |
| **Activity** | idle | — | — | working (equalizer) | needs-you (bell) | — |

Glyphs stay distinct so meaning survives without color: `checkmark.circle.fill` (positive),
`exclamationmark.triangle.fill` (error), `moon.zzz` (dormant), spinner (pending), bell (attention).
Unseen background output is a small ink dot. A healthy connected row stays visually quiet.

---

## 7. Elevation — no shadows

This system has **zero drop shadows** (chrome and cards alike). Depth comes from three things only:
1. Hairline **Linen** borders that define edges like a printed rule.
2. Background contrast between Ivory canvas, White surfaces, and Warm Parchment.
3. The dark-to-light inversion of Charcoal filled buttons and the dark terminal pane.

---

## 8. Motion

Restrained — motion is reserved for things that genuinely change state, and there is exactly **one
signature looping animation**:
- **Equalizer bars** while a terminal is actively producing output (the live-activity signal).
- Everything else is one-shot/interaction-triggered (sidebar collapse, board drag spring, toast fade,
  selection). No perpetual loops on bells/dots; the board "running" tag is static.
- Typing-combo spark effects default **off**.
- All decorative motion honors **Reduce Motion**.

---

## 9. Component inventory (TFA)

Each maps to the tokens above. Flat, border-defined, 9.6px corners, no shadows.

- **Sidebar** — Cream chrome; hosts the host pill, filter pill, terminal list, and tool dock.
- **Host pill** — White capsule + Linen border on Cream; sage status dot + host name + chevron; paired
  with a filled-charcoal square `+` (new terminal).
- **Filter pill** — White capsule + Linen border, 9.6px; live-filters the list (distinct from ⌘F search).
- **Sidebar terminal row** — White on Cream; `rowTitle` name + `rowSubtitle` (cwd / live line);
  status glyph (§6); left accent rail (amber=needs-you, charcoal=working); active = charcoal wash.
- **Group folder** — disclosure row, `groupHeader`; drag-reorderable; drop targets highlight in accent.
- **Tool dock** (任务 / 隧道 / CLAUDE / Skills / 实验室) — sidebar bottom; equal-width icon+label cells,
  selected = filled charcoal cell with ivory glyph (mirrors a selected row).
- **Status indicator** — shared spinner-or-glyph component; symbol + tint + VoiceOver label.
- **Panel header bar** — Ivory canvas, `headerTitle`, sidebar-toggle + a leading accent icon.
- **Task board card** — White, Linen border, 16px radius; status chip, agent label, latest-record line;
  blocked = brick wash, needs-takeover = amber wash.
- **Tunnel row** — White card, 16px radius; status dot (running=slate, retrying=amber, stopped=stone),
  name + endpoint, a Cream port-mapping chip (mono), enable switch, log/edit/delete.
- **Sheets / forms** (SSH host, tunnel, environment editor) — White, Linen border, `headerTitle` title,
  rounded-border inputs, Charcoal primary button.
- **Banners & toasts** (tmux-missing, error, detach-undo) — flat, Linen-bordered, accent-tinted.
- **Terminal watermark** — large faded session name on the dark pane, in `terminalForeground` at ~8%.
- **Empty states** — `emptyTitle` + `emptyBody`, centered, with a faint accent glyph and key shortcuts.

---

## 10. Do's and Don'ts

### Do
- Keep the three tiers distinct: Cream (`#f4f2ea`) sidebar/chrome, Ivory (`#faf9f5`) main canvas,
  White (`#ffffff`) cards; never invert under system dark mode.
- Use Linen (`#dedcd1`) 1px borders instead of shadows to separate surfaces.
- Use Charcoal fill + white text for primary actions; the global `.tint` is Charcoal.
- Use the **system font** for all chrome text so 中英 mix stays size-consistent.
- Keep the terminal pane dark; route its accents (cursor, watermark) through Dust Blue / terminal FG.
- Reserve Dust Blue for links / cursor / soft washes only; keep status shape-first.

### Don't
- No drop shadows, glows, gradients, or glassmorphism — flat and border-defined.
- No serif for UI text (breaks CJK size consistency); no pill radii (9.6px max for interactive).
- No saturated brand color; don't add hues beyond the two functional status exceptions.
- Don't make the terminal pane light, or put ink-colored accents on it (they vanish).
- Don't use Cool Stone borders on content cards — nav-level interactive elements only.
- Don't reintroduce perpetual looping animations beyond the working equalizer.

---

## 11. Agent quick reference

```
Main canvas        #faf9f5   (Theme.canvas)
Cream chrome       #f4f2ea   (Theme.chrome / Theme.surface2)  → sidebar, tool dock, quiet chips
Card surface       #ffffff   (Theme.surface)
Primary text       #141413   (Theme.textPrimary)
Emphasis / filled  #1f1e1d   (Theme.brand)
Secondary text     #3d3d3a   (Theme.textSecondary)
Muted text         #73726c   (Theme.textTertiary)
Hairline border    #dedcd1   (Theme.border)
Accent (sole hue)  #ccdbe8   (Theme.accent)  → links, terminal cursor
Terminal BG / FG   #1D2026 / #DBDEE5         → fixed dark pane
Status intents:  neutral #73726c · positive(good) #5b7d68 · active #1f1e1d · attention #b8732e · error #a3402e
                 (3 hues only: sage=good, amber=attention, brick=error; idle/pending stay gray + spinner)
Radius: 9.6 interactive · 16 cards · 24 containers   ·   No shadows   ·   System font
```

Implementation note: change tokens in **`Sources/Mux/Theme.swift`** only; views consume `Theme.*`.
