import Foundation
import SuperagentCore
import TmuxKit

/// AppModel ↔ SuperagentRuntime：执行终端出现在侧栏「工单」分组里、常驻角色的终端在「角色」分组里（不抢焦点），
/// 主管终端固定在顶部；
/// 人正在打字的终端不往里打字；进入「需要你」时发系统通知。
extension AppModel {
    /// 工单终端自动归入的分组名。
    static let ticketGroupName = "工单"
    /// 常驻角色（助理等）的终端归入的分组名。
    static let agentGroupName = "角色"
    static let routerDirKey = "superagent.routerDir"

    func startSuperagent() {
        superagent.onSessionCreated = { [weak self] name, isRouter in self?.adoptSuperagentSession(name, isRouter: isRouter) }
        superagent.userTypedRecently = { [weak self] session in
            guard let conn = self?.localConnection(named: session), let at = conn.lastUserInputAt else { return false }
            return Date().timeIntervalSince(at) < 20
        }
        superagent.postNotification = { title, body in NotificationManager.superagent(title: title, body: body) }
        superagent.start()
    }

    /// The local terminal for a tmux session name.
    func localConnection(named name: String) -> ConnectionSession? {
        connections.first { $0.host == nil && $0.controller.connection.sessionName == name }
    }

    /// The「主管」terminal, if it's open.
    var routerConnection: ConnectionSession? {
        superagent.routerSession.flatMap { localConnection(named: $0) }
    }

    /// A ticket terminal's ticket (nil for ordinary terminals).
    func ticket(for conn: ConnectionSession) -> TicketView? {
        guard conn.host == nil else { return nil }
        return superagent.ticket(forSession: conn.controller.connection.sessionName)
    }

    /// 新的执行 / 主管终端：作为休眠行加入侧栏（选中时才 attach），执行终端放进「工单」分组，
    /// 常驻角色的终端放进「角色」分组。
    func adoptSuperagentSession(_ name: String, isRouter: Bool) {
        let conn: ConnectionSession
        if let existing = localConnection(named: name) {
            conn = existing
        } else {
            guard let made = openDiscovered(sessionName: name) else { return }
            conn = made
        }
        guard !isRouter, group(for: conn) == nil else { return }
        let hostKey = HostTarget.local.persistKey
        let groupName = superagent.agentSessions.contains(name) ? Self.agentGroupName : Self.ticketGroupName
        if !groups.contains(where: { $0.name == groupName && $0.hostKey == hostKey }) {
            groups.append(TerminalGroup(name: groupName, hostKey: hostKey))
        }
        if let g = groups.first(where: { $0.name == groupName && $0.hostKey == hostKey }) { assign(conn, toGroup: g.id) }
    }

    /// 主管终端的目录（`tfa route accept` 默认的工单目录）。没设过时：选中的工作区项目 → 当前终端所在的
    /// 目录（不是家目录时）→ 家目录。家目录不能开工单，主管会用 `tfa read projects` 按名字找项目。
    var routerDirectory: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: Self.routerDirKey) { return saved }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if let project = WorkspaceStore.shared.selected?.path, !project.isEmpty { return project }
            if let cwd = selectedConnection?.currentPath, cwd != home, ticket(for: selectedConnection!) == nil { return cwd }
            return home
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.routerDirKey) }
    }

    /// 打开主管终端（没有就建一个；里面的 Claude Code 退出了就重新启动），并切过去。
    func openRouter() {
        if let conn = routerConnection { activateTerminal(conn.id) }
        let dir = routerDirectory
        Task { @MainActor in
            guard let name = await superagent.openRouter(dir: dir) else { return }
            adoptSuperagentSession(name, isRouter: true)
            if let conn = localConnection(named: name) { activateTerminal(conn.id) }
        }
    }

    /// 第 2 期事件源：普通终端（不是工单 / 主管终端）里长命令失败或 agent 请求关注 → 推断候选，
    /// 交给主管按规则研判。规则关闭或没有启用的规则时引擎直接丢弃（不打扰主管）。
    func superagentTerminalEvent(_ conn: ConnectionSession, _ what: String) {
        guard conn.host == nil, ticket(for: conn) == nil, conn.id != routerConnection?.id,
              superagent.mode != .off, superagent.rules.contains(where: \.enabled) else { return }
        let name = conn.controller.connection.sessionName
        let repo = conn.currentPath ?? ""
        superagent.terminalEvent(session: name, title: conn.title, what: what, repo: repo)
    }

    /// 跳到工单的执行终端。
    func goToTicket(_ id: Int64) {
        guard let v = superagent.views.first(where: { $0.id == id }), !v.ticket.session.isEmpty else { return }
        if localConnection(named: v.ticket.session) == nil { adoptSuperagentSession(v.ticket.session, isRouter: false) }
        if let conn = localConnection(named: v.ticket.session) { activateTerminal(conn.id) }
    }
}
