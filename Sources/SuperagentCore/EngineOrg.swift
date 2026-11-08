import Foundation

// 组织同步的引擎侧（TFA-工作清单-需求文档 §10.3；docs/worklist/org-protocol.md §3；注意事项 I）。
// 下行：组织任务 upsert 成本地任务（按 origin + origin_id 唯一、幂等，I-01）；任务字段服务端为准，清单勾选取并集，
// 同一项两边改成不同的非 done 状态 → 冲突，进「需要你」让人定（I-03）。
// 上行：引擎里改了组织任务的地方只调 `orgChanged`，把要传的东西记进 outbox（I-02）；网络在 App 的 OrgSync，按序重放。
// 单一写入者不变：这里是唯一写组织任务到 superagent.db 的地方。

extension SuperagentEngine {
    // MARK: - 下行：组织任务 → 本地（I-01 / I-03）

    /// 把服务端给的任务 upsert 到本地：没有就建（`source = org`、工作流用服务端的快照），有就按版本合并；同一版本什么都不做。
    /// `claimable` = 这些是本范围「待领取」的（本地也建一行，`syncState = "claimable"`，不在进行中里显示）。
    /// `directory`：组织范围 → 本地目录（App 按工作区项目名找；找不到留空，交给会改文件的角色时再提示）。返回本地任务。
    @discardableResult
    public func importOrgTasks(_ dtos: [OrgTaskDTO], origin: String, claimable: Bool = false,
                               directory: ((OrgScopeDTO) -> String?)? = nil, by: String = "组织") throws -> [WorkTask] {
        try store.transaction { try dtos.map { try importOrgTask($0, origin: origin, claimable: claimable, directory: directory, by: by) } }
    }

    /// 领取成功 / 组织派单到本节点：待领取的占位行（或新任务）变成普通任务——服务端返回的任务已在第一个 `doing`，本地待分配。
    /// `edits` 给了（派单带授权：能否改文件）就把全部清单项交给「开发」或「助理」；交不出去留在待分配并记 timeline。
    @discardableResult
    public func markClaimed(_ dto: OrgTaskDTO, origin: String, edits: Bool? = nil,
                            directory: ((OrgScopeDTO) -> String?)? = nil, by: String = "组织") throws -> WorkTask {
        try store.transaction {
            let before = try store.task(origin: origin, originID: String(dto.id))
            let t = try importOrgTask(dto, origin: origin, claimable: false, directory: directory, by: by)
            let at = now()
            if before == nil || before?.syncState == "claimable" {
                try store.log(nil, "org", edits == nil ? "\(by)领取了组织任务 \(dto.displayLabel)" : "组织把 \(dto.displayLabel) 派给了这台 TFA", at: at, task: t.id)
            }
            if let edits { try orgAutoAssign(t, edits: edits, by: by, at: at) }
            return try requireTask(t.id)
        }
    }

    /// 被别人领走了（领取 409 / 对账时不在待领取列表里）：待领取的占位行从本地删掉（它从没被做过，不是取消）。
    public func dropClaimable(_ taskID: Int64) throws {
        try store.transaction {
            guard let t = try store.task(taskID) else { return }
            guard t.syncState == "claimable" else { throw SuperagentError("任务 \(t.label) 不是待领取的组织任务") }
            try removeClaimable(t, reason: "组织任务被别人领走了")
        }
    }

    /// 对账：服务端现在可领取的只有 `keeping`（组织任务号）；本地其余待领取的占位行删掉。预留给我这个人的（服务端已进
    /// 第一个 doing、还没绑定节点，不在可领取列表里）留着，它们被别人接手时服务端会发事件。返回删掉的个数。
    @discardableResult
    public func pruneClaimable(origin: String, keeping: Set<String>) throws -> Int {
        try store.transaction {
            var n = 0
            for t in try store.tasks(origin: origin, syncState: "claimable")
            where t.stageKind == .todo && !keeping.contains(t.originID ?? "") {
                try removeClaimable(t, reason: "组织任务被别人领走了")
                n += 1
            }
            return n
        }
    }

    /// 占位行不要了（被别人领走 / 对账时不在列表里 / 组织取消）：从没做过的硬删；做过的（曾派给本节点，释放回待领取池后
    /// 又被别人领走）按取消处理——硬删会让它名下的工单指向不存在的任务、时间线一起消失（注意事项 B-08）。调用方在事务里。
    private func removeClaimable(_ t: WorkTask, reason: String) throws {
        guard try !store.tickets(task: t.id).isEmpty else { try store.deleteTask(t.id); return }
        var t = t
        let at = now()
        t.status = .cancelled
        t.syncState = "synced"
        t.notifiedStage = nil
        t.syncedAt = at
        t.updatedAt = at
        try store.saveTask(t)
        try store.dropEffect(.notify, t.label)
        try store.dropOutbox(task: t.id)
        try store.log(nil, "cancelled", reason + "；之前在这里做过的工单和记录留着", at: at, task: t.id)
    }

    /// 组织取消了任务 / 转交给了别人：本地标为已取消，名下打开的工单停掉，没发出去的上行作废。待领取的占位行直接删。
    public func orgDetach(_ taskID: Int64, reason: String, by: String = "组织") throws {
        try store.transaction {
            guard var t = try store.task(taskID) else { return }
            if t.syncState == "claimable" { try removeClaimable(t, reason: reason); return }
            guard t.status == .open else { return }
            let at = now()
            t.status = .cancelled
            t.notifiedStage = nil
            t.syncedAt = at
            t.updatedAt = at
            try store.saveTask(t) // 先置取消，再停工单（停工单会尝试推进任务，取消的任务不动）
            let open = try store.tickets(task: taskID).filter(\.isOpen)
            for ticket in open { try stop(ticket.id, by: by, reason: reason) }
            try store.dropEffect(.notify, t.label)
            try store.dropOutbox(task: taskID)
            try store.log(nil, "cancelled", reason + (open.isEmpty ? "" : "；停止了工单 " + open.map { "#\($0.id)" }.joined(separator: "、")), at: at, task: taskID)
        }
    }

    /// 组织负责人打回（事件 `task.rejected`；调用方先把服务端的任务同步下来）：回到第一个 `doing`；意见送给原工单、做完的项
    /// 退回重做。意见那条清单项由服务端追加、随下行同步过来，这里**不**本地加项（和 `rejectTask` 的区别）。
    public func orgRejected(_ taskID: Int64, text: String, by: String = "组织负责人") throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "组织负责人打回，看服务端的意见"
        try store.transaction {
            var t = try requireTask(taskID)
            guard t.status == .open else { return }
            let at = now()
            if t.stageKind == .review {
                let doing = Self.firstDoing(t.stages)
                t.stage = doing.name
                t.notifiedStage = nil
                t.updatedAt = at
                try store.saveTask(t)
                try store.dropEffect(.notify, t.label)
                try store.log(nil, "stage", "打回，回到「\(doing.name)」", at: at, task: taskID)
            }
            let items = try store.items(taskID)
            let targets = try items.compactMap(\.ticketID).reduce(into: [Int64]()) { list, tid in
                if !list.contains(tid), let ticket = try store.ticket(tid), ticket.status != .stopped { list.append(tid) }
            }
            if targets.isEmpty {
                try store.log(nil, "rejected", "\(by)打回：\(Self.clip(text, 300))（意见是服务端加的清单项，等人定谁来做）", at: at, task: taskID)
            } else {
                try store.log(nil, "rejected", "\(by)打回：\(Self.clip(text, 300))（已送给工单 \(targets.map { "#\($0)" }.joined(separator: "、"))）", at: at, task: taskID)
                for tid in targets {
                    try feedback(tid, text: "打回：\(text)", by: by)
                    try applyFollowUpToTask(try requireTicket(tid), by: by, at: at, redo: true)
                }
            }
            try orgChanged(taskID)
        }
    }

    /// 组织负责人在 Web 上回答 / 留言（事件 `task.updated`，`change = answer`）：送给在等回答的工单（清掉它的问题，受阻的项回到
    /// 工作中），没有在等的就送给名下打开的工单当补充；一张打开的工单都没有只记活动。
    public func orgAnswered(_ taskID: Int64, text: String, by: String = "组织负责人") throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        try store.transaction {
            let t = try requireTask(taskID)
            guard t.status == .open else { return }
            let open = try store.tickets(task: taskID).filter(\.isOpen)
            let asking = open.filter { $0.attention != nil }
            let targets = asking.isEmpty ? open : asking
            try store.log(nil, "answer", "\(by)回答：\(Self.clip(text, 300))" + (targets.isEmpty ? "（没有打开的工单，只记在这里）" : ""),
                          at: now(), task: taskID)
            for ticket in targets { try feedback(ticket.id, text: text, by: by) }
            try orgChanged(taskID)
        }
    }

    /// 组织主管（或别的节点）往任务上挂的留言（事件 `task.updated`，`change = audit`，`entries[].summary`）：挂到名下打开的工单
    /// （送达执行者，同本地主管的 `attach`）；没有打开的就挂到最近一张交付了的开发 / 助理工单上（它会恢复）；一张都没有只记活动。
    public func orgAttached(_ taskID: Int64, _ texts: [String], by: String = "组织主管") throws {
        let texts = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !texts.isEmpty else { return }
        try store.transaction {
            let t = try requireTask(taskID)
            guard t.status == .open else { return }
            let tickets = try store.tickets(task: taskID).filter { $0.reviewOf == nil && $0.status != .stopped }
            let open = tickets.filter(\.isOpen)
            let targets = open.isEmpty ? Array(tickets.filter { $0.status == .done }.suffix(1)) : open
            let at = now()
            for text in texts {
                try store.log(nil, "attach", "\(by)留言：\(Self.clip(text, 300))" + (targets.isEmpty ? "（没有工单可送，只记在这里）" : ""), at: at, task: taskID)
                for ticket in targets { try attach(ticket.id, text: text, by: by) }
            }
            try orgChanged(taskID)
        }
    }

    /// 人定了冲突的一项以哪边为准（I-03）；没有别的冲突了就回到已同步，并把定下来的状态上传。
    public func resolveConflict(_ taskID: Int64, ord: Int, useServer: Bool, by: String = "你") throws {
        try store.transaction {
            var t = try requireTask(taskID)
            guard var i = try store.items(taskID).first(where: { $0.ord == ord }) else { throw SuperagentError("任务 \(t.label) 没有第 \(ord) 项") }
            guard var st = try store.orgItems(taskID).first(where: { $0.itemID == i.id }), let server = st.conflictServer else {
                throw SuperagentError("任务 \(t.label) 的第 \(ord) 项没有同步冲突")
            }
            let chosen = useServer ? server : (st.conflictLocal ?? .todo)
            let at = now()
            i.status = chosen
            if chosen == .done {
                i.doneAt = i.doneAt ?? at
                i.doneBy = i.doneBy ?? (useServer ? "组织" : by)
            } else {
                i.doneAt = nil
                i.doneBy = nil
            }
            if chosen == .doing, i.startedAt == nil { i.startedAt = at }
            try store.saveItem(i)
            st.conflictLocal = nil
            st.conflictServer = nil
            try store.saveOrgItem(st)
            if try !store.orgItems(taskID).contains(where: { $0.conflictServer != nil }) { t.syncState = "synced" }
            t.updatedAt = at
            try store.saveTask(t)
            try store.log(nil, "conflict", "\(by)定了第 \(ord) 项以\(useServer ? "服务端" : "本地")为准：\(chosen.label)", at: at, task: taskID)
            try advanceIfComplete(taskID, at: at)
            try orgChanged(taskID)
        }
    }

    /// PATCH 成功：服务端返回的任务就是合并后的事实（版本已 +1），按它更新本地；`conflicts` 里的项进冲突。
    public func applyPatchResponse(_ taskID: Int64, _ dto: OrgTaskDTO, conflicts: [OrgConflictDTO], origin: String) throws {
        try store.transaction {
            _ = try importOrgTask(dto, origin: origin, claimable: false, directory: nil, by: "组织")
            if !conflicts.isEmpty { try markConflicts(taskID, conflicts) }
            try markSynced(taskID, version: dto.version)
        }
    }

    /// 记下服务端版本；没有未裁决的冲突就是已同步。
    public func markSynced(_ taskID: Int64, version: Int) throws {
        try store.transaction {
            guard var t = try store.task(taskID), var st = try store.orgState(taskID) else { return }
            st.version = max(st.version, version)
            try store.saveOrgState(st)
            if t.syncState != "claimable" {
                t.syncState = (try store.orgItems(taskID).contains { $0.conflictServer != nil }) ? "conflict" : "synced"
            }
            t.syncedAt = now()
            try store.saveTask(t)
        }
    }

    // MARK: - 上行：outbox 的内容（由 App 的 OrgSync 按序重放）

    /// 改动挂钩：有 origin 的任务 → 阶段 / 勾选 / 结果、需要人、活动摘要三样入队（同类未发送的合并）；没有 origin 的任务
    /// 和待领取的占位行直接返回。调用方在事务里。
    func orgChanged(_ taskID: Int64) throws {
        guard let t = try store.task(taskID), t.origin != nil, t.syncState != "claimable" else { return }
        let at = now()
        for kind in ["patch", "needs", "audit"] { try store.enqueueOutbox(taskID, kind: kind, at: at) }
    }

    /// 打扰计数 +1 了（注意事项 G-02）：注册了组织才入队（没注册的机器不攒队列）。调用方在事务里。
    func orgInterrupted(day: String) throws {
        guard try store.kv("org.nodeID") != nil else { return }
        try store.enqueueOutbox(0, kind: "interruptions", payload: day, at: now())
    }

    /// `PATCH /tasks/{id}` 的 body，从当前本地状态生成：`baseVersion` = 本地记录的服务端版本；只带有服务端 id 的项
    /// （本地自己加的项服务端对不上）；冲突里的项先不传（等人定）。不是组织任务 → nil。
    public func orgPatch(for taskID: Int64) throws -> OrgPatch? {
        guard let t = try store.task(taskID), t.origin != nil, let state = try store.orgState(taskID) else { return nil }
        let map = Dictionary(uniqueKeysWithValues: try store.orgItems(taskID).map { ($0.itemID, $0) })
        let items = try store.items(taskID).compactMap { i -> OrgPatchItem? in
            guard let m = map[i.id], m.conflictServer == nil else { return nil }
            return OrgPatchItem(id: m.originItemID, ord: i.ord, status: i.status.rawValue, doneBy: i.doneBy,
                                doneAt: i.doneAt.map(OrgTime.string), startedAt: i.startedAt.map(OrgTime.string))
        }
        // 结束态只有服务端（通过 / 取消）或节点的放弃能设：本地的取消也只能告诉服务端「这个节点放弃了」。
        let status: String? = t.status == .dropped || t.status == .cancelled ? "dropped" : nil
        return OrgPatch(baseVersion: state.version, stage: t.stage, status: status, items: items,
                        resultSummary: t.resultSummary, updatedAt: OrgTime.string(t.updatedAt))
    }

    /// `POST /tasks/{id}/needs`：这个任务此刻需要人的事。待评审（等组织负责人通过）→ `review`；等你回答 → `answer`；
    /// 受阻 / 停下未回报 / 同步冲突 → `blocked`；失败 / 送达失败 → `failed`；都没有 → `none`。
    public func orgNeeds(for taskID: Int64) throws -> OrgNeedsUpload {
        let v = try taskView(taskID)
        guard v.task.isOpen else { return .none }
        if let c = v.syncConflicts.first { return OrgNeedsUpload(kind: "blocked", question: "同步冲突：" + c.line) }
        if v.task.stageKind == .review {
            return OrgNeedsUpload(kind: "review", question: v.reviewSummary ?? v.tickets.last(where: { $0.ticket.reportState == .ready })?.ticket.reportSummary)
        }
        guard let need = v.firstNeed else { return .none }
        let t = v.tickets.first { $0.ticket.isOpen && $0.stage.needsPerson == need }
        let ref = t.map { "#\($0.id)" }
        switch need {
        case .answer: return OrgNeedsUpload(kind: "answer", question: t?.ticket.attention, ticketRef: ref)
        case .review: return OrgNeedsUpload(kind: "review", question: t?.ticket.reportSummary, ticketRef: ref)
        case .blocked, .stalled: return OrgNeedsUpload(kind: "blocked", question: t?.ticket.reportSummary ?? v.needLineText, ticketRef: ref)
        case .failed: return OrgNeedsUpload(kind: "failed", question: t?.ticket.reportSummary, ticketRef: ref)
        case .delivery: return OrgNeedsUpload(kind: "failed", question: t?.ticket.deliveryError, ticketRef: ref)
        }
    }

    /// 上次上传的 needs 签名（同样的不重复传）。
    public func orgNeedsSent(_ taskID: Int64) throws -> String? { try store.orgState(taskID)?.needsSent }

    public func markNeedsSent(_ taskID: Int64, _ signature: String) throws {
        try store.transaction {
            guard var st = try store.orgState(taskID) else { return }
            st.needsSent = signature
            try store.saveOrgState(st)
        }
    }

    /// `POST /tasks/{id}/audit`：还没上传的活动摘要（时间线的一句话；不含命令全文、环境变量，I-06），一次最多 50 条。
    public func orgAudit(for taskID: Int64) throws -> (entries: [OrgAuditEntry], upTo: Int64) {
        guard let st = try store.orgState(taskID) else { return ([], 0) }
        let events = try store.events(taskID: taskID, after: st.auditAfter)
        let entries = events.map {
            OrgAuditEntry(at: OrgTime.string($0.at), kind: $0.kind, summary: Self.clip($0.text, 200).nilIfEmpty ?? $0.kind, credentialNames: [])
        }
        return (entries, events.last?.id ?? st.auditAfter)
    }

    public func markAudited(_ taskID: Int64, upTo: Int64) throws {
        try store.transaction {
            guard var st = try store.orgState(taskID) else { return }
            st.auditAfter = max(st.auditAfter, upTo)
            try store.saveOrgState(st)
        }
    }

    /// 本地记录的服务端版本（测试和同步行用）。
    public func orgVersion(_ taskID: Int64) throws -> Int? { try store.orgState(taskID)?.version }

    /// 同步时的一句记录（上行被拒绝等），进任务的活动；`taskID = 0`（节点级）不记。
    public func orgNote(_ taskID: Int64, _ text: String) throws {
        guard taskID != 0 else { return }
        try store.transaction { try store.log(nil, "org", text, at: now(), task: taskID) }
    }

    // MARK: - 内部

    /// 一张任务的 upsert（调用方在事务里）。
    private func importOrgTask(_ dto: OrgTaskDTO, origin: String, claimable: Bool, directory: ((OrgScopeDTO) -> String?)?, by: String) throws -> WorkTask {
        let at = now()
        let originID = String(dto.id)
        let existing = try store.task(origin: origin, originID: originID)
        let state = try existing.flatMap { try store.orgState($0.id) }
        // 同一版本、同一身份：服务端没变，什么都不做（幂等）。
        if let t = existing, let state, state.version == dto.version, (t.syncState == "claimable") == claimable { return t }
        let isNew = existing == nil
        let stages = Self.orgStages(dto.workflow)
        var t = existing ?? WorkTask(id: 0, origin: origin, originID: originID, title: dto.title, request: dto.title, source: .org,
                                     workflow: dto.workflow?.id ?? Workflow.defaultID, stages: stages, stage: dto.stage, createdAt: at, updatedAt: at)
        let oldStage = t.stage, oldStatus = t.status
        // 任务字段以服务端为准（标题 / 原文 / 来源链接 / 负责人 / 截止 / 优先级 / 依赖 / 备注 / 结果）。
        t.title = Self.cut(dto.title, WorkTask.maxTitle)
        t.request = dto.request?.nilIfEmpty ?? dto.title
        t.sourceRef = dto.sourceRef?.nilIfEmpty
        t.owner = dto.ownerEmail?.nilIfEmpty ?? "组织"
        t.due = OrgTime.parse(dto.due)
        t.priority = TaskPriority(rawValue: dto.priority ?? "") ?? .medium
        t.note = dto.note ?? ""
        t.resultSummary = dto.resultSummary ?? ""
        t.deps = try (dto.deps ?? []).compactMap { try store.task(origin: origin, originID: String($0))?.id }
        if t.scope.isEmpty, let s = dto.scope { t.scope = directory?(s) ?? Self.localDirectory(for: s) }
        // 阶段 / 状态以服务端为准。例外：本地已经往前走了、而且改动还没上传（服务端还不知道）→ 先留着本地的，上传后两边一致。
        let pendingUpload = isNew ? false : try !store.outbox(task: t.id).isEmpty
        let serverStatus = dto.taskStatus
        let serverIndex = t.stages.firstIndex { $0.name == dto.stage }
        let localAhead = pendingUpload && serverStatus == .open && t.status == .open && (serverIndex.map { $0 < t.stageIndex } ?? false)
        if !localAhead {
            if serverIndex != nil || isNew { t.stage = dto.stage }
            t.status = serverStatus
        }
        if t.stage != oldStage || t.status != oldStatus { t.notifiedStage = nil }
        t.syncState = claimable ? "claimable" : "synced"
        t.syncedAt = at
        t.updatedAt = at
        if isNew { t.id = try store.insertTask(t) } else { try store.saveTask(t) }
        try store.saveOrgState(OrgTaskState(taskID: t.id, version: dto.version, label: dto.displayLabel, scopeName: dto.scope?.name ?? "",
                                            edits: dto.edits ?? state?.edits ?? true, needsSent: state?.needsSent ?? "",
                                            auditAfter: state?.auditAfter ?? 0))
        let conflicts = try mergeOrgItems(t, dto.items, at: at)
        if try store.orgItems(t.id).contains(where: { $0.conflictServer != nil }) {
            t.syncState = "conflict"
            try store.saveTask(t)
        }
        if isNew {
            try store.log(nil, "org", "组织任务 \(dto.displayLabel) 同步到本地（\(claimable ? "待领取" : dto.stage)，\(dto.items.count) 项）", at: at, task: t.id)
        } else if t.stage != oldStage || t.status != oldStatus {
            try store.log(nil, "org", "组织把任务改为「\(t.isOpen ? t.stage : t.status.label)」（版本 \(dto.version)）", at: at, task: t.id)
            if t.status != .open { try store.dropEffect(.notify, t.label) }
        }
        if !conflicts.isEmpty {
            try store.log(nil, "conflict", "同步冲突：" + conflicts.map(\.line).joined(separator: "；"), at: at, task: t.id)
            try store.enqueue(.notify, t.label, at: at)
        }
        return t
    }

    /// 清单合并（I-03）。`syncedStatus` = 上次同步时服务端的状态，据此判断两边各自改没改：
    /// 服务端没变 → 本地的留着（包括本地刚取消的勾）；本地没变 → 用服务端的；两边都变了 → 任一边 done 即 done，
    /// 一样就一样，不同的非 done 状态 → 冲突（本地先标受阻，进「需要你」）。本机工单正在做的项只接受服务端的 done。
    /// 文字服务端为准；谁来做本地为准（本机的 Agent 是本机的事）。服务端没有的项（它删了）本地也删，除非工单还开着。
    private func mergeOrgItems(_ t: WorkTask, _ server: [OrgItemDTO], at: Double) throws -> [SyncConflict] {
        var local = try store.items(t.id)
        var states = Dictionary(uniqueKeysWithValues: try store.orgItems(t.id).map { ($0.originItemID, $0) })
        let open = Set(try store.tickets(task: t.id).filter(\.isOpen).map(\.id))
        var conflicts: [SyncConflict] = []
        var matched: Set<Int64> = []
        for s in server.sorted(by: { $0.ord < $1.ord }) {
            let serverStatus = s.itemStatus
            guard var st = states[s.id], let idx = local.firstIndex(where: { $0.id == st.itemID }) else {
                // 新项（服务端加的）：照搬。
                var i = Item(id: 0, taskID: t.id, ord: s.ord, text: Self.cut(s.text, Item.maxText), assignee: Assignee(raw: s.assignee ?? ""),
                             status: serverStatus, doneAt: serverStatus == .done ? (OrgTime.parse(s.doneAt) ?? at) : nil,
                             doneBy: serverStatus == .done ? (s.doneBy?.nilIfEmpty ?? "组织") : nil, startedAt: OrgTime.parse(s.startedAt))
                i.id = try store.insertItem(i)
                local.append(i)
                matched.insert(i.id)
                try store.saveOrgItem(OrgItemState(itemID: i.id, taskID: t.id, originItemID: s.id, syncedStatus: serverStatus,
                                                   conflictLocal: nil, conflictServer: nil))
                continue
            }
            var i = local[idx]
            matched.insert(i.id)
            i.text = Self.cut(s.text, Item.maxText)
            i.ord = s.ord
            if i.assignee == .unassigned, let a = s.assignee?.nilIfEmpty { i.assignee = Assignee(raw: a) }
            let localStatus = st.conflictServer != nil ? (st.conflictLocal ?? i.status) : i.status
            let serverChanged = serverStatus != st.syncedStatus
            let localChanged = localStatus != st.syncedStatus
            let held = i.ticketID.map(open.contains) ?? false
            func adopt(_ status: ItemStatus) {
                i.status = status
                if status == .done {
                    i.doneAt = OrgTime.parse(s.doneAt) ?? i.doneAt ?? at
                    i.doneBy = s.doneBy?.nilIfEmpty ?? i.doneBy ?? "组织"
                } else {
                    i.doneAt = nil
                    i.doneBy = nil
                    if status == .doing, i.startedAt == nil { i.startedAt = OrgTime.parse(s.startedAt) ?? at }
                }
                st.conflictLocal = nil
                st.conflictServer = nil
            }
            if st.conflictServer != nil {
                // 已经在冲突里：服务端又改了就更新它那边的值；改成 done 或和本地一样 → 冲突自然消失。
                if serverChanged {
                    if serverStatus == .done || serverStatus == localStatus { adopt(serverStatus) }
                    else { st.conflictServer = serverStatus; conflicts.append(SyncConflict(ord: i.ord, text: i.text, local: localStatus, server: serverStatus)) }
                }
            } else if held {
                if serverStatus == .done, i.status != .done { adopt(.done) }
            } else if !serverChanged {
                // 服务端没变：本地的留着。
            } else if !localChanged || i.status == serverStatus || serverStatus == .done {
                adopt(serverStatus)
            } else if i.status == .done {
                // 本地已完成、服务端改成了别的非 done：并集，完成的留着。
            } else {
                st.conflictLocal = i.status
                st.conflictServer = serverStatus
                i.status = .blocked // 受阻 + 没有工单在做 = 进「需要你」（现有规则），人定了再恢复
                conflicts.append(SyncConflict(ord: i.ord, text: i.text, local: localStatus, server: serverStatus))
            }
            st.syncedStatus = serverStatus
            try store.saveItem(i)
            try store.saveOrgItem(st)
            states[s.id] = st
            local[idx] = i
        }
        // 服务端没有的项：它删了。工单还开着的留下（变成本地自己的项），其余删掉；本地自己加的项排在服务端的后面。
        var next = (server.map(\.ord).max() ?? 0)
        for i in local.sorted(by: { $0.ord < $1.ord }) where !matched.contains(i.id) {
            if let st = states.values.first(where: { $0.itemID == i.id }) {
                try store.deleteOrgItem(i.id)
                if !(i.ticketID.map(open.contains) ?? false) {
                    try store.deleteItem(i.id)
                    try store.log(nil, "item", "组织删掉了第 \(i.ord) 项：\(i.text)", at: at, task: t.id)
                    continue
                }
                _ = st
            }
            next += 1
            if i.ord != next {
                var m = i
                m.ord = next
                try store.saveItem(m)
            }
        }
        return conflicts
    }

    /// 服务端 PATCH 响应里的冲突：这些项进冲突（本地标受阻）。
    private func markConflicts(_ taskID: Int64, _ conflicts: [OrgConflictDTO]) throws {
        let items = try store.items(taskID)
        var lines: [String] = []
        for c in conflicts {
            guard var st = try store.orgItems(taskID).first(where: { $0.originItemID == c.itemId }), var i = items.first(where: { $0.id == st.itemID }),
                  let server = ItemStatus(rawValue: c.serverStatus), st.conflictServer == nil else { continue }
            let localStatus = ItemStatus(rawValue: c.clientStatus) ?? i.status
            if localStatus == server || localStatus == .done || server == .done { continue }
            st.conflictLocal = localStatus
            st.conflictServer = server
            i.status = .blocked
            try store.saveItem(i)
            try store.saveOrgItem(st)
            lines.append(SyncConflict(ord: i.ord, text: i.text, local: localStatus, server: server).line)
        }
        guard !lines.isEmpty, var t = try store.task(taskID) else { return }
        let at = now()
        t.syncState = "conflict"
        t.updatedAt = at
        try store.saveTask(t)
        try store.log(nil, "conflict", "同步冲突：" + lines.joined(separator: "；"), at: at, task: taskID)
        try store.enqueue(.notify, t.label, at: at)
    }

    /// 派单带授权（能否改文件）：全部还没分配的清单项交给「开发」(能改文件) 或「助理」；交不出去（目录不合法、角色不存在）
    /// 留在待分配并记 timeline，不抛错。调用方在事务里。
    func orgAutoAssign(_ t: WorkTask, edits: Bool, by: String, at: Double) throws {
        guard t.status == .open, t.stageKind == .doing else { return }
        let ords = try store.items(t.id).filter { $0.assignee == .unassigned && $0.status != .done }.map(\.ord)
        guard !ords.isEmpty else { return }
        let roleName = edits ? Role.developer : Role.assistant
        guard let role = try store.role(roleName) else {
            try store.log(nil, "assign", "角色「\(roleName)」不存在，留在待分配", at: at, task: t.id)
            return
        }
        do {
            if role.edits || !role.standing { try Self.checkScope(t) }
            _ = try assignItems(t.id, ords.map { Allocation(ord: $0, to: .agent(role: roleName)) }, oneTicket: true, by: by, source: nil)
            try store.log(nil, "assign", "按派单授权（\(edits ? "能改文件" : "只读")）把\(Self.ordLabel(ords))交给「\(roleName)」", at: at, task: t.id)
        } catch {
            for var i in try store.items(t.id) where i.assignee.isAgent && i.ticketID == nil {
                i.assignee = .unassigned
                i.status = .todo
                i.startedAt = nil
                try store.saveItem(i)
            }
            try store.log(nil, "assign", "按派单授权交给「\(roleName)」失败：\(error)。留在待分配，等人定谁来做", at: at, task: t.id)
        }
    }

    /// 服务端的工作流快照；缺了或不合法就用内置默认（阶段判断只看 kind 和顺序）。
    static func orgStages(_ w: OrgWorkflowDTO?) -> [WorkflowStage] {
        guard let stages = w?.stages, !stages.isEmpty, stages.contains(where: { $0.kind == .doing }) else { return Workflow.builtins[0].stages }
        return stages
    }

    /// 没有 App 帮忙找目录时：`path_hint` 是绝对路径就用它，否则留空（交给会改文件的角色时再提示填目录）。
    static func localDirectory(for scope: OrgScopeDTO) -> String {
        let hint = scope.pathHint ?? ""
        return hint.hasPrefix("/") ? hint : ""
    }
}

extension TaskView {
    /// `orgNeeds` 用：受阻而没有工单时的一句说明。
    fileprivate var needLineText: String? {
        let ords = items.filter { $0.status == .blocked }.map(\.ord)
        return ords.isEmpty ? nil : SuperagentEngine.ordLabel(ords) + "受阻"
    }
}
