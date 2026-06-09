import AppKit
import SwiftUI

@main
struct MuxApp: App {
    @State private var appModel = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("TFA") {
            RootView()
                .environment(appModel)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    delegate.appModel = appModel
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NotificationManager.requestAuthorization()
                    appModel.start()
                }
        }
        .commands {
            // Replace the default File ▸ Close (⌘W) so the SINGLE ⌘W in the app means "detach the
            // selected terminal", with no ambiguous second ⌘W binding fighting the window-close item.
            CommandGroup(replacing: .saveItem) {
                Button("Close Terminal") {
                    if let c = appModel.selectedConnection { appModel.detachTerminal(c) }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(appModel.selectedConnection == nil)
            }
            // App/menu-level shortcuts: AppKit resolves these before the focused SwiftTerm view,
            // so ⌘-shortcuts are not swallowed by the shell.
            CommandMenu("Terminal") {
                Button("New Terminal") { appModel.newTerminal() }
                    .keyboardShortcut("t")

                Button(appModel.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") {
                    appModel.toggleSidebar()
                }
                .keyboardShortcut("\\", modifiers: .command)

                Divider()

                Button("Quick Switch…") { appModel.isShowingQuickSwitch = true }
                    .keyboardShortcut("k")
                    .disabled(appModel.connections.isEmpty)

                Button("Next Terminal") { appModel.selectNext() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Previous Terminal") { appModel.selectPrev() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Next Active Terminal") { appModel.selectNextUnseen() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(appModel.connections.isEmpty)
                Button("下一个待处理终端") { appModel.selectNextAttention() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(appModel.attentionCount == 0)

                Divider()

                Button("分屏（与下一个并排）") { appModel.splitWithNext() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(appModel.connections.count < 2 || appModel.splitConnections.count >= 4)
                Button("退出分屏") { appModel.clearSplit() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(!appModel.isSplit)
                ForEach(1...9, id: \.self) { n in
                    Button("Select Terminal \(n)") { appModel.selectIndex(n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")))
                }

                Divider()

                Button("Find") { appModel.isShowingSearch = true }
                    .keyboardShortcut("f")

                Divider()

                Button("Increase Font Size") { appModel.incFont() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Decrease Font Size") { appModel.decFont() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Reset Font Size") { appModel.resetFont() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }

        // File-manager windows, opened from a session's right-click menu via `openWindow(value:)`.
        // Each distinct root path gets its own window (same path re-focuses the existing one).
        WindowGroup("文件管理器", for: URL.self) { $url in
            if let url { FileExplorerView(root: url) }
        }

        // Standard macOS Settings window (⌘,). Shares the app model so toggles/font apply live.
        Settings {
            SettingsView()
                .environment(appModel)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appModel: AppModel?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A raw SIGTERM (`pkill TFA`, a crash-reporter kill) or SIGINT does NOT run
        // applicationWillTerminate — so our spawned `tmux -CC` children (each a setsid session
        // leader holding a pty) would orphan to launchd and accumulate across restarts until the
        // system pty limit is hit and no terminal can open. Trap those signals and run the same
        // clean shutdown (which SIGTERMs every child) before exiting. SIGKILL is uncatchable —
        // the Lab's PTY monitor cleans up any that still slip through.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN) // ignore default disposition; the dispatch source handles it instead
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.appModel?.shutdown() }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { appModel?.shutdown() }
    }
}
