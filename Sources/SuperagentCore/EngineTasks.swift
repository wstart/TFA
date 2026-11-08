import Foundation

// 工作清单（TFA-工作清单-需求文档 §5；注意事项 B / C / D / G）。
// 单一写入者不变：任务、清单项、工作流只在这里写 `superagent.db`；界面、CLI、运行时都只调这些方法。
// 公开方法各自开事务；内部方法（advance / apply* / autoReview / reopen）由调用方在事务里调。事务里不做 I/O，副作用一律入队。

extension SuperagentEngine {
    // MARK: - 命令的入参

    /// 建任务（§5.1 `createTask`）。
    public struct TaskDraft {
        public var title: String
        /// 原文；空时用标题。
        public var request: String
        public var source: TaskSource
        public var sourceRef: String?
        /// 项目目录（个人层）；可空。
        public var scope: String
        /// 清单项文字（≤200 字各）；空 → 自动生成一项 = 标题（§3.3）。
        public var items: [String]
        /// 主管的 `--suggest`：`ord` → 角色名或「你」。只是「谁来做」的默认值，**不分配、不建工单**（注意事项 E-02）。
        public var suggestions: [Int: String]
        /// 工作流模板 id；nil = 按 `scope` 的默认模板，再退到 `Workflow.defaultID`。
        public var workflow: String?
        public var priority: TaskPriority
        public var due: Double?
        public var deps: [Int64]
        /// 路由备注（≤30 词）。
        public var note: String
        public var by: String

        public init(title: String, request: String = "", source: TaskSource = .manual, sourceRef: String? = nil, scope: String = "",
                    items: [String] = [], suggestions: [Int: String] = [:], workflow: String? = nil, priority: TaskPriority = .medium,
                    due: Double? = nil, deps: [Int64] = [], note: String = "", by: String = "你") {
            self.title = title; self.request = request; self.source = source; self.sourceRef = sourceRef; self.scope = scope
            self.items = items; self.suggestions = suggestions; self.workflow = workflow; self.priority = priority
            self.due = due; self.deps = deps; self.note = note; self.by = by
        }
    }

    /// 「谁来做」里一项的决定。
    public struct Allocation: Equatable, Sendable {
        public var ord: Int
        public var to: Assignee
        public init(ord: Int, to: Assignee) { self.ord = ord; self.to = to }
    }

    // MARK: - 任务（人 / 主管 / 事件源）

    /// 建任务：校验标题 ≤80、清单项 ≤200（人写的超了报错；主管生成的调用方先截断）；没有 items 就生成一项 = 标题；
    /// 个人层直接进第一个 `doing` 阶段（跳过 `todo`）；快照工作流模板；记 timeline「建任务」。
    @discardableResult
    public func createTask(_ d: TaskDraft) throws -> WorkTask {
        let title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw SuperagentError("缺少任务标题") }
        guard title.count <= WorkTask.maxTitle else { throw SuperagentError("标题最多 \(WorkTask.maxTitle) 字") }
        guard Self.words(d.note) <= 30 else { throw SuperagentError("路由备注最多 30 词：只写路由背景或人的明确约束，不写实现方案") }
        // 原文原样存（不动内部换行，注意事项 B-12）；只去掉首尾空白。
        let request = d.request.trimmingCharacters(in: .whitespacesAndNewlines)
        let texts = try Self.itemTexts(d.items.isEmpty ? [title] : d.items)
        return try store.transaction {
            let at = now()
            let workflow = try resolveWorkflow(d.workflow, scope: d.scope)
            for dep in d.deps where try store.task(dep) == nil { throw SuperagentError("前置任务 A-\(dep) 不存在") }
            for (ord, who) in d.suggestions {
                guard texts.indices.contains(ord - 1) else { throw SuperagentError("建议的第 \(ord) 项不存在（共 \(texts.count) 项）") }
                if who != "你" { _ = try requireRole(who) }
            }
            var t = WorkTask(id: 0, title: title, request: request.isEmpty ? title : request, source: d.source, sourceRef: d.sourceRef,
                             scope: d.scope, due: d.due, priority: d.priority, deps: Array(Set(d.deps)).sorted(), workflow: workflow.id,
                             stages: workflow.stages, stage: Self.firstDoing(workflow.stages).name, note: d.note, createdAt: at, updatedAt: at)
            t.id = try store.insertTask(t)
            for (i, text) in texts.enumerated() { _ = try store.insertItem(Item(id: 0, taskID: t.id, ord: i + 1, text: text)) }
            try store.log(nil, "task", "\(d.by)建了任务「\(title)」（\(texts.count) 项，\(d.source.label)）", at: at, task: t.id)
            if !d.suggestions.isEmpty {
                try store.saveSuggestions(task: t.id, d.suggestions)
                let list = d.suggestions.keys.sorted().map { "\($0) → \(d.suggestions[$0]!)" }.joined(separator: "，")
                try store.log(nil, "suggest", "\(d.by)建议谁来做：\(list)（未分配）", at: at, task: t.id)
            }
            return t
        }
    }

    /// 改标题 / 范围 / 优先级 / 截止 / 依赖（`due: .some(nil)` = 清掉截止）。
    public func updateTask(_ id: Int64, title: String? = nil, scope: String? = nil, priority: TaskPriority? = nil,
                           due: Double?? = nil, deps: [Int64]? = nil, by: String = "你") throws {
        try store.transaction {
            var t = try requireTask(id)
            try requireNotCancelled(t)
            var changes: [String] = []
            if let title {
                let s = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.isEmpty else { throw SuperagentError("缺少任务标题") }
                guard s.count <= WorkTask.maxTitle else { throw SuperagentError("标题最多 \(WorkTask.maxTitle) 字") }
                if s != t.title { t.title = s; changes.append("标题改为「\(s)」") }
            }
            if let scope, scope != t.scope { t.scope = scope; changes.append(scope.isEmpty ? "清掉了范围" : "范围改为 \(scope)") }
            if let priority, priority != t.priority { t.priority = priority; changes.append("优先级改为「\(priority.label)」") }
            if let due, due != t.due {
                t.due = due
                changes.append(due.map { "截止改为 \(SuperagentStore.day($0))" } ?? "清掉了截止")
            }
            if let deps {
                let list = Array(Set(deps)).sorted()
                guard !list.contains(id) else { throw SuperagentError("任务不能依赖自己") }
                for dep in list where try store.task(dep) == nil { throw SuperagentError("前置任务 A-\(dep) 不存在") }
                if list != t.deps { t.deps = list; changes.append(list.isEmpty ? "清掉了前置任务" : "前置任务改为 " + list.map { "A-\($0)" }.joined(separator: "、")) }
            }
            guard !changes.isEmpty else { return }
            t.updatedAt = now()
            try store.saveTask(t)
            try store.log(nil, "task", "\(by)\(changes.joined(separator: "，"))", at: t.updatedAt, task: id)
        }
    }

    /// 加清单项（追加到末尾，`ord` 连续）。任务在 review 时加项 → 回到 doing；已完成时加项 → 重新打开（注意事项 C-05 / C-10）。
    @discardableResult
    public func addItems(_ taskID: Int64, _ texts: [String], by: String = "你") throws -> [Item] {
        let texts = try Self.itemTexts(texts)
        guard !texts.isEmpty else { throw SuperagentError("没有要加的清单项") }
        return try store.transaction {
            var t = try requireTask(taskID)
            try requireNotCancelled(t)
            let at = now()
            if t.status != .open { try reopenTask(&t, by: by, at: at) }
            var count = try store.items(taskID).count
            var added: [Item] = []
            for text in texts {
                count += 1
                var i = Item(id: 0, taskID: taskID, ord: count, text: text)
                i.id = try store.insertItem(i)
                added.append(i)
            }
            let label = Self.ordLabel(added.map(\.ord))
            try store.log(nil, "item", "\(by)新增\(label)：\(Self.clip(added.map(\.text).joined(separator: "；"), 200))", at: at, task: taskID)
            if t.stageKind == .review {
                try backToDoing(&t, reason: "新增\(label)，回到「\(Self.firstDoing(t.stages).name)」", at: at)
            } else {
                t.updatedAt = at
                try store.saveTask(t)
            }
            return added
        }
    }

    /// 改一项的文字；有工单的项改了要用 `insertInput(.system)` 提示执行者（注意事项 B-07）。
    public func editItem(_ taskID: Int64, ord: Int, text: String, by: String = "你") throws {
        let text = try Self.itemTexts([text])[0]
        try store.transaction {
            var t = try requireTask(taskID)
            try requireNotCancelled(t)
            var i = try requireItem(t, ord)
            guard i.text != text else { return }
            let old = i.text
            let at = now()
            i.text = text
            try store.saveItem(i)
            t.updatedAt = at
            try store.saveTask(t)
            try store.log(nil, "item", "\(by)把第 \(ord) 项改为：\(text)", at: at, task: taskID)
            if let tid = i.ticketID, var ticket = try store.ticket(tid), ticket.isOpen {
                try queueInput(&ticket, .system, "任务 \(t.label) 的第 \(ord) 项改了：「\(old)」→「\(text)」。按新的做。", by: by)
            }
        }
    }

    /// 删一项（有工单的项不能删，先取消工单）；删后重排 `ord`，同一事务（注意事项 B-06 / B-07）。
    public func removeItem(_ taskID: Int64, ord: Int, by: String = "你") throws {
        try store.transaction {
            var t = try requireTask(taskID)
            try requireNotCancelled(t)
            var items = try store.items(taskID)
            guard let idx = items.firstIndex(where: { $0.ord == ord }) else { throw Self.noItem(t, ord, items.count) }
            guard items.count > 1 else { throw SuperagentError("任务至少要有一个清单项；不要这个任务就取消它") }
            let i = items[idx]
            if let tid = i.ticketID, let ticket = try store.ticket(tid), ticket.isOpen {
                throw SuperagentError("第 \(ord) 项已交给「\(ticket.role)」（工单 #\(tid)），先停止工单再删")
            }
            try store.deleteItem(i.id)
            items.remove(at: idx)
            var renumbered: [Int64: [(old: Int, new: Int)]] = [:] // 工单 → 它的项的新旧编号
            for (k, var it) in items.enumerated() where it.ord != k + 1 {
                let old = it.ord
                it.ord = k + 1
                try store.saveItem(it)
                if let tid = it.ticketID { renumbered[tid, default: []].append((old, it.ord)) }
            }
            let at = now()
            t.updatedAt = at
            try store.saveTask(t)
            try store.log(nil, "item", "\(by)删除了第 \(ord) 项：\(i.text)", at: at, task: taskID)
            // 执行者按编号回报：它负责的项重新编号了要告诉它（同 editItem 的做法）。
            for (tid, moves) in renumbered.sorted(by: { $0.key < $1.key }) {
                guard var ticket = try store.ticket(tid), ticket.isOpen else { continue }
                try queueInput(&ticket, .system, "任务 \(t.label) 的清单项已重新编号：你负责的现在是\(Self.ordLabel(moves.map { $0.new }))"
                               + "（原\(Self.ordLabel(moves.map { $0.old }))）；回报 --item 用新的编号。", by: by)
            }
            try advanceIfComplete(taskID, at: at)
        }
    }

    /// 谁来做（§5.1 `assign`）：
    /// - `.you`：清单项标为你的（不建终端、不占槽；注意事项 C-11）。
    /// - `.agent(role)`：为这些项建工单——必须走 `createTicket(taskID:itemIDs:)`，`oneTicket` 为真时同一角色合成一张；
    ///   `request` 按 §5.2 生成，`repo = task.scope`，`note = task.note`；标题 = 任务标题 + 清单项序号。
    /// - 改派：Agent → 你 要先 `stop` 那张工单；你 → Agent 直接建；Agent → 另一个 Agent 先停再建，记「改派」（注意事项 C-03）。
    ///   一张工单带几项、只改派其中一项时，工单不停：剩下的项它继续做，改派的那项用系统消息告诉它不用做了。
    /// - 前置任务未完成时分配给 Agent 要拒绝（注意事项 C-14）；`edits == true` 的角色校验 `scope` 目录（注意事项 H-02）。
    /// 返回新建的工单。
    @discardableResult
    public func assign(_ taskID: Int64, _ allocations: [Allocation], oneTicket: Bool = true, by: String = "你") throws -> [Ticket] {
        try assignItems(taskID, allocations, oneTicket: oneTicket, by: by, source: nil)
    }

    /// 自动接单（规则 / 定时，EnginePolicy）的来源：第一张工单直接挂在这条事件上（执行者看到的「来源」就是原候选，审计链
    /// 「事件 → 决定 → 任务 → 工单」不断），授权的强度随事件（候选 = inferred），逐条研判和理由进它的决定行。
    struct AutoSource {
        var trigger: Trigger
        var rules: [String: String]
        var reason: String
    }

    /// `assign` 的内部版本：`source` 给了就是自动接单（见 `AutoSource`）。
    func assignItems(_ taskID: Int64, _ allocations: [Allocation], oneTicket: Bool, by: String, source: AutoSource?) throws -> [Ticket] {
        guard !allocations.isEmpty else { throw SuperagentError("没有要分配的清单项") }
        // H-02：会改文件的角色要有合法目录。目录的 stat 在事务外做（事务里不做 I/O）；角色不存在的在事务里报。
        if try allocations.contains(where: { a in try a.to.role.map { try store.role($0)?.edits == true } ?? false }) {
            try Self.checkScope(try requireTask(taskID))
        }
        return try store.transaction {
            var t = try requireTask(taskID)
            try requireNotCancelled(t)
            let at = now()
            if t.status != .open { try reopenTask(&t, by: by, at: at) }
            var items = try store.items(taskID)
            // 同一项出现几次只取最后一个决定；保持第一次出现的顺序。
            var decided: [Int: Assignee] = [:]
            var order: [Int] = []
            for a in allocations {
                if decided[a.ord] == nil { order.append(a.ord) }
                decided[a.ord] = a.to
            }
            for ord in order where !items.contains(where: { $0.ord == ord }) { throw Self.noItem(t, ord, items.count) }
            // 交给 Agent 的前置校验：角色存在、前置任务做完（C-14）。
            var roles: [String: Role] = [:]
            for name in Set(order.compactMap { decided[$0]?.role }).sorted() {
                for dep in t.deps {
                    if let d = try store.task(dep), d.status != .done {
                        throw SuperagentError("前置任务 \(d.label)「\(d.title)」还没完成，先完成它再交给 Agent（分给自己不受限）")
                    }
                }
                roles[name] = try requireRole(name)
            }
            // 1. 先把每项从原来的执行者手里摘下来；交给 Agent 的攒起来建工单。
            var groups: [(role: String, ords: [Int])] = []
            var touched: Set<Int64> = []   // 被改派动过的旧工单
            var notes: [String] = []
            func index(_ ord: Int) -> Int { items.firstIndex { $0.ord == ord }! }
            for ord in order {
                guard let to = decided[ord] else { continue }
                var i = items[index(ord)]
                let old = i.assignee
                let openTicket = try i.ticketID.flatMap { try store.ticket($0) }.flatMap { $0.isOpen ? $0 : nil }
                // 没变：同一个人；或同一角色且它的工单还开着（工单结束了再分给同一角色 = 重新派一张）。
                // 例外：没有工单的受阻项（前置被取消）重新分配 = 解开，哪怕还是给同一个人。
                if to == old, !to.isAgent || openTicket != nil, !(i.status == .blocked && openTicket == nil) { continue }
                if let ot = openTicket {
                    touched.insert(ot.id)
                    notes.append("改派：第 \(ord) 项 \(old.label) → \(to.label)（工单 #\(ot.id)）")
                }
                i.ticketID = nil
                i.assignee = to
                if to.isAgent || i.status != .done {
                    i.status = .todo
                    i.doneAt = nil
                    i.doneBy = nil
                }
                // 你的项没有「开始」这一步：分给你就算开始做了（Agent 的项等它 ack）。
                i.startedAt = to == .you && i.status != .done ? at : nil
                items[index(ord)] = i
                try store.saveItem(i)
                switch to {
                case .you: notes.append("\(by)把第 \(ord) 项标为自己做")
                case .unassigned: notes.append("\(by)取消了第 \(ord) 项的分配")
                case .agent(let role):
                    if oneTicket, let g = groups.firstIndex(where: { $0.role == role }) { groups[g].ords.append(ord) }
                    else { groups.append((role, [ord])) }
                }
            }
            // 2. 原来的工单：项全被摘走就停（C-03）；还剩项就让它继续，告诉它哪项不用做了。
            for tid in touched.sorted() {
                guard let ticket = try store.ticket(tid), ticket.isOpen else { continue }
                let left = items.filter { $0.ticketID == tid && $0.status != .done }
                if left.isEmpty {
                    try stop(tid, by: by, reason: "清单项已改派")
                } else {
                    var tk = ticket
                    let gone = items.filter { ticket.itemIDs.contains($0.id) && $0.ticketID != tid }.map(\.ord)
                    try queueInput(&tk, .system, "任务 \(t.label) 的\(Self.ordLabel(gone))已改派给别人，不用做了；你剩下的是\(Self.ordLabel(left.map(\.ord)))。", by: by)
                }
            }
            t = try requireTask(taskID) // 停工单可能已推进了阶段
            // 3. 交给 Agent 的项建工单（C-01：只走 createTicket）。
            var made: [Ticket] = []
            for (k, g) in groups.enumerated() {
                let role = roles[g.role]!
                let mine = g.ords.map { items[index($0)] }
                let request = Self.agentRequest(task: t, mine: mine, all: items)
                let title = String("\(t.title) · \(Self.ordLabel(g.ords))".prefix(WorkTask.maxTitle))
                // 人分配：每张工单一条「task:A-N」事件；自动接单：第一张直接挂在原事件上，其余（不会有）各建一条。
                var trigger: Trigger
                if k == 0, let s = source {
                    trigger = s.trigger
                } else {
                    trigger = Trigger(id: try store.nextTriggerID(), source: "task:\(t.label)", strength: source?.trigger.strength ?? .explicit,
                                      text: request, repo: t.scope, status: .pending, ticketID: nil, createdAt: at)
                    try store.insertTrigger(trigger)
                }
                let id = try createTicket(trigger: &trigger, title: title, request: request, repo: t.scope, note: t.note, worktree: nil,
                                          by: by, rules: source?.rules ?? [:], role: role, taskID: t.id, itemIDs: mine.map(\.id),
                                          reason: source?.reason ?? "")
                for var i in mine {
                    i.ticketID = id
                    items[index(i.ord)] = i
                    try store.saveItem(i)
                }
                notes.append("\(by)把\(Self.ordLabel(g.ords))交给「\(g.role)」（工单 #\(id)）")
                made.append(try requireTicket(id))
            }
            for n in notes { try store.log(nil, "assign", n, at: at, task: taskID) }
            // 待评审时重新分配 = 有项要重做：回到进行中。
            if t.stageKind == .review, items.contains(where: { $0.status != .done }) {
                try backToDoing(&t, reason: "清单项重新分配，回到「\(Self.firstDoing(t.stages).name)」", at: at)
            } else {
                t.updatedAt = at
                try store.saveTask(t)
            }
            try advanceIfComplete(taskID, at: at)
            try orgChanged(taskID) // 组织任务：清单项状态变了，上行（EngineOrg.swift）
            return made
        }
    }

    /// 规则 / 定时自动把全部清单项交给一个角色（EnginePolicy，第 2 期）。角色不存在：`fallbackToDeveloper` 为真退到「开发」，
    /// 否则留在待分配；目录不合法等分配失败也留在待分配并记 timeline，不抛错给主管。返回建出的工单（没建出为空）。调用方在事务里。
    func autoAssign(_ task: WorkTask, role name: String, by: String, source: AutoSource, fallbackToDeveloper: Bool, at: Double) throws -> [Ticket] {
        var roleName = name.isEmpty ? Role.developer : name
        if try store.role(roleName) == nil {
            guard fallbackToDeveloper else {
                try store.log(nil, "assign", "角色「\(roleName)」不存在，留在待分配", at: at, task: task.id)
                return []
            }
            try store.log(nil, "assign", "角色「\(roleName)」不存在，改交给「\(Role.developer)」", at: at, task: task.id)
            roleName = Role.developer
        }
        guard let role = try store.role(roleName) else { return [] }
        let ords = try store.items(task.id).map(\.ord)
        do {
            // 每单一个终端的角色要有合法目录：先查，免得建到一半失败。
            if role.edits || !role.standing { try Self.checkScope(task) }
            return try assignItems(task.id, ords.map { Allocation(ord: $0, to: .agent(role: roleName)) }, oneTicket: true, by: by, source: source)
        } catch {
            for var i in try store.items(task.id) where i.assignee.isAgent && i.ticketID == nil {
                i.assignee = .unassigned
                i.status = .todo
                i.startedAt = nil
                try store.saveItem(i)
            }
            try store.log(nil, "assign", "自动交给「\(roleName)」失败：\(error)。留在待分配，等人定谁来做", at: at, task: task.id)
            return []
        }
    }

    /// 人手动勾 / 取消勾自己的项（Agent 的项只读，由回报推进）。勾完同一事务里 `advanceIfComplete`（注意事项 C-04）。
    public func setItemDone(_ taskID: Int64, ord: Int, done: Bool = true, by: String = "你") throws {
        try store.transaction {
            var t = try requireTask(taskID)
            try requireNotCancelled(t)
            let at = now()
            if t.status != .open {
                guard !done else { return } // 已完成的任务上再勾：没有要做的
                try reopenTask(&t, by: by, at: at) // 取消勾 = 跟进（C-10）
            }
            var i = try requireItem(t, ord)
            if let tid = i.ticketID, let ticket = try store.ticket(tid), ticket.isOpen {
                throw SuperagentError("第 \(ord) 项由「\(ticket.role)」在做（工单 #\(tid)），由它的回报推进；要自己做先改派给你")
            }
            guard (i.status == .done) != done else { return }
            if done {
                i.status = .done; i.doneAt = at; i.doneBy = by
            } else {
                i.status = .todo; i.doneAt = nil; i.doneBy = nil
                i.startedAt = i.assignee == .you ? at : nil // 取消勾 = 还是你在做，2 天的计时从现在重新算
            }
            try store.saveItem(i)
            try store.log(nil, "item", "\(by)\(done ? "勾掉" : "取消勾")第 \(ord) 项：\(i.text)", at: at, task: taskID)
            if !done, t.stageKind == .review {
                try backToDoing(&t, reason: "第 \(ord) 项取消勾选，回到「\(Self.firstDoing(t.stages).name)」", at: at)
            } else {
                t.updatedAt = at
                try store.saveTask(t)
            }
            try advanceIfComplete(taskID, at: at)
            try orgChanged(taskID) // 组织任务：勾选上行
        }
    }

    /// 当前阶段所有项 done（且没有进行中的自动评审）→ 进下一阶段，只前进一个；进 `review` 入队通知（key `A-<id>`）；
    /// 进 `done` 写 `resultSummary`（最后一张 ready 工单的 summary，否则留空）并结束任务。调用方在事务里。
    /// 只从 `doing` 阶段自动前进：`review` → 下一阶段只能由人 `approveTask`（§4.1）。名下还有打开的工单持有清单项
    /// （用 `--item` 勾完了但还没报 ready）时也等它交付再进。
    func advanceIfComplete(_ taskID: Int64, at: Double) throws {
        guard var t = try store.task(taskID), t.status == .open, t.stageKind == .doing else { return }
        let items = try store.items(taskID)
        guard !items.isEmpty, items.allSatisfy({ $0.status == .done }) else { return }
        let tickets = try store.tickets(task: taskID)
        let open = Set(tickets.filter(\.isOpen).map(\.id))
        guard !tickets.contains(where: { $0.isOpen && $0.reviewOf != nil }) else { return } // 自动评审还在跑
        guard !items.contains(where: { $0.ticketID.map(open.contains) ?? false }) else { return } // 工单还没交付
        let idx = t.stageIndex
        guard idx + 1 < t.stages.count else { return }
        try enter(&t, t.stages[idx + 1], tickets: tickets, at: at)
        try orgChanged(taskID) // 组织任务：阶段前进上行
    }

    /// 通过（§4.1）：`review` → `done`。`merged` = App 已把名下开发工单的分支合并进主仓库的那句结果（记 timeline）。
    public func approveTask(_ id: Int64, by: String = "你", merged: String? = nil) throws {
        try store.transaction {
            var t = try requireTask(id)
            guard t.status == .open else { throw SuperagentError("任务 \(t.label) \(t.status.label)，不能通过") }
            guard t.stageKind == .review, !t.stages.isEmpty else { throw SuperagentError("任务 \(t.label) 现在是「\(t.stage)」，清单做完进「待评审」后才能通过") }
            let at = now()
            // 名下还开着、已报 ready 的工单（迁移进来的旧「待评审」单）：随任务一起通过结单，不留永远 open 的孤儿。
            for ticket in try store.tickets(task: id) where ticket.isOpen && ticket.reportState == .ready {
                try approve(ticket.id, by: by)
                try store.log(nil, "approved", "工单 #\(ticket.id) 随任务通过结单", at: at, task: id)
            }
            try store.log(nil, "approved", merged.map { "\(by)通过；\($0)" } ?? "\(by)通过", at: at, task: id)
            let idx = t.stageIndex
            try enter(&t, t.stages[min(idx + 1, t.stages.count - 1)], tickets: try store.tickets(task: id), at: at)
            try orgChanged(id) // 组织任务：阶段上行
        }
    }

    /// 打回（§4.1、§5.1）：回到第一个 `doing`；意见送给原工单（有工单的项 → `feedback`），没有工单时新建一个清单项 = 意见。
    public func rejectTask(_ id: Int64, text: String, by: String = "你") throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SuperagentError("缺少打回意见") }
        try store.transaction {
            var t = try requireTask(id)
            try requireNotCancelled(t)
            let at = now()
            if t.status != .open {
                try reopenTask(&t, by: by, at: at) // 对已完成任务的打回 = 跟进（C-10）
            } else {
                guard t.stageKind == .review else { throw SuperagentError("任务 \(t.label) 现在是「\(t.stage)」，只有「待评审」的任务能打回") }
            }
            let items = try store.items(id)
            // 有工单的项：意见送给原工单（已结束的会恢复；被停止的不能），项回到工作中（跟进挂钩里做）。
            let targets = try items.compactMap(\.ticketID).reduce(into: [Int64]()) { list, tid in
                if !list.contains(tid), let ticket = try store.ticket(tid), ticket.status != .stopped { list.append(tid) }
            }
            if targets.isEmpty {
                let i = Item(id: 0, taskID: id, ord: items.count + 1, text: Self.cut(text, Item.maxText))
                _ = try store.insertItem(i)
                try store.log(nil, "rejected", "\(by)打回：\(Self.clip(text, 300))（已作为第 \(i.ord) 项）", at: at, task: id)
            } else {
                try store.log(nil, "rejected", "\(by)打回：\(Self.clip(text, 300))（已送给工单 \(targets.map { "#\($0)" }.joined(separator: "、"))）", at: at, task: id)
            }
            try backToDoing(&t, reason: "打回，回到「\(Self.firstDoing(t.stages).name)」", at: at)
            for tid in targets {
                try feedback(tid, text: "打回：\(text)", by: by)
                try applyFollowUpToTask(try requireTicket(tid), by: by, at: at, redo: true) // 做完的项退回重做
            }
            try orgChanged(id) // 组织任务：阶段 / 清单项上行
        }
    }

    /// 取消：`status = cancelled`；名下打开的工单 `stop`（常驻角色正在做别的单时不中断，现有规则）；
    /// 依赖它的任务的清单项标 blocked 并进需要你（注意事项 C-09 / C-14）。
    public func cancelTask(_ id: Int64, by: String = "你") throws {
        try store.transaction {
            var t = try requireTask(id)
            guard t.status == .open else { throw SuperagentError("任务 \(t.label) \(t.status.label)，不用取消") }
            let at = now()
            t.status = .cancelled
            t.notifiedStage = nil
            t.updatedAt = at
            try store.saveTask(t) // 先置取消，再停工单（停工单会尝试推进任务，取消的任务不动）
            let open = try store.tickets(task: id).filter(\.isOpen)
            for ticket in open { try stop(ticket.id, by: by, reason: "任务 \(t.label) 已取消") }
            try store.dropEffect(.notify, t.label)
            try store.log(nil, "cancelled", "\(by)取消了任务" + (open.isEmpty ? "" : "，停止了工单 " + open.map { "#\($0.id)" }.joined(separator: "、")),
                          at: at, task: id)
            // 依赖它的任务：没在做的项标受阻，进「需要你」（正在被工单做的项由工单自己管）。
            for dep in try store.dependents(of: id) {
                guard let d = try store.task(dep), d.status == .open else { continue }
                var blocked: [Int] = []
                for var i in try store.items(dep) where i.status == .todo || i.status == .doing {
                    if let tid = i.ticketID, let tk = try store.ticket(tid), tk.isOpen { continue }
                    i.status = .blocked
                    try store.saveItem(i)
                    blocked.append(i.ord)
                }
                guard !blocked.isEmpty else { continue }
                try store.log(nil, "blocked", "前置任务 \(t.label) 已取消，\(Self.ordLabel(blocked))受阻", at: at, task: dep)
                try store.enqueue(.notify, d.label, at: at)
            }
            try orgChanged(id) // 组织任务：本地取消 = 这个节点放弃，上行
        }
    }

    /// 已放弃（§4.1、§5.3、注意事项 D-04）：Agent 把它的项都报了 dropped、人确认。只在「所有项都未分配且没有一项 done」时允许，
    /// 否则抛错（还有人在做的、做完一部分的，不要了就取消）。`status = dropped`；名下还开着的工单 `stop`；记 timeline。
    /// 之后的跟进（加项、分配、回报）会像已完成的任务一样重新打开它。
    public func dropTask(_ id: Int64, by: String = "你") throws {
        try store.transaction {
            var t = try requireTask(id)
            guard t.status == .open else { throw SuperagentError("任务 \(t.label) \(t.status.label)，不能标为已放弃") }
            let items = try store.items(id)
            guard items.allSatisfy({ $0.assignee == .unassigned && $0.status != .done }) else {
                throw SuperagentError("任务 \(t.label) 还有已分配或已完成的清单项，不能标为已放弃；不要了就取消任务")
            }
            let at = now()
            t.status = .dropped
            t.notifiedStage = nil
            t.updatedAt = at
            try store.saveTask(t) // 先置已放弃，再停工单（停工单会尝试推进任务，已放弃的不动）
            let open = try store.tickets(task: id).filter(\.isOpen)
            for ticket in open { try stop(ticket.id, by: by, reason: "任务 \(t.label) 已放弃") }
            try store.dropEffect(.notify, t.label)
            try store.log(nil, "dropped", "\(by)确认任务已放弃：清单项都被放弃了，没有一项完成"
                          + (open.isEmpty ? "" : "；停止了工单 " + open.map { "#\($0.id)" }.joined(separator: "、")), at: at, task: id)
            try orgChanged(id) // 组织任务：放弃上行（status = dropped）
        }
    }

    /// 对已完成任务的跟进（打回、补充、新增项）→ 重新打开：`open`、第一个 `doing`。被取消的不能重开（注意事项 C-10）。
    func reopenTask(_ t: inout WorkTask, by: String, at: Double) throws {
        try requireNotCancelled(t)
        guard t.status != .open else { return }
        t.status = .open
        t.stage = Self.firstDoing(t.stages).name
        t.notifiedStage = nil
        t.updatedAt = at
        try store.saveTask(t)
        try store.log(nil, "resumed", "\(by)的跟进重新打开了任务", at: at, task: t.id)
    }

    // MARK: - 回报映射（由 `report()` / `handback()` 在同一事务里调用；§5.3、注意事项 C-07 / D-01～D-05）

    /// `ack` → 这张单的项 doing；`progress --item n` → 第 n 项 done（n 不在 `itemIDs` 里 → 抛错「第 n 项不归这张工单」）；
    /// `ready` → 全部项 done（`delivered` 为真时工单已结束）；`blocked / --ask / failed` → 项 blocked；`dropped` → 项回 todo 未分配。
    /// 属于任务的开发工单（`role.edits && role.review`）ready 后，若有「评审」角色 → `autoReview`。
    /// 每次变化后 `advanceIfComplete`；通知按任务 × 阶段入队（key `A-<id>`），不按工单。工单没有任务时什么都不做。
    func applyReportToTask(_ t: Ticket, _ r: Report, ask: String?, delivered: Bool, at: Double) throws {
        guard let taskID = t.taskID, var task = try store.task(taskID) else {
            if r.item != nil { throw SuperagentError("这张工单不属于任务，没有清单项；不要带 --item") }
            return
        }
        if task.status == .done || task.status == .dropped { try reopenTask(&task, by: "工单 #\(t.id)", at: at) }
        guard task.status == .open else { return }
        let items = try store.items(taskID)
        let mine = items.filter { $0.ticketID == t.id }
        let what = mine.isEmpty ? (t.reviewOf != nil ? "评审工单 #\(t.id)" : "工单 #\(t.id)") : "\(Self.ordLabel(mine.map(\.ord)))（工单 #\(t.id)）"
        let head = "[TFA] 任务 \(task.label)「\(task.title)」"
        let summary = Self.clip(r.summary, 400)
        var relay: String?
        var finished: [Int] = []
        switch r.state {
        case .progress:
            if let ord = r.item {
                guard let i = items.first(where: { $0.ord == ord }) else { throw Self.noItem(task, ord, items.count) }
                guard t.itemIDs.contains(i.id) else {
                    let owned = items.filter { t.itemIDs.contains($0.id) }.map { String($0.ord) }
                    throw SuperagentError("第 \(ord) 项不归这张工单（你负责的是 \(owned.isEmpty ? "无" : owned.joined(separator: "、"))）")
                }
                if i.ticketID != t.id {
                    try store.log(t.id, "item", "第 \(ord) 项已不归工单 #\(t.id)（改派或退回），这次回报不改它", at: at, task: taskID) // C-07
                } else if i.status != .done {
                    try finish(i, by: t.role, at: at)
                    finished.append(ord)
                    try store.log(t.id, "item", "工单 #\(t.id)（\(t.role)）完成第 \(ord) 项：\(summary)", at: at, task: taskID)
                }
            }
            // 其余没做完的项：还在做 = 工作中（没 ack 就回报也算开始了）；带问题 = 等人，受阻。
            for var i in mine where i.status != .done && !finished.contains(i.ord) {
                i.status = ask == nil ? .doing : .blocked
                if i.startedAt == nil { i.startedAt = at }
                try store.saveItem(i)
            }
            if let ask { relay = "\(head)\(what)进行中。需要人回答：\(Self.clip(ask, 300))" }
        case .ready:
            guard delivered else {
                for var i in mine where i.status != .done {
                    i.status = .doing
                    if i.startedAt == nil { i.startedAt = at }
                    try store.saveItem(i)
                }
                try store.log(t.id, "item", "工单 #\(t.id) 报了 ready，但还有跟进没送到；等它处理完再算", at: at, task: taskID)
                relay = "\(head)\(what)报了 ready，但还有跟进没送到，等下一轮。"
                break
            }
            for id in t.itemIDs {
                guard let i = items.first(where: { $0.id == id }) else { continue }
                if i.ticketID != t.id {
                    if i.status != .done {
                        try store.log(t.id, "item", "第 \(i.ord) 项已不归工单 #\(t.id)（改派或退回），这次回报不改它", at: at, task: taskID) // C-07
                    }
                } else if i.status != .done {
                    try finish(i, by: t.role, at: at)
                    finished.append(i.ord)
                }
            }
            if t.reviewOf != nil {
                try store.log(t.id, "review", "评审结论（工单 #\(t.id)）：\(summary)", at: at, task: taskID)
            } else {
                try store.log(t.id, "item", "工单 #\(t.id)（\(t.role)）交付" + (finished.isEmpty ? "" : "，\(Self.ordLabel(finished))完成") + "：\(summary)", at: at, task: taskID)
                if let role = try store.role(t.role), role.edits, role.review { try autoReview(for: t, at: at) }
            }
        case .blocked, .failed:
            for var i in mine where i.status != .done { i.status = .blocked; try store.saveItem(i) }
            relay = "\(head)\(what)\(r.state == .blocked ? "受阻" : "失败")：\(summary)" + (ask.map { "。需要人回答：\(Self.clip($0, 300))" } ?? "")
        case .dropped:
            var back: [Int] = []
            for var i in mine where i.status != .done {
                i.status = .todo
                i.assignee = .unassigned
                i.ticketID = nil
                i.startedAt = nil
                try store.saveItem(i)
                back.append(i.ord)
            }
            try store.log(t.id, "item", "工单 #\(t.id)（\(t.role)）放弃：\(summary)" + (back.isEmpty ? "" : "；\(Self.ordLabel(back))待重新分配"), at: at, task: taskID)
        case .waiting:
            break // 由 TFA 自己记（D-05），不进 report()
        }
        try advanceIfComplete(taskID, at: at)
        if r.state == .ready, delivered {
            let after = try requireTask(taskID)
            let open = try store.tickets(task: taskID).filter(\.isOpen)
            let lead = t.reviewOf != nil
                ? "评审结论（工单 #\(t.id)）：\(Self.sentence(summary))"
                : "\(Self.ordLabel(finished.isEmpty ? mine.map(\.ord) : finished))已完成（工单 #\(t.id)，\(t.role)）：\(Self.sentence(summary))"
            let tail: String
            if let review = open.first(where: { $0.reviewOf == t.id }) {
                tail = "已派评审（工单 #\(review.id)），结论出来会进「待评审」"
            } else if after.status == .done {
                tail = "任务已完成"
            } else if after.stageKind == .review {
                tail = "已进入待评审，在「需要你」里等人通过"
            } else {
                let left = try store.items(taskID).filter { $0.status != .done }.map(\.ord)
                tail = left.isEmpty ? "等自动评审的结论" : "清单还有\(Self.ordLabel(left))没完成"
            }
            relay = "\(head)\(lead)。\(tail)。"
        }
        if let relay { try queueRelay(t.id, relay, at: at) }
        if ask != nil || r.state == .blocked || r.state == .failed { try store.enqueue(.notify, task.label, at: at) }
        try orgChanged(taskID) // 组织任务：回报改了清单项 / 需要人，上行
    }

    /// `ack` 的清单项映射（`ack()` 在事务里调用）：这张单的项 → doing。
    func applyAckToTask(_ t: Ticket, at: Double) throws {
        guard let taskID = t.taskID else { return }
        for var i in try store.items(taskID) where i.ticketID == t.id && i.status == .todo {
            i.status = .doing
            i.startedAt = at
            try store.saveItem(i)
        }
        try orgChanged(taskID) // 组织任务：开始做了，上行
    }

    /// 人（或主管）对工单的跟进 / 重试（`feedback` / `attach` / `retry` 在事务里调用）：这张单受阻的项回到工作中（注意事项 D-03）；
    /// `redo` 只有打回（`rejectTask`）传真：做完的项也退回工作中重做。跟进的是已完成任务的工单 → 任务重新打开（注意事项 C-10）。
    func applyFollowUpToTask(_ t: Ticket, by: String, at: Double, redo: Bool = false) throws {
        guard let taskID = t.taskID, var task = try store.task(taskID), task.status != .cancelled else { return }
        if task.status != .open { try reopenTask(&task, by: by, at: at) }
        // 待评审时跟进工单 = 要返工：回到进行中，否则它再报 ready 会绕过人的通过直接完成。
        if task.stageKind == .review { try backToDoing(&task, reason: "\(by)跟进了工单 #\(t.id)，回到「\(Self.firstDoing(task.stages).name)」", at: at) }
        for var i in try store.items(taskID) where i.ticketID == t.id && (i.status == .blocked || (redo && i.status == .done)) {
            i.status = .doing
            i.doneAt = nil
            i.doneBy = nil
            if i.startedAt == nil { i.startedAt = at }
            try store.saveItem(i)
        }
        try orgChanged(taskID) // 组织任务：受阻解开 / 需要人变了，上行
    }

    /// 自动评审：为开发工单 `dev` 建一张「评审」工单（`createTicket(role: 评审, taskID:, itemIDs: [], reviewOf: dev.id)`，
    /// `repo` = dev 的工作目录，request 说明核对什么）。评审工单 ready（直接交付）→ 它的 summary 成为 `TaskView.reviewSummary`，
    /// 任务才能进 `review`。没有「评审」角色就跳过。
    func autoReview(for dev: Ticket, at: Double) throws {
        guard let taskID = dev.taskID, let task = try store.task(taskID), let reviewer = try store.role(Role.reviewer) else { return }
        // 上一版的评审还开着（人又让开发改了一版）：不再新建，让它重新核对。
        if var review = try store.tickets(task: taskID).first(where: { $0.reviewOf == dev.id && $0.isOpen }) {
            try queueInput(&review, .system, "工单 #\(dev.id) 又交付了一版，重新核对。新的回报：\(Self.clip(dev.reportSummary, 400))", by: "TFA")
            try store.log(dev.id, "review", "又交付了一版，让评审工单 #\(review.id) 重新核对", at: at, task: taskID)
            return
        }
        let items = try store.items(taskID).filter { dev.itemIDs.contains($0.id) }
        let dir = dev.dir.isEmpty ? dev.repo : dev.dir
        var s = "[任务 \(task.label)] 核对工单 #\(dev.id) 的交付：\(task.title)\n原文：\(task.request)\n"
        if !items.isEmpty { s += "工单 #\(dev.id) 负责的清单项：\n" + items.map(\.line).joined(separator: "\n") + "\n" }
        s += "工单 #\(dev.id) 的回报：\(dev.reportSummary)\n"
        s += "工作目录：\(dir)" + (dev.branch.isEmpty ? "" : "（分支 \(dev.branch)）") + "\n"
        s += "对照原文和清单项核对：改动是否完整、相关改动有没有合并、能否构建运行。只读，不改文件。结论第一句写「通过」或「有问题」。"
        var trigger = Trigger(id: try store.nextTriggerID(), source: "review:#\(dev.id)", strength: .explicit, text: s,
                              repo: dir, status: .pending, ticketID: nil, createdAt: at)
        try store.insertTrigger(trigger)
        let id = try createTicket(trigger: &trigger, title: String("评审 #\(dev.id) · \(task.title)".prefix(WorkTask.maxTitle)), request: s,
                                  repo: dir, note: "", worktree: nil, by: "TFA", rules: [:], role: reviewer,
                                  taskID: taskID, itemIDs: [], reviewOf: dev.id)
        try store.log(dev.id, "review", "已派评审（工单 #\(id)）核对工单 #\(dev.id) 的交付", at: at, task: taskID)
    }

    /// `handback` 的任务映射：属于任务的工单退回请求 → **新任务**（`source = .handback`，`sourceRef = "#<工单>"`，
    /// scope 同原任务，一项 = 退回的请求）（注意事项 C-08）。退回的是「越界请求」，原工单继续做自己的项，清单项不动
    /// （执行者做不了自己的项该报 dropped）。返回新任务；工单没有任务时返回 nil（沿用现有的候选路径）。
    func handbackToTask(_ t: Ticket, request: String, reason: String, at: Double) throws -> WorkTask? {
        guard let taskID = t.taskID, let task = try store.task(taskID) else { return nil }
        // Agent 生成的文字：超长截断并记录（注意事项 B-12）。
        let title = Self.cut(request, WorkTask.maxTitle)
        let text = Self.cut(request, Item.maxText)
        let w = try store.workflow(task.workflow) ?? Workflow.builtins[0]
        var n = WorkTask(id: 0, title: title, request: request, source: .handback, sourceRef: "#\(t.id)", scope: task.scope,
                         priority: task.priority, workflow: w.id, stages: w.stages, stage: Self.firstDoing(w.stages).name,
                         createdAt: at, updatedAt: at)
        n.id = try store.insertTask(n)
        _ = try store.insertItem(Item(id: 0, taskID: n.id, ord: 1, text: text))
        try store.log(nil, "task", "工单 #\(t.id)（任务 \(task.label)）退回的请求成为新任务；原因：\(Self.clip(reason, 200))"
                      + (text.count < request.count ? "；清单项按 \(Item.maxText) 字截断，原文见任务" : ""), at: at, task: n.id)
        try store.log(t.id, "handback", "退回请求，成为新任务 \(n.label)：\(Self.clip(reason, 200))", at: at, task: taskID)
        try queueRelay(t.id, "[TFA] 工单 #\(t.id) 退回了一个请求，已作为新任务 \(n.label) 进「待分配」：\(Self.clip(request, 300))；原因：\(Self.clip(reason, 120))。"
                       + "谁来做由人在清单里决定；不要挂回 #\(t.id)。", at: at)
        return n
    }

    // MARK: - 读视图

    public func taskView(_ id: Int64) throws -> TaskView {
        let t = try requireTask(id)
        var v = try makeView(t, items: try store.items(id), tickets: try store.tickets(task: id))
        v.syncConflicts = try store.orgConflicts(taskIDs: [id])[id] ?? [] // 组织同步（第 3 期）
        return v
    }

    /// 打开的任务（新的在前）+ 最近结束的 `endedLimit` 个（按更新时间）；一次聚合，不 N+1（注意事项 B-11）。
    /// 分区（需要你 / 进行中 / 待分配 / 已完成）由界面按 `needsYou` / `unassignedCount` / `task.status` 自己分。
    public func taskViews(endedLimit: Int = 30) throws -> [TaskView] {
        let tasks = try store.tasks(endedLimit: endedLimit)
        let ids = tasks.map(\.id)
        let items = try store.items(taskIDs: ids)
        let tickets = try store.tickets(taskIDs: ids)
        let conflicts = try store.orgConflicts(taskIDs: ids) // 组织同步（第 3 期）
        return try tasks.map {
            var v = try makeView($0, items: items[$0.id] ?? [], tickets: tickets[$0.id] ?? [])
            v.syncConflicts = conflicts[$0.id] ?? []
            return v
        }
    }

    /// §4.3：名下打开工单的 PersonAction ∪ {review}（当前阶段是 review）∪ {blocked}（清单项受阻且没有打开的工单）。
    /// 组织任务的「待评审」不算需要你：通过 / 打回由组织负责人在 Web 上做（第 3 期）。
    private func makeView(_ t: WorkTask, items: [Item], tickets: [Ticket]) throws -> TaskView {
        let views = try tickets.map(view)
        var needs = Set<PersonAction>()
        if t.isOpen {
            for v in views where v.ticket.isOpen { if let a = v.stage.needsPerson { needs.insert(a) } }
            if t.stageKind == .review, t.origin == nil { needs.insert(.review) }
            let open = Set(tickets.filter(\.isOpen).map(\.id))
            if items.contains(where: { $0.status == .blocked && !($0.ticketID.map(open.contains) ?? false) }) { needs.insert(.blocked) }
        }
        let reviewing = tickets.contains { $0.isOpen && $0.reviewOf != nil }
        let summary = reviewing ? nil : tickets.last(where: { $0.reviewOf != nil && $0.status == .done })?.reportSummary
        return TaskView(task: t, items: items, tickets: views, needsYou: needs.sorted(), reviewSummary: summary, reviewing: reviewing)
    }

    // MARK: - 通知与打扰（注意事项 G-01～G-03）

    /// 通知粒度是任务 × 阶段：`task.notifiedStage` 去重；两件事同时需要你 → 一条「任务 A-12 有 2 件事需要你」。
    /// 发出时当天打扰计数 +1（本地日历日）。返回要通知的内容（nil = 不需要）。
    ///
    /// 去重键：`notifiedStage = "<阶段名>|<事由>|<事由>…"`，事由 = 工单号 + 动作 + 回报时间（送达失败用错误文案）、
    /// `review`（进了待评审）、`blocked:<序号>`（无工单的受阻项）。有没通知过的事由才发；阶段变了（打回、重开）键自然不同。
    public func takeTaskNotification(_ id: Int64) throws -> (title: String, body: String)? {
        try store.transaction {
            var t = try requireTask(id)
            let v = try taskView(id)
            guard t.isOpen, let first = v.firstNeed else { return nil }
            var causes: [String] = []
            var detail: [PersonAction: String] = [:]
            for tv in v.tickets where tv.ticket.isOpen {
                guard let a = tv.stage.needsPerson else { continue }
                let tk = tv.ticket
                let cause: String
                switch a {
                case .delivery: cause = "#\(tk.id):delivery:\(Self.clip(tk.deliveryError ?? "", 40))"
                // 问题文字也进键：看门狗挂上的问题不改 reportAt，和它之前问过、已答过的那件事要分得开。
                case .answer: cause = "#\(tk.id):answer:\(Int64((tk.reportAt ?? 0) * 1000)):\(Self.clip(tk.attention ?? "", 40))"
                default: cause = "#\(tk.id):\(a.rawValue):\(Int64((tk.reportAt ?? 0) * 1000))"
                }
                causes.append(cause.replacingOccurrences(of: "|", with: "/"))
                if detail[a] == nil {
                    switch a {
                    case .answer: detail[a] = tk.attention ?? tk.reportSummary
                    case .delivery: detail[a] = tk.deliveryError ?? ""
                    default: detail[a] = tk.reportSummary
                    }
                }
            }
            if t.stageKind == .review, t.origin == nil { // 组织任务的通过在组织那边，不在这里等你
                causes.append("review")
                if detail[.review] == nil { detail[.review] = v.reviewSummary ?? Self.lastDelivery(v.tickets.map(\.ticket))?.reportSummary ?? "清单全部完成" }
            }
            let open = Set(v.tickets.filter(\.ticket.isOpen).map(\.id))
            let stuck = v.items.filter { $0.status == .blocked && !($0.ticketID.map(open.contains) ?? false) }.map(\.ord)
            if !stuck.isEmpty {
                causes.append("blocked:" + stuck.map(String.init).joined(separator: ","))
                if detail[.blocked] == nil { detail[.blocked] = "\(Self.ordLabel(stuck))受阻" }
            }
            let prefix = t.stage + "|"
            let notified = Set(t.notifiedStage.map { $0.hasPrefix(prefix) ? $0.dropFirst(prefix.count).split(separator: "|").map(String.init) : [] } ?? [])
            guard causes.contains(where: { !notified.contains($0) }) else { return nil }
            t.notifiedStage = prefix + causes.sorted().joined(separator: "|")
            try store.saveTask(t)
            try store.bumpInterruptions(day: SuperagentStore.day(now()))
            try orgInterrupted(day: SuperagentStore.day(now())) // 组织：当天打扰次数上行（EngineOrg.swift）
            let title = causes.count > 1 ? "任务 \(t.label) 有 \(causes.count) 件事需要你：\(t.title)" : "任务 \(t.label) \(first.label)：\(t.title)"
            return (title, Self.clip(detail[first] ?? t.title, 200))
        }
    }

    /// 今天打扰了几次。
    public func interruptionsToday() throws -> Int {
        try store.interruptions(day: SuperagentStore.day(now()))
    }

    /// 第 2 期：今天的打扰达到预算后，任务层送主管的每条消息带上它，主管据此合并转告；不压制（注意事项 G-03）。
    func overBudgetPrefix() throws -> String? {
        let n = try interruptionsToday()
        let budget = try store.settings().interruptionBudget
        return n >= budget ? "[今天已打扰 \(n)/\(budget) 次] " : nil
    }

    // MARK: - 工作流模板

    /// 新建 / 更新模板（内置的不能改）；校验 `Workflow.problem`。
    public func setWorkflow(_ w: Workflow, by: String = "你") throws {
        guard !w.isBuiltin else { throw SuperagentError("「\(w.name)」是内置模板，不能改") }
        if let p = w.problem { throw SuperagentError(p) }
        try store.transaction {
            try store.saveWorkflow(w)
            try store.log(nil, "workflow", "\(by)保存了工作流模板「\(w.name)」", at: now())
        }
    }

    public func deleteWorkflow(_ id: String, by: String = "你") throws {
        guard !Workflow.builtins.contains(where: { $0.id == id }) else { throw SuperagentError("内置模板不能删除") }
        try store.transaction {
            try store.deleteWorkflow(id)
            try store.log(nil, "workflow", "\(by)删除了工作流模板 \(id)", at: now())
        }
    }

    // MARK: - 迁移（注意事项 B-01 / B-02 / J-02）

    /// 现有工单 → 任务：每张没有 `task_id` 的打开工单一个任务（标题 / 原文 / 目录原样；一项 = 标题，assignee = `.agent(role)`，
    /// `ticket_id` 回指；阶段按工单现状），已结束的只迁最近 30 张为已完成 / 已取消。整体一个事务；`kv.migrated.tasks = 1` 后
    /// 不再跑（幂等，可重跑）；**不改工单的任何已有列**，只写 `task_id`。返回迁移的工单数。调用方先 `store.backup()`。
    @discardableResult
    public func migrateTicketsToTasks() throws -> Int {
        try store.transaction {
            guard try store.kv("migrated.tasks") != "1" else { return 0 }
            let at = now()
            var n = 0
            for t in try store.tickets(endedLimit: 30) where t.taskID == nil {
                let role = try store.role(t.role)
                let w = Workflow.builtins.first { $0.id == ((role?.review ?? true) ? Workflow.defaultID : Workflow.noReviewID) }!
                let trigger = try t.triggerID.flatMap { try store.trigger($0) }
                let inReview = try t.isOpen && view(t).stage == .person(.review)
                let stage: WorkflowStage
                if !t.isOpen { stage = w.stages.last! }
                else if inReview, let r = w.stages.first(where: { $0.kind == .review }) { stage = r }
                else { stage = Self.firstDoing(w.stages) }
                var task = WorkTask(id: 0, title: t.title, request: t.request, source: Self.source(of: trigger), sourceRef: t.triggerID,
                                    scope: t.repo, workflow: w.id, stages: w.stages, stage: stage.name, status: Self.status(of: t.status),
                                    resultSummary: t.status == .done && t.reportState == .ready ? t.reportSummary : "", note: t.note,
                                    createdAt: t.createdAt, updatedAt: t.updatedAt)
                task.id = try store.insertTask(task)
                let done = t.status == .done || inReview
                let running = try store.latestAssignment(t.id)?.state == .running
                let itemStatus: ItemStatus
                if done { itemStatus = .done }
                else if !t.isOpen { itemStatus = .todo }
                else if t.reportState == .blocked || t.reportState == .failed || t.attention != nil { itemStatus = .blocked }
                else if !t.ack.isEmpty || running { itemStatus = .doing }
                else { itemStatus = .todo }
                let item = Item(id: 0, taskID: task.id, ord: 1, text: String(t.title.prefix(Item.maxText)), assignee: .agent(role: t.role),
                                status: itemStatus, ticketID: t.id, doneAt: done ? (t.endedAt ?? t.reportAt) : nil, doneBy: done ? t.role : nil)
                let itemID = try store.insertItem(item)
                try store.linkTicket(t.id, task: task.id, itemIDs: [itemID])
                try store.retagEvents(ticket: t.id, task: task.id)
                try store.log(t.id, "migrated", "工单 #\(t.id) 迁为任务 \(task.label)", at: at, task: task.id)
                n += 1
            }
            try store.setKV("migrated.tasks", "1")
            return n
        }
    }

    // MARK: - 内部

    func requireTask(_ id: Int64) throws -> WorkTask {
        guard let t = try store.task(id) else { throw SuperagentError("任务 A-\(id) 不存在") }
        return t
    }

    private func requireNotCancelled(_ t: WorkTask) throws {
        guard t.status != .cancelled else { throw SuperagentError("任务 \(t.label) 已取消；要做就新建任务") }
    }

    private func requireItem(_ t: WorkTask, _ ord: Int) throws -> Item {
        let items = try store.items(t.id)
        guard let i = items.first(where: { $0.ord == ord }) else { throw Self.noItem(t, ord, items.count) }
        return i
    }

    private static func noItem(_ t: WorkTask, _ ord: Int, _ count: Int) -> SuperagentError {
        SuperagentError("任务 \(t.label) 没有第 \(ord) 项（共 \(count) 项）")
    }

    /// 清单项标 done（调用方在事务里）。
    private func finish(_ item: Item, by: String, at: Double) throws {
        var i = item
        i.status = .done
        i.doneAt = at
        i.doneBy = by
        try store.saveItem(i)
    }

    /// 回到第一个 `doing`（打回 / 待评审时加项或重新分配）；阶段变了才记 timeline。通知键随阶段名变化，不用另清。
    private func backToDoing(_ t: inout WorkTask, reason: String, at: Double) throws {
        let doing = Self.firstDoing(t.stages)
        let changed = t.stage != doing.name
        t.stage = doing.name
        t.notifiedStage = nil
        t.updatedAt = at
        try store.saveTask(t)
        if changed {
            try store.dropEffect(.notify, t.label)
            try store.log(nil, "stage", reason, at: at, task: t.id)
        }
    }

    /// 进入一个阶段（自动推进 / 通过共用）：`review` 入队通知；`done` 结束任务并写 `resultSummary`。
    private func enter(_ t: inout WorkTask, _ stage: WorkflowStage, tickets: [Ticket], at: Double) throws {
        t.stage = stage.name
        t.notifiedStage = nil
        t.updatedAt = at
        switch stage.kind {
        case .review:
            try store.saveTask(t)
            try store.log(nil, "stage", "清单全部完成，进入「\(stage.name)」等你通过", at: at, task: t.id)
            try store.enqueue(.notify, t.label, at: at) // C-13：owner 是你自己也进「需要你」
        case .done:
            t.status = .done
            if let last = Self.lastDelivery(tickets) { t.resultSummary = last.reportSummary }
            try store.saveTask(t)
            try store.dropEffect(.notify, t.label)
            try store.log(nil, "stage", "任务完成" + (t.resultSummary.isEmpty ? "" : "：\(Self.clip(t.resultSummary, 200))"), at: at, task: t.id)
        case .doing, .todo:
            try store.saveTask(t)
            try store.log(nil, "stage", "进入「\(stage.name)」", at: at, task: t.id)
        }
    }

    /// 最后一张交付（ready）的非评审工单。
    private static func lastDelivery(_ tickets: [Ticket]) -> Ticket? {
        tickets.filter { $0.reviewOf == nil && $0.reportState == .ready }.max { ($0.reportAt ?? 0, $0.id) < ($1.reportAt ?? 0, $1.id) }
    }

    private func resolveWorkflow(_ id: String?, scope: String) throws -> Workflow {
        let all = try store.workflows()
        if let id {
            guard let w = all.first(where: { $0.id == id }) else { throw SuperagentError("没有工作流模板「\(id)」") }
            return w
        }
        if !scope.isEmpty, let w = all.first(where: { $0.scope == scope }) { return w }
        return all.first { $0.id == Workflow.defaultID } ?? Workflow.builtins[0]
    }

    static func firstDoing(_ stages: [WorkflowStage]) -> WorkflowStage {
        stages.first { $0.kind == .doing } ?? stages.first ?? Workflow.builtins[0].stages[1]
    }

    static func itemTexts(_ texts: [String]) throws -> [String] {
        try texts.map {
            let s = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { throw SuperagentError("清单项不能为空") }
            guard s.count <= Item.maxText else { throw SuperagentError("清单项最多 \(Item.maxText) 字：\(Self.clip(s, 30))") }
            return s
        }
    }

    /// H-02：交给会改文件的角色时，任务的目录要存在、是目录、不是家目录或根目录。有 stat，调用方在事务外调。
    static func checkScope(_ t: WorkTask) throws {
        guard !t.scope.isEmpty else { throw SuperagentError("任务 \(t.label) 没有项目目录，不能交给会改文件的角色：先在任务里填范围（目录）") }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = URL(fileURLWithPath: t.scope).standardizedFileURL.path
        guard path != "/", path != home else { throw SuperagentError("任务 \(t.label) 的目录不能是家目录或根目录：改成要改的项目目录") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { throw SuperagentError("任务 \(t.label) 的目录不存在：\(t.scope)") }
        guard isDir.boolValue else { throw SuperagentError("任务 \(t.label) 的范围不是目录：\(t.scope)") }
    }

    /// 执行者看到的请求文本（§5.2）：「其余清单项」只列序号和一句话，不写谁在做、不写别人的工单号（注意事项 D-06）。
    static func agentRequest(task t: WorkTask, mine: [Item], all: [Item]) -> String {
        var s = "[任务 \(t.label)] \(t.title)\n原文：\(t.request)\n你负责的清单项：\n"
        s += mine.map(\.line).joined(separator: "\n") + "\n"
        let others = all.filter { o in !mine.contains { $0.id == o.id } }
        if !others.isEmpty { s += "其余清单项（不归你）：" + others.map(\.line).joined(separator: " · ") + "\n" }
        if !t.scope.isEmpty { s += "目录：\(t.scope)\n" }
        s += "完成一项就 `tfa report --state progress --item <n> --summary …`；全部完成报 ready。"
        return s
    }

    /// 序号的一句话：`第 3–4 项`、`第 1–3、5 项`（连续的合成区间）。
    public static func ordLabel(_ ords: [Int]) -> String {
        let s = Array(Set(ords)).sorted()
        guard !s.isEmpty else { return "" }
        var parts: [String] = []
        var i = 0
        while i < s.count {
            var j = i
            while j + 1 < s.count, s[j + 1] == s[j] + 1 { j += 1 }
            parts.append(j > i ? "\(s[i])–\(s[j])" : "\(s[i])")
            i = j + 1
        }
        return "第 " + parts.joined(separator: "、") + " 项"
    }

    /// 截到 n 字（Agent / 规则 / 定时生成的文字；人写的超长要报错，注意事项 B-12）。
    static func cut(_ s: String, _ n: Int) -> String { String(clip(s, n).prefix(n)) }

    /// 拼进句子前去掉末尾的句号和空白（summary 自己带「。」时不会连成「。。」）。
    static func sentence(_ s: String) -> String {
        var t = Substring(s)
        while let last = t.last, last == "。" || last == "." || last.isWhitespace { t.removeLast() }
        return String(t)
    }

    /// 迁移：工单的 trigger 来源 → 任务来源。
    private static func source(of trigger: Trigger?) -> TaskSource {
        guard let trigger else { return .manual }
        if trigger.source == "router" { return .router }
        if trigger.source.hasPrefix("handback:") { return .handback }
        if trigger.source.hasPrefix("schedule:") { return .schedule }
        if trigger.strength == .inferred { return .rule }
        return .manual
    }

    private static func status(of s: TicketStatus) -> TaskStatus {
        switch s {
        case .open: return .open
        case .done: return .done
        case .dropped: return .dropped
        case .stopped: return .cancelled
        }
    }
}
