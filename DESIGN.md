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

## Workspace interaction standard (2026-10)

- Sidebar hierarchy: one header row — the scope field (host · project menu | terminal filter) + 待处理 button + “+” (启动终端 / 启动 axis-claude / 新建分组) → 在线/已断开 → the pinned「主管」row → the built-in「未分组」folder, then group folders (ticket terminals collect in「工单」) → tools. The project is chosen from the scope field's menu; ⌘F search lives in the 终端 menu and the terminal footer.
- Super-agent (2026-11): requests go to the「主管」terminal in natural language; it routes them into tickets, each executed in its own terminal + git worktree. People are interrupted only when a ticket needs them (待评审 / 等你回答 / 受阻 / 失败 / 送达失败 / 停下未回报) — those appear in 待处理, the dock's 主管 badge and the 主管 panel; progress stays silent.
- Work list (2026-11): the first screen is「我的清单」, pinned above 主管 in the sidebar. The unit of work is a task (`A-12`) with a checklist; the person decides 谁来做 per item (你, or a role's agent) and only items handed to an agent become tickets, which run as before. 需要你 is shown in one place per thing — the list / task card (amber), 待处理 and the dock badge count tasks (a task-less ticket counts on its own), ⌘] / ⌘⇧] visit the task cards that need you before the terminals, and clicking a task's notification opens its card. The 主管 terminal is a side entrance that adds tasks to the list; the old 主管 panel is only the fallback when the ticket → task migration failed. People can see five concepts: 任务、清单项、谁来做、工作流、需要你 — tickets, roles, rules live one layer down (the task card, the list's 设置 fold).
- Projects keep a local folder and stable terminal associations. New terminals inherit the selected folder; board tasks created in a project retain that project even before assignment. “全部项目” clears the filter.
- Attention inbox is global: terminal errors/attention and unanswered, blocked or queued tasks remain visible across project filters. Viewing a terminal does not resolve an outstanding board question; replying records a task comment.
- New-session sheet: ordinary shell / Codex / Claude Code; show CLI discovery status before creation. Never infer an exact conversation from “most recent”; use an explicitly bound UUID or the CLI picker.
- Skills: show source and same-name markers, one-line purpose with full hover text; click opens SKILL.md, supporting files remain expandable. Tab/Return works on file rows. Dependency status must say “未检测” unless actually verified.
- Editors: failed writes keep drafts and show the real error. File/agent switches offer save/discard/cancel; tool navigation retains in-memory buffers, and normal quit checks unsaved drafts. Skill removal uses Trash.
- Keep SF/PingFang, quiet warm surfaces and the fixed-dark terminal. Status labels carry meaning; avoid adding decorative motion.

## 1. The surface model (TFA's defining decision)

TFA is a **three-tier warm paper stack** in the light chrome, plus one fixed-dark terminal — every
styling choice respects which tier it's in. The tiers must stay visibly distinct: that layering IS the
"editorial workbench" identity (v2).

| World | Background | Foreground | Where | Why |
|-------|-----------|-----------|-------|-----|
| **Chrome** (cream) | Cream `#f4f2ea` | Ink `#141413` | Sidebar, titlebar, tool dock, quiet chips | One tier warmer than canvas — frames the workspace |
| **Chrome** (canvas) | Ivory `#faf9f5` | Ink `#141413` | Main content: terminal header, model panel, tunnels, lab | The neutral working ground |
| **Chrome** (cards) | White `#ffffff` | Ink `#141413` | Cards, inputs, list rows, scope field, sheets | Elevated surfaces floating on canvas |
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
| Pure White | `#ffffff` | `surface` | Cards, input fields, list/board rows, scope field, elevated containers |
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
activity, tunnels, model service) maps onto it. Communicated **shape-first, color-second** (color-blind
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

**Ticket stages** (`Stage.tint` / `Stage.symbol` in `SuperagentStyle.swift`): every "needs a person"
stage is amber — 等你回答 (questionmark.bubble), 待评审 (checkmark.seal), 受阻 (hand.raised),
停下未回报 (pause.circle) — except 失败 (xmark.octagon) and 送达失败 (exclamationmark.triangle), which
are brick. 工作中 is ink (hammer), 排队中 / 空闲 / 已停止 / 已放弃 stone, 已完成 sage.

| Domain | neutral | pending | positive | active | attention | error |
|--------|---------|---------|----------|--------|-----------|-------|
| **Connection** | dormant · ended | connecting · reconnecting | connected | — | — | failed |
| **Tunnel** | stopped | connecting | running | — | retrying | — |
| **Model service** | stopped · not installed | starting · stopping | running | — | standby (no model loaded) | — |
| **Activity** | idle | — | — | working (equalizer) | needs-you (bell) | — |
| **Task stage / item** | 待做 · 待分配 · 已取消 · 已放弃 | — | 完成 | 工作中 (static `◐`) | 需要你 (等你回答 · 待评审 · 受阻 · 停下未回报) | 失败 · 送达失败 |

**Task stages** (the work list): only 需要你 is colored — the stage tag, priority, assignee chips and the `3/5`
progress stay ink/stone whatever the stage, so the number of amber spots on a screen is the number of things
the person has to do (注意事项 A-04). Stage *position* is drawn by the stage bar's fill (charcoal = current,
cream = passed, white = ahead), never by hue.

Glyphs stay distinct so meaning survives without color: `checkmark.circle.fill` (positive),
`exclamationmark.triangle.fill` (error), `moon.zzz` (dormant), `arrow.counterclockwise.circle` (ended —
session gone, kept as a recoverable record), spinner (pending), bell (attention).
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

- **Sidebar** — Cream chrome; hosts the scope field, terminal list, and tool dock.
- **Scope field** — the sidebar's anchor, one row: White, 32px tall, Cool Stone border (nav-level),
  9.6px, split by a 16px Linen hairline. Left half = the host · project menu: host glyph with a
  sage/stone status dot, 「本机」/host in 13 semibold, the project in muted caption (only when one is
  selected), and an up-down chevron; a Cream wash on hover. As the sidebar narrows it steps down to
  the project alone, then the project cut short, then the glyph alone. Right half = the live filter
  (「筛选终端」, at least 64px so the placeholder stays whole; distinct from ⌘F search). Followed by
  the 待处理 button and a 32px filled-charcoal `+` (menu: 启动终端 / 启动 axis-claude / 新建分组…).
- **待处理 button** — a tray glyph in the header; amber with a small count badge while tasks need you,
  terminals ask for you or fail to connect, muted otherwise; opens the attention center, which lists
  tasks (one row each: stage tag, `A-12 标题`, the first thing it needs, 打开任务), then task-less
  tickets, then terminals.
- **我的清单 row** — pinned above 主管: a 40pt row with a 22px charcoal badge (`list.bullet.clipboard`),
  「我的清单」 in `rowTitle`, and one subtitle — 「N 件需要你」 (amber) > 「N 件进行中」 (stone) > 「清单是
  空的」. The signal column carries an amber count capsule while tasks need you, else nothing (no
  equalizer — that is a terminal's). Tapping opens the list; while the list is on screen the row shows the
  3px charcoal bar a tool pane's row gets (the system List highlight belongs to terminal rows).
- **清单行 (task row)** — a White card, Linen 1px, `md` radius, at least 52pt tall, 8/14 padding, 6pt
  between its lines; the whole card takes a 6% amber wash while the task needs you. Line 1: `A-12` in
  mono 11 stone + the title in `rowTitle` (truncated, full text in the tooltip) + a `StateTag` on the
  right (tinted only when it needs you). Line 2: progress `3/5` (monospaced digits) · executor chips (你 /
  开发 / 助理, deduplicated, at most 3) · the due date only within 3 days. The right end holds that stage's
  one or two actions (the ticket bar's set: 回答… / 打回… + 通过 / 补充… + 重试; 待分配: 谁来做…); a row in
  progress has no button.
- **阶段条 (stage bar)** — one segment per stage, 32pt tall, `md` radius, 24pt Linen connectors between
  segments. Current = Charcoal fill + ivory semibold text; passed = Cream + stone; ahead = White + Linen
  stroke. Stages are never told apart by hue.
- **清单项行 (item row)** — 40pt, a Linen rule above; the ordinal in mono 11 (always `ord`, never an item
  id); a 22pt checkbox with 6pt corners: done = Charcoal fill + ivory check, working = a static half disc
  `◐`, todo = Cool Stone stroke, blocked = amber stroke + `hand.raised`. Your items are clickable
  (optimistic update, roll back with the real error); agent items are read-only and move by reports. The
  text may wrap to two lines; on the right an executor chip, the ticket chip (mono, jumps to its
  terminal) and a 60pt right-aligned status word (待你 in amber, the rest stone).
- **执行者 chip / task chip** — 22pt, Cream, Linen hairline, 6pt corners, 11pt text; 「你」 gets a 1pt
  Charcoal stroke, roles are plain, 「未定」 stone. The ticket number chip is mono. The ticket bar's task
  chip (`list.bullet.clipboard` + 「任务 A-12 · 第 1–3 项」, mono, the item range written as consecutive
  runs) opens the task card; the card's ticket chip jumps back to the terminal.
- **待领取 / 组织 (claimable & org)** — an org task that is not yet yours sits in a 「待领取」 section with a
  neutral `StateTag` 「待领取」 and a quiet row action 「领取」; it never counts as needing you. A task that
  came from the organisation carries a mono Cream chip 「组织 · T-128」 (opens the task on the org site) and a
  one-line 同步行 under the activity: 「已同步」 stone / 「N 条待发」 stone / an error in one sentence. A sync
  conflict is a blocked item: the needs-you strip reads 「同步冲突」 with the item line and offers exactly two
  actions, 「本地为准（…）」 and 「服务端为准（…）」. The 组织 card in the worklist settings (server, email,
  invite code; registered: node id, status, 「立即同步」 + quiet 「断开…」 with a confirmation) uses the same
  `SettingRow` grammar as the other settings; the token is never shown.
- **需要你条 (needs-you strip)** — 44pt, amber 6% fill + amber 1pt stroke, `md` radius, an 8pt amber
  square at the left; the stage name in bold, then the question / report in one line; 1–2 actions on the
  right (回答… / 打回… + 通过 / 补充… + 重试). One per card: the first `PersonAction` in declaration order,
  the rest as a small 「还有 N 件：…」 line.
- **谁来做 sheet** — 560pt wide; one row per item: ordinal, editable text, and a segmented control (你 +
  the roles in `tfa read roles` order; a Linen well with `md` corners, the chosen segment raised in White
  with a 1pt Linen ring — the 在线 / 已断开 switch). Defaults come from the 主管's `--suggest`, else the
  heuristic (改 / 修 / 实现 / 提交 → 开发; 查 / 问 / 分析 / 总结 → 助理; otherwise 你). At the bottom a
  「同一角色的项合成一张工单」 switch (on) and one line of explanation; ⌘↩ confirms, Esc cancels, and an
  unconfirmed change on close asks save / discard / cancel.
- **在线 / 已断开 switch** — full-width segmented bar: a Linen well with the chosen half raised in white.
- **Sidebar terminal row** — a 22px rounded-square **kind badge** (agents — axis-claude / Claude /
  Codex — solid Charcoal with an ivory glyph; shells and ssh a White chip with a Linen hairline;
  ended/dormant faded), then `rowTitle` name + `rowSubtitle` (cwd shown as `~` and, when deep, only
  its last two parts `…/proj/sub`, head-truncated; full path in the tooltip), and ONE 14pt signal
  column (bell > connection glyph > slim equalizer > check/unseen dot). Selection is the system
  List highlight; only while a tool pane hides that selection does the current row show a 3px
  Charcoal bar at its leading edge. On a prominent (accent-filled) selection the badge becomes a
  translucent light chip and the equalizer/dot turn ivory. "Needs you" is an amber wash at 10%
  with the same rounded footprint as the selection; working is carried by the equalizer alone.
  Ungrouped terminals live in a built-in「未分组」folder pinned above the groups.
- **Group folder** — a 22pt-wide chevron (the badge width, so folder names align with row titles),
  an 11pt tracked muted caps label, and the count in the rows' 14pt signal column; hovering swaps
  the count for the drag grip. Folders are separated by 12pt; drop targets highlight in accent.
- **已断开 bulk actions** — at the top of the 已断开 list: a small prominent 「全部恢复 N」 and a quiet
  「全部移除…」 text button.
- **Metric card** (Lab system monitor) — White, Linen border, `card` radius; caption title, one large
  rounded monospaced value, an optional 6px capsule usage bar (Charcoal; amber past 85%), a caption
  detail. Laid out in a 760pt column (two wide cards, then three small).
- **Status capsule** (new-session sheet) — a 7px dot + caption on a 10% tint of the same status color.
- **Tool dock** (主管 / 模型 / 隧道 / 规则 / Skills / 实验室) — sidebar bottom; equal-width icon+label cells,
  selected = filled charcoal cell with ivory glyph (mirrors a selected row). 主管 opens the work list with
  its 设置 fold expanded and carries a 7px amber dot (chrome ring) while a task, or a ticket outside any
  task, needs you.
- **主管 row** — pinned under 我的清单: a 22px charcoal badge with the `person.crop.rectangle.stack`
  glyph, 「主管」 in `rowTitle`, and one subtitle line — 「N 个工单需要你」 (amber, only tickets outside any
  task: tasks are counted on the 我的清单 row) / 「N 个任务进行中 · 对我说一句就能加任务」 / 「未启动 ·
  点击启动」 / 「对我说一句就能加任务」. The signal column shows an amber count capsule for those tickets,
  else the equalizer while the router works. Tapping it when not running starts the router terminal.
- **Ticket terminal row** — an ordinary terminal row whose subtitle reads `#id 阶段 · ack`; the stage
  word takes its tint only when the ticket needs you, and a needing ticket gets the same amber wash
  as a ringing terminal. The live output line still wins while the agent works.
- **Ticket bar** — 34px strip under the terminal header of a ticket terminal: stage glyph + state
  tag + `#id 标题`, the branch in a mono Cream chip, the latest question / report / ack in one
  truncated line, then the stage's actions (待评审: 打回… + prominent 通过; 等你回答: prominent 回答…;
  stuck: 补充… + prominent 重试; working: 补充…) and a quiet stop glyph. A needing stage tints the
  strip at 6%. The 主管 terminal gets the same strip with a one-line explanation and 工单面板.
- **主管 panel** — tool pane in the 760pt column: 主管 card (status, folder, 打开/启动), then 需要你
  (only when non-empty; one white card per ticket with its actions), 进行中 (compact rows), 问题 (only
  when effects keep failing), 最近结束, rules & accept mode, schedules, settings, decision log.
- **Status indicator** — shared spinner-or-glyph component; symbol + tint + VoiceOver label.
- **Terminal header** — 40px: sidebar toggle, name (`headerTitle`), a state tag (运行中 sage / 需要你
  amber / 连接失败 brick / 空闲·已断开 stone, tinted 12% fill), a muted monospaced `~` path, then small
  bordered 历史 / 文件 / ⌘K buttons (+ prominent 重新连接 when failed).
- **Terminal footer** — 24px under the pane: kind + host on the left, ⌘] (下一个需要你: task cards first,
  then terminals) / ⌘K / ⌘F hints on the right.
- **Panel header bar** — Ivory canvas, sidebar-toggle + accent icon + `headerTitle`, and one muted line
  underneath saying what the pane is for.
- **Model panel card** — White, Linen border, 16px radius; a status dot + title header above, then
  control / stats (mono values) / model list cards.
- **Tunnel row** — White card, 16px radius; status dot (running=slate, retrying=amber, stopped=stone),
  name + endpoint, a Cream port-mapping chip (mono), enable switch, log/edit/delete.
- **Sheets / forms** (SSH host, tunnel, environment editor) — White, Linen border, `headerTitle` title,
  rounded-border inputs, Charcoal primary button.
- **Banners & toasts** (tmux-missing, error, detach-undo) — flat, Linen-bordered, accent-tinted.
- **Terminal watermark** — the session name in the pane's bottom-right corner, rounded bold, at most
  140pt, `terminalForeground` at 5% — an identity cue that never competes with output.
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
