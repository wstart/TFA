import Foundation

/// 一个工单 + 它的阶段（UI / CLI 的读视图）。
public struct TicketView: Equatable, Sendable, Identifiable {
    public var ticket: Ticket
    public var stage: Stage
    public var assignment: Assignment?
    public var pendingInputs: Int
    public var id: Int64 { ticket.id }
}

/// 调度引擎：所有领域写入的唯一入口（主管、执行者、人、App 运行时都只「提交命令」）。
/// 不碰 tmux / 文件系统——副作用只入队（effect 表），由 App 的 Pass 循环执行后再回调这里。
public final class SuperagentEngine {
    public let store: SuperagentStore
    /// 可注入的时钟（测试用）。
    public var now: () -> Double = { Date().timeIntervalSince1970 }

    public init(store: SuperagentStore) { self.store = store }

    // MARK: - 阶段

    /// 纯函数：工单阶段。等人 > 工作中 > 空闲 > 已结束，第一条命中的规则生效。
    public static func stage(ticket: Ticket, assignment: Assignment?, pendingInputs: Int) -> Stage {
        guard ticket.status == .open else { return .ended(ticket.status) }
        if ticket.deliveryError != nil { return .person(.delivery) }
        if ticket.attention != nil { return .person(.answer) }
        // 人的跟进（或 TFA 的提示）还没送到：工单回到执行方手里。
        if pendingInputs > 0 { return .working(queued: assignment?.state != .running) }
        switch ticket.reportState {
        case .ready: return .person(.review)
        case .blocked: return .person(.blocked)
        case .failed: return .person(.failed)
        case .waiting: return .person(.stalled)
        default: break
        }
        guard let a = assignment, a.state != .pending else { return .working(queued: true) }
        if a.state == .ended { return .idle }
        return .working(queued: false)
    }

    public func view(_ t: Ticket) throws -> TicketView {
        let a = try store.latestAssignment(t.id)
        let pending = try store.undelivered(t.id).count
        return TicketView(ticket: t, stage: Self.stage(ticket: t, assignment: a, pendingInputs: pending), assignment: a, pendingInputs: pending)
    }

    public func views(endedLimit: Int = 30) throws -> [TicketView] {
        try store.tickets(endedLimit: endedLimit).map(view)
    }

    public func view(_ id: Int64) throws -> TicketView {
        try view(requireTicket(id))
    }

    /// 正在占用执行槽位的工单数（工作中、未排队）。
    public func busyCount(excluding id: Int64? = nil) throws -> Int {
        try store.tickets(endedLimit: 0).filter { $0.id != id }.map(view)
            .filter { $0.stage == .working(queued: false) }.count
    }

    // MARK: - 主管（Router）命令

    public struct AcceptRequest {
        public var title: String
        public var request: String
        public var repo: String
        public var note: String = ""
        /// nil = 用设置里的默认值。
        public var worktree: Bool?
        /// 接一个已有的候选（退回 / 定时 / 研判）；nil = 主管转达的新请求。
        public var triggerID: String?
        public var by: String = "主管"

        public init(title: String, request: String, repo: String, note: String = "", worktree: Bool? = nil,
                    triggerID: String? = nil, by: String = "主管") {
            self.title = title; self.request = request; self.repo = repo; self.note = note
            self.worktree = worktree; self.triggerID = triggerID; self.by = by
        }
    }

    /// 接单：建 Ticket（+ 不可变 Mandate）+ 待启动的 Assignment，并入队 launch。
    /// 对同一个 trigger 幂等：接过的候选再接一次返回原工单。
    @discardableResult
    public func accept(_ r: AcceptRequest) throws -> Ticket {
        let title = r.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = r.request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw SuperagentError("缺少 --title（工单标题）") }
        guard title.count <= 80 else { throw SuperagentError("标题最多 80 字") }
        guard !request.isEmpty || r.triggerID != nil else { throw SuperagentError("缺少 --request（请求原文）") }
        guard Self.words(r.note) <= 30 else { throw SuperagentError("路由备注最多 30 词：只写路由背景或人的明确约束，不写实现方案") }
        return try store.transaction {
            let at = now()
            var trigger: Trigger
            if let tid = r.triggerID {
                guard let t = try store.trigger(tid) else { throw SuperagentError("没有候选 \(tid)") }
                if let existing = t.ticketID, let ticket = try store.ticket(existing) { return ticket }
                guard t.status == .pending else { throw SuperagentError("候选 \(tid) 已经决定过（未接单）") }
                if t.strength == .inferred { throw SuperagentError("候选 \(tid) 是推断出的工作，请用 tfa eval decide 研判") }
                trigger = t
            } else {
                trigger = Trigger(id: try store.nextTriggerID(), source: "router", strength: .explicit, text: request,
                                  repo: r.repo, status: .pending, ticketID: nil, createdAt: at)
                try store.insertTrigger(trigger)
            }
            let repo = r.repo.isEmpty ? trigger.repo : r.repo
            let id = try createTicket(trigger: &trigger, title: title, request: request.isEmpty ? trigger.text : request,
                                      repo: repo, note: r.note, worktree: r.worktree, by: r.by, rules: [:])
            return try requireTicket(id)
        }
    }

    /// 把一条明确请求挂到已有工单上（送达它的执行者）。已结束的工单会恢复，被人停掉的除外。
    public func attach(_ id: Int64, text: String, by: String = "主管") throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SuperagentError("缺少要转达的内容") }
        try store.transaction {
            var t = try requireTicket(id)
            if t.status == .stopped { throw SuperagentError("工单 #\(id) 已被停止，不能挂接；请新开工单") }
            if t.status != .open { try reopen(&t, by: by) }
            // 主管转达的也可能是对执行者问题的回答：和人在界面上回答一样，清掉待回答的问题。
            let answered = t.attention
            t.attention = nil
            let line = answered.map { "回答你的问题「\(Self.clip($0, 80))」：\(text)" } ?? text
            try queueInput(&t, .human, line, by: by)
        }
    }

    /// 停止：人明确要求时才停（worker 报告的 blocker 不是停的理由）。
    public func stop(_ id: Int64, by: String, reason: String = "") throws {
        try store.transaction {
            var t = try requireTicket(id)
            guard t.status == .open else { throw SuperagentError("工单 #\(id) 已经结束") }
            let at = now()
            try end(&t, .stopped, by: by, at: at)
            try store.dropUndelivered(id)
            try store.dropEffect(.deliver, String(id))
            try store.dropEffect(.launch, String(id))
            if !t.session.isEmpty { try store.enqueue(.stop, String(id), at: at) }
            try store.log(id, "stopped", reason.isEmpty ? "\(by) 停止了工单" : "\(by) 停止了工单：\(reason)", at: at)
        }
    }

    /// 不接一个候选。
    public func ignore(trigger tid: String, reason: String, by: String = "主管") throws {
        try store.transaction {
            guard let t = try store.trigger(tid) else { throw SuperagentError("没有候选 \(tid)") }
            guard t.status == .pending else { throw SuperagentError("候选 \(tid) 已经决定过") }
            try store.decideTrigger(tid, ticketID: nil)
            try store.insertDecision(triggerID: tid, ticketID: nil, kind: .ignore, reason: reason,
                                     policyVersion: try store.policyVersion(), rules: "{}", at: now())
        }
    }

    /// 请一个停下没回报的执行者回报状态（只问它，不唤醒别的工单）。
    public func requestStatus(_ id: Int64) throws {
        try store.transaction {
            var t = try requireTicket(id)
            guard t.status == .open else { throw SuperagentError("工单 #\(id) 已经结束") }
            try queueInput(&t, .system, "请用 tfa report 回报当前状态（有问题要人回答就加 --ask）。", by: "主管")
        }
    }

    /// 重试：受阻 / 失败 / 送达失败 / 停下未回报 / 空闲的工单开一个新的 Assignment（沿用同一终端和目录）。
    public func retry(_ id: Int64, by: String = "你") throws {
        try store.transaction {
            var t = try requireTicket(id)
            guard t.status == .open else { throw SuperagentError("工单 #\(id) 已经结束") }
            let stage = try view(t).stage
            let launchQueued = try store.effect(.launch, String(id)) != nil
            switch stage {
            case .person(.blocked), .person(.failed), .person(.delivery), .person(.stalled), .idle: break
            case .working(queued: true) where !launchQueued: break // 排队却没有启动在排：卡住了
            default: throw SuperagentError("工单 #\(id) 现在是「\(stage.label)」，不需要重试")
            }
            let at = now()
            let last = t.reportState.map { "上次回报 \($0.rawValue)：\(t.reportSummary)" } ?? "上次没有回报"
            if let a = try store.latestAssignment(id), a.state != .ended { try store.setAssignment(a.id, state: .ended, at: at, reason: "retry") }
            t.deliveryError = nil
            t.reportState = nil
            t.nudged = false
            t.updatedAt = at
            try store.saveTicket(t)
            _ = try store.insertAssignment(ticketID: id, reason: "retry", at: at)
            _ = try store.insertInput(ticketID: id, kind: .system, text: "\(by)要求重试工单 #\(id)。\(last)", at: at)
            try store.enqueue(.launch, String(id), at: at)
            try store.log(id, "retry", "\(by) 重试", at: at)
        }
    }

    // MARK: - 执行者（Worker）命令

    /// 一次性确认：开始实质工作前说清「在改什么、预期结果」。之后的调用被忽略（返回 false）。
    @discardableResult
    public func ack(_ id: Int64, text: String) throws -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SuperagentError("ack 需要一句具体的确认：改哪个对象、预期结果") }
        return try store.transaction {
            var t = try requireTicket(id)
            guard t.status == .open else { throw SuperagentError("工单 #\(id) 已经结束，停止工作") }
            try markRunning(t)
            guard t.ack.isEmpty else { return false }
            t.ack = String(text.prefix(200))
            t.updatedAt = now()
            try store.saveTicket(t)
            try store.log(id, "ack", t.ack, at: t.updatedAt)
            return true
        }
    }

    public struct Report {
        public var state: ReportState
        public var summary: String
        /// 一个具体的、要人回答的问题。
        public var ask: String?
        /// 附带的报告文件（例如验收 report.html）。
        public var reportPath: String?

        public init(state: ReportState, summary: String, ask: String? = nil, reportPath: String? = nil) {
            self.state = state; self.summary = summary; self.ask = ask; self.reportPath = reportPath
        }
    }

    /// 结构化回报。progress 只进记录；ready / blocked / failed / 带问题 才送主管并通知人；dropped 静默结单。
    public func report(_ id: Int64, _ r: Report) throws {
        let summary = r.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = r.ask?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard !summary.isEmpty else { throw SuperagentError("缺少 --summary") }
        guard r.state != .waiting else { throw SuperagentError("waiting 由 TFA 自己记录；要人回答请用 --ask") }
        if ask != nil, r.state == .ready || r.state == .dropped {
            throw SuperagentError("ready / dropped 不能带问题；要人决定就用 blocked 或 progress 加 --ask")
        }
        try store.transaction {
            var t = try requireTicket(id)
            guard t.status == .open else { throw SuperagentError("工单 #\(id) 已经结束，停止工作，不要再回报") }
            let at = now()
            try markRunning(t)
            let wasPerson = try view(t).stage.needsPerson
            t.reportState = r.state
            t.reportSummary = String(summary.prefix(2000))
            t.reportPath = r.reportPath?.nilIfEmpty ?? (r.state == .progress ? t.reportPath : nil)
            t.reportAt = at
            // 只有给出结论或提问才算回应了催报；用 progress 敷衍再停下，下次就记「停下未回报」。
            if r.state != .progress || ask != nil { t.nudged = false }
            if r.state == .ready { t.attention = nil }
            if let ask { t.attention = String(ask.prefix(500)) }
            t.updatedAt = at
            if r.state == .dropped {
                try end(&t, .dropped, by: "执行者", at: at)
            } else {
                try store.saveTicket(t)
            }
            try store.log(id, "report.\(r.state.rawValue)", ask.map { "\(summary)｜问：\($0)" } ?? summary, at: at)
            // 只有人必须行动或能用上结果时才出声。
            let head = "[TFA] 工单 #\(id)「\(t.title)」"
            var relay: String?
            switch r.state {
            case .ready: relay = "\(head)已就绪待评审：\(Self.clip(summary, 300))"
            case .blocked: relay = "\(head)受阻：\(Self.clip(summary, 300))"
            case .failed: relay = "\(head)失败：\(Self.clip(summary, 300))"
            case .progress, .waiting, .dropped: break
            }
            if let ask { relay = (relay ?? head + "进行中") + "。需要人回答：\(Self.clip(ask, 300))" }
            if let relay { try queueRelay(id, relay, at: at) }
            let nowPerson = try view(t).stage.needsPerson
            if nowPerson != nil, nowPerson != wasPerson { try store.enqueue(.notify, String(id), at: at) }
        }
    }

    /// 退回一个超出本工单范围（或属于别的工单）的请求：成为主管的新候选。
    @discardableResult
    public func handback(_ id: Int64, request: String, reason: String) throws -> String {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { throw SuperagentError("缺少要退回的请求原文") }
        guard !reason.isEmpty else { throw SuperagentError("缺少一句退回原因") }
        return try store.transaction {
            let t = try requireTicket(id)
            let at = now()
            let trigger = Trigger(id: try store.nextTriggerID(), source: "handback:#\(id)", strength: .explicit, text: request,
                                  repo: t.repo, status: .pending, ticketID: nil, createdAt: at)
            try store.insertTrigger(trigger)
            try store.log(id, "handback", "退回 \(trigger.id)：\(reason)", at: at)
            try queueRelay(id, "[TFA] 工单 #\(id) 退回了一个超出范围的请求（候选 \(trigger.id)）：\(Self.clip(request, 300))；原因：\(Self.clip(reason, 120))。"
                           + "接单用 tfa route accept --trigger \(trigger.id) --title …，不接用 tfa route ignore --trigger \(trigger.id) --reason …；不要挂回 #\(id)。", at: at)
            return trigger.id
        }
    }

    // MARK: - 人的命令（App 界面）

    /// 通过：结果被人接受，工单完成。
    public func approve(_ id: Int64, by: String = "你") throws {
        try store.transaction {
            var t = try requireTicket(id)
            guard t.status == .open else { throw SuperagentError("工单 #\(id) 已经结束") }
            let at = now()
            try end(&t, .done, by: by, at: at)
            try store.log(id, "approved", "\(by) 通过", at: at)
        }
    }

    /// 人的跟进：回答问题 / 打回意见 / 补充。直达执行者（等同原型的订阅扇出），已结束（非停止）的工单会恢复。
    public func feedback(_ id: Int64, text: String, by: String = "你") throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SuperagentError("内容为空") }
        try store.transaction {
            var t = try requireTicket(id)
            if t.status == .stopped { throw SuperagentError("工单 #\(id) 已被停止；请新开工单") }
            if t.status != .open { try reopen(&t, by: by) }
            let answered = t.attention
            t.attention = nil
            let line = answered.map { "回答你的问题「\(Self.clip($0, 80))」：\(text)" } ?? text
            try queueInput(&t, .human, line, by: by)
        }
    }

    // MARK: - 运行时回调（App 执行副作用后调用）

    /// launch 完成：执行终端已就绪。`agentStarted` = 刚启动了 agent（初始提示让它 `tfa read` 读全部消息，
    /// 所以排队的输入一并视为送达）；false = agent 本来就在跑，排队的输入改走 deliver。
    /// `sentAt` = 打入启动命令的时刻：比它晚的回报属于这一轮，不能作废（agent 可能在确认启动前就回报了）。
    public func launched(_ id: Int64, session: String, dir: String, branch: String, agentStarted: Bool = true, sentAt: Double? = nil) throws {
        try store.transaction {
            var t = try requireTicket(id)
            let at = now()
            t.session = session
            t.dir = dir
            t.branch = branch
            // 启动途中工单被停掉 / 结束了：刚起来的 agent 立即中断，不让它在没人要的工单上干活。
            guard t.status == .open else {
                try store.saveTicket(t)
                try store.enqueue(.stop, String(id), at: at)
                try store.log(id, "launched", "工单已结束，中断刚启动的 agent", at: at)
                return
            }
            t.deliveryError = nil
            t.turnAt = at
            t.updatedAt = at
            try store.saveTicket(t)
            if let a = try store.latestAssignment(id), a.state == .pending { try store.setAssignment(a.id, state: .running, at: at) }
            if agentStarted {
                // 新启动的 agent = 新的一轮：旧回报作废。
                if t.reportAt.map({ $0 <= (sentAt ?? at) }) ?? true {
                    t.reportState = nil
                    t.nudged = false
                }
                try store.saveTicket(t)
                try store.markDelivered(try store.undelivered(id).map(\.id), at: at)
                try store.dropEffect(.deliver, String(id))
            } else if try !store.undelivered(id).isEmpty {
                try store.enqueue(.deliver, String(id), at: at)
            }
            try store.log(id, "launched", agentStarted ? "执行终端 \(session)（\(dir)）" : "沿用执行终端 \(session)", at: at)
        }
    }

    /// deliver 完成：这些输入已打进执行终端并核验到回显。新一轮开始。
    /// `sentAt` = 开始打字的时刻：比它晚的回报已经是对这条消息的回应，不能作废。
    public func delivered(_ id: Int64, inputIDs: [Int64], sentAt: Double? = nil) throws {
        guard !inputIDs.isEmpty else { return }
        try store.transaction {
            var t = try requireTicket(id)
            let at = now()
            let inputs = try store.undelivered(id).filter { inputIDs.contains($0.id) }
            try store.markDelivered(inputIDs, at: at)
            t.deliveryError = nil
            t.turnAt = sentAt ?? at
            let stale = t.reportAt.map { $0 <= (sentAt ?? at) } ?? true
            // 人的跟进开启新一轮：旧的回报作废。TFA 自己的催报不清（否则会无限催）。
            if stale, inputs.contains(where: { $0.kind == .human }) || t.reportState == .ready || t.reportState == .blocked || t.reportState == .failed {
                t.reportState = nil
                t.nudged = false
            }
            t.updatedAt = at
            try store.saveTicket(t)
            if let a = try store.latestAssignment(id), a.state == .pending { try store.setAssignment(a.id, state: .running, at: at) }
            try store.log(id, "delivered", "送达 \(inputIDs.count) 条消息", at: at)
        }
    }

    public func relayed(_ ids: [Int64]) throws {
        try store.transaction { try store.markRelayed(ids, at: now()) }
    }

    /// 执行终端停下了，本轮却没有回报：先催一次；催过仍不回报 → 记 waiting（停下未回报）并通知人。
    public func workerIdle(_ id: Int64, lastOutput: String) throws {
        try store.transaction {
            var t = try requireTicket(id)
            guard t.status == .open, t.reportState == nil || t.reportState == .progress else { return }
            guard try store.undelivered(id).isEmpty else { return }
            let at = now()
            if !t.nudged {
                t.nudged = true
                try queueInput(&t, .system, "你停下了，但这一轮还没有用 tfa report 回报。请现在回报：做完用 ready，要人决定用 --ask，做不了用 blocked / failed。", by: "TFA")
                try store.log(id, "nudge", "停下未回报，已催一次", at: at)
            } else {
                t.reportState = .waiting
                t.reportSummary = String(lastOutput.suffix(600))
                t.reportAt = at
                t.updatedAt = at
                try store.saveTicket(t)
                try store.log(id, "report.waiting", "催报后仍未回报", at: at)
                try queueRelay(id, "[TFA] 工单 #\(id)「\(t.title)」的执行终端停下了，催报后仍未回报。最后输出：\(Self.clip(lastOutput, 200))", at: at)
                try store.enqueue(.notify, String(id), at: at)
            }
        }
    }

    /// 执行终端还在，但里面的 agent 退出了（前台回到 shell）。本轮没回报 → 记「停下未回报」并通知；
    /// 之后的跟进或重试会在同一终端重新启动 agent。
    public func agentExited(_ id: Int64, lastOutput: String) throws {
        try store.transaction {
            var t = try requireTicket(id)
            guard let a = try store.latestAssignment(id), a.state == .running else { return }
            let at = now()
            try store.setAssignment(a.id, state: .ended, at: at, reason: "agentExited")
            // 还有消息等着送（人的跟进 / 催报）：在同一终端重新启动 agent，它会 tfa read 读到。
            if t.status == .open, try !store.undelivered(id).isEmpty {
                try store.log(id, "agentExited", "agent 已退出，重新启动以送达排队的消息", at: at)
                try requeue(id, at: at)
                return
            }
            guard t.status == .open, t.reportState == nil || t.reportState == .progress else {
                try store.log(id, "agentExited", "执行终端里的 agent 已退出", at: at)
                return
            }
            t.reportState = .waiting
            t.reportSummary = "执行终端里的 agent 已退出，没有回报。最后输出：" + String(lastOutput.suffix(500))
            t.reportAt = at
            t.updatedAt = at
            try store.saveTicket(t)
            try store.log(id, "agentExited", "agent 退出且未回报", at: at)
            try queueRelay(id, "[TFA] 工单 #\(id)「\(t.title)」的 agent 退出了，没有回报。最后输出：\(Self.clip(lastOutput, 200))", at: at)
            try store.enqueue(.notify, String(id), at: at)
        }
    }

    /// 执行终端（tmux 会话）没了。还没交付的工单自动在原目录重开，附恢复说明。
    public func sessionLost(_ id: Int64) throws {
        try store.transaction {
            var t = try requireTicket(id)
            let at = now()
            guard let a = try store.latestAssignment(id), a.state == .running else { return }
            try store.setAssignment(a.id, state: .ended, at: at, reason: "sessionLost")
            try store.log(id, "sessionLost", "执行终端 \(t.session) 已不存在", at: at)
            t.session = ""
            t.updatedAt = at
            try store.saveTicket(t)
            guard t.status == .open else { return }
            let settled = t.reportState == .ready || t.reportState == .blocked || t.reportState == .failed
            if settled, try store.undelivered(id).isEmpty { return }
            _ = try store.insertAssignment(ticketID: id, reason: "recovery", at: at)
            _ = try store.insertInput(ticketID: id, kind: .system,
                                      text: "执行终端中断过。先检查当前目录、git 历史和已有改动，不要重复已完成的外部操作；继续完成原工单并回报。", at: at)
            try store.enqueue(.launch, String(id), at: at)
        }
    }

    /// 副作用连续失败（≥3 次）：launch / deliver 失败让工单进入「需要你」。
    public func effectFailed(_ e: Effect, error: String, attempts: Int) throws {
        guard attempts >= 3, e.kind == .launch || e.kind == .deliver, let id = Int64(e.key) else { return }
        try store.transaction {
            var t = try requireTicket(id)
            guard t.status == .open, t.deliveryError == nil else { return }
            let at = now()
            t.deliveryError = "\(e.kind == .launch ? "启动" : "送达")失败：\(Self.clip(error, 200))"
            t.updatedAt = at
            try store.saveTicket(t)
            try store.log(id, "effect.failed", t.deliveryError!, at: at)
            try store.enqueue(.notify, String(id), at: at)
        }
    }

    /// 送不进去（执行终端一直开着对话框等人确认）：进「需要你」并通知，消息仍排着，人处理完对话框后照常送达。
    public func deliveryBlocked(_ id: Int64, reason: String) throws {
        try store.transaction {
            var t = try requireTicket(id)
            guard t.status == .open, t.deliveryError == nil else { return }
            let at = now()
            t.deliveryError = reason
            t.updatedAt = at
            try store.saveTicket(t)
            try store.log(id, "delivery.blocked", reason, at: at)
            try store.enqueue(.notify, String(id), at: at)
        }
    }

    /// 通知已发出：同一阶段不再通知。返回要通知的内容（nil = 不需要通知）。
    public func takeNotification(_ id: Int64) throws -> (title: String, body: String)? {
        try store.transaction {
            var t = try requireTicket(id)
            guard let action = try view(t).stage.needsPerson else { return nil }
            // 同一次（同一条回报 / 同一个错误）只通知一次；打回后再次 ready 是新的一次。
            let key = action == .delivery ? "delivery:\(t.deliveryError ?? "")" : "\(action.rawValue):\(Int64((t.reportAt ?? 0) * 1000))"
            guard t.notifiedStage != key else { return nil }
            t.notifiedStage = key
            try store.saveTicket(t)
            let body: String
            switch action {
            case .answer: body = t.attention ?? t.reportSummary
            case .delivery: body = t.deliveryError ?? ""
            default: body = t.reportSummary
            }
            return ("工单 #\(id) \(action.label)：\(t.title)", Self.clip(body, 200))
        }
    }

    // MARK: - 内部

    /// 建 Ticket + Mandate + 待启动的 Assignment，并入队 launch（调用方在事务里）。
    func createTicket(trigger: inout Trigger, title: String, request: String, repo: String, note: String,
                      worktree: Bool?, by: String, rules: [String: String]) throws -> Int64 {
        guard !repo.isEmpty else { throw SuperagentError("缺少 --dir（工单要改的目录）") }
        // 执行者全部放行：家目录或根目录不是一个项目，不能让它在那里干活。
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard URL(fileURLWithPath: repo).standardizedFileURL.path != home, repo != "/" else {
            throw SuperagentError("工单目录不能是家目录或根目录：用 --dir 指明要改的项目目录")
        }
        let at = now()
        let version = try store.policyVersion()
        let mandate = try Self.json(["strength": trigger.strength.rawValue, "trigger": trigger.id,
                                     "policy_version": version, "by": by, "rules": rules])
        let ticket = Ticket(id: 0, title: title, request: request, note: note,
                            repo: repo, dir: "", branch: "", worktree: try worktree ?? store.settings().worktree,
                            status: .open, endedBy: nil, endedAt: nil,
                            ack: "", attention: nil, reportState: nil, reportSummary: "", reportPath: nil, reportAt: nil,
                            deliveryError: nil, nudged: false, notifiedStage: nil, mandate: mandate, triggerID: trigger.id,
                            session: "", turnAt: nil, createdAt: at, updatedAt: at)
        let id = try store.insertTicket(ticket)
        trigger.ticketID = id
        try store.decideTrigger(trigger.id, ticketID: id)
        try store.insertDecision(triggerID: trigger.id, ticketID: id, kind: .accept, reason: "", policyVersion: version,
                                 rules: try Self.json(rules), at: at)
        _ = try store.insertAssignment(ticketID: id, reason: "accepted", at: at)
        try store.enqueue(.launch, String(id), at: at)
        try store.log(id, "accepted", "\(by) 接单：\(title)", at: at)
        return id
    }

    func requireTicket(_ id: Int64) throws -> Ticket {
        guard let t = try store.ticket(id) else { throw SuperagentError("没有工单 #\(id)") }
        return t
    }

    private func queueInput(_ t: inout Ticket, _ kind: InputKind, _ text: String, by: String) throws {
        let at = now()
        _ = try store.insertInput(ticketID: t.id, kind: kind, text: text, at: at)
        t.updatedAt = at
        try store.saveTicket(t)
        try requeue(t.id, at: at)
        try store.log(t.id, kind == .human ? "input" : "system", "\(by)：\(Self.clip(text, 200))", at: at)
    }

    /// 有排队的输入要送：上一轮已结束（或从没开始）→ 新建一轮并启动；否则直接送达。
    func requeue(_ id: Int64, at: Double) throws {
        if let a = try store.latestAssignment(id), a.state != .ended {
            try store.enqueue(.deliver, String(id), at: at)
        } else {
            _ = try store.insertAssignment(ticketID: id, reason: "wake", at: at)
            try store.enqueue(.launch, String(id), at: at)
        }
    }

    private func queueRelay(_ id: Int64?, _ text: String, at: Double) throws {
        try store.insertRelay(ticketID: id, text: text, at: at)
        try store.enqueue(.relay, "router", at: at)
    }

    /// worker 发来 ack / report = 它活着。待启动的这一轮直接算开始；有排队的输入就送给它，
    /// 不再另起一个 agent（否则 launch 看到 running 就放弃，输入永远送不到）。
    private func markRunning(_ t: Ticket) throws {
        guard let a = try store.latestAssignment(t.id), a.state == .pending else { return }
        try store.setAssignment(a.id, state: .running, at: now())
        if try !store.undelivered(t.id).isEmpty, !t.session.isEmpty {
            try store.dropEffect(.launch, String(t.id))
            try store.enqueue(.deliver, String(t.id), at: now())
        }
    }

    private func end(_ t: inout Ticket, _ status: TicketStatus, by: String, at: Double) throws {
        t.status = status
        t.endedBy = by
        t.endedAt = at
        t.attention = nil
        t.deliveryError = nil
        t.updatedAt = at
        try store.saveTicket(t)
        if let a = try store.latestAssignment(t.id), a.state != .ended { try store.setAssignment(a.id, state: .ended, at: at, reason: status.rawValue) }
        try store.dropEffect(.notify, String(t.id))
    }

    private func reopen(_ t: inout Ticket, by: String) throws {
        let at = now()
        t.status = .open
        t.endedBy = nil
        t.endedAt = nil
        t.reportState = nil
        t.notifiedStage = nil
        t.updatedAt = at
        try store.saveTicket(t)
        try store.log(t.id, "resumed", "\(by) 的跟进恢复了工单", at: at)
    }

    static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.count > n ? String(one.prefix(n)) + "…" : one
    }

    /// 词数：中日韩字符每 2 个算一个词（近似分词），其余按空白分隔。
    static func words(_ s: String) -> Int {
        var cjk = 0
        var latin = ""
        for ch in s {
            if ch.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }) {
                cjk += 1
                latin.append(" ")
            } else {
                latin.append(ch)
            }
        }
        return (cjk + 1) / 2 + latin.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).count
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
