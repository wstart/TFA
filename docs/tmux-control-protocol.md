# tmux Control Mode (`-CC`) Protocol Spec

Implementation-ready spec for driving REAL tmux from a native macOS GUI via `tmux -CC`.

**Target:** tmux 3.6a at `/opt/homebrew/bin/tmux` (verified `tmux -V` → `tmux 3.6a`).
**Sources tagged per fact:** `[man]` = `man tmux` CONTROL MODE; `[src]` = tmux GitHub source
(`control.c`, `control-notify.c`, `cmd-refresh-client.c`); `[wiki]` = tmux wiki Control-Mode;
`[iterm]` = iTerm2 tmux-integration docs; `[CAP]` = empirically captured from local 3.6a via a
Python PTY harness on throwaway socket `-L muxresearch`.

All `[CAP]` lines below are verbatim from tmux 3.6a. In captures, every protocol line is
terminated by `\r\n` (CR LF). Octal escapes like `\033` are literally those 4 ASCII bytes
on the wire (tmux's own escaping), not control bytes.

---

## 1. Launching control mode

`-C` = control mode in canonical line mode (for manual testing — typed input echoes). `-CC` =
control mode with echo/canonical disabled, for applications. **Use `-CC`.** `[man][wiki]`

Always pass `-u` to force UTF-8 output regardless of locale. `[man]`

### Exact argv

(a) **Brand-new session** (create + attach in one shot):
```
tmux -u -CC new-session -A -s GUI
```
`-A` = attach if a session named `GUI` already exists, else create it (idempotent — best for a
GUI that reconnects). Plain form used in captures: `tmux -CC new-session -s NAME`. `[CAP]`

(b) **Attach existing session by name:**
```
tmux -u -CC attach-session -t GUI
```
Captured handshake differs from new-session (see §2). `[CAP]`

(c) **Over SSH** — run tmux on the remote, control mode is spoken over the ssh pipe:
```
ssh -t user@host -- tmux -u -CC new-session -A -s GUI
```
Use `-t` so ssh allocates a PTY (tmux `-CC` wants a tty). For attach: `ssh -t host -- tmux -u -CC attach -t GUI`.

### Recommended flags
- `-CC` always (not `-C`). `[wiki]`
- `-u` always. `[man]`
- `new-session -A -s NAME` for idempotent open. `[man new-session]`
- Add a dedicated socket if you don't want to share the user's default server: `-L GUI` (or `-S /path`).
- **ID discipline:** always target by `$id` / `@id` / `%id`, never by name/index — they are
  unambiguous and stable. `[wiki]`

---

## 2. Initial handshake bytes

Immediately after launch tmux emits a **DCS opener** then state notifications. `[src control.c: bufferevent_write("\033P1000p",7)]`

Opener bytes (hex): `1b 50 31 30 30 30 70` = ESC `P` `1` `0` `0` `0` `p`  (`\033P1000p`). `[src][CAP]`
It is prepended to the first output line (it is NOT on its own line).

**`new-session` handshake** `[CAP]`:
```
\x1bP1000p%begin 1780149568 271 0
%end 1780149568 271 0
%window-add @0
%sessions-changed
%session-changed $0 research
%output %0 <first pane output...>
```

**`attach` handshake** `[CAP]` (note: no leading `%window-add`/`%sessions-changed`; just the
session change, then existing windows are reported as you query, plus async notifications):
```
\x1bP1000p%begin 1780149792 275 0
%end 1780149792 275 0
%session-changed $0 keep
%output %0 <pane output...>
```

After the handshake, fetch full initial state with `list-sessions` / `list-windows` /
`list-panes` (see §11) — do not rely on the handshake to enumerate everything.

---

## 3. Full notification list (with real 3.6a captures)

Format strings are the literal C format from `control-notify.c` (`%%`→`%`, `%%%u`→`%` + number).
"In 3.6" column: ✅ present & captured, ✅* present in source/man (not all reproduced here),
N = not applicable. A notification **never** occurs inside a `%begin`/`%end` block. `[man]`

| Notification | Format `[src/man]` | Real captured example `[CAP]` | 3.6 |
|---|---|---|---|
| `%output` | `%output %%%u <escaped>` | `%output %0 \033[1m\033[7m%\033[27m...` | ✅ |
| `%extended-output` | `%extended-output %%%u %llu : <escaped>` | `%extended-output %0 1 : AFTER\015\012` | ✅ |
| `%begin` | `%begin <time> <num> <flags>` | `%begin 1780149568 271 0` | ✅ |
| `%end` | `%end <time> <num> <flags>` | `%end 1780149568 271 0` | ✅ |
| `%error` | `%error <time> <num> <flags>` | `%error 1780149577 292 1` | ✅ |
| `%session-changed` | `%session-changed $%u %s` | `%session-changed $0 research` | ✅ |
| `%sessions-changed` | `%sessions-changed` | `%sessions-changed` | ✅ |
| `%session-renamed` | `%session-renamed $%u %s` | `%session-renamed $0 newname` | ✅ |
| `%session-window-changed` | `%session-window-changed $%u @%u` | `%session-window-changed $0 @1` | ✅ |
| `%window-add` | `%window-add @%u` | `%window-add @1` | ✅ |
| `%window-close` | `%window-close @%u` | (see note) | ✅* |
| `%window-renamed` | `%window-renamed @%u %s` | `%window-renamed @1 renamedwin` | ✅ |
| `%window-pane-changed` | `%window-pane-changed @%u %%%u` | `%window-pane-changed @1 %2` | ✅ |
| `%unlinked-window-add` | `%unlinked-window-add @%u` | (window created in another session) | ✅* |
| `%unlinked-window-close` | `%unlinked-window-close @%u` | `%unlinked-window-close @1` | ✅ |
| `%unlinked-window-renamed` | `%unlinked-window-renamed @%u %s` | — | ✅* |
| `%layout-change` | `%layout-change @%u <layout> <visible-layout> <flags>` | `%layout-change @1 419a,80x24,0,0[80x12,0,0,1,80x11,0,13,2] 419a,... *` | ✅ |
| `%pane-mode-changed` | `%pane-mode-changed %%%u` | (enter copy-mode) | ✅* |
| `%client-session-changed` | `%client-session-changed %s $%u %s` | (multi-client) | ✅* |
| `%client-detached` | `%client-detached %s` | (multi-client) | ✅* |
| `%continue` | `%continue %%%u` | (pause-after resume) | ✅* |
| `%pause` | `%pause %%%u` | (pause-after, slow client) | ✅* |
| `%subscription-changed` | `%subscription-changed %s $%u @%u <idx> %%%u : %s` | `%subscription-changed sub1 $0 @0 0 %0 : zsh` | ✅ |
| `%exit` | `%exit` or `%exit <reason>` | `%exit` | ✅ |
| `%config-error` | `%config-error <error>` | (config file error) | ✅* |
| `%message` | `%message <message>` | (`display-message`) | ✅* |
| `%paste-buffer-changed` | `%paste-buffer-changed %s` | — | ✅* |
| `%paste-buffer-deleted` | `%paste-buffer-deleted %s` | — | ✅* |

Notes:
- **`%window-close` vs `%unlinked-window-close`:** if the closed window is in the session your
  control client is attached to → `%window-close @N`; if it is in another session the server is
  managing → `%unlinked-window-close @N`. Captured: closing a window I'd switched away from gave
  `%unlinked-window-close @1`. `[CAP][src]`
- **`%window-add` vs `%unlinked-window-add`:** same linked/unlinked distinction. `[src]`
- **`%session-changed` vs `%client-session-changed`:** `%session-changed` is for *your* client;
  `%client-session-changed <client> $id name` reports *another* client switching session. `[src]`
- All notifications except `%exit` are also tmux "hooks" (e.g. `window-renamed`). `[man]`
- `%subscription-changed` trailing args before `:` (here window-index + pane-id) — per man, "Any
  arguments after pane-id up until a single ':' are for future use and should be ignored."

---

## 4. `%output` escaping rule (empirically confirmed)

**Rule** `[src control.c]`:
```c
for each byte b in payload:
    if (b < 0x20) || (b == 0x5C /* backslash */):
        emit "\%03o"   // backslash + 3 octal digits, e.g. \033
    else:
        emit b verbatim
```
So **only** bytes `0x00–0x1F` and `0x5C` are escaped, as 3-digit octal. Everything else passes
through raw — including space, all printable ASCII, **DEL (0x7F)**, and **all high bytes
0x80–0xFF (UTF-8 multibyte)**. There is no `\xNN`; it is always octal `\NNN`. `[src][CAP]`

**Empirical proof** `[CAP]`. Sent via `send-keys -H` (hex) a printf producing bytes
`01 02 03 09 0d 0a 1b 5c 7e 7f 80 e2 98 83`. tmux emitted the decoded line as:
```
%output %0 \001\002\003\011\015\015\012\033\134~\x7f\x80\xe2\x98\x83
```
(In the harness repr, `\x7f`/`\x80`/`\xe2...` are *raw bytes* tmux passed through; `\001` etc.
are the literal 4-char octal escapes tmux wrote.) Confirms:
`0x01→\001`, `0x09(TAB)→\011`, `0x0a(LF)→\012`, `0x0d(CR)→\015`, `0x1b(ESC)→\033`,
`0x5c(\)→\134`, `~(0x7e)→~`, `0x7f→raw`, `0x80→raw`, snowman `e2 98 83→raw`.

Second proof (a literal backslash in a string): `\` was emitted as `\134`, never `\\`. `[CAP]`

### Decode algorithm (pseudocode)
```
decode(line_bytes):                      # line_bytes = everything after "%output %ID "
    out = []
    i = 0
    while i < len(line_bytes):
        b = line_bytes[i]
        if b == ord('\\') and i+3 < len(line_bytes)+1 and all of next 3 are octal digits 0-7:
            out.append( (next3 as base-8) & 0xFF )   # e.g. "\033" -> 0x1B
            i += 4
        else:
            out.append(b)                            # raw byte (incl 0x7f, 0x80-0xff)
            i += 1
    return bytes(out)                                # feed straight into your VT parser
```
A `\` is ALWAYS followed by exactly 3 octal digits (tmux never emits a bare `\`), so the parser
is unambiguous. Decoded bytes are a raw terminal stream (CR, LF, ESC sequences intact) — pipe
them into your VT100/xterm emulator per pane id.

**Captured raw→decoded example:**
- Raw line on wire: `%output %0 \033[31mhi\134\134\007\x7f\033[0m\015\012`
- Decoded payload bytes: `1b 5b 33 31 6d 68 69 5c 5c 07 7f 1b 5b 30 6d 0d 0a`
  = `ESC[31m` `h` `i` `\` `\` `BEL` `DEL` `ESC[0m` `CR LF`.

---

## 5. Command reply framing & matching

Every command you send on stdin (newline-terminated) produces exactly **one** output block. `[man]`
```
%begin <time> <cmdnum> <flags>
<command output, 0+ lines, may be empty>
%end   <time> <cmdnum> <flags>      ← success
   …or…
%error <time> <cmdnum> <flags>      ← failure
```
- `<time>` = seconds since epoch; `<cmdnum>` = a monotonically increasing command number;
  `<flags>` = bitfield (1 when the command came from the client, 0 for internal/handshake). `[man][wiki]`
- The `<time>` AND `<cmdnum>` on `%begin` exactly match its closing `%end`/`%error`. `[wiki][CAP]`
- **Ordering guarantee:** blocks come back in the same order commands were sent (FIFO). Match
  replies to issued commands by FIFO position; the `<cmdnum>` lets you double-check. Commands you
  did not send (internal ones in the handshake, e.g. `271`) also appear — track the FIFO queue of
  *your* issued commands and pop on each `%end`/`%error` whose flags=1, or correlate by cmdnum. `[CAP]`
- **Error detection:** a block terminated by `%error` failed; its body holds the message. `[CAP]`:
```
%begin 1780149577 292 1
parse error: unknown command: this-is-a-bad-command
%error 1780149577 292 1
```
- Notifications (`%output`, `%window-add`, …) are NEVER emitted between a `%begin` and its
  `%end`/`%error`; they only appear outside blocks, so block parsing is clean. `[man][CAP]`

**Recommended client model:** maintain a FIFO of pending commands. On `%begin`, start buffering;
on `%end`/`%error`, resolve the head of the FIFO with success/failure + buffered body. Treat any
`%`-line seen while NOT inside a block as a notification.

---

## 6. Sending input to a pane (binary-safe)

Three options:
1. `send-keys -t %ID <keyname...>` — interprets key names (`Enter`, `C-c`, `Up`, `Space`). NOT
   safe for arbitrary text (e.g. a literal "Enter" or "C-c" in your data gets interpreted).
2. `send-keys -t %ID -l <literal>` — `-l` disables key-name lookup; sends the string literally.
   Still goes through tmux arg quoting, and you must escape shell/tmux metacharacters.
3. `send-keys -t %ID -H <hex...>` — each arg is a 2-hex-digit byte; **fully binary-safe**, zero
   key-name interpretation, no quoting hazards. `[src cmd-send-keys]`

**Recommendation: use `-H` for everything.** Encode your bytes (already UTF-8 for text) as
space-separated hex and send. It cannot be confused with key names and handles control bytes and
multibyte cleanly. `[CAP confirms -H delivers exact bytes — see §4 proof, which used -H]`

Syntax: `send-keys -t %ID -H AA BB CC …`

Worked examples (target pane `%0`):
- **Ctrl-C (0x03):**            `send-keys -t %0 -H 03`
- **Up arrow (ESC `[` `A`):**   `send-keys -t %0 -H 1b 5b 41`
- **UTF-8 "café☃" :**           `send-keys -t %0 -H 63 61 66 c3 a9 e2 98 83`
- **Enter (CR):**               `send-keys -t %0 -H 0d`

To avoid ALL key-name interpretation: never use bare key names from untrusted/arbitrary input —
always `-H` (or `-l` if you must, with careful quoting). With `-H` there is no interpretation at
all. `[CAP]`

Alternative for large pastes: `load-buffer` + `paste-buffer -t %ID -p` (the `-p` makes it
bracketed-paste aware). For a GUI driving keystrokes, `-H` is simplest and robust.

---

## 7. Fetching pane content / scrollback (`capture-pane`)

Flags: `-p` print to stdout (into the `%begin/%end` block), `-e` include SGR/escape sequences,
`-J` join wrapped lines + preserve trailing spaces, `-S <n>` start line, `-E <n>` end line,
`-t %ID` target. Line numbers: `0` = top of visible; negative = scrollback; `-` = oldest history;
`-E -` = end of history. `[man capture-pane]`

**Recommended: grab last N lines of history WITH colors:**
```
capture-pane -p -e -J -t %ID -S -N -E -
```
e.g. last 2000 lines: `capture-pane -p -e -J -t %ID -S -2000 -E -`.
Output arrives as body lines inside the command's `%begin`/`%end` block — note `-e` color
escapes are the same raw ANSI you'd feed your emulator (they are body text, NOT `%output`
octal-escaped). `[CAP]` example body line: `0: [80x24] [history 1/2000, 1600 bytes] %0 (active)`
for `list-panes`; `capture-pane -p -e` returns the literal screen rows.

For full known history size, query `#{history_size}` per pane first, then `-S -#{history_size}`.

---

## 8. Layout strings & pane geometry

Value from `list-windows -F '#{window_layout}'` and field 2 of `%layout-change`. `[man]`

**Grammar:** `CSUM,<cell>` where `<cell>` is:
```
cell      = WxH,X,Y[,paneid | groupbody]
groupbody = { cell , cell , ... }     // horizontal split (panes side by side, sharing height)
          | [ cell , cell , ... ]     // vertical split   (panes stacked, sharing width)
```
`{ }` = panes laid out **left→right** (an H-split). `[ ]` = panes **top→bottom** (a V-split).
Leaf cells end in a pane id (the `%N` integer). `CSUM` = 4 hex digits (see below). `[src layout-custom.c]`

### Leading checksum
4-hex-digit checksum of the layout body (everything after `CSUM,`). Algorithm `[src
layout_checksum]`, **verified against 6 real captured strings (100% match)** `[CAP]`:
```
csum = 0
for each byte b of body_string:               // body = layout text after "CSUM,"
    csum = ((csum >> 1) + ((csum & 1) << 15)) & 0xFFFF
    csum = (csum + b) & 0xFFFF
print as %04x
```
You only need to *verify* incoming layouts (or generate when sending `select-layout`); for
driving size you normally just send `resize-pane`/`refresh-client` and read back the new layout.

### Decode a REAL captured layout step by step `[CAP]`
String: `020a,80x24,0,0{40x24,0,0,1,39x24,41,0,2}`
1. `020a` = checksum (verifies: csum("80x24,0,0{40x24,0,0,1,39x24,41,0,2}") = 0x020a ✓).
2. Root cell `80x24,0,0` = window is 80×24 at origin (0,0).
3. `{ … }` → horizontal split, two children side by side:
   - `40x24,0,0,1` → pane id **%1**, rect **W=40 H=24 at X=0 Y=0**.
   - `39x24,41,0,2` → pane id **%2**, rect **W=39 H=24 at X=41 Y=0**.
   (The 1-column gap at X=40 is the vertical split divider.)

Second example `419a,80x24,0,0[80x12,0,0,1,80x11,0,13,2]`:
- Root 80×24; `[ ]` vertical split → `%1` = 80×12 @ (0,0) on top; `%2` = 80×11 @ (0,13) below
  (row 12 is the horizontal divider).

`%layout-change` carries TWO layout strings: `window-layout` then `window-visible-layout`
(identical unless a pane is zoomed), then `window-flags` (e.g. `*` = current window). `[man][CAP]`:
`%layout-change @1 2e7a,80x24,0,0{...} 2e7a,80x24,0,0{...} *`

---

## 9. Client size / resize control

**Set control-client size:** `refresh-client -C WxH` (e.g. `refresh-client -C 100x30`). In 3.6 the
syntax accepts BOTH `WxH` and `W,H` (`sscanf "%ux%u"` or `"%u,%u"`); per-window form
`@WIN:WxH` and clear form `@WIN:` also exist. `[src cmd-refresh-client.c][CAP]` — captured
`refresh-client -C 100x30` immediately produced `%layout-change @0 a87d,100x30,0,0,0 …`,
confirming the GUI's size took effect.

- If you **never** call `refresh-client -C`, the control client does NOT influence window size —
  windows stay at other clients' size (or default). `[wiki]`
- Once you DO set `-C`, your client is treated like any other client and participates in sizing.
- **window-size option** (`set -g window-size latest|largest|smallest|manual`): controls how tmux
  reconciles multiple attached clients. With multiple clients, default `latest` uses the most
  recently active client's size; `smallest` clamps to the smallest client. `[man options]`
- **aggressive-resize** (`set -g aggressive-resize on`): resize each window to the size of the
  client *currently viewing it* rather than the smallest across the session. `[man]`

**To make the GUI authoritative over size:**
1. `set -g window-size manual` (or `largest`) so other clients don't shrink windows.
2. Call `refresh-client -C WxH` on every GUI resize (debounced).
3. Be the only attached client, or ensure `aggressive-resize off` and your client is the latest.
4. React to `%layout-change` to re-render panes at the new geometry.

Multi-client caveat `[iterm]`: attaching the same session from two GUIs gets "weird" (sizes fight);
for shared use, normal tmux is better. Design for single authoritative GUI client.

---

## 10. Clean detach / close & `%exit`

- **Clean detach (leave server & session alive):** send `detach-client` → tmux emits a clean
  `%exit` (no reason) then the DCS terminator `\x1b\\` (ST). Captured `[CAP]`:
  ```
  %begin … / %end …
  %exit
  \x1b\
  ```
  Equivalent: sending a **single empty line** detaches. `[wiki]`
- **`%exit [reason]`** = the control client is exiting NOW (not attached to any session, or an
  error/server-exit). Reason is present only sometimes (e.g. `server exited`); a normal
  `detach-client` and a `kill-session` of the attached session both gave bare `%exit`. `[man][CAP]`
- After `%exit`, tmux writes the **ST terminator** `\x1b\\` (ESC `\`) closing the DCS, then the
  client process exits. Your GUI should treat `%exit` as "tear down this connection". `[src][CAP]`
- **Kill a window/pane/session** while staying connected: `kill-pane -t %ID`, `kill-window -t @ID`,
  `kill-session -t $ID` — these generate `%window-close`/`%unlinked-window-close` etc., not `%exit`,
  unless you kill the session your client is attached to. `[CAP]`
- `refresh-client -f wait-exit` makes tmux wait for an empty line after `%exit` before the process
  actually exits (lets you flush). `[wiki]`

---

## 11. Ready-to-use `-F` format strings for initial state

Run these right after the handshake; replies arrive in `%begin/%end` blocks (parse body lines).

**Sessions** (`list-sessions`):
```
list-sessions -F '#{session_id}|#{session_name}|#{session_attached}|#{session_windows}'
```

**Windows** (`list-windows -a` for all sessions, or `-t $S` for one):
```
list-windows -a -F '#{session_id}|#{window_id}|#{window_index}|#{window_name}|#{window_active}|#{window_zoomed_flag}|#{window_layout}'
```

**Panes** (`list-panes -a` for all, or `-t @W`):
```
list-panes -a -F '#{session_id}|#{window_id}|#{pane_id}|#{pane_active}|#{pane_pid}|#{pane_title}|#{pane_width}|#{pane_height}|#{pane_left}|#{pane_top}|#{pane_current_command}|#{pane_current_path}|#{cursor_x}|#{cursor_y}|#{history_size}'
```
Captured single-pane reply with a subset `[CAP]`: `%0 1 30859 80 24 0 0 zsh` for
`#{pane_id} #{pane_active} #{pane_pid} #{pane_width} #{pane_height} #{pane_left} #{pane_top} #{pane_current_command}`.

Use a delimiter unlikely in names (here `|`); names can contain spaces, so do NOT split on space.
Pane geometry (`pane_left/top/width/height`) matches the layout-string rectangles in §8.

---

## 12. 3.6-specific notes

- **Pause mode (flow control):** `refresh-client -f pause-after=N` (N seconds). When the client
  falls behind, tmux buffers and emits `%pause %ID`; output then arrives as **`%extended-output`**
  instead of `%output`. Resume with `refresh-client -A '%ID:continue'` → `%continue %ID`. Manual
  pause: `refresh-client -A '%ID:pause'`. `[man][wiki][CAP]`
- **`%extended-output` format:** `%extended-output %ID <age_ms> : <escaped>` where `age_ms` =
  milliseconds tmux buffered before sending. Captured `[CAP]`: `%extended-output %0 1 : AFTER\015\012`
  (age 1 ms). Same octal escaping as `%output` (§4). Everything after the single `:` is the
  payload; args between pane-id and `:` are reserved — skip to first ` : `.
- **Subscriptions (`refresh-client -B`):** push a format value when it changes (≤ once/sec).
  Syntax `refresh-client -B 'name:what:format'`. `what`: empty=session, `%N`=one pane, `%*`=all
  panes, `@N`=one window, `@*`=all windows. `[src][wiki]`. Remove with just the name:
  `refresh-client -B name`. Notification format `%subscription-changed name $sess @win idx %pane : value`.
  Captured `[CAP]`: subscribed `'sub1:%*:#{pane_current_command}'` →
  `%subscription-changed sub1 $0 @0 0 %0 : zsh` (and `… : sleep` while a command ran).
  Subscriptions are the efficient way to watch titles/cwd/commands without polling.
- **`refresh-client -f no-output`:** suppress all `%output` (useful if you only want notifications
  + capture-pane snapshots). `[wiki]`

---

## Implementation checklist

1. Spawn `tmux -u -CC new-session -A -s GUI` (or `attach-session -t GUI`) on a PTY; over SSH wrap
   with `ssh -t host -- …`.
2. Read DCS opener `\033P1000p`; begin line-buffered parse (lines end `\r\n`).
3. Parser states: NORMAL vs IN-BLOCK. `%begin`→IN-BLOCK (buffer body); `%end`/`%error`→resolve
   head of your issued-command FIFO (success/fail + body); outside a block, any `%`-line is a
   notification.
4. For `%output`/`%extended-output`: strip `%output %ID ` (or `%extended-output %ID age : `),
   octal-decode (§4: `\NNN`→byte; everything else raw), feed bytes into that pane's VT emulator.
5. After handshake, build initial tree via `list-sessions`/`list-windows -a`/`list-panes -a` with
   the §11 format strings (split on `|`).
6. Handle notifications: maintain session/window/pane tree on `%window-add`/`%window-close`(+unlinked
   variants)/`%window-renamed`/`%window-pane-changed`/`%session-*`; on `%layout-change` re-layout
   panes by decoding the layout string (§8).
7. Send input via `send-keys -t %ID -H <hex bytes>` (binary-safe, no key-name interpretation).
8. Drive size: on GUI resize, debounce then `refresh-client -C WxH`; set `window-size manual` and
   stay single-client to be authoritative; re-render on the resulting `%layout-change`.
9. Hydrate scrollback per pane with `capture-pane -p -e -J -t %ID -S -N -E -`.
10. Use `refresh-client -B 'name:%*:#{...}'` subscriptions to watch titles/cwd/command cheaply;
    optionally `-f pause-after=N` for flow control (then parse `%pause`/`%extended-output`/`%continue`).
11. Always target by `$id`/`@id`/`%id`, never names/indexes.
12. On `%exit` (+ trailing `\x1b\\` ST): tear down the connection. Clean shutdown = send
    `detach-client` (or a blank line) and wait for `%exit`.

---

### Appendix: capture methodology / cleanup
All `[CAP]` data produced by driving `tmux -CC` over a Python `pty.fork()` harness, feeding
commands on the master fd and recording raw bytes (rendered with Python `repr` so tmux's own
octal escapes and raw high bytes are both visible). Every run used throwaway socket `-L muxresearch`
and ended with `tmux -L muxresearch kill-server`. Final check `tmux -L muxresearch list-sessions`
→ `no server running on …/muxresearch` (clean — no research servers left).
