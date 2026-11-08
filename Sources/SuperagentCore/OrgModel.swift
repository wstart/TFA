import Foundation

// 组织端（TFA-工作清单-需求文档 §10、docs/worklist/org-protocol.md；注意事项 I）：TFA 是一个节点，组织任务在本地也是一行
// `task`（`origin` = 服务器地址、`originID` = 组织任务号），工单只在本地。这里是协议的对象（下行 DTO、上行 body）和本地的同步状态。

/// 协议里的时间：ISO 8601 UTC（`2026-11-08T03:12:00Z`，也容忍带小数秒的）。服务端时间为准（I-07）。
public enum OrgTime {
    private static let plain: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    public static func parse(_ s: String?) -> Double? {
        guard let s, !s.isEmpty else { return nil }
        return (plain.date(from: s) ?? fractional.date(from: s))?.timeIntervalSince1970
    }

    public static func string(_ at: Double) -> String { plain.string(from: Date(timeIntervalSince1970: at)) }
}

/// 游标 / 编号：服务端可能给数字也可能给字符串，一律按字符串原样回传。
public struct LenientString: Codable, Equatable, Sendable {
    public var value: String

    public init(_ value: String) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let n = try? c.decode(Int64.self) { value = String(n) }
        else if let d = try? c.decode(Double.self) { value = String(d) }
        else { value = "" }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

// MARK: - 下行（协议 §1 Task）

public struct OrgScopeDTO: Codable, Equatable, Sendable {
    public var id: Int
    public var name: String
    public var kind: String?
    public var pathHint: String?

    public init(id: Int, name: String, kind: String? = nil, pathHint: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.pathHint = pathHint
    }
}

public struct OrgWorkflowDTO: Codable, Equatable, Sendable {
    public var id: String?
    public var name: String?
    public var stages: [WorkflowStage]

    public init(id: String? = nil, name: String? = nil, stages: [WorkflowStage]) { self.id = id; self.name = name; self.stages = stages }
}

public struct OrgItemDTO: Codable, Equatable, Sendable {
    public var id: Int64
    public var ord: Int
    public var text: String
    /// 同 `Assignee.raw`：`""` / `你` / `agent:<角色>`。
    public var assignee: String?
    public var status: String
    public var doneBy: String?
    public var doneAt: String?
    public var startedAt: String?

    public init(id: Int64, ord: Int, text: String, assignee: String? = nil, status: String = "todo",
                doneBy: String? = nil, doneAt: String? = nil, startedAt: String? = nil) {
        self.id = id; self.ord = ord; self.text = text; self.assignee = assignee; self.status = status
        self.doneBy = doneBy; self.doneAt = doneAt; self.startedAt = startedAt
    }

    public var itemStatus: ItemStatus { ItemStatus(rawValue: status) ?? .todo }
}

public struct OrgNeedsDTO: Codable, Equatable, Sendable {
    public var kind: String?
    public var question: String?
    public var since: String?
}

/// 组织任务（协议 §1）。字段都按「服务端给什么就收什么」，缺的用默认值，不因为多一个少一个字段就解不开。
public struct OrgTaskDTO: Codable, Equatable, Sendable {
    public var id: Int64
    public var label: String?
    public var title: String
    public var request: String?
    public var source: String?
    public var sourceRef: String?
    public var scope: OrgScopeDTO?
    public var ownerEmail: String?
    public var assigneeEmail: String?
    public var assigneeNode: String?
    public var claimedAt: String?
    public var due: String?
    public var priority: String?
    public var deps: [Int64]?
    public var workflow: OrgWorkflowDTO?
    public var stage: String
    public var status: String?
    public var items: [OrgItemDTO]
    public var resultSummary: String?
    public var note: String?
    public var needs: OrgNeedsDTO?
    /// 派单授权：能否改文件（派单事件的 payload 里也有）。
    public var edits: Bool?
    public var version: Int
    public var updatedAt: String?

    public init(id: Int64, label: String? = nil, title: String, request: String? = nil, source: String? = nil, sourceRef: String? = nil,
                scope: OrgScopeDTO? = nil, ownerEmail: String? = nil, assigneeEmail: String? = nil, assigneeNode: String? = nil,
                claimedAt: String? = nil, due: String? = nil, priority: String? = nil, deps: [Int64]? = nil, workflow: OrgWorkflowDTO? = nil,
                stage: String, status: String? = "open", items: [OrgItemDTO], resultSummary: String? = nil, note: String? = nil,
                needs: OrgNeedsDTO? = nil, edits: Bool? = nil, version: Int, updatedAt: String? = nil) {
        self.id = id; self.label = label; self.title = title; self.request = request; self.source = source; self.sourceRef = sourceRef
        self.scope = scope; self.ownerEmail = ownerEmail; self.assigneeEmail = assigneeEmail; self.assigneeNode = assigneeNode
        self.claimedAt = claimedAt; self.due = due; self.priority = priority; self.deps = deps; self.workflow = workflow
        self.stage = stage; self.status = status; self.items = items; self.resultSummary = resultSummary; self.note = note
        self.needs = needs; self.edits = edits; self.version = version; self.updatedAt = updatedAt
    }

    /// `T-128`。
    public var displayLabel: String { label.flatMap(\.nilIfEmpty) ?? "T-\(id)" }
    public var taskStatus: TaskStatus { TaskStatus(rawValue: status ?? "open") ?? .open }
    /// 快照里当前阶段的种类；找不到按 `doing`。
    public var stageKind: StageKind { (workflow?.stages ?? []).first { $0.name == stage }?.kind ?? .doing }
    /// 还没人领的待领取任务（本范围的「待领取」分区）。
    public var isClaimable: Bool { (assigneeNode?.isEmpty ?? true) && stageKind == .todo && taskStatus == .open }

    /// 协议 JSON 是 snake_case：`source_ref` / `path_hint` / `done_by`…
    public static let decoder: JSONDecoder = { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }()
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; e.outputFormatting = [.sortedKeys]; return e
    }()
}

/// PATCH 响应里的 `conflicts[]`：同一项两边改成不同的非 done 状态。
public struct OrgConflictDTO: Codable, Equatable, Sendable {
    public var itemId: Int64
    public var serverStatus: String
    public var clientStatus: String

    public init(itemId: Int64, serverStatus: String, clientStatus: String) {
        self.itemId = itemId; self.serverStatus = serverStatus; self.clientStatus = clientStatus
    }
}

// MARK: - 上行（协议 §2 PATCH / needs / audit）

public struct OrgPatchItem: Codable, Equatable, Sendable {
    /// 服务端的清单项 id（下行时记下的）。
    public var id: Int64
    public var ord: Int
    public var status: String
    public var doneBy: String?
    public var doneAt: String?
    public var startedAt: String?
}

/// `PATCH /tasks/{id}`：阶段 / 勾选 / 结果；`baseVersion` = 本地记录的服务端版本（离线重放也用它，§3）。
public struct OrgPatch: Codable, Equatable, Sendable {
    public var baseVersion: Int
    public var stage: String
    /// 只会是 `dropped`（结束态只有服务端或节点的放弃能设）。
    public var status: String?
    public var items: [OrgPatchItem]
    public var resultSummary: String
    public var updatedAt: String
}

/// `POST /tasks/{id}/needs`：这个任务此刻需要人的事；`none` 清除。
public struct OrgNeedsUpload: Codable, Equatable, Sendable {
    public var kind: String
    public var question: String?
    public var ticketRef: String?

    public init(kind: String, question: String? = nil, ticketRef: String? = nil) {
        self.kind = kind; self.question = question; self.ticketRef = ticketRef
    }

    public static let none = OrgNeedsUpload(kind: "none")
    /// 去重用：同样的内容不重复上传。
    public var signature: String { "\(kind)|\(question ?? "")|\(ticketRef ?? "")" }
}

/// `POST /tasks/{id}/audit` 的一条：命令摘要和凭据**名字**，不传命令全文（I-06）。
public struct OrgAuditEntry: Codable, Equatable, Sendable {
    public var at: String
    public var kind: String
    public var summary: String
    public var credentialNames: [String]
}

// MARK: - 本地的同步状态

/// 上行队列的一条（I-02：append-only、按序重放、发送成功才删）。同一任务同类未发送的合并成一条。
public struct OutboxEntry: Equatable, Sendable, Identifiable {
    public var id: Int64
    /// 0 = 节点级（当天打扰次数）。
    public var taskID: Int64
    /// `patch`（阶段 / 勾选 / 结果）· `needs`（需要人）· `audit`（活动摘要）· `interruptions`（当天打扰次数，payload = 日期）。
    public var kind: String
    public var payload: String
    /// 每次重新入队 +1；发送完成时 seq 不同 = 期间又有新改动，不能删。
    public var seq: Int64
    public var attempts: Int
    public var nextAt: Double
    public var lastError: String?
    public var createdAt: Double
}

/// 同一项两边改成不同的非 done 状态（I-03）：不自动裁决，进「需要你」让人定。
public struct SyncConflict: Equatable, Sendable, Identifiable {
    public var ord: Int
    public var text: String
    public var local: ItemStatus
    public var server: ItemStatus
    public var id: Int { ord }

    public init(ord: Int, text: String, local: ItemStatus, server: ItemStatus) {
        self.ord = ord; self.text = text; self.local = local; self.server = server
    }

    /// 「同步冲突：第 3 项本地「工作中」、服务端「受阻」，以哪个为准？」
    public var line: String { "第 \(ord) 项本地「\(local.label)」、服务端「\(server.label)」，以哪个为准？" }
}

/// 节点的注册信息（`kv`：`org.serverURL / org.email / org.nodeID / org.lastSync …`）。token 在钥匙串里，不在库里。
public struct OrgSettings: Equatable, Sendable {
    public var serverURL = ""
    public var email = ""
    /// 首次注册时生成（UUID 前 8 位），之后不变；重复注册同一 id = 换 token。
    public var nodeID: String?
    public var lastSync: Double?
    /// `GET /tasks?since=` 和 `GET /events?since=` 的游标。
    public var taskCursor: String?
    public var eventCursor: String?
    public var workspace = ""

    public init() {}

    public var isRegistered: Bool { nodeID != nil && !serverURL.isEmpty }
}

/// 组织任务在本地记的服务端状态（`org_task` 表）。
struct OrgTaskState: Equatable {
    var taskID: Int64
    var version: Int
    var label: String
    var scopeName: String
    var edits: Bool
    /// 上次上传的 needs 签名（同样的不重复传）。
    var needsSent: String
    /// 活动摘要已上传到的 event id。
    var auditAfter: Int64
}

/// 清单项 ↔ 服务端清单项（`org_item` 表）。`syncedStatus` = 上次同步时服务端的状态：两边各自改没改都靠它判断。
struct OrgItemState: Equatable {
    var itemID: Int64
    var taskID: Int64
    var originItemID: Int64
    var syncedStatus: ItemStatus
    var conflictLocal: ItemStatus?
    var conflictServer: ItemStatus?
}
