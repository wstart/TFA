import Foundation

// 领域模型（docs/superagent-design.md）。只有这些概念：请求(Trigger)、工单(Ticket)、派工(Assignment)、
// 输入(Input)、回报(Report)、待你决定(Attention)、决定(Decision)、规则(Policy)、角色(Role，docs/superagent-roles.md)。

/// Worker 回报的状态。`waiting` 只由 TFA 自己记录（执行终端停下了却没回报）。
public enum ReportState: String, CaseIterable, Sendable {
    case progress, waiting, ready, blocked, failed, dropped
}

/// 工单的生命周期。只有 open 是活的；其余都是结束态。
public enum TicketStatus: String, Sendable {
    case open, done, stopped, dropped
}

public enum AssignmentState: String, Sendable {
    case pending, running, ended
}

/// 一个需要人的工单在等什么。声明顺序 = 「需要你」列表的排序。
public enum PersonAction: String, CaseIterable, Sendable, Comparable {
    case answer, review, blocked, failed, delivery, stalled

    public static func < (a: PersonAction, b: PersonAction) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    public var label: String {
        switch self {
        case .answer: return "等你回答"
        case .review: return "待评审"
        case .blocked: return "受阻"
        case .failed: return "失败"
        case .delivery: return "送达失败"
        case .stalled: return "停下未回报"
        }
    }
}

/// 工单阶段：等人 > 工作中 > 空闲 > 已结束（第一条命中的规则生效）。
public enum Stage: Equatable, Sendable {
    case person(PersonAction)
    case working(queued: Bool)
    case idle
    case ended(TicketStatus)

    public var needsPerson: PersonAction? { if case .person(let a) = self { return a }; return nil }
    public var isEnded: Bool { if case .ended = self { return true }; return false }

    public var label: String {
        switch self {
        case .person(let a): return a.label
        case .working(let queued): return queued ? "排队中" : "工作中"
        case .idle: return "空闲"
        case .ended(let s):
            switch s {
            case .done: return "已完成"
            case .stopped: return "已停止"
            case .dropped: return "已放弃"
            case .open: return "进行中"
            }
        }
    }
}

public struct Ticket: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var title: String
    /// 接这张单的角色（`Role.name`）。
    public var role: String = Role.developer
    /// 原始请求原文——worker 从这里推导需求，路由备注不能替代它。
    public var request: String
    /// 路由备注（≤30 词），只写路由背景或人的明确约束。
    public var note: String
    /// 请求所指的目录（仓库）；常驻角色的单可以没有（空）。
    public var repo: String
    /// 实际工作目录（git worktree 或 repo 本身）；空 = 尚未准备。
    public var dir: String
    public var branch: String
    public var worktree: Bool
    public var status: TicketStatus
    public var endedBy: String?
    public var endedAt: Double?
    /// worker 的一次性确认（「在改…，预期…」）。
    public var ack: String
    /// 待人回答的问题（结构化，只能由 `report --ask` 提出）。
    public var attention: String?
    public var reportState: ReportState?
    public var reportSummary: String
    /// 附带的报告文件（例如验收 report.html）。
    public var reportPath: String?
    public var reportAt: Double?
    public var deliveryError: String?
    /// 本轮已经催过一次回报。
    public var nudged: Bool
    /// 最近一次通知人时的阶段（同一阶段只通知一次）。
    public var notifiedStage: String?
    /// 不可变的授权记录（JSON：strength、trigger、policy_version、rules）。
    public var mandate: String
    public var triggerID: String?
    /// 执行终端的 tmux 会话名。
    public var session: String
    /// 当前这一轮开始的时间（启动或送达新输入）；空闲检测从这里算。
    public var turnAt: Double?
    public var createdAt: Double
    public var updatedAt: Double

    public var isOpen: Bool { status == .open }
}

public struct Assignment: Equatable, Sendable {
    public var id: Int64
    public var ticketID: Int64
    public var state: AssignmentState
    public var reason: String
    public var createdAt: Double
    public var startedAt: Double?
    public var endedAt: Double?
}

public enum InputKind: String, Sendable {
    /// 人的跟进（打回、回答、主管转达的明确请求）。
    case human
    /// TFA 自己的提示（催报、重试、恢复说明）。
    case system
}

public struct TicketInput: Equatable, Sendable {
    public var id: Int64
    public var ticketID: Int64
    public var kind: InputKind
    public var text: String
    public var createdAt: Double
    public var deliveredAt: Double?
}

public enum Strength: String, Sendable {
    /// 人直接提出的请求。
    case explicit
    /// 没人点名，但可能命中成文规则（需研判）。
    case inferred
}

public enum TriggerStatus: String, Sendable {
    case pending, decided
}

/// 一条不可变的事件：审计与幂等的单位。
public struct Trigger: Equatable, Sendable {
    public var id: String
    /// router / handback:#12 / terminal:<name> / schedule:<id>
    public var source: String
    public var strength: Strength
    public var text: String
    public var repo: String
    public var status: TriggerStatus
    public var ticketID: Int64?
    public var createdAt: Double
}

public enum DecisionKind: String, Sendable {
    case accept, attach, stop, ignore
    /// observe 模式：研判通过，但只记录不执行。
    case wouldAccept = "would_accept"
    /// 研判超时或无法进行。
    case unavailable
}

public struct Decision: Equatable, Sendable {
    public var id: Int64
    public var triggerID: String?
    public var ticketID: Int64?
    public var kind: DecisionKind
    public var reason: String
    public var policyVersion: String
    /// 逐条规则的研判（JSON 对象 ruleID → verdict）。
    public var rules: String
    public var createdAt: Double
}

public struct TimelineEvent: Equatable, Sendable {
    public var id: Int64
    public var at: Double
    public var ticketID: Int64?
    public var kind: String
    public var text: String
}

/// 副作用的种类。和状态变更在同一事务里入队，提交后由 App 执行。
public enum EffectKind: String, CaseIterable, Sendable {
    /// 准备目录 + 建执行终端 + 启动 agent。
    case launch
    /// 把排队的输入送进执行终端。
    case deliver
    /// 把回报/候选送进「主管」终端（有序）。
    case relay
    /// 中断执行终端里的 agent。
    case stop
    /// 工单进入「需要你」时发一次系统通知。
    case notify

    /// 失败后的退避：(起始, 上限) 秒。
    var backoff: (base: Double, cap: Double) {
        switch self {
        case .launch: return (5, 300)
        default: return (2, 60)
        }
    }
}

public struct Effect: Equatable, Sendable {
    public var kind: EffectKind
    public var key: String
    /// 每次重新入队 +1；执行完成时 seq 不同 = 期间又有新工作，不能删。
    public var seq: Int64
    public var attempts: Int
    public var nextAt: Double
    public var lastError: String?
    public var createdAt: Double

    /// 连续失败 3 次才算问题（"稍后"不计）。
    public var isProblem: Bool { attempts >= 3 }
}

/// 送给主管的一条消息（回报、退回、候选）。
public struct Relay: Equatable, Sendable {
    public var id: Int64
    public var ticketID: Int64?
    public var text: String
    public var createdAt: Double
    public var deliveredAt: Double?
}

// MARK: - 规则（第 2 期）

public enum AcceptMode: String, CaseIterable, Sendable {
    /// 不考虑推断出的工作。
    case off
    /// 照常研判，但只记录「would accept」。默认。
    case observe
    /// 研判通过就接单。
    case auto

    public var label: String {
        switch self {
        case .off: return "关闭"
        case .observe: return "只观察"
        case .auto: return "自动接单"
        }
    }
}

public struct Rule: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    /// 自然语言规则（≤2000 字）。
    public var instruction: String

    public init(id: String, name: String, enabled: Bool = true, instruction: String) {
        self.id = id; self.name = name; self.enabled = enabled; self.instruction = instruction
    }

    public static let maxInstruction = 2000
}

/// 研判对一条规则的结论。
public enum RuleVerdict: String, CaseIterable, Sendable {
    case match
    case noMatch = "no_match"
    /// 方向不明确，需要人做设计决定 → 一律不接。
    case requiresDesignDecision = "requires_design_decision"
}

/// 定时任务：每天固定时间向主管提交一条明确请求。
public struct Schedule: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    /// "HH:mm"（本地时间）。
    public var time: String
    public var request: String
    public var repo: String
    /// 上次触发的日期（yyyy-MM-dd），同一天只触发一次。
    public var lastFired: String?

    public init(id: String, name: String, enabled: Bool = true, time: String, request: String, repo: String, lastFired: String? = nil) {
        self.id = id; self.name = name; self.enabled = enabled; self.time = time
        self.request = request; self.repo = repo; self.lastFired = lastFired
    }
}

// MARK: - 角色

/// 一类 Agent 的定义：主要行为（写进它的 system prompt）+ 运行方式。主管接单时先选角色，
/// TFA 按定义生成（启动）这个角色的 Agent，再把工单交给它（docs/superagent-roles.md）。
public struct Role: Equatable, Sendable, Codable, Identifiable {
    /// 名称即 id：主管在命令里写 `--role 助理`，也是常驻终端的名字。
    public var name: String
    /// 一句话：接什么任务（主管据此选角色）。
    public var scope: String
    /// 主要行为。
    public var behavior: String
    /// 常驻：一个终端串行处理这个角色的所有工单，追问自带上下文；否则每单一个终端 + 目录。
    public var standing: Bool
    /// 能改文件（全部放行）；否则禁用编辑类工具，只读。
    public var edits: Bool
    /// ready 后进「待评审」等人通过；否则 ready 就是交付，工单自动结束。
    public var review: Bool

    public init(name: String, scope: String, behavior: String, standing: Bool, edits: Bool, review: Bool) {
        self.name = name; self.scope = scope; self.behavior = behavior
        self.standing = standing; self.edits = edits; self.review = review
    }

    public var id: String { name }
    public var isBuiltin: Bool { Self.builtins.contains { $0.name == name } }

    /// 「常驻 · 只读 · 直接交付」
    public var traits: String {
        [standing ? "常驻" : "每单一个终端", edits ? "能改文件" : "只读", review ? "待评审" : "直接交付"].joined(separator: " · ")
    }

    public static let maxName = 12
    public static let maxScope = 200
    public static let maxBehavior = 2000

    public static let assistant = "助理"
    public static let developer = "开发"

    /// 内置角色：运行方式固定，接什么和主要行为可以在面板里改。
    public static let builtins: [Role] = [
        Role(name: assistant,
             scope: "查资料、问答、分析、总结，以及和项目无关的事；关于某个项目或代码的问题（只读）。不接要提交的改动。",
             behavior: """
             - 先给结论，再给要点和依据；引用网上的信息注明来源和抓取时间，查不到就直说。
             - 问到某个项目时，到工单写明的目录里读代码和文档，读最少的必要内容。
             - 发现要改代码或文件才能完成，用 tfa handback 退回，由主管改派「开发」。
             - 追问不重新从头查：先用前面的结果，只补查新问的部分。
             """,
             standing: true, edits: false, review: false),
        Role(name: developer,
             scope: "要提交的改动：代码、配置、脚本、仓库里的文档。每单一个终端和 git worktree，改完待评审。",
             behavior: """
             - 用项目已有的模式、库和工具函数，只改请求需要的部分，改动小而聚焦。
             - 修 bug 先复现再修；改动前后跑相关的构建和测试，没跑的检查在回报里写明原因。
             """,
             standing: false, edits: true, review: true),
    ]
}

/// 用户可调的少量设置（一个默认值适合几乎所有人）。
public struct Settings: Equatable, Sendable {
    /// 同时执行的工单数。人的跟进额外 +1。
    public var slots: Int = 3
    /// 每个工单默认建 git worktree。
    public var worktree: Bool = true
    /// 交付前跑 LobeHub Acceptance（第 3 期）。
    public var acceptance: Bool = false
    /// 执行终端停下多少秒没回报，就催一次。
    public var idleSeconds: Double = 90

    public init() {}
}

/// 校验/业务错误：信息直接给人（或 agent）看。
public struct SuperagentError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
