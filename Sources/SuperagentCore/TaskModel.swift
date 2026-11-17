import Foundation

// 工作清单（TFA-工作清单-需求文档 §3）：任务是人的工作单位；清单项是最小的分配单位；交给 Agent 的清单项才变成工单。
// 人能看到的概念只有：任务、清单项、谁来做、工作流、需要你（注意事项 A-03）。

/// 任务从哪来。
/// 一次退回（handback）：任务 `fromTaskID` 的第 `itemOrd` 项被工单 `ticketID` 退回，成为新任务 `toTaskID`（设计评审 2026-11-08，4A）。
public struct HandbackLink: Equatable, Hashable, Sendable {
    public let fromTaskID: Int64
    public let itemOrd: Int
    public let ticketID: Int64
    public let toTaskID: Int64
    public init(fromTaskID: Int64, itemOrd: Int, ticketID: Int64, toTaskID: Int64) {
        self.fromTaskID = fromTaskID; self.itemOrd = itemOrd; self.ticketID = ticketID; self.toTaskID = toTaskID
    }
}

/// 链接项（TODOS「退回的清单项变成链接项」，设计评审 2026-11-08 4C）：原任务 A 被退回的那一项指向新任务 B，状态跟随 B。
public struct LinkedItem: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        /// B 还有没定谁来做的项：等你去分配 B（A 算「需要你」）。
        case unassigned
        /// B 的项都有人做了：在等 B 完成。
        case doing
    }
    public let link: HandbackLink
    public let state: State
    public init(link: HandbackLink, state: State) { self.link = link; self.state = state }
}

public enum TaskSource: String, CaseIterable, Sendable {
    case manual, router, rule, schedule, handback, org

    public var label: String {
        switch self {
        case .manual: return "自己建"
        case .router: return "主管"
        case .rule: return "规则"
        case .schedule: return "定时"
        case .handback: return "退回"
        case .org: return "组织"
        }
    }
}

/// 任务的生命周期。只有 open 是活的；其余都是结束态（任务不硬删，注意事项 B-08）。
public enum TaskStatus: String, Sendable {
    case open, done, cancelled, dropped

    public var label: String {
        switch self {
        case .open: return "进行中"
        case .done: return "已完成"
        case .cancelled: return "已取消"
        case .dropped: return "已放弃"
        }
    }
}

public enum TaskPriority: String, CaseIterable, Sendable {
    case high, medium, low

    public var label: String {
        switch self {
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        }
    }
}

/// 阶段的行为（§3.2）：代码只看 kind 和顺序，阶段名只用于显示。
public enum StageKind: String, Sendable, Codable {
    /// 没人做（组织清单的「待领取」；个人任务跳过它）。
    case todo
    /// 清单项在推进。
    case doing
    /// 等负责人通过 / 打回。
    case review
    /// 终态。
    case done
}

public struct WorkflowStage: Equatable, Sendable, Codable {
    public var name: String
    public var kind: StageKind

    public init(name: String, kind: StageKind) { self.name = name; self.kind = kind }
}

/// 工作流模板。建任务时**快照**进任务（注意事项 B-04）：之后改模板不影响已有任务。
public struct Workflow: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// 个人层：项目目录（空 = 通用默认）；组织层：范围 id（第 3 期）。
    public var scope: String
    public var stages: [WorkflowStage]

    public init(id: String, name: String, scope: String = "", stages: [WorkflowStage]) {
        self.id = id; self.name = name; self.scope = scope; self.stages = stages
    }

    public static let defaultID = "default"
    public static let noReviewID = "no-review"

    public static let builtins: [Workflow] = [
        Workflow(id: defaultID, name: "默认", stages: [
            WorkflowStage(name: "待领取", kind: .todo), WorkflowStage(name: "进行中", kind: .doing),
            WorkflowStage(name: "待评审", kind: .review), WorkflowStage(name: "完成", kind: .done)]),
        Workflow(id: noReviewID, name: "不评审", stages: [
            WorkflowStage(name: "待领取", kind: .todo), WorkflowStage(name: "进行中", kind: .doing),
            WorkflowStage(name: "完成", kind: .done)]),
    ]

    public var isBuiltin: Bool { Self.builtins.contains { $0.id == id } }

    /// §3.2：恰好一个 `done` 且在末尾；恰好一个 `doing`（多个会把任务晾在半路）；`todo` 只能在最前；
    /// `review` 可有可无，有就必须紧挨着 `done`（只能由人通过进入下一阶段）。nil = 合法。
    public var problem: String? {
        guard !stages.isEmpty else { return "至少要有一个阶段" }
        guard stages.filter({ $0.kind == .done }).count == 1, stages.last?.kind == .done else { return "最后一个阶段必须是「完成」，且只能有一个" }
        guard stages.filter({ $0.kind == .doing }).count == 1 else { return "必须恰好有一个「进行中」阶段" }
        if let i = stages.lastIndex(where: { $0.kind == .todo }), i != 0 { return "「待领取」只能是第一个阶段" }
        for (i, s) in stages.enumerated() where s.kind == .review && i != stages.count - 2 { return "「待评审」必须紧挨着「完成」，且只能有一个" }
        guard Set(stages.map(\.name)).count == stages.count else { return "阶段名不能重复" }
        return nil
    }
}

/// 谁来做（§3.3）。库里存 `raw`：`""` / `你` / `agent:开发`。
public enum Assignee: Equatable, Hashable, Sendable {
    case unassigned
    case you
    case agent(role: String)

    public init(raw: String) {
        if raw.isEmpty { self = .unassigned }
        else if raw == "你" { self = .you }
        else if raw.hasPrefix("agent:") { self = .agent(role: String(raw.dropFirst(6))) }
        else { self = .agent(role: raw) }
    }

    public var raw: String {
        switch self {
        case .unassigned: return ""
        case .you: return "你"
        case .agent(let role): return "agent:\(role)"
        }
    }

    /// chip 文案：未定 / 你 / 角色名。
    public var label: String {
        switch self {
        case .unassigned: return "未定"
        case .you: return "你"
        case .agent(let role): return role
        }
    }

    public var role: String? { if case .agent(let r) = self { return r }; return nil }
    public var isAgent: Bool { role != nil }
}

public enum ItemStatus: String, Sendable {
    case todo, doing, done, blocked

    public var label: String {
        switch self {
        case .todo: return "待做"
        case .doing: return "工作中"
        case .done: return "完成"
        case .blocked: return "受阻"
        }
    }
}

/// 清单项（§3.3）。对外永远用 `ord`（从 1 起、连续），不显示 `id`（注意事项 B-06）。
public struct Item: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var taskID: Int64
    public var ord: Int
    /// 一句话、可验证的结果（≤200 字）。
    public var text: String
    public var assignee: Assignee
    public var status: ItemStatus
    /// 交给 Agent 后挂的工单。
    public var ticketID: Int64?
    public var doneAt: Double?
    /// 「你」或角色名。
    public var doneBy: String?
    /// 开始做的时间：Agent 的项在 `todo → doing`（ack / 第一次回报）时写；你的项没有「开始」这一步，分给你的那一刻就算开始；
    /// 回到 `todo`（改派、放弃、取消勾）时清。清单页的「今天」视图据此把你名下做了超过 2 天还没勾的项提到前面（需求文档 §13）。
    public var startedAt: Double?

    public init(id: Int64, taskID: Int64, ord: Int, text: String, assignee: Assignee = .unassigned, status: ItemStatus = .todo,
                ticketID: Int64? = nil, doneAt: Double? = nil, doneBy: String? = nil, startedAt: Double? = nil) {
        self.id = id; self.taskID = taskID; self.ord = ord; self.text = text; self.assignee = assignee
        self.status = status; self.ticketID = ticketID; self.doneAt = doneAt; self.doneBy = doneBy; self.startedAt = startedAt
    }

    public static let maxText = 200

    /// 清单项的一行文字，三处同源（CLI、执行者的请求文本、界面；注意事项 E-04）：`3. 改为分段加锁，跑回归 ✓`。
    public var line: String {
        let mark: String
        switch status {
        case .done: mark = " ✓"
        case .blocked: mark = "（受阻）"
        case .doing, .todo: mark = ""
        }
        return "\(ord). \(text)\(mark)"
    }
}

/// 任务（§3.1）。界面编号 `A-<id>`。
public struct WorkTask: Equatable, Sendable, Identifiable {
    public var id: Int64
    /// 来自组织时：组织工作区 + 组织任务号；本地任务为空（第 3 期）。
    public var origin: String?
    public var originID: String?
    public var title: String
    /// 原文（人的话 / 事件原文）。执行者从这里推导需求，标题不能替代。
    public var request: String
    public var source: TaskSource
    /// 群 / PR / Issue 链接，或触发它的 `t<id>` / 退回它的 `#<工单>`。
    public var sourceRef: String?
    /// 个人：项目目录（可空 = 不针对项目）；组织：范围 id。
    public var scope: String
    /// 负责人；个人层恒为「你」。
    public var owner: String
    public var due: Double?
    public var priority: TaskPriority
    /// 前置任务；有未完成的前置时不可分配给 Agent（注意事项 C-14）。
    public var deps: [Int64]
    /// 工作流模板 id（只供显示）。
    public var workflow: String
    /// 建任务时的模板快照；阶段判断只看这里（注意事项 B-04 / B-05）。
    public var stages: [WorkflowStage]
    /// 当前阶段名（快照里的名字）。
    public var stage: String
    public var status: TaskStatus
    /// 完成时的一句话结果。
    public var resultSummary: String
    /// 路由备注（≤30 词），交给 Agent 时沿用到工单。
    public var note: String
    /// 通知去重：任务 × 阶段 只通知一次（注意事项 G-01）。
    public var notifiedStage: String?
    /// 第 3 期；现在只会是 `local`。
    public var syncState: String
    public var syncedAt: Double?
    public var createdAt: Double
    public var updatedAt: Double

    public init(id: Int64, origin: String? = nil, originID: String? = nil, title: String, request: String, source: TaskSource,
                sourceRef: String? = nil, scope: String = "", owner: String = "你", due: Double? = nil, priority: TaskPriority = .medium,
                deps: [Int64] = [], workflow: String = Workflow.defaultID, stages: [WorkflowStage], stage: String, status: TaskStatus = .open,
                resultSummary: String = "", note: String = "", notifiedStage: String? = nil, syncState: String = "local",
                syncedAt: Double? = nil, createdAt: Double, updatedAt: Double) {
        self.id = id; self.origin = origin; self.originID = originID; self.title = title; self.request = request
        self.source = source; self.sourceRef = sourceRef; self.scope = scope; self.owner = owner; self.due = due
        self.priority = priority; self.deps = deps; self.workflow = workflow; self.stages = stages; self.stage = stage
        self.status = status; self.resultSummary = resultSummary; self.note = note; self.notifiedStage = notifiedStage
        self.syncState = syncState; self.syncedAt = syncedAt; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public static let maxTitle = 80

    /// 界面编号。
    public var label: String { "A-\(id)" }
    public var isOpen: Bool { status == .open }

    /// 当前阶段在快照里的位置；找不到（数据损坏）→ 第一个 `doing`（注意事项 B-05）。
    public var stageIndex: Int {
        stages.firstIndex { $0.name == stage } ?? stages.firstIndex { $0.kind == .doing } ?? 0
    }
    public var stageKind: StageKind { stages.isEmpty ? .doing : stages[stageIndex].kind }

    /// `A-12` / `a12` / `12` → 12（注意事项 B-09）。
    public static func parseID(_ s: String) -> Int64? {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("a-") { t.removeFirst(2) } else if t.hasPrefix("a") { t.removeFirst() }
        guard let n = Int64(t), n > 0 else { return nil }
        return n
    }
}

/// 一个任务的读视图：任务 + 清单 + 名下工单 + 派生值（界面和 CLI 都用它，注意事项 J-05）。
public struct TaskView: Equatable, Sendable, Identifiable {
    public var task: WorkTask
    /// 按 `ord` 排好。
    public var items: [Item]
    /// 名下工单（打开的 + 已结束的），按 id。
    public var tickets: [TicketView]
    /// 派生（§4.3）：名下打开工单的 PersonAction ∪ {review}（当前阶段是 review）∪ {blocked}（清单项受阻且无工单）；
    /// 按 `PersonAction` 声明顺序去重排序。
    public var needsYou: [PersonAction]
    /// 自动评审的结论（评审工单交付后的 summary）；nil = 没评审或还在评审。
    public var reviewSummary: String?
    /// 自动评审正在进行（评审工单还开着）：清单勾完也先不进待评审。
    public var reviewing: Bool
    /// 组织同步（第 3 期）：没裁决的同步冲突（同一项两边改成不同的非 done 状态），按 `ord`；本地任务恒为空。
    public var syncConflicts: [SyncConflict]
    /// 退回链接（设计评审 2026-11-08，4A）：这个任务的哪些项被工单退回、成了哪个新任务（`fromTaskID == task.id`）；
    /// 按新任务号升序，同一项退回过两次（前一个新任务被取消后又退回）时以最后一条为准。
    public var handbacks: [HandbackLink] = []
    /// 这个任务本身是退回产生的：来自哪个任务的第几项、哪张工单（`toTaskID == task.id`）；不是退回产生的为 nil。
    public var handbackOrigin: HandbackLink?
    /// 链接项（TODOS 4C）：退回成新任务、新任务还开着、没被人改派的项（按 `ord`）。这些项的 `status` 在读视图里已换成
    /// 跟随新任务的状态（新任务还有没人做的项 → todo，否则 → doing；新任务完成时引擎把它勾掉）；不再有受阻态。
    public var linked: [Int: LinkedItem] = [:]
    /// 本任务自身的总结沉淀知识卡（已完成或手动提炼过时有值）。
    public var knowledge: KnowledgeEntry? = nil
    /// 本任务显式关联的历史任务总结 / 经验卡（注入给执行者做上下文参考）。
    public var relatedKnowledge: [RelatedKnowledgeSummary] = []
    /// 引用了本任务总结的后续衍生任务（双向脉络）。
    public var derivedTasks: [DerivedTaskSummary] = []

    public init(task: WorkTask, items: [Item], tickets: [TicketView], needsYou: [PersonAction], reviewSummary: String? = nil, reviewing: Bool = false,
                syncConflicts: [SyncConflict] = []) {
        self.task = task; self.items = items; self.tickets = tickets; self.needsYou = needsYou
        self.reviewSummary = reviewSummary; self.reviewing = reviewing; self.syncConflicts = syncConflicts
    }

    public var id: Int64 { task.id }
    public var doneCount: Int { items.filter { $0.status == .done }.count }
    public var totalCount: Int { items.count }
    public var unassignedCount: Int { items.filter { $0.assignee == .unassigned }.count }
    /// 执行者 chips：按清单顺序去重（你 / 各角色；未定不算）。
    public var assignees: [Assignee] {
        var seen: [Assignee] = []
        for i in items where i.assignee != .unassigned && !seen.contains(i.assignee) { seen.append(i.assignee) }
        return seen
    }
    public var firstNeed: PersonAction? { needsYou.first }
    public func item(ord: Int) -> Item? { items.first { $0.ord == ord } }
    public func ticket(_ id: Int64) -> TicketView? { tickets.first { $0.id == id } }
}

/// 「完成任务…」确认单的数据（设计评审 2026-11-08，5A）：要合并的分支、没有分支的工单、没做完的项。目标分支由 App 用 git 算。
public struct FinishPreview: Sendable {
    /// 名下交付了的非评审工单，按工单号：已结束为 `done`（含退回结束的），或还开着但已报 ready——App 通过时合并的就是这一批。
    /// `branch` 没有（常驻角色、还没启动）为 nil。
    public var tickets: [(ticketID: Int64, branch: String?, title: String)]
    /// 还没完成的清单项序号（含退回出去、还在等新任务的项）。
    public var unfinishedOrds: [Int]

    public init(tickets: [(ticketID: Int64, branch: String?, title: String)], unfinishedOrds: [Int]) {
        self.tickets = tickets; self.unfinishedOrds = unfinishedOrds
    }
}
