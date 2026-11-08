import Foundation
import Observation
import SuperagentCore

/// TFA ↔ TFA-Org 的节点同步（TFA-工作清单-需求文档 §10.3；docs/worklist/org-protocol.md；注意事项 I）。
/// 注册（清单设置里填服务器地址 + 我的邮箱 + 邀请码）→ 心跳每 30 s → 长轮询 `/events` → 收到事件 / 每 60 s 兜底拉任务
/// → 引擎 upsert（`importOrgTasks` / `markClaimed`）；上行走 outbox（引擎入队），这里按序重放，发送成功才删。
/// 网络在 URLSession（后台），主线程只改引擎和这里的状态。一个节点一个 token，存钥匙串（I-04）。
@MainActor
@Observable
final class OrgSync {
    // MARK: 状态（界面）

    private(set) var settings = OrgSettings()
    /// 最近一次心跳 / 请求成功。
    private(set) var online = false
    /// token 失效或被吊销（401）：停下来，等人重新注册。
    private(set) var tokenInvalid = false
    private(set) var lastError: String?
    /// 每个任务未发送的上行条数（任务卡的同步行）。
    private(set) var pending: [Int64: Int] = [:]
    private(set) var pendingTotal = 0
    /// 注册 / 领取 / 立即同步 进行中。
    private(set) var busy = false

    /// 注册过而且本机还有 token。
    var registered: Bool { settings.isRegistered && token != nil }

    var statusText: String {
        if !settings.isRegistered { return "未注册" }
        if token == nil { return "已断开 · 重新注册才会同步" }
        if tokenInvalid { return "token 已失效或被吊销 · 重新注册" }
        if online { return "在线" }
        return lastError.map { "离线 · \($0)" } ?? "连接中…"
    }

    // MARK: 依赖（Runtime 注入；测试注入假的）

    @ObservationIgnored var clock: () -> Double = { Date().timeIntervalSince1970 }
    @ObservationIgnored var loadToken: (_ nodeID: String) -> String? = { OrgTokenStore.load(nodeID: $0) }
    @ObservationIgnored var saveToken: (_ token: String, _ nodeID: String) -> Void = { OrgTokenStore.save($0, nodeID: $1) }
    @ObservationIgnored var deleteToken: (_ nodeID: String) -> Void = { OrgTokenStore.delete(nodeID: $0) }
    @ObservationIgnored var heartbeatInterval: Double = 30
    @ObservationIgnored var pullInterval: Double = 60
    @ObservationIgnored var drainInterval: Double = 3
    /// 长轮询的最长等待（协议：25 s）。
    @ObservationIgnored var longPoll: Double = 25
    /// 心跳里报的：角色名、并发槽、工作中的工单数。
    @ObservationIgnored var roles: () -> [String] = { Role.builtins.map(\.name) }
    @ObservationIgnored var slots: () -> Int = { 3 }
    @ObservationIgnored var openTickets: () -> Int = { 0 }
    @ObservationIgnored var version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    @ObservationIgnored var machine = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    /// 组织范围 → 本地目录（按工作区的项目名找；找不到留空）。
    @ObservationIgnored var directory: (OrgScopeDTO) -> String? = { OrgSync.workspaceDirectory($0) }
    /// 引擎里的任务变了（下行 / 领取 / 裁决）：让运行时刷新视图并跑一轮 Pass。
    @ObservationIgnored var onChanged: (() -> Void)?

    @ObservationIgnored private var engine: SuperagentEngine?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var draining = false
    @ObservationIgnored private(set) var pulling = false
    /// 预留给我这个人、还没绑定节点的组织任务号：要 `POST claim` 绑定本节点（连不上时留着，下一轮拉取再试）。
    @ObservationIgnored private var pendingBinds: Set<Int64> = []
    @ObservationIgnored private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    init() {}

    // MARK: - 启动 / 注册 / 断开

    /// 接上引擎：读注册信息和钥匙串里的 token（没注册什么都不做）。
    func attach(engine: SuperagentEngine) {
        self.engine = engine
        settings = (try? engine.store.orgSettings()) ?? OrgSettings()
        token = settings.nodeID.flatMap(loadToken)
        refreshPending()
    }

    /// 注册过才开始心跳、长轮询、兜底拉取、outbox 重放；第一轮先全量拉一次。
    func start() {
        guard engine != nil, registered, loops.isEmpty else { return }
        tokenInvalid = false
        loops = [
            loop(every: { [weak self] in self?.heartbeatInterval ?? 30 }, first: true) { [weak self] in await self?.heartbeat() },
            eventsLoop(),
            loop(every: { [weak self] in self?.pullInterval ?? 60 }, first: true) { [weak self] in await self?.pull(full: self?.settings.taskCursor == nil) },
            loop(every: { [weak self] in self?.drainInterval ?? 3 }, first: false) { [weak self] in await self?.drain() },
        ]
    }

    func stop() {
        for l in loops { l.cancel() }
        loops = []
        pendingBinds = []
        online = false
    }

    /// 注册：邀请码由管理员按成员生成、一次性；`node_id` 首次生成后不变（重复注册同一 id = 换 token）。返回错误文案（nil = 成功）。
    func register(server: String, email: String, invite: String) async -> String? {
        guard let engine else { return "工单数据库还没打开" }
        guard let base = Self.normalize(server) else { return "服务器地址要像 http://127.0.0.1:5180" }
        if Self.needsTLS(base) { return "公网地址要用 https://（节点 token 不能明文传）；本机或局域网才可以用 http://" }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let invite = invite.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@") else { return "填你在组织里的邮箱" }
        guard !invite.isEmpty else { return "填管理员给你的邀请码" }
        busy = true
        defer { busy = false }
        let nodeID = settings.nodeID ?? String(UUID().uuidString.lowercased().prefix(8))
        let body = RegisterBody(inviteCode: invite, nodeId: nodeID, personEmail: email, roles: roles(), version: version, machine: machine)
        do {
            let r: RegisterResponse = try await OrgClient(base: base, token: nil, nodeID: nodeID, session: session)
                .send("POST", "/nodes/register", body: body)
            guard !r.token.isEmpty else { return "服务端没有给 token" }
            stop()
            saveToken(r.token, nodeID)
            token = r.token
            var s = OrgSettings()
            s.serverURL = base.absoluteString
            s.email = email
            s.nodeID = nodeID
            s.workspace = r.workspace?.name ?? ""
            if s.serverURL == settings.serverURL { s.taskCursor = settings.taskCursor; s.eventCursor = settings.eventCursor }
            settings = s
            try engine.store.saveOrgSettings(s)
            tokenInvalid = false
            lastError = nil
            start()
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    /// 断开：本机删 token、停同步；注册信息和已经在清单里的组织任务留着（服务端的吊销由管理员做）。
    func disconnect() {
        stop()
        if let id = settings.nodeID { deleteToken(id) }
        token = nil
        lastError = nil
        tokenInvalid = false
    }

    /// 人点的「立即同步」：拉一次、重放 outbox、发一次心跳。
    func syncNow() async {
        guard registered else { return }
        busy = true
        defer { busy = false }
        await pull(full: false)
        await drain()
        await heartbeat()
    }

    // MARK: - 人的操作（界面）

    /// 「待领取」分区的领取：服务端 CAS（I-05）；成功变成普通本地任务（进行中、待分配），409 = 被别人领走，本地那行删掉。
    func claim(_ taskID: Int64) async {
        guard let engine, let c = client(), let t = try? engine.store.task(taskID), let originID = t.originID else { return }
        busy = true
        defer { busy = false }
        do {
            let r: TaskResponse = try await c.send("POST", "/tasks/\(originID)/claim", body: Empty())
            try engine.markClaimed(r.task, origin: origin, edits: nil, directory: directory, by: "你")
            lastError = nil
            setOnline()
        } catch let OrgClientError.http(status, code, message) {
            switch status {
            case 409, 403:
                // 409 = 被别人领走（服务端 CAS）；403 = 已派给别人 / 不在允许名单：都不是我的了，占位行删掉。
                try? engine.dropClaimable(taskID)
                lastError = status == 409 ? "任务 \(t.label) 已被别人领走" : "任务 \(t.label) 不能领取：\(message)"
            case 401: await invalidToken()
            default: lastError = "领取失败（\(code)）：\(message)"
            }
        } catch {
            await failed(error)
        }
        onChanged?()
    }

    /// 同步冲突（I-03）：人定一边。
    func resolveConflict(_ taskID: Int64, ord: Int, useServer: Bool) {
        guard let engine else { return }
        do { try engine.resolveConflict(taskID, ord: ord, useServer: useServer) } catch { lastError = "\(error)" }
        onChanged?()
    }

    /// 服务端任务页：`http://<server>/tasks/128`。
    func taskURL(_ t: WorkTask) -> URL? {
        guard let origin = t.origin, let id = t.originID else { return nil }
        return URL(string: "\(origin)/tasks/\(id)")
    }

    // MARK: - 循环

    private func loop(every interval: @escaping () -> Double, first: Bool, _ body: @escaping () async -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            if !first { try? await Task.sleep(nanoseconds: UInt64(interval() * 1_000_000_000)) }
            while !Task.isCancelled {
                await body()
                try? await Task.sleep(nanoseconds: UInt64(interval() * 1_000_000_000))
            }
        }
    }

    /// 长轮询：没有事件时服务端 25 s 后返回空数组；断线退避 2s→60s。
    private func eventsLoop() -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            var backoff: Double = 2
            while !Task.isCancelled {
                guard let self, let c = self.client() else { return }
                let since = self.settings.eventCursor
                do {
                    let r: EventsResponse = try await c.send("GET", "/events", query: since.map { [URLQueryItem(name: "since", value: $0)] } ?? [],
                                                             timeout: self.longPoll + 15)
                    backoff = 2
                    self.setOnline()
                    for e in r.events { await self.handle(e) }
                    if let cursor = r.cursor?.value, cursor != self.settings.eventCursor {
                        self.settings.eventCursor = cursor
                        try? self.engine?.store.saveOrgSettings(self.settings)
                    }
                    if !r.events.isEmpty { self.onChanged?() }
                } catch {
                    if Task.isCancelled { return }
                    await self.failed(error)
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    backoff = min(60, backoff * 2)
                }
            }
        }
    }

    private func heartbeat() async {
        guard let c = client() else { return }
        do {
            let _: HeartbeatResponse = try await c.send("POST", "/nodes/heartbeat", body: HeartbeatBody(
                online: true, slots: slots(), openTickets: openTickets(), roles: roles(), version: version))
            setOnline()
        } catch {
            await failed(error)
        }
    }

    /// 下行：派给我 / 我领的 / 预留给我的（按 `since` 增量）；本范围的待领取另问一次、不带 `since`（全量）——谁被别人领走了
    /// 只能靠「不在列表里了」知道，不在的占位行删掉。
    func pull(full: Bool) async {
        guard let engine, let c = client(), !pulling else { return }
        pulling = true
        defer { pulling = false }
        var query = [URLQueryItem(name: "mine", value: "1")]
        if !full, let cursor = settings.taskCursor { query.append(URLQueryItem(name: "since", value: cursor)) }
        do {
            let r: TasksResponse = try await c.send("GET", "/tasks", query: query)
            for dto in r.tasks { try apply(dto) }
            await bindPending(r.tasks)
            let all: TasksResponse = try await c.send("GET", "/tasks", query: [URLQueryItem(name: "claimable", value: "1")])
            let claimable = (all.claimable ?? []).filter(\.isClaimable)
            if !claimable.isEmpty { try engine.importOrgTasks(claimable, origin: origin, claimable: true, directory: directory) }
            try engine.pruneClaimable(origin: origin, keeping: Set(claimable.map { String($0.id) }))
            if let cursor = r.cursor?.value { settings.taskCursor = cursor }
            settings.lastSync = clock()
            try engine.store.saveOrgSettings(settings)
            setOnline()
            onChanged?()
        } catch {
            await failed(error)
        }
    }

    /// 一张服务端任务落到本地：派给这台 TFA → 我的（待领取的占位行变普通任务）；预留给我这个人但还没绑定节点（Web 领取 /
    /// 派单给人）→ 记下来，`bindPending` 去 `claim` 绑定本节点（同一人的几台 TFA 谁先绑谁做）；没人领 → 待领取；
    /// 派给了别人 → 本地的占位行删掉 / 正在做的任务按转交处理；服务端取消了 → 本地取消。
    /// `assignedEdits` 只在派单事件里有：按授权自动分配清单项。
    private func apply(_ dto: OrgTaskDTO, assignedEdits: Bool? = nil) throws {
        guard let engine else { return }
        let local = try engine.store.task(origin: origin, originID: String(dto.id))
        if dto.taskStatus == .cancelled, let local {
            try engine.orgDetach(local.id, reason: "组织取消了任务 \(dto.displayLabel)")
            return
        }
        let mine = isMine(dto)
        if mine {
            pendingBinds.remove(dto.id)
            if local == nil || local?.syncState == "claimable" || assignedEdits != nil {
                try engine.markClaimed(dto, origin: origin, edits: assignedEdits, directory: directory)
            } else {
                try engine.importOrgTasks([dto], origin: origin, directory: directory)
            }
        } else if isReservedForMe(dto) {
            pendingBinds.insert(dto.id)
        } else if dto.isClaimable {
            try engine.importOrgTasks([dto], origin: origin, claimable: true, directory: directory)
        } else if let local {
            if local.syncState == "claimable" { try engine.dropClaimable(local.id) }
            else if local.isOpen { try engine.orgDetach(local.id, reason: "组织把任务 \(dto.displayLabel) 转交给了别人") }
            else { try engine.importOrgTasks([dto], origin: origin, directory: directory) }
        }
    }

    private func handle(_ e: OrgEventDTO) async {
        guard let engine, let c = client() else { return }
        switch e.type {
        case "task.assigned", "task.updated", "task.approved", "task.rejected", "task.unassigned", "task.cancelled":
            guard let id = e.taskId else { return }
            let local = try? engine.store.task(origin: origin, originID: String(id))
            if e.type == "task.cancelled" {
                if let local { try? engine.orgDetach(local.id, reason: "组织取消了任务 T-\(id)") }
                return
            }
            do {
                let r: TaskResponse = try await c.send("GET", "/tasks/\(id)")
                if e.type == "task.unassigned", let local, local.isOpen, local.syncState != "claimable" {
                    try engine.orgDetach(local.id, reason: "组织把任务 \(r.task.displayLabel) 转交给了别人")
                }
                let p = e.payload
                if e.type == "task.assigned", p?.reserved == true || isReservedForMe(r.task) {
                    // 预留给我这个人（Web 领取 / 派单给人）：绑定本节点。自己在 Web 上领的 → 待分配；别人派的 → 按授权自动分配。
                    let byMe = p?.by?.lowercased() == settings.email.lowercased()
                    await bind(r.task, edits: byMe ? nil : (p?.edits ?? r.task.edits))
                } else {
                    try apply(r.task, assignedEdits: e.type == "task.assigned" ? (p?.edits ?? r.task.edits) : nil)
                    await bindPending([r.task])
                }
                if let local = try engine.store.task(origin: origin, originID: String(id)) {
                    switch e.type {
                    case "task.rejected": try engine.orgRejected(local.id, text: p?.text ?? "", by: p?.by.map { "组织负责人 \($0)" } ?? "组织负责人")
                    case "task.updated" where p?.change == "answer":
                        if let text = p?.text { try engine.orgAnswered(local.id, text: text, by: p?.by.map { "组织负责人 \($0)" } ?? "组织负责人") }
                    case "task.updated" where p?.change == "audit":
                        try engine.orgAttached(local.id, (p?.entries ?? []).compactMap(\.summary), by: p?.by.map { "组织主管 \($0)" } ?? "组织主管")
                    default: break
                    }
                }
            } catch let OrgClientError.http(status, _, _) where status == 404 {
                if let local { try? engine.orgDetach(local.id, reason: "组织删掉了任务 T-\(id)") }
            } catch {
                await failed(error)
            }
        default:
            break // policy.changed：本机规则是本机的，范围规则不在这一期拉
        }
    }

    /// 上行：到期的 outbox 按序重放；一条连不上（或服务端 5xx / 429）就退避、停下（后面的等下一轮，顺序不乱）；
    /// 业务拒绝（其余 4xx）以服务端为准、这条作废。
    func drain() async {
        guard let engine, let c = client(), !draining else { return }
        draining = true
        defer { draining = false; refreshPending() }
        let due = (try? engine.store.pendingOutbox(now: clock())) ?? []
        var sent = false
        for e in due {
            do {
                if try await send(e, engine: engine, client: c) { try engine.store.completeOutbox(e) }
                sent = true
            } catch let OrgClientError.http(status, code, message) {
                if status == 401 { await invalidToken(); return }
                if status >= 500 || status == 429 || status == 408 {
                    // 服务端出错 / 限流 / 代理超时：不是业务拒绝，和连不上一样留着退避重放（I-02：发送成功才删）。
                    let error = OrgClientError.http(status: status, code: code, message: message)
                    _ = try? engine.store.failOutbox(e, error: Self.describe(error), now: clock())
                    await failed(error)
                    return
                }
                // 业务拒绝：记一笔、作废；阶段后退 / 不是我的了 → 重新拉这张任务，以服务端为准。
                try? engine.orgNote(e.taskID, "上行被拒绝（\(code)）：\(message)")
                try? engine.store.completeOutbox(e)
                if status != 404, status != 400, let originID = try? engine.store.task(e.taskID)?.originID { await refetch(originID) }
                sent = true
            } catch {
                _ = try? engine.store.failOutbox(e, error: Self.describe(error), now: clock())
                await failed(error)
                return
            }
        }
        if sent {
            settings.lastSync = clock()
            try? engine.store.saveOrgSettings(settings)
            setOnline()
            onChanged?()
        }
    }

    /// 返回 true = 这条可以删（发成功，或没什么可发）。抛 `OrgClientError.http` 给调用方分类。
    private func send(_ e: OutboxEntry, engine: SuperagentEngine, client c: OrgClient) async throws -> Bool {
        switch e.kind {
        case "patch":
            guard let patch = try engine.orgPatch(for: e.taskID), let originID = try engine.store.task(e.taskID)?.originID else { return true }
            let r: PatchResponse = try await c.send("PATCH", "/tasks/\(originID)", body: patch)
            try engine.applyPatchResponse(e.taskID, r.task, conflicts: r.conflicts ?? [], origin: origin)
            return true
        case "needs":
            let needs = try engine.orgNeeds(for: e.taskID)
            guard try engine.orgNeedsSent(e.taskID) != needs.signature, let originID = try engine.store.task(e.taskID)?.originID else { return true }
            let _: TaskResponse = try await c.send("POST", "/tasks/\(originID)/needs", body: needs)
            try engine.markNeedsSent(e.taskID, needs.signature)
            return true
        case "audit":
            let (entries, upTo) = try engine.orgAudit(for: e.taskID)
            guard !entries.isEmpty, let originID = try engine.store.task(e.taskID)?.originID else { return true }
            let _: OkResponse = try await c.send("POST", "/tasks/\(originID)/audit", body: AuditBody(entries: entries))
            try engine.markAudited(e.taskID, upTo: upTo)
            return entries.count < 50 // 一批 50 条：还有就留着下一轮接着发
        case "interruptions":
            let count = try engine.store.interruptions(day: e.payload)
            let _: OkResponse = try await c.send("POST", "/nodes/interruptions", body: InterruptionsBody(date: e.payload, count: count))
            return true
        default:
            return true
        }
    }

    private func isMine(_ dto: OrgTaskDTO) -> Bool {
        !(dto.assigneeNode?.isEmpty ?? true) && dto.assigneeNode == settings.nodeID
    }

    /// 预留给我这个人、还没绑定节点：`assignee_email` 是我、`assignee_node` 为空、任务还开着。
    private func isReservedForMe(_ dto: OrgTaskDTO) -> Bool {
        (dto.assigneeNode?.isEmpty ?? true) && dto.taskStatus == .open && !settings.email.isEmpty
            && dto.assigneeEmail?.lowercased() == settings.email.lowercased()
    }

    /// 绑定一张预留给我的任务：服务端 CAS（`assignee_node IS NULL AND assignee_email = 我`）。成功 → 本地的任务（`edits` 给了就按授权
    /// 自动分配）；409 = 我的另一台 TFA 先绑了 → 本地有占位行就删掉；403 = 不归我了。连不上留在 `pendingBinds`，下一轮再试。
    private func bind(_ dto: OrgTaskDTO, edits: Bool?) async {
        guard let engine, let c = client() else { return }
        do {
            let r: TaskResponse = try await c.send("POST", "/tasks/\(dto.id)/claim", body: Empty())
            pendingBinds.remove(dto.id)
            try engine.markClaimed(r.task, origin: origin, edits: edits, directory: directory, by: "你")
            setOnline()
            onChanged?()
        } catch let OrgClientError.http(status, code, message) {
            pendingBinds.remove(dto.id)
            switch status {
            case 401: await invalidToken()
            case 409, 403, 404, 422:
                if let local = try? engine.store.task(origin: origin, originID: String(dto.id)), local.syncState == "claimable" {
                    try? engine.dropClaimable(local.id)
                    onChanged?()
                }
            default: lastError = "绑定 \(dto.displayLabel) 失败（\(code)）：\(message)"
            }
        } catch {
            await failed(error)
        }
    }

    /// 拉取路径的兜底绑定（派单事件没收到：比如预留时这个节点还没注册）。刚预留的先不动——`task.assigned` 事件带着谁派的、
    /// 能否改文件，一个长轮询周期内会到，由它来绑；超过这个时间还没绑的才在这里绑，当待分配（不知道授权，不自动分配）。
    private func bindPending(_ dtos: [OrgTaskDTO]) async {
        guard !pendingBinds.isEmpty else { return }
        let settled = clock() - (longPoll + 5)
        func stale(_ dto: OrgTaskDTO) -> Bool { OrgTime.parse(dto.claimedAt).map { $0 <= settled } ?? true }
        for dto in dtos where pendingBinds.contains(dto.id) && stale(dto) { await bind(dto, edits: nil) }
        guard !pendingBinds.isEmpty, let c = client() else { return }
        for id in pendingBinds.sorted() {
            guard let r: TaskResponse = try? await c.send("GET", "/tasks/\(id)") else { continue }
            if !isReservedForMe(r.task) { pendingBinds.remove(id) } else if stale(r.task) { await bind(r.task, edits: nil) }
        }
    }

    private func refetch(_ originID: String) async {
        guard let c = client() else { return }
        if let r: TaskResponse = try? await c.send("GET", "/tasks/\(originID)") { try? apply(r.task) }
    }

    // MARK: - 状态

    private var origin: String { settings.serverURL }

    private func client() -> OrgClient? {
        guard let token, let base = URL(string: settings.serverURL), !tokenInvalid else { return nil }
        return OrgClient(base: base, token: token, nodeID: settings.nodeID, session: session)
    }

    private func setOnline() {
        if !online { online = true }
        if lastError != nil { lastError = nil }
    }

    private func failed(_ error: Error) async {
        if case let OrgClientError.http(status, _, _) = error, status == 401 { await invalidToken(); return }
        online = false
        lastError = Self.describe(error)
    }

    private func invalidToken() async {
        tokenInvalid = true
        lastError = "token 已失效或被吊销"
        stop()
    }

    func refreshPending() {
        let rows = (try? engine?.store.outbox()) ?? []
        var counts: [Int64: Int] = [:]
        for r in rows where r.taskID != 0 { counts[r.taskID, default: 0] += 1 }
        if counts != pending { pending = counts }
        if rows.count != pendingTotal { pendingTotal = rows.count }
    }

    /// `http://host:port`，去掉末尾的斜杠和路径。
    static func normalize(_ s: String) -> URL? {
        var text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        guard let u = URL(string: text), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = u.host, !host.isEmpty else { return nil }
        return URL(string: "\(scheme)://\(host)" + (u.port.map { ":\($0)" } ?? ""))
    }

    /// 节点 token 走 `Authorization: Bearer` 明文：公网地址必须 https（协议 §6）。本机和局域网可以 http：
    /// loopback、localhost、*.local、10/8、172.16/12、192.168/16、169.254/16，以及 IPv6 的 ::1、fe80::/10、fc00::/7。
    static func needsTLS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") { return false }
        if host.contains(":") { return !(host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")) }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return true }
        if parts[0] == 127 || parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254)
            || (parts[0] == 172 && (16...31).contains(parts[1])) { return false }
        return true
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let OrgClientError.http(status, code, message): return "\(status) \(code)：\(message)"
        case let OrgClientError.transport(text): return text
        case let e as URLError: return "连不上服务器：\(e.localizedDescription)"
        default: return "\(error)"
        }
    }

    /// 组织范围 → 工作区里同名的项目目录（`path_hint` 是绝对路径就直接用）。
    static func workspaceDirectory(_ scope: OrgScopeDTO) -> String? {
        let hint = scope.pathHint ?? ""
        if hint.hasPrefix("/") { return hint }
        let names = Set([hint, scope.name].map { $0.lowercased() }.filter { !$0.isEmpty })
        return WorkspaceStore.shared.projects.first { names.contains(($0.path as NSString).lastPathComponent.lowercased()) || names.contains($0.name.lowercased()) }?.path
    }
}

// MARK: - HTTP

enum OrgClientError: Error {
    /// 服务端的错误（协议 §0：`{error, message}`）。
    case http(status: Int, code: String, message: String)
    case transport(String)
}

/// 一个服务器 + 一个 token 的请求器；JSON 进出按 snake_case。
struct OrgClient: Sendable {
    let base: URL
    let token: String?
    let nodeID: String?
    let session: URLSession

    func send<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], timeout: Double = 15) async throws -> T {
        try await request(method, path, query: query, body: nil, timeout: timeout)
    }

    func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: B, timeout: Double = 15) async throws -> T {
        try await request(method, path, query: query, body: try OrgTaskDTO.encoder.encode(body), timeout: timeout)
    }

    private func request<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem], body: Data?, timeout: Double) async throws -> T {
        guard var comps = URLComponents(string: base.absoluteString + "/api/v1" + path) else { throw OrgClientError.transport("地址不对：\(path)") }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw OrgClientError.transport("地址不对：\(path)") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let nodeID { req.setValue(nodeID, forHTTPHeaderField: "X-TFA-Node") }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw OrgClientError.transport("没有 HTTP 响应") }
        guard (200..<300).contains(http.statusCode) else {
            let e = try? JSONDecoder().decode(APIError.self, from: data)
            throw OrgClientError.http(status: http.statusCode, code: e?.error ?? "http_\(http.statusCode)",
                                      message: e?.message ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
        do { return try OrgTaskDTO.decoder.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data) }
        catch { throw OrgClientError.transport("响应解析失败（\(method) \(path)）：\(error)") }
    }
}

// MARK: - 协议的请求 / 响应（§2）

struct Empty: Encodable {}
struct APIError: Decodable { var error: String?; var message: String? }
struct OkResponse: Decodable { var ok: Bool? }
struct NamedDTO: Decodable { var id: LenientString?; var name: String? }
struct PersonDTO: Decodable { var email: String?; var name: String? }
struct RegisterBody: Encodable { var inviteCode: String; var nodeId: String; var personEmail: String; var roles: [String]; var version: String; var machine: String }
struct RegisterResponse: Decodable { var token: String; var workspace: NamedDTO?; var person: PersonDTO?; var serverTime: String? }
struct HeartbeatBody: Encodable { var online: Bool; var slots: Int; var openTickets: Int; var roles: [String]; var version: String }
struct HeartbeatResponse: Decodable { var ok: Bool?; var serverTime: String?; var policyVersions: [String: String]? }
struct TasksResponse: Decodable { var tasks: [OrgTaskDTO]; var claimable: [OrgTaskDTO]?; var cursor: LenientString? }
struct TaskResponse: Decodable { var task: OrgTaskDTO }
struct PatchResponse: Decodable { var task: OrgTaskDTO; var conflicts: [OrgConflictDTO]? }
struct AuditBody: Encodable { var entries: [OrgAuditEntry] }
struct InterruptionsBody: Encodable { var date: String; var count: Int }
/// 事件的 payload（按类型取用）：`task.assigned` `{edits, by, reserved?}`；`task.rejected` `{text, item_id, by}`；
/// `task.updated` `{change: created|claimed|reserved|assigned|transferred|released|stage|fields|items|needs|answer|dropped|blocked, text?}`。
struct OrgEventEntry: Decodable { var kind: String?; var summary: String? }
struct OrgEventPayload: Decodable {
    var text: String?; var edits: Bool?; var reserved: Bool?; var by: String?; var change: String?; var itemId: Int64?
    /// `change = audit`：主管 attach 的留言（节点转告执行者）。
    var entries: [OrgEventEntry]?
}
struct OrgEventDTO: Decodable { var id: LenientString?; var type: String; var taskId: Int64?; var scopeId: Int?; var payload: OrgEventPayload?; var at: String? }
struct EventsResponse: Decodable { var events: [OrgEventDTO]; var cursor: LenientString? }
