import Foundation

// 第 2 期：规则与主动接单。先确定性 gate（模式 + 启用的规则），再由主管研判；
// 研判必须对每条启用的规则恰好判断一次，方向不明确（requires_design_decision）一律不接。

extension SuperagentEngine {
    /// 候选等待研判的时限，过期记 unavailable。
    public static let assessmentTimeout: Double = 15 * 60

    // MARK: - 规则管理（人）

    public func setRules(_ rules: [Rule], by: String = "你") throws {
        var seen = Set<String>()
        for r in rules {
            guard !r.id.isEmpty, r.id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
                throw SuperagentError("规则 id 只能用字母、数字、- 和 _")
            }
            guard seen.insert(r.id).inserted else { throw SuperagentError("规则 id 重复：\(r.id)") }
            guard !r.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw SuperagentError("规则 \(r.id) 缺少名称") }
            guard !r.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SuperagentError("规则 \(r.id) 缺少内容") }
            guard r.instruction.count <= Rule.maxInstruction else { throw SuperagentError("规则 \(r.id) 超过 \(Rule.maxInstruction) 字") }
        }
        try store.transaction {
            let before = try store.policyVersion()
            let data = try JSONEncoder().encode(rules)
            try store.setKV("policy.rules", String(decoding: data, as: UTF8.self))
            try policyChanged(from: before, summary: "\(by) 更新了规则（启用 \(rules.filter(\.enabled).count) 条）")
        }
    }

    public func setMode(_ mode: AcceptMode, by: String = "你") throws {
        try store.transaction {
            let before = try store.policyVersion()
            try store.setKV("policy.mode", mode.rawValue)
            try policyChanged(from: before, summary: "\(by) 把接单模式改为「\(mode.label)」")
        }
    }

    /// 版本变了：记历史；依据旧版本授权的推断工单收到一条通知——不取消正在跑的工作。
    private func policyChanged(from before: String, summary: String) throws {
        let version = try store.policyVersion()
        guard version != before else { return }
        let at = now()
        try store.appendPolicyHistory(version: version, at: at, summary: summary)
        try store.log(nil, "policy", "\(summary)（版本 \(version)）", at: at)
        for var t in try store.tickets(endedLimit: 0) where t.mandate.contains("\"strength\":\"inferred\"") {
            // 已交付 / 受阻 / 失败的不打扰（规则变更不取消工作，也不把待评审拉回工作中）。
            guard t.reportState != .ready, t.reportState != .blocked, t.reportState != .failed else { continue }
            _ = try store.insertInput(ticketID: t.id, kind: .system,
                                      text: "规则已更新到版本 \(version)。按新规则重新确认本工单仍在授权范围内；超出就回报 dropped。", at: at)
            t.updatedAt = at
            try store.saveTicket(t)
            try requeue(t.id, at: at)
        }
    }

    // MARK: - 候选（事件源 → 主管研判）

    /// 一条推断出的候选（终端事件等）。gate：模式 off 或没有启用的规则 → 不考虑；同一来源 10 分钟内只提一次。
    @discardableResult
    public func candidate(source: String, text: String, repo: String) throws -> Trigger? {
        try store.transaction {
            guard try store.acceptMode() != .off else { return nil }
            let rules = try store.rules().filter(\.enabled)
            guard !rules.isEmpty else { return nil }
            let at = now()
            // 同一来源 10 分钟内只提一次（同一个终端连续失败，输出尾巴每次都不同）。
            let recent = try store.db.query("SELECT 1 FROM trigger WHERE source=? AND created_at>?",
                                            [.text(source), .real(at - 600)])
            guard recent.isEmpty else { return nil }
            let trigger = Trigger(id: try store.nextTriggerID(), source: source, strength: .inferred, text: text,
                                  repo: repo, status: .pending, ticketID: nil, createdAt: at)
            try store.insertTrigger(trigger)
            let version = try store.policyVersion()
            let list = rules.map { "\($0.id)「\($0.name)」：\(Self.clip($0.instruction, 160))" }.joined(separator: "；")
            let verdicts = rules.map { "--rule \($0.id)=match|no_match|requires_design_decision" }.joined(separator: " ")
            try store.insertRelay(ticketID: nil, text: "[TFA 候选 \(trigger.id)] 来源 \(source)（目录 \(repo)）：\(Self.clip(text, 400))。"
                                  + "启用的规则：\(list)。研判后执行：tfa eval decide --trigger \(trigger.id) --version \(version) \(verdicts) "
                                  + "--decision accept|ignore --title … --reason …（每条规则判断一次；方向不明确就 requires_design_decision 并 ignore）", at: at)
            try store.enqueue(.relay, "router", at: at)
            try store.log(nil, "candidate", "\(trigger.id) \(source)：\(Self.clip(text, 120))", at: at)
            return trigger
        }
    }

    public struct Assessment {
        public var triggerID: String
        public var version: String
        public var verdicts: [String: RuleVerdict]
        public var accept: Bool
        public var title: String
        public var reason: String

        public init(triggerID: String, version: String, verdicts: [String: RuleVerdict], accept: Bool, title: String = "", reason: String) {
            self.triggerID = triggerID; self.version = version; self.verdicts = verdicts
            self.accept = accept; self.title = title; self.reason = reason
        }
    }

    /// 研判结果。返回建出的工单（observe 模式只记录 would_accept，返回 nil）。
    @discardableResult
    public func decide(_ a: Assessment, by: String = "主管") throws -> Ticket? {
        try store.transaction {
            guard var trigger = try store.trigger(a.triggerID) else { throw SuperagentError("没有候选 \(a.triggerID)") }
            guard trigger.status == .pending else { throw SuperagentError("候选 \(a.triggerID) 已经决定过") }
            guard trigger.strength == .inferred else { throw SuperagentError("候选 \(a.triggerID) 是明确请求，用 tfa route accept / ignore") }
            let version = try store.policyVersion()
            guard a.version == version else { throw SuperagentError("规则已变更（当前版本 \(version)），请按新规则重新研判") }
            let enabled = Set(try store.rules().filter(\.enabled).map(\.id))
            let judged = Set(a.verdicts.keys)
            guard judged == enabled else {
                let missing = enabled.subtracting(judged).sorted(), extra = judged.subtracting(enabled).sorted()
                var parts: [String] = []
                if !missing.isEmpty { parts.append("缺少 \(missing.joined(separator: ","))") }
                if !extra.isEmpty { parts.append("多出 \(extra.joined(separator: ","))") }
                throw SuperagentError("每条启用的规则必须恰好判断一次：\(parts.joined(separator: "；"))")
            }
            guard !a.reason.trimmingCharacters(in: .whitespaces).isEmpty else { throw SuperagentError("缺少 --reason") }
            let open = a.verdicts.filter { $0.value == .requiresDesignDecision }.keys.sorted()
            let matched = a.verdicts.filter { $0.value == .match }.keys.sorted()
            if a.accept {
                guard open.isEmpty else { throw SuperagentError("规则 \(open.joined(separator: ",")) 需要设计决定，不能接单：请 ignore") }
                guard !matched.isEmpty else { throw SuperagentError("没有命中任何规则，不能接单") }
                guard !a.title.trimmingCharacters(in: .whitespaces).isEmpty else { throw SuperagentError("接单需要 --title") }
            }
            let rulesJSON = try Self.json(Dictionary(uniqueKeysWithValues: a.verdicts.map { ($0.key, $0.value.rawValue) }))
            let at = now()
            guard a.accept else {
                try store.decideTrigger(trigger.id, ticketID: nil)
                try store.insertDecision(triggerID: trigger.id, ticketID: nil, kind: .ignore, reason: a.reason,
                                         policyVersion: version, rules: rulesJSON, at: at)
                return nil
            }
            switch try store.acceptMode() {
            case .auto:
                let verdicts = Dictionary(uniqueKeysWithValues: a.verdicts.map { ($0.key, $0.value.rawValue) })
                let id = try createTicket(trigger: &trigger, title: a.title, request: trigger.text, repo: trigger.repo,
                                          note: "", worktree: nil, by: "\(by)（规则 \(matched.joined(separator: ","))）", rules: verdicts)
                return try requireTicket(id)
            case .observe, .off:
                try store.decideTrigger(trigger.id, ticketID: nil)
                try store.insertDecision(triggerID: trigger.id, ticketID: nil, kind: .wouldAccept, reason: a.reason,
                                         policyVersion: version, rules: rulesJSON, at: at)
                try store.log(nil, "would_accept", "\(trigger.id)：\(a.title)（只观察，未执行）", at: at)
                return nil
            }
        }
    }

    /// 过期的候选记 unavailable（主管没在时限内研判）。返回过期数。
    @discardableResult
    public func expireCandidates() throws -> Int {
        // 先只读判断（每 2 秒一次，不为「什么都不做」开写事务）。明确请求（退回 / 定时）不过期：主管不在时它们等着。
        let at = now()
        let expired = try store.pendingTriggers().filter { $0.strength == .inferred && at - $0.createdAt > Self.assessmentTimeout }
        guard !expired.isEmpty else { return 0 }
        return try store.transaction {
            var n = 0
            for t in try store.pendingTriggers() where t.strength == .inferred && at - t.createdAt > Self.assessmentTimeout {
                try store.decideTrigger(t.id, ticketID: nil)
                try store.insertDecision(triggerID: t.id, ticketID: nil, kind: .unavailable, reason: "研判超时",
                                         policyVersion: try store.policyVersion(), rules: "{}", at: at)
                n += 1
            }
            return n
        }
    }

    // MARK: - 定时任务

    /// 保存定时任务。新建或改了时间的任务，如果今天的时间已经过了，从明天开始（不立刻补触发）；
    /// 没改时间的任务沿用库里的「上次触发」（界面上的副本可能是旧的）。
    public func setSchedules(_ list: [Schedule], calendar: Calendar = .current) throws {
        var seen = Set<String>()
        for s in list {
            guard seen.insert(s.id).inserted else { throw SuperagentError("定时任务 id 重复：\(s.id)") }
            guard Self.minutes(s.time) != nil else { throw SuperagentError("定时任务「\(s.name)」的时间要写成 HH:mm") }
            guard !s.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SuperagentError("定时任务「\(s.name)」缺少请求内容") }
            guard !s.repo.isEmpty else { throw SuperagentError("定时任务「\(s.name)」缺少目录") }
        }
        try store.transaction {
            let old = Dictionary(uniqueKeysWithValues: try store.schedules().map { ($0.id, $0) })
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: Date(timeIntervalSince1970: now()))
            let today = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            let nowMinutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            var saved = list
            for i in saved.indices {
                if let prev = old[saved[i].id], prev.time == saved[i].time {
                    saved[i].lastFired = prev.lastFired
                } else if let m = Self.minutes(saved[i].time), m <= nowMinutes {
                    saved[i].lastFired = today
                } else {
                    saved[i].lastFired = nil
                }
            }
            try store.saveSchedules(saved)
        }
    }

    /// 到点的定时任务：每天一次，生成一条明确请求交给主管（定时任务本身就是人写下的请求）。
    @discardableResult
    public func fireSchedules(at date: Date, calendar: Calendar = .current) throws -> [Trigger] {
        // 先只读判断有没有到点的（每 2 秒一次，不为「什么都不做」开写事务）。
        let c0 = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let today0 = String(format: "%04d-%02d-%02d", c0.year ?? 0, c0.month ?? 0, c0.day ?? 0)
        let now0 = (c0.hour ?? 0) * 60 + (c0.minute ?? 0)
        guard try store.schedules().contains(where: { $0.enabled && $0.lastFired != today0 && (Self.minutes($0.time) ?? .max) <= now0 }) else { return [] }
        return try store.transaction {
            var list = try store.schedules()
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let today = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            let nowMinutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            var fired: [Trigger] = []
            for i in list.indices where list[i].enabled && list[i].lastFired != today {
                guard let m = Self.minutes(list[i].time), m <= nowMinutes else { continue }
                list[i].lastFired = today
                let at = now()
                let s = list[i]
                let trigger = Trigger(id: try store.nextTriggerID(), source: "schedule:\(s.id)", strength: .explicit,
                                      text: s.request, repo: s.repo, status: .pending, ticketID: nil, createdAt: at)
                try store.insertTrigger(trigger)
                try store.insertRelay(ticketID: nil, text: "[TFA 定时 \(trigger.id)] 「\(s.name)」到点了：\(Self.clip(s.request, 400))（目录 \(s.repo)）。"
                                      + "接单用 tfa route accept --trigger \(trigger.id) --role … --title …；今天不需要就 tfa route ignore --trigger \(trigger.id) --reason …", at: at)
                try store.enqueue(.relay, "router", at: at)
                try store.log(nil, "schedule", "\(s.name) 到点 → \(trigger.id)", at: at)
                fired.append(trigger)
            }
            if !fired.isEmpty { try store.saveSchedules(list) }
            return fired
        }
    }

    static func minutes(_ hhmm: String) -> Int? {
        let p = hhmm.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
}
