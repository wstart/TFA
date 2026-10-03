# TFA repository guide

TFA (Terminal For AI) is a native macOS SwiftUI application that presents real tmux sessions through tmux control mode (`tmux -CC`).

## Working agreements

- Communicate with the user in Chinese unless they request another language.
- Preserve the core invariant: one TFA terminal maps to one tmux session and one control-mode connection.
- Keep `TmuxKit` UI-independent; SwiftUI and SwiftTerm integration belong in `Sources/Mux`.
- Treat `swift build` as the source of truth when SourceKit diagnostics disagree.
- Run `swift test` when the local `Tests/` directory exists. The tests use local fixtures and have no production access.
- After changing packaging behavior, verify `./scripts/build-app.sh release`; ordinary source changes only require build and affected tests.
- Do not add signing identities, notarization credentials, personal names, email addresses, or other local secrets to tracked files.
- Do not add `Co-Authored-By` trailers.

## Relevant documentation

- Use `DESIGN.md` for visual tokens, spacing, status colors, and component conventions.
- Use `docs/tmux-control-protocol.md` for control-protocol parsing or transport changes.
- Use `docs/swiftterm-integration.md` for terminal rendering, input, resize, and cursor hydration work.

## High-risk invariants

- Before capture or cursor positioning, pin the SwiftTerm engine to the real tmux pane size through `PaneTerminal.pinEngineToPaneSize()`.
- A user detach must not reconnect; an unexpected disconnect may retry; a killed session must finalize once.
- Session metadata is keyed by stable `@tfa_id`. Renaming a session must migrate name-keyed environment and group data.
- Any new child process or PTY must be reclaimed on normal exit and signal-driven shutdown.
