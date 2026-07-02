import AppKit
import SwiftUI

/// Presentation state for the per-session right-click menu, shared by BOTH the sidebar row and the
/// terminal area so right-clicking either surface offers the same session actions. The sheets/alerts
/// it drives are hosted ONCE at the root (`.sessionMenuHost`), so the menu keeps working even when the
/// sidebar is collapsed. Owned by `AppModel` so any view can reach it.
@MainActor
@Observable
final class SessionMenu {
    var renameTarget: ConnectionSession?
    var renameText = ""
    var envTarget: ConnectionSession?
    var restartTarget: ConnectionSession?
    var killTarget: ConnectionSession?
    var pasteConn: ConnectionSession?
    var pasteCount = 0
    // "新建分组并把此终端放进去" flow.
    var newGroupShown = false
    var newGroupName = ""
    var newGroupConn: ConnectionSession?
}

/// The shared menu items. Identical content the sidebar row used to build inline — now one source of
/// truth, dropped into `.contextMenu { SessionMenuItems(conn:) }` on both the row and the terminal.
struct SessionMenuItems: View {
    let conn: ConnectionSession
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let menu = appModel.sessionMenu
        Button("重命名…") { menu.renameText = conn.title; menu.renameTarget = conn }
        Divider()

        Button("同步当前文件夹") { conn.syncCurrentFolder() }
            .help("重新读取该终端真实的工作目录（cd 后刷新路径）")
        Button("文件管理器…") {
            if let p = conn.currentPath { openWindow(value: URL(fileURLWithPath: p)) }
        }
        .disabled(conn.host != nil || conn.currentPath == nil)
        .help(conn.host != nil ? "暂不支持远程会话" : "")
        Button("在 Finder 中打开当前文件夹") {
            if let p = conn.currentPath { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
        }
        .disabled(conn.host != nil || conn.currentPath == nil)
        .help(conn.host != nil ? "暂不支持远程会话" : "")

        Menu("分组") {
            ForEach(appModel.currentGroups) { g in
                Button {
                    appModel.assign(conn, toGroup: g.id)
                } label: {
                    appModel.group(for: conn)?.id == g.id ? Label(g.name, systemImage: "checkmark") : Label(g.name, systemImage: "")
                }
            }
            if !appModel.currentGroups.isEmpty { Divider() }
            Button("新建分组…") { menu.newGroupName = ""; menu.newGroupConn = conn; menu.newGroupShown = true }
            if appModel.group(for: conn) != nil {
                Button("移出分组") { appModel.removeFromGroups(conn) }
            }
        }
        Divider()

        Button("环境变量…") { menu.envTarget = conn }
        Button("拷贝环境变量") { appModel.copyEnvironment(conn) }
        Button("粘贴环境变量") {
            menu.pasteCount = appModel.pasteEnvironment(into: conn)
            menu.pasteConn = conn
        }
        Divider()

        Button("克隆 session") { appModel.cloneTerminal(conn) }
        Button("重启 session（重载环境变量）") { menu.restartTarget = conn }
        Divider()

        Button("关闭") { appModel.detachTerminal(conn) }                    // detach — session survives
        Button("结束 session…", role: .destructive) { menu.killTarget = conn } // kill — confirmed
    }
}

extension View {
    /// Host the per-session menu's sheets/alerts once (at the root), so the shared menu works from the
    /// sidebar AND the terminal area regardless of which is on screen.
    func sessionMenuHost(_ menu: SessionMenu, _ appModel: AppModel) -> some View {
        modifier(SessionMenuHostModifier(menu: menu, appModel: appModel))
    }
}

private struct SessionMenuHostModifier: ViewModifier {
    @Bindable var menu: SessionMenu
    let appModel: AppModel

    func body(content: Content) -> some View {
        content
            .alert("重命名终端", isPresented: optBinding(\.renameTarget)) {
                TextField("名称", text: $menu.renameText)
                Button("重命名") {
                    if let conn = menu.renameTarget { appModel.renameTerminal(conn, to: menu.renameText) }
                    menu.renameTarget = nil
                }
                Button("取消", role: .cancel) { menu.renameTarget = nil }
            }
            .alert("结束 session?", isPresented: optBinding(\.killTarget)) {
                Button("结束 session", role: .destructive) {
                    if let conn = menu.killTarget { appModel.closeTerminal(conn) }
                    menu.killTarget = nil
                }
                Button("取消", role: .cancel) { menu.killTarget = nil }
            } message: {
                Text("永久结束该 tmux 会话，下次启动不再恢复。")
            }
            .alert("重启 session?", isPresented: optBinding(\.restartTarget)) {
                Button("重启", role: .destructive) {
                    if let conn = menu.restartTarget { appModel.restartSession(conn) }
                    menu.restartTarget = nil
                }
                Button("取消", role: .cancel) { menu.restartTarget = nil }
            } message: {
                Text("重启该会话的 shell 以重新加载环境变量。会话本身保留，但当前窗格里正在运行的程序会被中断。")
            }
            .alert(menu.pasteCount > 0 ? "已粘贴环境变量" : "没有可粘贴的内容", isPresented: optBinding(\.pasteConn)) {
                if menu.pasteCount > 0 {
                    Button("重启 session 生效") {
                        if let conn = menu.pasteConn { appModel.restartSession(conn) }
                        menu.pasteConn = nil
                    }
                    Button("稍后", role: .cancel) { menu.pasteConn = nil }
                } else {
                    Button("好", role: .cancel) { menu.pasteConn = nil }
                }
            } message: {
                if menu.pasteCount > 0 {
                    Text("已合并 \(menu.pasteCount) 个环境变量到「\(menu.pasteConn?.title ?? "")」。新窗口或重启 session 后生效。")
                } else {
                    Text("剪贴板里没有可识别的 KEY=VALUE 环境变量。先在另一个会话「拷贝环境变量」，或复制 .env 格式的文本。")
                }
            }
            .alert("新建分组", isPresented: $menu.newGroupShown) {
                TextField("分组名", text: $menu.newGroupName)
                Button("创建") {
                    let name = menu.newGroupName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        appModel.newGroup(name: name)
                        if let conn = menu.newGroupConn, let g = appModel.currentGroups.last {
                            appModel.assign(conn, toGroup: g.id)
                        }
                    }
                    menu.newGroupShown = false
                }
                Button("取消", role: .cancel) { menu.newGroupShown = false }
            }
            .sheet(item: $menu.envTarget) { conn in
                EnvironmentSheet(initial: appModel.environment(for: conn), sessionName: conn.title) { env in
                    appModel.setEnvironment(env, for: conn)
                    menu.envTarget = nil
                } onSaveAndRestart: { env in
                    appModel.setEnvironment(env, for: conn)
                    conn.restartShell()
                    menu.envTarget = nil
                } onCancel: { menu.envTarget = nil }
            }
    }

    /// `isPresented` binding derived from an optional target (shown while non-nil; clearing dismisses).
    private func optBinding(_ key: ReferenceWritableKeyPath<SessionMenu, ConnectionSession?>) -> Binding<Bool> {
        Binding(get: { menu[keyPath: key] != nil }, set: { if !$0 { menu[keyPath: key] = nil } })
    }
}
