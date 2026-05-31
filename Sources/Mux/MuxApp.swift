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

        // Standard macOS Settings window (⌘,). Shares the app model so toggles/font apply live.
        Settings {
            SettingsView()
                .environment(appModel)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appModel: AppModel?
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { appModel?.shutdown() }
    }
}
