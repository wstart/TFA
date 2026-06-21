import SwiftUI

/// The content of the standard macOS `Settings` scene (⌘,), wired in `MuxApp` with the shared
/// `AppModel`. Two tabs: **General** (appearance + terminal) and **Shortcuts** (a read-only
/// cheat-sheet of every binding). The shortcuts reference lives HERE rather than behind its own ⌘/
/// panel — one place to look, and one fewer global shortcut to remember.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("通用", systemImage: "gearshape") }
            ShortcutsSettingsPane()
                .tabItem { Label("快捷键", systemImage: "keyboard") }
        }
        .frame(width: 460)
    }
}

/// General settings: appearance + terminal.
///
/// WHY route font changes through `incFont()`/`decFont()`/`resetFont()` (never a direct binding to
/// `fontSize`): only those clamp to 9–28 AND broadcast the new size to every live terminal pane; a
/// plain `Binding` would update the stored value but leave already-open terminals at the old size.
private struct GeneralSettingsPane: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var model = appModel
        Form {
            Section("外观 / Appearance") {
                Toggle("键入特效（Typing Combo）", isOn: $model.typingEffectsEnabled)
                    .accessibilityLabel("键入特效")
                Text("每次按键在光标处的粒子特效与右上角连击计数。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("终端 / Terminal") {
                LabeledContent("字号") {
                    HStack(spacing: Theme.Space.sm) {
                        Button { appModel.decFont() } label: { Image(systemName: "minus") }
                            .disabled(appModel.fontSize <= AppModel.minFontSize)
                            .accessibilityLabel("减小字号")

                        // Fixed-width, monospaced-digit readout so the −/+ buttons don't shift between
                        // e.g. "9 pt" and "13 pt".
                        Text("\(Int(appModel.fontSize)) pt")
                            .monospacedDigit()
                            .frame(minWidth: 44)
                            .accessibilityLabel("当前字号 \(Int(appModel.fontSize)) 磅")

                        Button { appModel.incFont() } label: { Image(systemName: "plus") }
                            .disabled(appModel.fontSize >= AppModel.maxFontSize)
                            .accessibilityLabel("增大字号")

                        Button("重置") { appModel.resetFont() }
                            .accessibilityLabel("重置字号")
                            .padding(.leading, Theme.Space.sm)
                    }
                }
                Text("调整后会立即应用到所有已打开的终端。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(Theme.Space.lg)
    }
}

/// Shortcuts settings: a read-only reference of every binding, grouped like the menu bar so the panel
/// reads as a map of the same commands.
private struct ShortcutsSettingsPane: View {
    /// One binding: human-readable description + the literal key symbol(s).
    private struct Shortcut: Identifiable { let id = UUID(); let keys: String; let detail: String }
    /// A titled cluster of bindings (Terminal, Navigation, …).
    private struct ShortcutGroup: Identifiable { let id = UUID(); let title: String; let shortcuts: [Shortcut] }

    // Kept declarative so adding a command is a one-line edit. ⌘/ is intentionally gone — this panel
    // now lives inside Settings (⌘,), so there's nothing to "open the shortcuts panel" with.
    private let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "Terminal", shortcuts: [
            Shortcut(keys: "⌘T", detail: "New terminal"),
            Shortcut(keys: "⌘W", detail: "Close (detach — the session keeps running)"),
            Shortcut(keys: "⌘F", detail: "Search across terminals"),
            Shortcut(keys: "⌘K", detail: "Quick switch"),
        ]),
        ShortcutGroup(title: "Navigation", shortcuts: [
            Shortcut(keys: "⌘1–9", detail: "Select the Nth terminal"),
            Shortcut(keys: "⌘⌥← / ⌘⌥→", detail: "Previous / next terminal"),
            Shortcut(keys: "⌘]", detail: "Jump to the next terminal with new output"),
        ]),
        ShortcutGroup(title: "View", shortcuts: [
            Shortcut(keys: "⌘\\", detail: "Collapse / expand the sidebar"),
            Shortcut(keys: "⌘,", detail: "Settings (this window)"),
        ]),
        ShortcutGroup(title: "Font size", shortcuts: [
            Shortcut(keys: "⌘+", detail: "Increase"),
            Shortcut(keys: "⌘-", detail: "Decrease"),
            Shortcut(keys: "⌘0", detail: "Reset"),
        ]),
        ShortcutGroup(title: "Connection", shortcuts: [
            Shortcut(keys: "⌘R", detail: "Reconnect (when failed)"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Text(group.title)
                            .font(Theme.Font.sectionHeader)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        VStack(spacing: Theme.Space.xs) {
                            ForEach(group.shortcuts) { s in
                                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.lg) {
                                    Text(s.detail).font(.callout)
                                    Spacer(minLength: Theme.Space.lg)
                                    KeyCap(symbols: s.keys)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(s.detail), \(s.keys)")
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.xl)
        }
        .frame(height: 420)
    }
}

/// A self-contained key-cap renderer: the literal key string in a monospaced caption inside a
/// rounded, faintly-filled rectangle, so a binding reads as a physical key rather than body text.
private struct KeyCap: View {
    let symbols: String

    var body: some View {
        Text(symbols)
            .font(.caption.monospaced())
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, Theme.Space.xxs)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .accessibilityHidden(true)
    }
}
