# SwiftTerm Integration Guide (per-pane terminal, fed from tmux control mode)

Target: native macOS SwiftUI app, deployment target macOS 14+, Apple Silicon, Swift 6.2.
Use case: **one `TerminalView` per pane**, fed RAW BYTES from tmux control mode; user
keystrokes captured from the view and forwarded to tmux. **No child process is spawned by
SwiftTerm.**

All claims below were verified by cloning `migueldeicaza/SwiftTerm` at tag **v1.13.0**
(commit `8e7a1e1`) into `/tmp/swiftterm-research` and inspecting the source. A throwaway
SwiftPM executable package was built against this tag with the local Swift 6.2.3 toolchain.

## Build result (empirical)

- Toolchain: `Apple Swift version 6.2.3 (swiftlang-6.2.3.3.21)`, target `arm64-apple-macosx`.
- Probe package: `swift-tools-version:6.0`, `.macOS(.v14)`, executable target depending on
  `SwiftTerm` `from: "1.13.0"`.
- `swift build` -> **Build complete, 0 errors, 0 warnings** once Swift 6 actor isolation
  was handled (see "Swift 6 / threading" below — this is the main gotcha).
- SwiftPM resolved exactly `version 1.13.0` (`revision 8e7a1e1…`).

---

## 1. SPM dependency

```swift
// Package.swift  (swift-tools-version:6.0)
import PackageDescription

let package = Package(
    name: "YourApp",
    platforms: [
        .macOS(.v14)            // your app's target; >= SwiftTerm's own minimum (.macOS(.v13))
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0")
    ],
    targets: [
        .executableTarget(
            name: "YourApp",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        )
    ]
)
```

- **Known-good version:** `1.13.0` (latest tag; verified to build).
- **SwiftTerm's own minimum platform:** `.macOS(.v13)` — declared in SwiftTerm's
  `Package.swift` lines 110-117: `platforms: [.iOS(.v14), .macOS(.v13), .tvOS(.v13), .visionOS(.v1)]`.
  Your `.macOS(.v14)` is fine (it is >= v13).
- SwiftTerm itself uses `swift-tools-version:5.9` and `swiftLanguageVersions: [.v5]`. It is a
  pure-Swift library with no third-party runtime deps for the `SwiftTerm` product (its
  argument-parser/docc/benchmark deps are only for its own executables/tests). It does ship
  a Metal shader resource (`Apple/Metal/Shaders.metal`) processed automatically by SPM.
- No `unsafeFlags` are needed (the commented-out `-enforce-exclusivity=none` in SwiftTerm's
  manifest is disabled).

---

## 2. Key public types and roles

| Type | Role | Source |
|------|------|--------|
| `Terminal` | Headless VT/ANSI engine: parses bytes, holds the screen + scrollback buffer. `open class Terminal` (not Sendable). | `Sources/SwiftTerm/Terminal.swift:288` |
| `TerminalView` | The **AppKit `NSView`** that renders a `Terminal` and handles key/mouse input. `open class TerminalView : NSView, NSTextInputClient, …, TerminalDelegate`. | `Sources/SwiftTerm/Mac/MacTerminalView.swift:41` |
| `TerminalViewDelegate` | Protocol you implement to receive events (user input, resize, title, bell, clipboard…). | `Sources/SwiftTerm/Apple/TerminalViewDelegate.swift:12` |
| `LocalProcessTerminalView` | Subclass of `TerminalView` that **spawns a child process via PTY**. We do NOT use this. | `Sources/SwiftTerm/Mac/MacLocalTerminalView.swift:67` |

### Why plain `TerminalView`, not `LocalProcessTerminalView`

`LocalProcessTerminalView.setup()` constructs a `LocalProcess` and sets itself as its own
delegate; `startProcess(executable:…)` is what forks/execs a shell over a PTY and pipes its
output back via `dataReceived(slice:) { feed(byteArray: slice) }`
(`MacLocalTerminalView.swift:67-185`). Its `send(source:data:)` writes user input to that PTY
(`:131-134`).

A **plain `TerminalView` never creates a `LocalProcess`** and never spawns anything. It only:
- renders bytes you push via `feed(...)`, and
- calls `terminalDelegate?.send(source:self, data:)` for every user keystroke
  (`AppleTerminalView.swift:1958-1969`, `MacTerminalView.swift:558-560`).

So with a plain `TerminalView`, **all** user input arrives exclusively through your
`TerminalViewDelegate.send(source:data:)`, which is exactly the seam for forwarding to tmux.
There is no PTY, no fd, no process lifecycle to manage. This is what we want.

### Class name on AppKit

`TerminalView` is a **real `open class : NSView`** on macOS (defined directly in
`Mac/MacTerminalView.swift:41`) — *not* a typealias. (There is a separate
`open class TerminalView : UIScrollView` for UIKit in `iOS/iOSTerminalView.swift:54`; only one
compiles per platform.) The only typealias in this area is `TTImage = NSImage` / `UIImage`
(`Apple/AppleTerminalView.swift:28-37`).

---

## 3. FEEDING raw bytes from tmux into the view

Verified signatures (in the shared `Apple/AppleTerminalView.swift`, so identical on macOS/iOS):

```swift
// AppleTerminalView.swift:1916
public func feed(byteArray: ArraySlice<UInt8>)
// AppleTerminalView.swift:1924
public func feed(text: String)
```

Underlying engine (`Terminal.swift`):

```swift
public func feed(byteArray: [UInt8])         // Terminal.swift:4882
public func feed(text: String)               // Terminal.swift:4891
public func feed(buffer: ArraySlice<UInt8>)  // Terminal.swift:4900  (view's feed forwards here)
```

**Use `TerminalView.feed(byteArray: ArraySlice<UInt8>)`** for raw tmux output — it wraps the
engine call between `feedPrepare()`/`feedFinish()` which manage the display-update batching and
search-cache invalidation (`AppleTerminalView.swift:1899-1921`). Calling the bare
`Terminal.feed` skips that view bookkeeping, so prefer the view method.

tmux control-mode delivers bytes as `Data` (or already-decoded escaped bytes). Convert:

```swift
// Data -> ArraySlice<UInt8>  (canonical, no intermediate copy beyond Array init)
let chunk: Data = ...                       // raw output for this pane
terminalView.feed(byteArray: ArraySlice(chunk))

// or via [UInt8]
terminalView.feed(byteArray: [UInt8](chunk)[...])
```

> Do NOT write `terminalView.feed(byteArray: chunk[...])` — `Data`'s `[...]` yields a
> `Data` slice, not `ArraySlice<UInt8>`, and will not type-check. Wrap with
> `ArraySlice(chunk)`.

There is no `feed(data: Data)` overload — `feed(byteArray:)` / `feed(text:)` are the only
view-level feed methods.

Note: SwiftTerm's docs on `feed(byteArray:)` say "this can be invoked from a background
thread" (`AppleTerminalView.swift:1915`). Under Swift 6 strict concurrency the class is
`@MainActor`, so in practice call it on the main actor (see threading section). For very high
throughput, coalesce many small tmux chunks into one `feed` per run-loop tick.

---

## 4. CAPTURING user input (forward to tmux)

The delegate method (exact signature, `TerminalViewDelegate.swift:37`):

```swift
func send(source: TerminalView, data: ArraySlice<UInt8>)
```

- Element type is **`ArraySlice<UInt8>` (NOT optional)**. These are the raw bytes the terminal
  encoded for the user's keystroke (already in terminal wire form: control codes, CSI
  sequences for arrows/function keys honoring application-cursor mode, UTF-8 for text, etc.).
- Forward straight to tmux:

```swift
func send(source: TerminalView, data: ArraySlice<UInt8>) {
    tmux.sendKeysRaw(Array(data))   // or Data(data)
}
```

With a plain `TerminalView` this is the **only** path user input takes — confirmed: the view's
internal key handling ultimately calls `send(data:)` -> `terminalDelegate?.send(source:self,
data:)` (`AppleTerminalView.swift:1958-1992`), and no `LocalProcess` exists to intercept it.

(There are also view methods `send(txt:)`, `send(_:[UInt8])`, `send(data:)` you can call to
*inject* bytes as if typed, but you typically won't need them — tmux output goes through
`feed`, not `send`.)

---

## 5. RESIZE

Delegate callback (exact signature, `TerminalViewDelegate.swift:21`):

```swift
func sizeChanged(source: TerminalView, newCols: Int, newRows: Int)
```

Behavior to know:

- **The view auto-computes cols/rows from its frame + font.** On every NSView frame change,
  `setFrameSize` -> `processSizeChange(newSize:)` computes
  `newRows = Int(height / cellDimension.height)`,
  `newCols = Int((width - scrollerWidth) / cellDimension.width)`, resizes the engine, and fires
  `terminalDelegate?.sizeChanged(source:self, newCols:, newRows:)`
  (`MacTerminalView.swift:675-695`, `AppleTerminalView.swift:174-192`). Cell size derives from
  the font metrics (`computeFontDimensions`, `AppleTerminalView.swift:195+`).
- So in SwiftUI you just let SwiftUI size the view; `sizeChanged` tells you the resulting grid
  to report to tmux (`refresh-client -C` / `resize-pane`).
- The delegate's doc-comment about "remote client requested 80/132 columns" refers to a
  *separate* rare path; the common trigger is the frame-driven resize above. Either way you
  get `newCols/newRows`.

Read current grid size any time from the engine:

```swift
let cols = terminalView.getTerminal().cols   // Terminal.cols  (Terminal.swift:311)
let rows = terminalView.getTerminal().rows   // Terminal.rows  (Terminal.swift:314)
```

Force a specific grid (e.g. to match tmux's authoritative size) instead of frame-derived:

```swift
terminalView.resize(cols: 80, rows: 24)       // AppleTerminalView.swift:1934
```

`getTerminal()` returns the underlying `Terminal` (`AppleTerminalView.swift:166`). The view
also exposes `public var terminal: Terminal!` directly (`MacTerminalView.swift:146`) and
`func getOptimalFrameSize() -> NSRect` to size a window to the current grid
(`MacTerminalView.swift:569`).

---

## 6. SwiftUI wrapper (`NSViewRepresentable`) — complete minimal working struct

This compiles clean under Swift 6.2 (verified). The `@MainActor` annotations and the
`@MainActor TerminalViewDelegate` conformance isolation are **required** — see section 10.

```swift
import SwiftUI
import SwiftTerm   // macOS: TerminalView is an NSView

struct TerminalPane: NSViewRepresentable {
    /// Called once so the parent can hold the view and feed bytes into it.
    let onReady: (TerminalView) -> Void
    /// User keystrokes to forward to tmux.
    let onUserInput: (ArraySlice<UInt8>) -> Void
    /// Grid size changes to report to tmux.
    let onResize: (_ cols: Int, _ rows: Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onUserInput: onUserInput, onResize: onResize)
    }

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)            // MacTerminalView.swift:196
        tv.terminalDelegate = context.coordinator      // weak ref (MacTerminalView.swift:96)
        tv.configureNativeColors()                     // sensible default light/dark colors
        context.coordinator.view = tv
        onReady(tv)
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // Push transient config from SwiftUI state here if needed.
    }

    @MainActor
    final class Coordinator: NSObject, @MainActor TerminalViewDelegate {
        weak var view: TerminalView?
        let onUserInput: (ArraySlice<UInt8>) -> Void
        let onResize: (Int, Int) -> Void

        init(onUserInput: @escaping (ArraySlice<UInt8>) -> Void,
             onResize: @escaping (Int, Int) -> Void) {
            self.onUserInput = onUserInput
            self.onResize = onResize
        }

        /// Feed raw tmux output for this pane.
        func feed(_ data: Data) {
            view?.feed(byteArray: ArraySlice(data))
        }

        // --- TerminalViewDelegate ---
        func send(source: TerminalView, data: ArraySlice<UInt8>) { onUserInput(data) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { onResize(newCols, newRows) }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
```

You must implement **all 10** `TerminalViewDelegate` methods — none have default
implementations in the protocol (`TerminalViewDelegate.swift:12-91`). Empty bodies are fine for
the ones you don't care about.

To feed bytes later, keep the `TerminalView` (from `onReady`) and call
`tv.feed(byteArray: ArraySlice(data))`, or route through `coordinator.feed(_:)`.

---

## 7. Reading buffer text as plain Strings (cross-terminal search)

There is **no** `getScrollInvariantText` and no `getText()`-with-no-args (despite the name in
the brief — confirmed absent in v1.13.0). The available public APIs:

**Whole buffer incl. scrollback, fastest:**
```swift
// Terminal.swift:5850 — returns UTF-8 of every line in the chosen buffer, newline-separated
let term = terminalView.getTerminal()
let data: Data = term.getBufferAsData(kind: .active /* or .normal / .alt */, encoding: .utf8)
let text = String(data: data, encoding: .utf8) ?? ""
```
`BufferKind` is `public enum { active, normal, alt }` (`Terminal.swift:5797`).
This is the simplest way to get the entire pane's text (scrollback + screen) for indexing.

**Iterate visible rows (the on-screen viewport):**
```swift
for row in 0..<term.rows {
    if let line = term.getLine(row: row) {            // Terminal.swift:731, visible region
        let s = line.translateToString(trimRight: true)  // BufferLine.swift:322 (public)
        // index s ...
    }
}
```

**Iterate the entire scroll buffer (scroll-invariant, stable across scrolling):**
```swift
// Indices run over the whole scrollback; out-of-range returns nil.
var row = 0
while let line = term.getScrollInvariantLine(row: row) {   // Terminal.swift:743
    let s = line.translateToString(trimRight: true)
    row += 1
}
```
`getScrollInvariantLine` is counted from the start of scrollback (not the viewport), which is
what you want for a stable cross-terminal index.

**Range as String:**
```swift
let s = term.getText(start: Position(col: 0, row: 0),
                     end:   Position(col: term.cols - 1, row: 0))   // Terminal.swift:5869
```
`Position` is `public struct Position { public var col, row: Int; public init(col:row:) }`
(`Position.swift:11`).

**Single cell:** `term.getCharData(col:row:) -> CharData?` (`Terminal.swift:715`),
`term.getCharacter(col:row:) -> Character?` (`Terminal.swift:755`),
`term.getCharacter(for: CharData) -> Character` (`Terminal.swift:1405`).

`BufferLine.translateToString(trimRight:startCol:endCol:skipNullCellsFollowingWide:characterProvider:)`
is `public` (`BufferLine.swift:322`); all params have defaults, so `translateToString(trimRight: true)`
suffices. Note `Buffer`/`buffer.lines` themselves are internal — go through the `Terminal`
accessors above, not the raw buffer.

---

## 8. Theming / appearance (brief)

All on `TerminalView` (macOS, `MacTerminalView.swift` / `AppleTerminalView.swift`):

```swift
// Font: there is no `fontSize` property — set a sized NSFont; cell metrics recompute.
tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)   // MacTerminalView.swift:178

// Native (default) fg/bg used for the base text + the NSView layer background
tv.nativeForegroundColor = NSColor.white     // MacTerminalView.swift:409
tv.nativeBackgroundColor = NSColor.black      // MacTerminalView.swift:425
tv.configureNativeColors()                    // = textColor / textBackgroundColor (MacTerminalView.swift:548)

// Caret color
tv.caretColor = NSColor.systemBlue            // MacTerminalView.swift:456

// 16-color ANSI palette: pass exactly 16 Color values (else it no-ops)
tv.installColors([                            // AppleTerminalView.swift:310
    Color(red: 0, green: 0, blue: 0),         // Color(red/green/blue: UInt16 0...65535) — Colors.swift:322
    // ... 16 total
])
```

`Color` components are 16-bit (`0...65535`), `Colors.swift:23-29`. (There is an 8-bit
`init(red8:green8:blue8:)` but it is **internal**, not public — scale your 0-255 values to
0-65535, e.g. `UInt16(v) * 257`.)

**Cursor style:** `public enum CursorStyle { blinkBlock, steadyBlock, blinkUnderline,
steadyUnderline, blinkBar, steadyBar }` (`TerminalOptions.swift:13`). It's part of
`TerminalOptions.cursorStyle` (`TerminalOptions.swift:52`) read at terminal construction; the
engine also flips it at runtime via DECSCUSR. The view renders whatever the engine holds.

Other useful toggles on the view: `optionAsMetaKey: Bool` (default true,
`MacTerminalView.swift:888`), `allowMouseReporting: Bool` (default true, `MacTerminalView.swift:595`
— set false if you want local selection to always win), `caretViewTracksFocus`
(`MacTerminalView.swift:100`).

---

## 9. Selection & copy (brief)

```swift
let selected: String? = tv.getSelection()   // nil if nothing selected — AppleTerminalView.swift:2251
tv.selectAll()                               // AppleTerminalView.swift:2260
tv.selectNone()                              // AppleTerminalView.swift:2265
```
Lower level: `tv.selection: SelectionService` with `getSelectedText() -> String`
(`SelectionService.swift:536`), `setSelection(start:end:)`. Clipboard requests from the app
*inside* the terminal (OSC 52) arrive via `TerminalViewDelegate.clipboardCopy(source:content:Data)`
(`TerminalViewDelegate.swift:75`) — handle it to write `NSPasteboard` if you want OSC-52 copy
support (that's what `LocalProcessTerminalView` does, `MacLocalTerminalView.swift:107-113`).

Built-in incremental search on the view (handy, selects + scrolls to match):
```swift
tv.findNext("query", options: SearchOptions(), scrollToResult: true)   // TerminalViewSearch.swift:19
tv.findPrevious("query")                                               // :40
tv.clearSearch()                                                       // :55
```

---

## 10. Swift 6 / threading constraints (the main gotcha)

This is the one thing that will break your build if unhandled. Empirically, with Swift 6.2.3
strict concurrency:

1. **`TerminalView` is `@MainActor`-isolated** (it's an `NSView`). All feed/send/UI calls must
   happen on the main actor. In SwiftUI that's automatic; for tmux I/O that arrives on a
   background queue, hop to the main actor before `feed`:
   ```swift
   Task { @MainActor in terminalView.feed(byteArray: ArraySlice(chunk)) }
   // or DispatchQueue.main.async { ... }
   ```

2. **`Terminal` is NOT `Sendable`** (`open class Terminal`, `Terminal.swift:288`). You cannot
   pass it across actor boundaries. Anything touching `getTerminal()` / buffer text extraction
   must run on the main actor too. So your cross-terminal search indexing should snapshot text
   on the main actor (e.g. call `getBufferAsData()` on main, then hand the resulting `Data`/
   `String` — which *are* Sendable — to a background indexer).

3. **`TerminalViewDelegate` is a `nonisolated` protocol.** A `@MainActor` coordinator
   conforming to it triggers:
   `error: conformance … crosses into main actor-isolated code`.
   **Fix (used in the section-6 snippet):** isolate the conformance to the main actor:
   ```swift
   @MainActor
   final class Coordinator: NSObject, @MainActor TerminalViewDelegate { ... }
   ```
   (Alternatively `@preconcurrency TerminalViewDelegate`, or mark each delegate method
   `nonisolated` — but the `@MainActor`-conformance form is cleanest and is what compiled with
   zero warnings here.)

Net: **keep the entire SwiftTerm surface on `@MainActor`.** That's the natural place for UI
anyway; only the tmux socket read and the search indexing run off-main, and they exchange only
`Data`/`String`.

**Performance guidance:** no formal throughput doc in-source, but the design points the way —
`feed` batches display updates via `feedPrepare()`/`startDisplayUpdates()` …
`feedFinish()`/`queuePendingDisplay()` (`AppleTerminalView.swift:1899-1921`), so one `feed`
call with a large slice is much cheaper than many tiny ones. **Coalesce tmux output per
run-loop tick into a single `feed(byteArray:)`.** SwiftTerm also has an optional Metal GPU
renderer for heavy output: `try terminalView.setUseMetal(true)` (off by default,
`MacTerminalView.swift:247`) — call it after the view is in a window; consider it only if CPU
rendering is a bottleneck.

---

## 11. Other gotchas

- **Implement all 10 delegate methods** (no defaults). See section 6.
- **`Data[...]` is not `ArraySlice<UInt8>`.** Always `ArraySlice(data)`. See section 3.
- **No `getText()`/`getScrollInvariantText()` zero-arg method.** Use `getBufferAsData()` for the
  whole buffer or iterate `getScrollInvariantLine`/`getLine` + `translateToString`. Section 7.
- **`terminalDelegate` is `weak`** (`MacTerminalView.swift:96`) — keep a strong reference to
  your Coordinator (SwiftUI's `Context.coordinator` does this for you).
- **Frame drives the grid.** If tmux is authoritative about size, either drive the SwiftUI
  frame from tmux, or call `tv.resize(cols:rows:)` and ignore frame-derived `sizeChanged`
  echoes to avoid feedback loops.
- **Font has no separate size knob** — assign a fully-sized `NSFont`. Section 8.
- **8-bit `Color` init is internal** — use the 16-bit `init(red:green:blue:)` and scale
  (`*257`). Section 8.
- **macOS default-colors:** call `configureNativeColors()` (or set `nativeBackgroundColor`)
  early, otherwise the layer background may not match your theme.

---

## Appendix: source map (tag v1.13.0)

- `Package.swift:110-117` — SwiftTerm platforms (`.macOS(.v13)` min).
- `Sources/SwiftTerm/Mac/MacTerminalView.swift:41` — `open class TerminalView : NSView, …`.
- `Sources/SwiftTerm/Mac/MacTerminalView.swift:96` — `weak var terminalDelegate`.
- `Sources/SwiftTerm/Mac/MacTerminalView.swift:146` — `var terminal: Terminal!`.
- `Sources/SwiftTerm/Mac/MacTerminalView.swift:189/196` — `init(frame:font:)` / `init(frame:)`.
- `Sources/SwiftTerm/Mac/MacTerminalView.swift:558` — view's `send(source: Terminal, data:)` -> delegate.
- `Sources/SwiftTerm/Mac/MacTerminalView.swift:569` — `getOptimalFrameSize()`.
- `Sources/SwiftTerm/Mac/MacTerminalView.swift:675` — `setFrameSize` (auto-resize entry).
- `Sources/SwiftTerm/Mac/MacTerminalView.swift:2318` — `sizeChanged(source: Terminal)` -> delegate.
- `Sources/SwiftTerm/Apple/AppleTerminalView.swift:166` — `getTerminal()`.
- `Sources/SwiftTerm/Apple/AppleTerminalView.swift:174` — `processSizeChange(newSize:)` (cols/rows from frame+font).
- `Sources/SwiftTerm/Apple/AppleTerminalView.swift:310` — `installColors(_:[Color])`.
- `Sources/SwiftTerm/Apple/AppleTerminalView.swift:1916/1924` — `feed(byteArray:)` / `feed(text:)`.
- `Sources/SwiftTerm/Apple/AppleTerminalView.swift:1934` — `resize(cols:rows:)`.
- `Sources/SwiftTerm/Apple/AppleTerminalView.swift:1958-1992` — `send(data:)`/`send(txt:)`/`send(_:)`.
- `Sources/SwiftTerm/Apple/AppleTerminalView.swift:2251/2260/2265` — `getSelection()`/`selectAll()`/`selectNone()`.
- `Sources/SwiftTerm/Apple/TerminalViewDelegate.swift:12` — protocol; `:21` sizeChanged; `:37` send.
- `Sources/SwiftTerm/Terminal.swift:288` — `open class Terminal` (non-Sendable).
- `Sources/SwiftTerm/Terminal.swift:311/314` — `cols` / `rows`.
- `Sources/SwiftTerm/Terminal.swift:731/743` — `getLine` / `getScrollInvariantLine`.
- `Sources/SwiftTerm/Terminal.swift:4882/4891/4900` — engine `feed(...)`.
- `Sources/SwiftTerm/Terminal.swift:5797/5850/5869` — `BufferKind` / `getBufferAsData` / `getText`.
- `Sources/SwiftTerm/BufferLine.swift:322` — `translateToString(...)`.
- `Sources/SwiftTerm/Position.swift:11` — `Position`.
- `Sources/SwiftTerm/Colors.swift:23/322` — `Color` / `init(red:green:blue:)`.
- `Sources/SwiftTerm/TerminalOptions.swift:13` — `CursorStyle`.
- `Sources/SwiftTerm/Mac/MacLocalTerminalView.swift:67-185` — `LocalProcessTerminalView` (the one we avoid).
- `Sources/SwiftTerm/TerminalViewSearch.swift:19/40/55` — `findNext` / `findPrevious` / `clearSearch`.
