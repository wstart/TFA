import Foundation
import notify
import Observation
import SuperagentCore

/// Superagent 在 App 里的执行层：Pass 循环（每 2 秒 + `tfa` 提交后立即，单飞）执行引擎排进 effect 表的
/// 副作用——启动执行终端、把消息送进终端、把回报转给主管、中断、通知——再把结果回报给引擎。
/// 领域状态只在 `superagent.db`；这里只缓存读视图给界面用。
@MainActor
@Observable
final class SuperagentRuntime {
    // MARK: 读视图（界面）

    private(set) var views: [TicketView] = []
    /// 连续失败 ≥3 次的副作用（面板的「问题」列表）。
    private(set) var problems: [Effect] = []
    private(set) var decisions: [Decision] = []
    private(set) var settings = Settings()
    private(set) var rules: [Rule] = []
    private(set) var mode: AcceptMode = .observe
    private(set) var policyVersion = ""
    private(set) var schedules: [Schedule] = []
    private(set) var roles: [Role] = Role.builtins
    /// 常驻角色的终端（会话名）：侧栏把它们归进「角色」分组。
    private(set) var agentSessions: Set<String> = []
    /// 「主管」终端的 tmux 会话名（没开 = nil）。
    private(set) var routerSession: String?
    /// 打开数据库失败等：面板顶部显示。
    private(set) var setupError: String?

    var needsYou: [TicketView] {
        views.filter { $0.stage.needsPerson != nil }.sorted { ($0.stage.needsPerson!, -$0.id) < ($1.stage.needsPerson!, -$1.id) }
    }
    var openTickets: [TicketView] { views.filter { $0.ticket.isOpen } }

    /// 某个终端（会话名）对应的工单。常驻角色的终端先后处理多张单：等人的优先，然后是打开的，最后是最近结束的。
    func ticket(forSession name: String) -> TicketView? {
        let mine = views.filter { $0.ticket.session == name && !$0.ticket.session.isEmpty }
        return mine.first { $0.stage.needsPerson != nil } ?? mine.first { $0.ticket.isOpen } ?? mine.first
    }

    /// 工单的角色（角色被删了就按「开发」）。
    func role(for t: Ticket) -> Role {
        roles.first { $0.name == t.role } ?? Role.builtins.first { $0.name == Role.developer }!
    }

    // MARK: 依赖（AppModel 注入；测试注入假的）

    @ObservationIgnored private(set) var engine: SuperagentEngine?
    @ObservationIgnored var tmux = SuperagentTmux()
    /// 新建了执行 / 主管终端 → 让侧栏出现它（不抢焦点）。
    @ObservationIgnored var onSessionCreated: ((_ name: String, _ isRouter: Bool) -> Void)?
    /// 人刚在这个终端里打过字 → 先别往里打（会和人的输入混在一起）。
    @ObservationIgnored var userTypedRecently: ((_ session: String) -> Bool)?
    @ObservationIgnored var postNotification: ((_ title: String, _ body: String) -> Void)?
    /// 执行终端里启动 agent 的命令行（kickoff = 第一条消息）。nil = Claude Code，按工单的角色。
    @ObservationIgnored var workerCommand: ((_ ticket: Ticket, _ kickoff: String) -> String)?
    @ObservationIgnored var routerCommand: () -> String = SuperagentRuntime.claudeRouterCommand
    /// 送达后等回显的时间（测试可调小）。
    @ObservationIgnored var echoWait: Double = 2.0
    /// agent 启动的最长等待。
    @ObservationIgnored var launchWait: Double = 15
    @ObservationIgnored var worktreeRoot = SuperagentPaths.worktreesDir
    /// 常驻角色各自的目录：`<agentsRoot>/<角色>`。
    @ObservationIgnored var agentsRoot = SuperagentPaths.agentsDir
    @ObservationIgnored var clock: () -> Double = { Date().timeIntervalSince1970 }

    @ObservationIgnored private var passing = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var notifyToken: Int32 = 0
    @ObservationIgnored private var lostPasses: [Int64: Int] = [:]
    @ObservationIgnored private var exitedPasses: [Int64: Int] = [:]
    /// 副作用第一次撞上对话框的时间（-1 = 已经报过）。
    @ObservationIgnored private var dialogSince: [String: Double] = [:]
    /// 往已有终端里重新打启动命令的时间（按窗格）：30 秒内不叠着再打。
    @ObservationIgnored private var retypedAt: [String: Double] = [:]
    @ObservationIgnored private var routerTypedAt = Date.distantPast
    @ObservationIgnored private var routerOpening: Task<String?, Never>?
    @ObservationIgnored private var lastVersion: Int64 = -1
    @ObservationIgnored private var passCount = 0

    init() {}

    // MARK: - 启动

    /// 打开数据库、安装 prompt 与 `tfa` 命令、开始 Pass 循环。
    func start(store: SuperagentStore? = nil, installTools: Bool = true, interval: Double = 2) {
        guard engine == nil else { return }
        do {
            engine = SuperagentEngine(store: try store ?? SuperagentStore())
        } catch {
            setupError = "工单数据库打不开：\(error)"
            return
        }
        if installTools { installSupport() }
        reload()
        let name = SuperagentPaths.changedNotification
        notify_register_dispatch(name, &notifyToken, DispatchQueue.main) { [weak self] (_: Int32) in
            MainActor.assumeIsolated { self?.kick() }
        }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.pass()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopLoop() {
        loop?.cancel()
        loop = nil
        if notifyToken != 0 { notify_cancel(notifyToken); notifyToken = 0 }
    }

    /// prompt 文件 + `~/.tfa/bin/tfa` → App 包里的 `tfa`（开发构建：和 Mux 同目录）。
    private func installSupport() {
        let acceptance = settings.acceptance, roles = roles
        Task.detached(priority: .utility) {
            SuperagentPrompts.install(acceptance: acceptance, roles: roles)
            Self.installCLI()
        }
    }

    nonisolated static func installCLI() {
        guard let exe = bundledCLI() else { return }
        let fm = FileManager.default
        let link = SuperagentPaths.binDir.appendingPathComponent("tfa")
        try? fm.createDirectory(at: SuperagentPaths.binDir, withIntermediateDirectories: true)
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path), dest == exe.path { return }
        try? fm.removeItem(at: link)
        try? fm.createSymbolicLink(at: link, withDestinationURL: exe)
    }

    /// App 包里是 `Contents/Helpers/tfa`；开发构建（swift run）在 Mux 旁边。磁盘默认不区分大小写，
    /// `Contents/MacOS/tfa` 就是 App 自己（TFA）——绝不能把它当成命令行链出去。
    nonisolated static func bundledCLI() -> URL? {
        let fm = FileManager.default
        let app = Bundle.main.executableURL?.resolvingSymlinksInPath().path.lowercased()
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tfa"),
                          Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("tfa")].compactMap { $0 }
        return candidates.first {
            fm.isExecutableFile(atPath: $0.path) && $0.resolvingSymlinksInPath().path.lowercased() != app
        }
    }

    /// 立刻跑一轮（`tfa` 提交、界面操作之后）。
    func kick() { Task { @MainActor in await self.pass() } }

    // MARK: - 人的操作（界面）

    /// 通过：有工单分支就先把它合并进主仓库当前分支，合并成功才结单；合并不了工单留在「待评审」，
    /// 原因放进 `mergeError`。返回的 Task 给测试等结果。
    @discardableResult
    func approve(_ id: Int64) -> Task<Void, Never> {
        Task { @MainActor in
            guard let engine = self.engine, !self.merging.contains(id), let t = try? engine.store.ticket(id), t.isOpen else { return }
            guard !t.branch.isEmpty else { return self.act { try $0.approve(id) } }
            self.merging.insert(id)
            let message = "Merge \(t.branch) (#\(id) \(t.title))"
            let result = await Task.detached(priority: .userInitiated) {
                Result { try SuperagentTmux.mergeBranch(repo: t.repo, branch: t.branch, dir: t.dir, message: message) }
            }.value
            self.merging.remove(id)
            switch result {
            case .success(let note): self.act { try $0.approve(id, merged: note) }
            case .failure(let e): self.mergeError = "工单 #\(id) 仍在待评审：\(e)"
            }
        }
    }
    func feedback(_ id: Int64, _ text: String) { act { try $0.feedback(id, text: text) } }
    func stop(_ id: Int64) { act { try $0.stop(id, by: "你") } }
    func retry(_ id: Int64) { act { try $0.retry(id) } }
    func setRules(_ r: [Rule]) { act { try $0.setRules(r) } }
    func setMode(_ m: AcceptMode) { act { try $0.setMode(m) } }
    func setSchedules(_ s: [Schedule]) { act { try $0.setSchedules(s) } }
    func saveSettings(_ s: Settings) {
        let acceptanceChanged = s.acceptance != settings.acceptance
        act { try $0.store.saveSettings(s) }
        let roles = roles
        if acceptanceChanged { Task.detached(priority: .utility) { SuperagentPrompts.install(acceptance: s.acceptance, roles: roles) } }
    }

    /// 新建 / 更新 / 删除角色（面板）。
    func setRole(_ r: Role) { act { _ = try $0.setRole(r) } }
    func deleteRole(_ name: String) { act { try $0.deleteRole(name) } }

    /// 最近一次操作的错误（界面弹出后清掉）。
    var actionError: String?
    /// 正在合并工单分支的工单（「通过」按钮显示「合并中…」）。
    private(set) var merging: Set<Int64> = []
    /// 点「通过」却没能合并的原因（根视图弹窗显示，关掉后清空）。
    var mergeError: String?

    private func act(_ body: (SuperagentEngine) throws -> Void) {
        guard let engine else { return }
        do { try body(engine) } catch { actionError = "\(error)" }
        reload()
        kick()
    }

    /// 终端事件 → 候选（附最后几行输出）。
    func terminalEvent(session: String, title: String, what: String, repo: String) {
        guard let engine, !repo.isEmpty else { return }
        let tmux = self.tmux
        Task { @MainActor in
            let tail = await Task.detached(priority: .utility) { tmux.tail("=\(session):", lines: 8) }.value
            let text = "终端「\(title)」\(what)。最后输出：\(tail.replacingOccurrences(of: "\n", with: " ⏎ "))"
            _ = try? engine.candidate(source: "terminal:\(session)", text: text, repo: repo)
            self.reload()
            self.kick()
        }
    }

    func events(_ id: Int64) -> [TimelineEvent] { (try? engine?.store.events(ticketID: id, limit: 80)) ?? [] }
    func inputs(_ id: Int64) -> [TicketInput] { (try? engine?.store.inputs(id)) ?? [] }

    // MARK: - 主管终端

    /// 打开（或建）「主管」终端：Claude Code，只允许 `tfa` 命令、禁用编辑。返回会话名。
    func openRouter(dir: String) async -> String? {
        // 连点两下：第二次等第一次的结果，不并发建两个（同名会话会建失败）。
        if let inFlight = routerOpening { return await inFlight.value }
        let task = Task { @MainActor in await self.openRouterOnce(dir: dir) }
        routerOpening = task
        defer { routerOpening = nil }
        return await task.value
    }

    private func openRouterOnce(dir: String) async -> String? {
        let tmux = self.tmux
        let command = routerCommand()
        // 30 秒内刚打过启动命令：shell 可能还没执行它，别再打一遍（会拼成一行）。
        let mayRetype = Date().timeIntervalSince(routerTypedAt) > 30
        routerTypedAt = Date()
        let made = await Task.detached(priority: .userInitiated) { Self.makeRouter(tmux, dir: dir, command: command, mayRetype: mayRetype) }.value
        switch made {
        case .success(let name):
            if routerSession != name { routerSession = name }
            onSessionCreated?(name, true)
            return name
        case .failure(let e):
            actionError = "\(e)"
            return nil
        }
    }

    // MARK: - Pass

    func pass() async {
        if passing { again = true; return }
        passing = true
        defer { passing = false }
        repeat {
            again = false
            await passOnce()
        } while again
    }

    private func passOnce() async {
        guard let engine else { return }
        let store = engine.store
        _ = try? engine.fireSchedules(at: Date(timeIntervalSince1970: clock()))
        _ = try? engine.expireCandidates()
        let open = (try? store.tickets(endedLimit: 0)) ?? []
        let due = (try? store.dueEffects(now: clock())) ?? []
        passCount &+= 1
        // 没有打开的工单、没有到期的副作用：一次 SQLite 查询就结束，不 fork tmux（偶尔查一下主管终端还在不在）。
        guard !open.isEmpty || !due.isEmpty || passCount % 15 == 1 else { reloadIfChanged(); return }
        let tmux = self.tmux
        let snap = await Task.detached(priority: .utility) { tmux.snapshot() }.value
        if let snap {
            let router = snap.first(where: \.isRouter)?.session
            if router != routerSession { routerSession = router }
            let agents = Set(snap.filter { $0.agent != nil }.map(\.session))
            if agents != agentSessions { agentSessions = agents }
        }
        await reconcile(open: open, snap: snap)
        // 先通知 / 中断 / 转达 / 送达，最后才启动新的（唤醒优先于新建）。
        let order: [EffectKind] = [.notify, .stop, .relay, .deliver, .launch]
        let ready = ((try? store.dueEffects(now: clock())) ?? []).sorted {
            (order.firstIndex(of: $0.kind)!, $0.createdAt) < (order.firstIndex(of: $1.kind)!, $1.createdAt)
        }
        for e in ready {
            let outcome = await perform(e, snap: snap)
            switch outcome {
            case .done: try? store.completeEffect(e)
            case .later(let s): try? store.deferEffect(e, until: clock() + s)
            case .failed(let msg):
                if let n = try? store.failEffect(e, error: msg, now: clock()) { try? engine.effectFailed(e, error: msg, attempts: n) }
            }
        }
        reload()
    }

    /// 与 tmux 对账：会话没了 → sessionLost；agent 退出 → agentExited；停下没回报 → workerIdle。
    /// 都要连续两轮看到才算（避开启动瞬间和一次性的查询失败）。
    private func reconcile(open: [Ticket], snap: [SuperagentPane]?) async {
        guard let engine, let snap else { return }
        let now = clock()
        let launching = Set(((try? engine.store.effects()) ?? []).filter { $0.kind == .launch }.compactMap { Int64($0.key) })
        for t in open {
            guard let view = try? engine.view(t), let a = view.assignment, a.state == .running, !launching.contains(t.id) else {
                lostPasses[t.id] = nil; exitedPasses[t.id] = nil
                continue
            }
            guard let pane = pane(for: t, in: snap) else {
                lostPasses[t.id, default: 0] += 1
                if lostPasses[t.id]! >= 2 { lostPasses[t.id] = nil; try? engine.sessionLost(t.id) }
                continue
            }
            lostPasses[t.id] = nil
            if pane.isPlainShell {
                exitedPasses[t.id, default: 0] += 1
                if exitedPasses[t.id]! >= 2 {
                    exitedPasses[t.id] = nil
                    let tail = await tailOf(pane.pane)
                    try? engine.agentExited(t.id, lastOutput: tail)
                }
                continue
            }
            exitedPasses[t.id] = nil
            guard view.stage == .working(queued: false), view.pendingInputs == 0 else { continue }
            let quiet = now - Double(pane.activity)
            let sinceTurn = now - (t.turnAt ?? a.startedAt ?? now)
            if quiet >= settings.idleSeconds, sinceTurn >= settings.idleSeconds {
                let tail = await tailOf(pane.pane)
                try? engine.workerIdle(t.id, lastOutput: tail)
            }
        }
    }

    private func tailOf(_ target: String) async -> String {
        let tmux = self.tmux
        return await Task.detached(priority: .utility) { tmux.tail(target) }.value
    }

    // MARK: - 副作用

    enum Outcome: Equatable {
        case done
        /// 稍后再试（不计失败），秒。
        case later(Double)
        case failed(String)
    }

    private func perform(_ e: Effect, snap: [SuperagentPane]?) async -> Outcome {
        guard let engine else { return .later(5) }
        switch e.kind {
        case .notify:
            if let id = Int64(e.key), let n = try? engine.takeNotification(id) { postNotification?(n.title, n.body) }
            return .done
        case .stop:
            // 快照偶尔失败：停止命令不能丢，稍后再来。
            guard let snap else { return .later(3) }
            guard let id = Int64(e.key), let t = try? engine.store.ticket(id), let pane = pane(for: t, in: snap) else { return .done }
            // 常驻 Agent 已经在做别的单了：不打断它。
            if role(for: t).standing, (try? engine.agentBusy(t.role, excluding: id)) ?? true { return .done }
            let tmux = self.tmux
            await Task.detached { Self.interrupt(tmux, pane.pane) }.value
            return .done
        case .relay:
            return await performRelay(e, snap: snap)
        case .deliver:
            guard let id = Int64(e.key) else { return .done }
            return await performDeliver(e, id, snap: snap)
        case .launch:
            guard let id = Int64(e.key) else { return .done }
            return await performLaunch(id, snap: snap)
        }
    }

    /// 终端能不能落键：agent 在跑、此刻没输出、人最近没在里面打字。
    private func gate(_ pane: SuperagentPane) -> Outcome? {
        if pane.isPlainShell { return .later(5) }
        if clock() - Double(pane.activity) < Self.busyWindow { return .later(2) }
        if userTypedRecently?(pane.session) == true { return .later(5) }
        return nil
    }

    /// 最近这么多秒内有输出 = 忙（agent 正在出字，打进去会被吞或打断）。
    nonisolated static let busyWindow: Double = 4
    /// 对话框持续这么久没人处理：不再默默等，进「需要你」/ 通知人。
    static let dialogPatience: Double = 180

    private func performLaunch(_ id: Int64, snap: [SuperagentPane]?) async -> Outcome {
        guard let engine, let snap else { return .later(3) }
        guard let t = try? engine.store.ticket(id), t.isOpen else { return .done }
        guard let a = try? engine.store.latestAssignment(id), a.state == .pending else { return .done }
        // 槽位：默认 3 个并发；人的跟进 / 重试 / 恢复额外 +1。
        let wake = a.reason != "accepted"
        let busy = (try? engine.busyCount(excluding: id)) ?? 0
        if busy >= settings.slots + (wake ? 1 : 0) { return .later(3) }
        let role = role(for: t)
        // 每次启动前写好角色的 prompt：角色可能刚由主管新建，或被人改过。
        if workerCommand == nil { _ = try? SuperagentPrompts.installRole(role, acceptance: settings.acceptance) }
        if role.standing { return await performStandingLaunch(t, a, role, snap: snap) }

        let tmux = self.tmux
        let root = worktreeRoot
        let existing = snap.first { $0.ticket == id }
        let kickoff = "[TFA #\(id)] 你负责工单 #\(id)「\(t.title)」。先运行 tfa read ticket 读取请求原文和全部消息，然后开始。"
        let commandLine = command(t, role, kickoff)
        let wait = launchWait
        let taken = Set(snap.map(\.session))
        let sentAt = clock()
        let key = existing?.pane ?? ""
        let mayRetype = key.isEmpty || clock() - (retypedAt[key] ?? 0) > 30
        if existing?.isPlainShell == true {
            guard mayRetype else { return .later(10) } // 上一次打的启动命令还没跑起来
            retypedAt[key] = clock()
        }
        let result = await Task.detached(priority: .userInitiated) {
            Self.launch(tmux, ticket: t, existing: existing, taken: taken, root: root, commandLine: commandLine, wait: wait, mayRetype: mayRetype)
        }.value
        switch result {
        case .success(let r):
            do { try engine.launched(id, session: r.session, dir: r.dir, branch: r.branch, agentStarted: r.started, sentAt: sentAt) }
            catch { return .failed("\(error)") }
            if r.created { onSessionCreated?(r.session, false) }
            return .done
        case .failure(let e):
            return .failed("\(e)")
        }
    }

    /// 常驻角色：一个终端先后处理这个角色的所有单，一次一张。终端没有（或 agent 退出了）就按角色定义
    /// 生成它；它在跑就把新单的开场白打进去。同一终端里已经知道的单（跟进 / 重试）交给 deliver。
    private func performStandingLaunch(_ t: Ticket, _ a: Assignment, _ role: Role, snap: [SuperagentPane]) async -> Outcome {
        guard let engine else { return .later(3) }
        let id = t.id
        if (try? engine.agentBusy(role.name, excluding: id)) ?? true { return .later(3) }
        // 快照可能是这一轮开头的：同一轮里前一张单也许刚建了这个角色的终端。
        let tmux = self.tmux
        let live = await Task.detached(priority: .userInitiated) { tmux.snapshot() }.value ?? snap
        let existing = live.first { $0.agent == role.name }
        let kickoff = "[TFA #\(id)·a\(a.id)] 新工单 #\(id)「\(t.title)」交给你（\(role.name)）。先运行 tfa read ticket \(id) 读取请求原文和全部消息，然后开始；本单的 tfa 命令都带 --ticket \(id)。"
        let dir = agentsRoot.appendingPathComponent(role.name, isDirectory: true).path
        let sentAt = clock()
        if let pane = existing, !pane.isPlainShell {
            // 同一会话里已经交给过它的单：排队的消息走 deliver（开头带工单号）。
            if a.reason != "accepted", pane.session == t.session {
                do { try engine.launched(id, session: pane.session, dir: dir, branch: "", agentStarted: false, sentAt: sentAt) }
                catch { return .failed("\(error)") }
                return .done
            }
            if let wait = gate(pane) { return wait }
            switch await typeAndVerify(pane.pane, kickoff, marker: "#\(id)·a\(a.id)") {
            case .dialog:
                if dialogStuck(key: EffectKind.launch.rawValue + String(id)) {
                    try? engine.deliveryBlocked(id, reason: "「\(role.name)」的终端在等人确认一个对话框，新工单送不进去")
                }
                return .later(5)
            case .notReady: return .later(3)
            case .notEchoed: return .failed("没有在「\(role.name)」的终端 \(pane.session) 里看到新工单的开场白")
            case .delivered: break
            }
            dialogSince[EffectKind.launch.rawValue + String(id)] = nil
            do { try engine.launched(id, session: pane.session, dir: dir, branch: "", agentStarted: true, sentAt: sentAt) }
            catch { return .failed("\(error)") }
            return .done
        }
        // 还没有这个角色的终端（或里面的 agent 退出了）：按角色定义生成。
        let commandLine = command(t, role, kickoff)
        let wait = launchWait
        let key = existing?.pane ?? ""
        let mayRetype = key.isEmpty || clock() - (retypedAt[key] ?? 0) > 30
        if existing != nil {
            guard mayRetype else { return .later(10) }
            retypedAt[key] = clock()
        }
        let name = role.name
        let result = await Task.detached(priority: .userInitiated) {
            Self.launch(tmux, ticket: t, existing: existing, taken: Set(live.map(\.session)), root: URL(fileURLWithPath: dir),
                        commandLine: commandLine, wait: wait, mayRetype: mayRetype, agent: name)
        }.value
        switch result {
        case .success(let r):
            do { try engine.launched(id, session: r.session, dir: r.dir, branch: "", agentStarted: r.started, sentAt: sentAt) }
            catch { return .failed("\(error)") }
            if r.created {
                agentSessions.insert(r.session)
                onSessionCreated?(r.session, false)
            }
            return .done
        case .failure(let e):
            return .failed("\(e)")
        }
    }

    private func performDeliver(_ e: Effect, _ id: Int64, snap: [SuperagentPane]?) async -> Outcome {
        guard let engine, let snap else { return .later(3) }
        guard let t = try? engine.store.ticket(id), t.isOpen else { return .done }
        let pending = (try? engine.store.undelivered(id)) ?? []
        guard let last = pending.last else { return .done }
        guard let pane = pane(for: t, in: snap) else { return .later(5) }
        // 常驻 Agent 在做别的单：跟进等它这一轮结束再送。
        if role(for: t).standing, (try? engine.agentBusy(t.role, excluding: id)) ?? true { return .later(3) }
        if let wait = gate(pane) { return wait }
        // 唤醒一个已经停下（交付 / 受阻 / 失败 / 未回报）的工单：占一个槽，人的跟进可以多用 1 个。
        if [.ready, .blocked, .failed, .waiting].contains(t.reportState),
           ((try? engine.busyCount(excluding: id)) ?? 0) >= settings.slots + 1 { return .later(3) }
        let marker = "[TFA #\(id)·i\(last.id)]"
        var body = pending.map(\.text).joined(separator: " ｜ ")
        if body.count > 1500 { body = String(body.prefix(1500)) + "…（完整内容：tfa read ticket）" }
        let sentAt = clock()
        switch await typeAndVerify(pane.pane, "\(marker) \(body)", marker: "#\(id)·i\(last.id)") {
        case .dialog:
            if dialogStuck(e) { try? engine.deliveryBlocked(id, reason: "执行终端在等人确认一个对话框，消息送不进去") }
            return .later(5)
        case .notReady: return .later(3)
        case .notEchoed: return .failed("没有在执行终端 \(pane.session) 里看到送达的消息")
        case .delivered: break
        }
        dialogSince[e.kind.rawValue + e.key] = nil
        try? engine.delivered(id, inputIDs: pending.map(\.id), sentAt: sentAt)
        return .done
    }

    private func performRelay(_ e: Effect, snap: [SuperagentPane]?) async -> Outcome {
        guard let engine, let snap else { return .later(3) }
        let relays = (try? engine.store.pendingRelays()) ?? []
        guard let last = relays.last else { return .done }
        // 主管没开：消息留着，等它开了再送（不算失败）。
        guard let pane = snap.first(where: \.isRouter) else { return .later(10) }
        if let wait = gate(pane) { return wait }
        // 每批一个唯一标记：同一工单的几种回报开头一样，只看开头会把上一批的回显当成这一批。
        let marker = "[TFA·r\(last.id)]"
        var text = marker + " " + relays.map(\.text).joined(separator: " ｜ ")
        if text.count > 3000 { text = String(text.prefix(3000)) + "…（用 tfa read 查看全部）" }
        switch await typeAndVerify(pane.pane, text, marker: marker) {
        case .dialog:
            if dialogStuck(e) { postNotification?("主管在等你确认", "主管终端里有一个对话框，工单的回报暂时送不进去。") }
            return .later(5)
        case .notReady: return .later(3)
        case .notEchoed: return .failed("没有在主管终端里看到转达的消息")
        case .delivered: break
        }
        dialogSince[e.kind.rawValue + e.key] = nil
        try? engine.relayed(relays.map(\.id))
        return .done
    }

    /// 同一个副作用连续撞上对话框超过 `dialogPatience`：只报一次。
    private func dialogStuck(_ e: Effect) -> Bool { dialogStuck(key: e.kind.rawValue + e.key) }

    private func dialogStuck(key: String) -> Bool {
        guard let since = dialogSince[key] else { dialogSince[key] = clock(); return false }
        guard since > 0, clock() - since >= Self.dialogPatience else { return false }
        dialogSince[key] = -1 // 报过了；送达后清掉
        return true
    }

    /// 打字送入并核验：稍等后在窗格里找标记（「已发送」≠「已送达」）。
    private func typeAndVerify(_ target: String, _ text: String, marker: String) async -> Typed {
        let tmux = self.tmux
        let wait = echoWait
        return await Task.detached(priority: .userInitiated) {
            Self.typeAndCheck(tmux, target, text: text, marker: marker, wait: wait)
        }.value
    }

    // 阻塞的 tmux 步骤（在后台线程上跑）。

    nonisolated static func makeRouter(_ tmux: SuperagentTmux, dir: String, command: String, mayRetype: Bool) -> Result<String, Error> {
        let snap = tmux.snapshot() ?? []
        if let existing = snap.first(where: \.isRouter) {
            // 主管终端还在，但 Claude Code 已经退出（回到 shell）：重新启动它。
            if existing.isPlainShell, mayRetype { tmux.type(existing.pane, "cd \(SuperagentTmux.quote(dir)) && \(command)") }
            return .success(existing.session)
        }
        let name = SuperagentTmux.sessionName("主管", taken: Set(snap.map(\.session)))
        do {
            _ = try tmux.newSession(name: name, dir: dir, router: true, command: command)
            return .success(name)
        } catch { return .failure(error) }
    }

    enum Typed { case delivered, notEchoed, dialog, notReady }

    nonisolated static func typeAndCheck(_ tmux: SuperagentTmux, _ target: String, text: String, marker: String, wait: Double) -> Typed {
        // 快照可能是十几秒前的：落键前再确认一次 agent 还在、此刻没在出字。
        guard let state = tmux.paneState(target), !SuperagentPane.isShell(state.command),
              Date().timeIntervalSince1970 - Double(state.activity) >= busyWindow else { return .notReady }
        // 对话框（信任文件夹 / 权限确认）开着：打字 + 回车会替人选项，等人处理完。
        if SuperagentTmux.showsDialog(tmux.capture(target, lines: 40)) { return .dialog }
        tmux.type(target, text)
        Thread.sleep(forTimeInterval: wait)
        return tmux.capture(target, lines: 400).contains(marker) ? .delivered : .notEchoed
    }

    nonisolated static func interrupt(_ tmux: SuperagentTmux, _ target: String) {
        tmux.sendKey(target, "Escape")
        Thread.sleep(forTimeInterval: 0.3)
        tmux.sendKey(target, "Escape")
    }

    typealias Launched = (session: String, dir: String, branch: String, started: Bool, created: Bool)

    /// 准备目录 → 找到或建执行终端 → 前台是 shell 就打入 agent 命令并等它起来。
    /// `agent` = 常驻角色的名字：终端以角色命名、打上 `@tfa_agent`，目录就是 `root`（角色自己的目录）。
    nonisolated static func launch(_ tmux: SuperagentTmux, ticket t: Ticket, existing: SuperagentPane?, taken: Set<String>,
                                   root: URL, commandLine: String, wait: Double, mayRetype: Bool = true,
                                   agent: String? = nil) -> Result<Launched, Error> {
        do {
            var dir = t.dir, branch = t.branch
            if agent != nil {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                (dir, branch) = (root.path, "")
            } else if dir.isEmpty || !FileManager.default.fileExists(atPath: dir) {
                (dir, branch) = try SuperagentTmux.prepareDirectory(repo: t.repo, ticket: t.id, worktree: t.worktree, root: root,
                                                                    fresh: t.dir.isEmpty)
            }
            var session = existing?.session ?? ""
            var target = existing?.pane ?? ""
            var created = false
            if existing == nil {
                session = SuperagentTmux.sessionName(agent ?? "工单\(t.id)·\(t.title.prefix(14))", taken: taken)
                target = try tmux.newSession(name: session, dir: dir, ticket: agent == nil ? t.id : nil, agent: agent, command: commandLine)
                created = true
            }
            if let p = existing, !p.isPlainShell { return .success((session, dir, branch, false, false)) }
            if !created {
                // 已有终端回到了 shell：在里面重新启动 agent。上一次打的命令可能还没执行完——不叠着再打。
                guard mayRetype else { throw SuperagentTmux.Failure(description: "刚打过启动命令，等它起来") }
                tmux.run(["send-keys", "-t", target, "-X", "cancel"]) // 在 copy-mode 里就先退出
                tmux.type(target, "cd \(SuperagentTmux.quote(dir)) && \(commandLine)")
            }
            let deadline = Date().addingTimeInterval(wait)
            var startedAt: Date?
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
                if startedAt == nil, let state = tmux.paneState(target), !SuperagentPane.isShell(state.command) {
                    startedAt = Date()
                }
                guard let since = startedAt else { continue }
                // Claude Code 对 TFA 新建的工单目录会先问「是否信任此文件夹」（默认选项是退出）。这个目录是
                // 人要求改的仓库的 worktree，执行终端本就是全部放行：只确认说的正是这个目录的信任框。
                let screen = tmux.capture(target, lines: 40)
                if SuperagentTmux.showsTrustDialog(screen, for: dir) {
                    tmux.sendKey(target, "Down")
                    Thread.sleep(forTimeInterval: 0.2)
                    tmux.sendKey(target, "Enter")
                    Thread.sleep(forTimeInterval: 1)
                    continue
                }
                // 起来了、没有挡路的对话框：再观察几秒（信任框在启动后才画出来），然后交给 Pass。
                if Date().timeIntervalSince(since) >= 5 { return .success((session, dir, branch, true, created)) }
            }
            if startedAt != nil { return .success((session, dir, branch, true, created)) }
            throw SuperagentTmux.Failure(description: "agent 没有启动（\(session) 前台仍是 shell）：\(tmux.tail(target, lines: 3))")
        } catch { return .failure(error) }
    }


    // MARK: - 读视图

    private func reloadIfChanged() {
        guard let engine, engine.store.dataVersion != lastVersion else { return }
        reload()
    }

    func reload() {
        guard let engine else { return }
        let store = engine.store
        lastVersion = store.dataVersion
        let v = (try? engine.views()) ?? []
        if v != views { views = v }
        let p = ((try? store.effects()) ?? []).filter(\.isProblem)
        if p != problems { problems = p }
        let d = (try? store.decisions(limit: 40)) ?? []
        if d != decisions { decisions = d }
        let s = (try? store.settings()) ?? Settings()
        if s != settings { settings = s }
        let r = (try? store.rules()) ?? []
        if r != rules { rules = r }
        let m = (try? store.acceptMode()) ?? .observe
        if m != mode { mode = m }
        let pv = (try? store.policyVersion()) ?? ""
        if pv != policyVersion { policyVersion = pv }
        let sc = (try? store.schedules()) ?? []
        if sc != schedules { schedules = sc }
        let ro = (try? store.roles()) ?? Role.builtins
        if ro != roles { roles = ro }
    }

    /// 工单的 agent 窗格：每单角色认 `@tfa_ticket`，常驻角色认 `@tfa_agent`。
    func pane(for t: Ticket, in snap: [SuperagentPane]) -> SuperagentPane? {
        role(for: t).standing ? snap.first { $0.agent == t.role } : snap.first { $0.ticket == t.id }
    }

    private func command(_ t: Ticket, _ role: Role, _ kickoff: String) -> String {
        workerCommand?(t, kickoff) ?? Self.claudeWorkerCommand(t, role: role, kickoff: kickoff)
    }

    // MARK: - 命令行

    /// 打进终端的环境前缀：`tfa` 在 PATH 最前；私有实例（`TFA_HOME`）一并传下去。
    nonisolated static var envPrefix: String {
        var p = "PATH=\(SuperagentTmux.quote(SuperagentPaths.binDir.path)):\"$PATH\""
        if let home = ProcessInfo.processInfo.environment["TFA_HOME"], !home.isEmpty {
            p = "TFA_HOME=\(SuperagentTmux.quote(home)) " + p
        }
        return p
    }

    /// 执行终端：Claude Code，附加角色的执行者 prompt，不弹权限确认；只读的角色禁用编辑类工具。
    /// `tfa` 在 PATH 上；每单角色用 TFA_TICKET 指明工单，常驻角色用 TFA_AGENT 指明角色（工单号写在每条消息里）。
    nonisolated static func claudeWorkerCommand(_ t: Ticket, role: Role, kickoff: String) -> String {
        let who = role.standing ? "TFA_AGENT=\(SuperagentTmux.quote(role.name))" : "TFA_TICKET=\(t.id)"
        let readOnly = role.edits ? "" : "--disallowedTools 'Edit,Write,NotebookEdit' "
        return "\(envPrefix) \(who) claude --dangerously-skip-permissions "
            + "--settings '{\"skipDangerousModePermissionPrompt\":true}' \(readOnly)"
            + "--append-system-prompt-file \(SuperagentTmux.quote(SuperagentPaths.rolePrompt(role.name).path)) \(SuperagentTmux.quote(kickoff))"
    }

    /// 主管：Claude Code，只放行 `tfa` 命令（dontAsk：其余一律拒绝、不弹确认，也不继承人的默认 auto 模式），
    /// 禁用编辑类工具——物理上碰不到代码。
    nonisolated static func claudeRouterCommand() -> String {
        "\(envPrefix) TFA_ROLE=router claude --append-system-prompt-file \(SuperagentTmux.quote(SuperagentPaths.routerPrompt.path)) "
            + "--permission-mode dontAsk --allowedTools 'Bash(tfa *)' --disallowedTools 'Edit,Write,NotebookEdit'"
    }
}
