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
                    DispatchQueue.main.async { delegate.adoptMainWindow() } // 关窗驻留菜单栏(决议 #3)
                }
        }
        .commands {
            // Replace the default File ▸ Close (⌘W) so the SINGLE ⌘W in the app means "detach the
            // selected terminal", with no ambiguous second ⌘W binding fighting the window-close item.
            CommandGroup(replacing: .saveItem) {
                Button("关闭终端") {
                    if let c = appModel.selectedConnection { appModel.detachTerminal(c) }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(appModel.selectedConnection == nil)
            }
            // App/menu-level shortcuts: AppKit resolves these before the focused SwiftTerm view,
            // so ⌘-shortcuts are not swallowed by the shell.
            CommandMenu("终端") {
                Button("新建终端") { appModel.newTerminal() }
                    .keyboardShortcut("t")

                Button(appModel.tasksSelected ? "返回终端" : "任务看板") { appModel.toggleTasks() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])

                Button(appModel.sidebarCollapsed ? "显示侧栏" : "隐藏侧栏") {
                    appModel.toggleSidebar()
                }
                .keyboardShortcut("\\", modifiers: .command)

                Divider()

                Button("快速切换…") { appModel.isShowingQuickSwitch = true }
                    .keyboardShortcut("k")
                    .disabled(appModel.connections.isEmpty)

                Button("下一个终端") { appModel.selectNext() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("上一个终端") { appModel.selectPrev() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("下一个有动静的终端") { appModel.selectNextUnseen() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(appModel.connections.isEmpty)
                Button("下一个等待回复的终端") { appModel.selectNextAttention() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(appModel.attentionCount == 0)

                Divider()

                ForEach(1...9, id: \.self) { n in
                    Button("选择终端 \(n)") { appModel.selectIndex(n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")))
                }

                Divider()

                Button("搜索全部终端") { appModel.isShowingSearch = true }
                    .keyboardShortcut("f")

                Divider()

                Button("放大字号") { appModel.incFont() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("缩小字号") { appModel.decFont() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("重置字号") { appModel.resetFont() }
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var appModel: AppModel?
    private var signalSources: [DispatchSourceSignal] = []
    private var statusItem: NSStatusItem?
    private weak var mainWindow: NSWindow?

    // MARK: - 关窗驻留菜单栏(决议 #3)
    // tmux 里的 agent 7×24 跑,调度器(派发队列/attention)住在本进程 — 关掉窗口不能等于关掉
    // 调度。关闭主窗口时不销毁它:窗口隐藏、Dock 图标收起(accessory)、菜单栏留一个图标,
    // 心跳照跳;点图标(或 Dock 重开)恢复窗口。⌘Q 仍然是真正的退出(回收全部 tmux 子进程)。

    /// Find and adopt the main TFA window once it exists (called after the first frame).
    func adoptMainWindow() {
        guard mainWindow == nil else { return }
        guard let window = NSApp.windows.first(where: { $0.title == "TFA" && $0.canBecomeMain }) ?? NSApp.mainWindow
        else { return }
        mainWindow = window
        window.delegate = self
        if statusItem == nil { installStatusItem() }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "TFA")
        let menu = NSMenu()
        menu.addItem(withTitle: "打开 TFA", action: #selector(showMainWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 TFA", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    /// Closing the main window hides it instead — the app drops to a menu-bar accessory and the
    /// scheduler (dispatch queue, attention, board watch) keeps running. Other windows (file
    /// manager, settings) close normally.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow else { return true }
        sender.orderOut(nil)
        // Only vanish from the Dock when no other regular window is left visible.
        if !NSApp.windows.contains(where: { $0 !== sender && $0.isVisible && $0.canBecomeMain }) {
            NSApp.setActivationPolicy(.accessory)
        }
        return false
    }

    @objc private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// Clicking the Dock icon (when still regular) with the window hidden brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

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
