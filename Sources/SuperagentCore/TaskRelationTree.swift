import Foundation

// 任务关联清单脉络树（`TaskRelationTree.swift`）：
// 从任意焦点任务出发，沿「前置依赖（task_dep）」「退回衍生（handbackLinks）」「跨任务经验关联（task_context_link）」
// 双向多跳遍历连通子图，构建纯值类型无环树，供界面直观展示直接/间接关联清单的状态、完成进度与高信噪比简介。

/// 清单节点之间的有向关联类型（统一约定方向：`上游父节点 P -> 下游子节点 C`）。
public enum TaskRelationKind: Equatable, Hashable, Sendable {
    /// 前置依赖：`C` 在 `task_dep` 中依赖上游任务 `P`（`P -> C`）。
    case dependency
    /// 退回衍生：原任务 `P` 的第 `itemOrd` 项退回成为子任务 `C`（`P -> C`）。
    case handback(itemOrd: Int)
    /// 经验关联：下游任务 `C` 通过 `task_context_link` 引用了历史任务 `P` 的总结或独立知识卡 `K-M`（`P -> C`）。
    case experience

    public var label: String {
        switch self {
        case .dependency:
            return "前置依赖"
        case .handback(let ord):
            return ord > 0 ? "第 \(ord) 项退回" : "退回衍生"
        case .experience:
            return "经验衍生"
        }
    }

    /// 同一对节点同时存在多种关联时的展示优先级：退回衍生 > 前置依赖 > 经验衍生。
    fileprivate var priorityRank: Int {
        switch self {
        case .handback: return 3
        case .dependency: return 2
        case .experience: return 1
        }
    }
}

/// 节点状态语义色阶（供 UI 层一一映射至 `Theme.Status.*`，不引入 Core 对 SwiftUI 的依赖）。
public enum TaskRelationStatusTone: String, Equatable, Hashable, Sendable {
    /// 已完成（鼠尾草绿 `Theme.Status.positive`）。
    case positive
    /// 需要你介入：待评审 / 等你回答 / 受阻 / 停下未回报（琥珀色 `Theme.Status.attention`）。
    case attention
    /// 失败 / 送达失败（砖红色 `Theme.Status.error`）。
    case error
    /// 进行中 / 评审中（墨炭黑 `Theme.Status.active`）。
    case active
    /// 待分配 / 待领取 / 已取消 / 已放弃 / 独立知识卡（石灰中性色 `Theme.Status.neutral`）。
    case neutral
}

/// 关联脉络树中的单个节点（对应任务 `A-<id>` 或独立知识卡 `K-<id>`）。
public struct TaskRelationNode: Equatable, Sendable, Identifiable {
    /// 唯一节点标识：任务节点为 `"task:<id>"`，独立知识卡节点为 `"kb:<id>"`。
    public var id: String
    /// 任务节点的任务 ID；独立知识卡节点为 `nil`。
    public var taskID: Int64?
    /// 关联的知识卡 ID（独立知识卡必有值；已完成/已沉淀总结的任务节点也记录其对应知识卡 ID）。
    public var knowledgeID: Int64?
    /// 展示编号（如 `"A-18"` 或 `"K-21"`）。
    public var label: String
    /// 节点标题。
    public var title: String
    /// 高信噪比单/双行简介（无可用摘要时为空字符串）。
    public var summary: String
    /// 当前状态文案（如 `已完成`、`进行中`、`待评审`、`等你回答`、`受阻`、`失败`、`待分配`、`已取消`、`已放弃`、`知识卡`）。
    public var statusText: String
    /// 状态语义色阶。
    public var statusTone: TaskRelationStatusTone
    /// 已完成清单项数量（独立知识卡为 `0`）。
    public var doneCount: Int
    /// 清单项总数（独立知识卡为 `0`）。
    public var totalCount: Int
    /// 相对于树中父节点的关系类型；树根节点为 `nil`。
    public var relationFromParent: TaskRelationKind?
    /// 当节点作为次级汇合根（`relationFromParent == nil && children.isEmpty`）且与焦点任务直接相连时，记录它与焦点的关系供界面提示。
    public var relationToFocus: TaskRelationKind?
    /// 与当前焦点任务 `focusTaskID` 的最短无向图跳数：`0` = 当前任务自身，`1` = 直接关联，`>= 2` = 间接关联。
    public var distanceFromFocus: Int
    /// 若该节点是当前焦点任务通过 `task_context_link` 直接关联的上游经验，记录其 `knowledgeID` 供 UI 一键移除关联。
    public var canUnlinkFromFocus: Int64?
    /// 按时间/任务号稳定排序的子节点列表。
    public var children: [TaskRelationNode]

    public init(
        id: String,
        taskID: Int64?,
        knowledgeID: Int64?,
        label: String,
        title: String,
        summary: String,
        statusText: String,
        statusTone: TaskRelationStatusTone,
        doneCount: Int,
        totalCount: Int,
        relationFromParent: TaskRelationKind?,
        relationToFocus: TaskRelationKind? = nil,
        distanceFromFocus: Int,
        canUnlinkFromFocus: Int64? = nil,
        children: [TaskRelationNode] = []
    ) {
        self.id = id
        self.taskID = taskID
        self.knowledgeID = knowledgeID
        self.label = label
        self.title = title
        self.summary = summary
        self.statusText = statusText
        self.statusTone = statusTone
        self.doneCount = doneCount
        self.totalCount = totalCount
        self.relationFromParent = relationFromParent
        self.relationToFocus = relationToFocus
        self.distanceFromFocus = distanceFromFocus
        self.canUnlinkFromFocus = canUnlinkFromFocus
        self.children = children
    }

    public var isFocus: Bool { distanceFromFocus == 0 }
    public var isIndirect: Bool { distanceFromFocus >= 2 }
    public var isStandaloneKnowledge: Bool { taskID == nil && knowledgeID != nil }
}

/// 脉络图中的有向无环边（`fromID` 位于上游，`toID` 位于下游）。
public struct TaskRelationEdge: Equatable, Hashable, Sendable, Identifiable {
    public var fromID: String
    public var toID: String
    public var kind: TaskRelationKind

    public init(fromID: String, toID: String, kind: TaskRelationKind) {
        self.fromID = fromID
        self.toID = toID
        self.kind = kind
    }

    public var id: String { "\(fromID)->\(toID)" }
}

/// 围绕 `focusTaskID` 构建的多跳关联清单树容器。
public struct TaskRelationTree: Equatable, Sendable, Identifiable {
    public var focusTaskID: Int64
    public var roots: [TaskRelationNode]
    /// 连通子图经确定性去环后的全部有向边（保留多父汇聚边与菱形边）。
    public var edges: [TaskRelationEdge]
    /// 除焦点任务自身外的关联节点总数。
    public var totalRelatedCount: Int

    public init(
        focusTaskID: Int64,
        roots: [TaskRelationNode],
        edges: [TaskRelationEdge] = [],
        totalRelatedCount: Int
    ) {
        self.focusTaskID = focusTaskID
        self.roots = roots
        self.edges = edges
        self.totalRelatedCount = totalRelatedCount
    }

    public var id: Int64 { focusTaskID }
    public var isEmpty: Bool { totalRelatedCount == 0 }

    /// 树中距离焦点任务 `>= 2` 跳的间接关联节点总数。
    public var indirectCount: Int {
        allNodes.filter(\.isIndirect).count
    }

    /// 前序深度优先扁平化全部节点。
    public var allNodes: [TaskRelationNode] {
        var out: [TaskRelationNode] = []
        func walk(_ node: TaskRelationNode) {
            out.append(node)
            for child in node.children { walk(child) }
        }
        for root in roots { walk(root) }
        return out
    }
}

// MARK: - 引擎图遍历与无环脉络树生成

extension SuperagentEngine {
    private enum RelationNodeKey: Hashable, Comparable {
        case task(Int64)
        case knowledge(Int64)

        var idString: String {
            switch self {
            case .task(let tid): return "task:\(tid)"
            case .knowledge(let kid): return "kb:\(kid)"
            }
        }

        /// 稳定排序：任务节点按任务号（时间序）升序在前，独立知识卡按 ID 升序在后。
        static func < (lhs: RelationNodeKey, rhs: RelationNodeKey) -> Bool {
            switch (lhs, rhs) {
            case (.task(let a), .task(let b)): return a < b
            case (.task, .knowledge): return true
            case (.knowledge, .task): return false
            case (.knowledge(let a), .knowledge(let b)): return a < b
            }
        }
    }

    private struct DirectedEdgeKey: Hashable {
        let from: RelationNodeKey
        let to: RelationNodeKey
    }

    /// 构建指定焦点任务在 `maxDepth` 跳以内的完整关联脉络树。
    /// - 孤立无关联任务直接返回 `roots: [], totalRelatedCount: 0`。
    /// - 直接查 SQLite `store`，不受界面最近 30 条已结束任务截断限制，可追溯任意历史任务（如 `A-1`）与独立知识卡（`K-M`）。
    public func taskRelationTree(for focusTaskID: Int64, maxDepth: Int = 4) throws -> TaskRelationTree {
        _ = try requireTask(focusTaskID)
        guard maxDepth > 0 else {
            return TaskRelationTree(focusTaskID: focusTaskID, roots: [], totalRelatedCount: 0)
        }

        // 1. 读取全局轻量拓扑（仅整数 ID 列，微秒级）
        let existingTasks = try store.allTaskIDs()
        let deps = try store.allTaskDeps()
        let detached = try store.detachedHandbacks()
        let allHandbacks = try store.handbackLinks()
        let activeHandbacks = allHandbacks.filter { !detached.contains($0.toTaskID) }
        let contextLinks = try store.allTaskContextLinks()
        let kbMetaRows = try store.activeKnowledgeGraphMeta()

        var kbTaskMap: [Int64: Int64?] = [:] // knowledgeID -> taskID? (仅未归档条目)
        for row in kbMetaRows {
            kbTaskMap[row.id] = row.taskID
        }

        // 汇总全局有向边（from -> to）与无向邻接表
        var edgeKinds: [DirectedEdgeKey: TaskRelationKind] = [:]
        var undirectedAdj: [RelationNodeKey: Set<RelationNodeKey>] = [:]

        func recordEdge(from: RelationNodeKey, to: RelationNodeKey, kind: TaskRelationKind) {
            guard from != to else { return }
            let key = DirectedEdgeKey(from: from, to: to)
            if let old = edgeKinds[key], old.priorityRank >= kind.priorityRank {
                // 保留更高优先级的关系类型
            } else {
                edgeKinds[key] = kind
            }
            undirectedAdj[from, default: []].insert(to)
            undirectedAdj[to, default: []].insert(from)
        }

        // (a) 前置依赖边：dependsOn -> taskID
        for dep in deps where existingTasks.contains(dep.taskID) && existingTasks.contains(dep.dependsOn) {
            recordEdge(from: .task(dep.dependsOn), to: .task(dep.taskID), kind: .dependency)
        }

        // (b) 未脱离的退回衍生边：fromTaskID -> toTaskID
        for hb in activeHandbacks where existingTasks.contains(hb.fromTaskID) && existingTasks.contains(hb.toTaskID) {
            recordEdge(from: .task(hb.fromTaskID), to: .task(hb.toTaskID), kind: .handback(itemOrd: hb.itemOrd))
        }

        // (c) 跨任务经验关联边：历史任务 P（或独立知识卡 K）-> 下游任务 C
        for (downstreamTaskID, kids) in contextLinks.byTask where existingTasks.contains(downstreamTaskID) {
            for kid in kids {
                guard let maybeUpstreamTask = kbTaskMap[kid] else { continue } // 已归档或不存在的知识卡跳过
                if let upstreamTaskID = maybeUpstreamTask {
                    guard existingTasks.contains(upstreamTaskID) else { continue }
                    recordEdge(from: .task(upstreamTaskID), to: .task(downstreamTaskID), kind: .experience)
                } else {
                    recordEdge(from: .knowledge(kid), to: .task(downstreamTaskID), kind: .experience)
                }
            }
        }

        // 2. 从焦点任务出发执行无向 BFS，收集距离 <= maxDepth 的连通子图节点与最短跳数
        let focusKey = RelationNodeKey.task(focusTaskID)
        guard let initialNeighbors = undirectedAdj[focusKey], !initialNeighbors.isEmpty else {
            return TaskRelationTree(focusTaskID: focusTaskID, roots: [], totalRelatedCount: 0)
        }

        var distances: [RelationNodeKey: Int] = [focusKey: 0]
        var queue: [RelationNodeKey] = [focusKey]
        var head = 0
        while head < queue.count {
            let curr = queue[head]
            head += 1
            let d = distances[curr] ?? 0
            guard d < maxDepth else { continue }
            for next in (undirectedAdj[curr] ?? []).sorted() where distances[next] == nil {
                distances[next] = d + 1
                queue.append(next)
            }
        }

        let subgraphNodes = Set(distances.keys)
        guard subgraphNodes.count > 1 else {
            return TaskRelationTree(focusTaskID: focusTaskID, roots: [], totalRelatedCount: 0)
        }

        // 3. 批量加载连通子图内涉及的任务、清单项、工单、组织冲突与知识卡片
        let subgraphTaskIDs = subgraphNodes.compactMap { key -> Int64? in
            if case .task(let tid) = key { return tid }
            return nil
        }
        let standaloneKBIDs = subgraphNodes.compactMap { key -> Int64? in
            if case .knowledge(let kid) = key { return kid }
            return nil
        }

        let tasksByID = try store.tasks(ids: subgraphTaskIDs)
        let itemsByTask = try store.items(taskIDs: subgraphTaskIDs)
        let ticketsByTask = try store.tickets(taskIDs: subgraphTaskIDs)
        let conflictsByTask = try store.orgConflicts(taskIDs: subgraphTaskIDs)
        let taskKBsByTaskID = try store.knowledgeEntries(taskIDs: subgraphTaskIDs)
        let standaloneKBsByID = try store.knowledgeEntries(ids: standaloneKBIDs)

        // 构建子图内各任务的 TaskView（用于状态标签、进度与简介推导）
        var taskViewsByID: [Int64: TaskView] = [:]
        for tid in subgraphTaskIDs {
            guard let t = tasksByID[tid] else { continue }
            var tv = try makeView(
                t,
                items: itemsByTask[tid] ?? [],
                tickets: ticketsByTask[tid] ?? [],
                links: allHandbacks,
                detached: detached
            ) { childTaskID in
                if let cachedChild = tasksByID[childTaskID] {
                    guard cachedChild.isOpen else { return nil }
                    let childItems = itemsByTask[childTaskID] ?? []
                    return childItems.contains { $0.assignee == .unassigned } ? .unassigned : .doing
                }
                guard try store.task(childTaskID)?.isOpen == true else { return nil }
                return try store.items(childTaskID).contains { $0.assignee == .unassigned } ? .unassigned : .doing
            }
            tv.syncConflicts = conflictsByTask[tid] ?? []
            tv.knowledge = taskKBsByTaskID[tid]
            taskViewsByID[tid] = tv
        }

        // 当前焦点任务直接通过 task_context_link 关联的上游知识卡 ID 集合（支持一键移除）
        let directUpstreamKBIDs = Set(contextLinks.byTask[focusTaskID] ?? [])

        // 4. 构建导出有向子图邻接表（仅保留两端都在 subgraphNodes 且实体确实存在的节点）
        let validNodes = subgraphNodes.filter { key in
            switch key {
            case .task(let tid): return taskViewsByID[tid] != nil
            case .knowledge(let kid): return standaloneKBsByID[kid] != nil
            }
        }
        guard validNodes.contains(focusKey), validNodes.count > 1 else {
            return TaskRelationTree(focusTaskID: focusTaskID, roots: [], totalRelatedCount: 0)
        }

        var outgoing: [RelationNodeKey: [(to: RelationNodeKey, kind: TaskRelationKind)]] = [:]
        var inDegree: [RelationNodeKey: Int] = Dictionary(uniqueKeysWithValues: validNodes.map { ($0, 0) })

        struct CandidateEdge {
            let from: RelationNodeKey
            let to: RelationNodeKey
            let kind: TaskRelationKind
        }
        var candidateEdges: [CandidateEdge] = []
        candidateEdges.reserveCapacity(edgeKinds.count)

        for (edge, kind) in edgeKinds where validNodes.contains(edge.from) && validNodes.contains(edge.to) {
            outgoing[edge.from, default: []].append((edge.to, kind))
            inDegree[edge.to, default: 0] += 1
            candidateEdges.append(CandidateEdge(from: edge.from, to: edge.to, kind: kind))
        }
        for key in outgoing.keys {
            outgoing[key]?.sort { $0.to < $1.to }
        }

        // 4b. 构建确定性去环有向无环边集 edges（Cycle-safe DAG）：
        //     - 无环图 100% 保留全部多父汇聚边、菱形依赖与侧支连线；
        //     - 有向环出现时，按确定性优先级逐条加入 dagAdj（加入 u -> v 前检查是否已存在路径 v ~> u）。
        candidateEdges.sort { a, b in
            let aTouchesFocus = (a.from == focusKey || a.to == focusKey)
            let bTouchesFocus = (b.from == focusKey || b.to == focusKey)
            if aTouchesFocus != bTouchesFocus {
                return aTouchesFocus
            }
            let aMinDist = min(distances[a.from] ?? Int.max, distances[a.to] ?? Int.max)
            let bMinDist = min(distances[b.from] ?? Int.max, distances[b.to] ?? Int.max)
            if aMinDist != bMinDist {
                return aMinDist < bMinDist
            }
            if a.kind.priorityRank != b.kind.priorityRank {
                return a.kind.priorityRank > b.kind.priorityRank
            }
            if a.from != b.from {
                return a.from < b.from
            }
            return a.to < b.to
        }

        var dagAdj: [RelationNodeKey: [RelationNodeKey]] = [:]
        func hasDirectedPath(from start: RelationNodeKey, to target: RelationNodeKey) -> Bool {
            if start == target { return true }
            var seen = Set<RelationNodeKey>([start])
            var stack: [RelationNodeKey] = [start]
            while let curr = stack.popLast() {
                for next in dagAdj[curr] ?? [] {
                    if next == target { return true }
                    if seen.insert(next).inserted {
                        stack.append(next)
                    }
                }
            }
            return false
        }

        var acceptedEdges: [CandidateEdge] = []
        acceptedEdges.reserveCapacity(candidateEdges.count)
        for cand in candidateEdges {
            guard cand.from != cand.to, !hasDirectedPath(from: cand.to, to: cand.from) else { continue }
            dagAdj[cand.from, default: []].append(cand.to)
            acceptedEdges.append(cand)
        }

        acceptedEdges.sort { lhs, rhs in
            if lhs.from != rhs.from { return lhs.from < rhs.from }
            return lhs.to < rhs.to
        }
        let dagEdges = acceptedEdges.map {
            TaskRelationEdge(fromID: $0.from.idString, toID: $0.to.idString, kind: $0.kind)
        }

        // 5. 选定无环生成森林的根集合：
        //    - 首先收集所有入度为 0 的上游起点；
        //    - 若子图中存在有向环导致部分连通分支无法从入度为 0 的节点到达，自动补选该环中排序最前（最小 ID）的节点作为根；
        //    - 所有候选根按 RelationNodeKey 排序（任务节点按 taskID 升序优先于独立知识卡，保证任务主干链完整不断裂）。
        var seedRoots = validNodes.filter { (inDegree[$0] ?? 0) == 0 }.sorted()
        var reachable = Set<RelationNodeKey>()
        func markReachable(from start: RelationNodeKey) {
            var stack: [RelationNodeKey] = [start]
            while let curr = stack.popLast() {
                guard reachable.insert(curr).inserted else { continue }
                for edge in outgoing[curr] ?? [] {
                    if !reachable.contains(edge.to) { stack.append(edge.to) }
                }
            }
        }
        for r in seedRoots { markReachable(from: r) }
        while reachable.count < validNodes.count {
            let remaining = validNodes.subtracting(reachable).sorted()
            guard let fallback = remaining.first else { break }
            seedRoots.append(fallback)
            markReachable(from: fallback)
        }
        seedRoots.sort()

        // 6. DFS + visited 集合生成无环树（每个节点只出现一次）
        var visited = Set<RelationNodeKey>()

        func directRelationWithFocus(_ key: RelationNodeKey) -> TaskRelationKind? {
            guard key != focusKey else { return nil }
            if let forward = edgeKinds[DirectedEdgeKey(from: key, to: focusKey)] { return forward }
            if let backward = edgeKinds[DirectedEdgeKey(from: focusKey, to: key)] { return backward }
            return nil
        }

        func makeNode(_ key: RelationNodeKey, relationFromParent: TaskRelationKind?) -> TaskRelationNode {
            visited.insert(key)
            var childNodes: [TaskRelationNode] = []
            for edge in outgoing[key] ?? [] where !visited.contains(edge.to) {
                childNodes.append(makeNode(edge.to, relationFromParent: edge.kind))
            }

            let dist = distances[key] ?? 0
            let relFocus = (dist == 1) ? directRelationWithFocus(key) : nil

            switch key {
            case .task(let tid):
                let tv = taskViewsByID[tid]!
                let ownKB = taskKBsByTaskID[tid]
                let (statusText, statusTone) = Self.relationStatus(for: tv)
                let summary = Self.relationSummary(for: tv, knowledge: ownKB)
                let unlinkID: Int64? = {
                    guard tid != focusTaskID, let kid = ownKB?.id, directUpstreamKBIDs.contains(kid) else { return nil }
                    return kid
                }()
                return TaskRelationNode(
                    id: key.idString,
                    taskID: tid,
                    knowledgeID: ownKB?.id,
                    label: tv.task.label,
                    title: tv.task.title,
                    summary: summary,
                    statusText: statusText,
                    statusTone: statusTone,
                    doneCount: tv.doneCount,
                    totalCount: tv.totalCount,
                    relationFromParent: relationFromParent,
                    relationToFocus: relFocus,
                    distanceFromFocus: dist,
                    canUnlinkFromFocus: unlinkID,
                    children: childNodes
                )

            case .knowledge(let kid):
                let entry = standaloneKBsByID[kid]!
                let summary = Self.singleLineSummary(entry.tldr, limit: 160)
                let unlinkID: Int64? = directUpstreamKBIDs.contains(kid) ? kid : nil
                return TaskRelationNode(
                    id: key.idString,
                    taskID: nil,
                    knowledgeID: kid,
                    label: entry.kbLabel,
                    title: entry.title,
                    summary: summary,
                    statusText: "知识卡",
                    statusTone: .neutral,
                    doneCount: 0,
                    totalCount: 0,
                    relationFromParent: relationFromParent,
                    relationToFocus: relFocus,
                    distanceFromFocus: dist,
                    canUnlinkFromFocus: unlinkID,
                    children: childNodes
                )
            }
        }

        var roots: [TaskRelationNode] = []
        for seed in seedRoots where !visited.contains(seed) {
            roots.append(makeNode(seed, relationFromParent: nil))
        }
        // 防御性兜底：确保 validNodes 中 100% 节点均进入森林
        if visited.count < validNodes.count {
            for extra in validNodes.subtracting(visited).sorted() where !visited.contains(extra) {
                roots.append(makeNode(extra, relationFromParent: nil))
            }
        }

        let relatedCount = max(0, visited.count - 1)
        return TaskRelationTree(
            focusTaskID: focusTaskID,
            roots: roots,
            edges: dagEdges,
            totalRelatedCount: relatedCount
        )
    }

    // MARK: - 状态与高信噪比简介提取

    static func relationStatus(for view: TaskView) -> (text: String, tone: TaskRelationStatusTone) {
        switch view.task.status {
        case .done:
            return ("已完成", .positive)
        case .cancelled:
            return ("已取消", .neutral)
        case .dropped:
            return ("已放弃", .neutral)
        case .open:
            break
        }
        if view.task.syncState == "claimable" {
            return ("待领取", .neutral)
        }
        if let need = view.needsYou.first {
            let tone: TaskRelationStatusTone = (need == .failed || need == .delivery) ? .error : .attention
            return (need.label, tone)
        }
        if view.reviewing {
            return ("评审中", .active)
        }
        if view.unassignedCount > 0 {
            return ("待分配", .neutral)
        }
        return (view.task.stage, .active)
    }

    /// 任务节点的五级高信噪比摘要：
    /// ① `knowledgeEntry.tldr` -> ② `task.resultSummary` -> ③ 打开工单提问/受阻提示 ->
    /// ④ `items` 中已完成项摘要拼接 -> ⑤ `task.request`（若与标题不同）首段截断至 160 字。
    static func relationSummary(for view: TaskView, knowledge: KnowledgeEntry?) -> String {
        // ① 知识卡一句话结论
        if let kb = knowledge, !kb.archived {
            let tldr = singleLineSummary(kb.tldr, limit: 160)
            if !tldr.isEmpty { return tldr }
        }

        // ② 任务完成结果摘要
        let result = singleLineSummary(view.task.resultSummary, limit: 160)
        if !result.isEmpty { return result }

        // ③ 打开工单的提问 / 受阻 / 失败 / 送达异常提示
        let openTickets = view.tickets.filter(\.ticket.isOpen)
        for tv in openTickets {
            if let ask = tv.ticket.attention {
                let cleaned = singleLineSummary(ask, limit: 160)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        for tv in openTickets {
            switch tv.stage {
            case .person(.blocked), .person(.failed):
                let cleaned = singleLineSummary(tv.ticket.reportSummary, limit: 160)
                if !cleaned.isEmpty { return cleaned }
            case .person(.delivery):
                if let err = tv.ticket.deliveryError {
                    let cleaned = singleLineSummary(err, limit: 160)
                    if !cleaned.isEmpty { return cleaned }
                }
            default:
                break
            }
        }

        // ④ 已完成清单项的摘要拼接
        var doneSnippets: [String] = []
        for item in view.items where item.status == .done {
            var raw = item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty, let tid = item.ticketID, let tv = view.ticket(tid) {
                raw = tv.ticket.reportSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let cleaned = singleLineSummary(raw, limit: 120)
            if !cleaned.isEmpty, !doneSnippets.contains(cleaned) {
                doneSnippets.append(cleaned)
            }
        }
        if !doneSnippets.isEmpty {
            return singleLineSummary(doneSnippets.joined(separator: "；"), limit: 160)
        }

        // ⑤ task.request（若与标题不同）首段截断至 160 字
        let reqTrimmed = view.task.request.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleTrimmed = view.task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reqTrimmed.isEmpty, reqTrimmed != titleTrimmed {
            let firstParagraph = reqTrimmed
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? reqTrimmed
            return singleLineSummary(firstParagraph, limit: 160)
        }

        return ""
    }

    private static func singleLineSummary(_ raw: String, limit: Int) -> String {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "" }
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }
}
