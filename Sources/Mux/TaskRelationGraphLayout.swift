import CoreGraphics
import Foundation
import SuperagentCore

// 横向思维导图 DAG 几何与拓扑布局引擎（`TaskRelationGraphLayout.swift`）：
// 以当前焦点清单（`relativeStep == 0`）为视觉锚点，将多跳有向关联子图排版为
// 「左列上游 ──▶ 中间当前清单 ──▶ 右列下游/衍生」的严格左→右无重叠思维导图坐标系。

enum TaskRelationGraphLayout {
    struct Metrics: Equatable, Sendable {
        var cardWidth: CGFloat
        var cardHeight: CGFloat
        var experienceCardHeight: CGFloat = 64
        var columnGap: CGFloat
        var rowGap: CGFloat
        var headerHeight: CGFloat
        var canvasPaddingX: CGFloat
        var canvasPaddingY: CGFloat

        static func adaptive(columnCount: Int, availableWidth: CGFloat = 824) -> Metrics {
            let cardHeight: CGFloat = 114
            let experienceCardHeight: CGFloat = 64
            let rowGap: CGFloat = 14
            let headerHeight: CGFloat = 28
            let canvasPaddingX: CGFloat = 18
            let canvasPaddingY: CGFloat = 12

            let cardWidth: CGFloat
            let columnGap: CGFloat

            if columnCount <= 2 {
                cardWidth = 248
                columnGap = 72
            } else if columnCount == 3 {
                columnGap = 58
                let usable = availableWidth - canvasPaddingX * 2 - columnGap * 2 - 4
                cardWidth = max(208, min(228, floor(usable / 3)))
            } else {
                cardWidth = 218
                columnGap = 58
            }

            return Metrics(
                cardWidth: cardWidth,
                cardHeight: cardHeight,
                experienceCardHeight: experienceCardHeight,
                columnGap: columnGap,
                rowGap: rowGap,
                headerHeight: headerHeight,
                canvasPaddingX: canvasPaddingX,
                canvasPaddingY: canvasPaddingY
            )
        }
    }

    struct ColumnHeader: Equatable, Identifiable, Sendable {
        let index: Int
        let relativeStep: Int
        let title: String
        let centerX: CGFloat
        let width: CGFloat

        var id: Int { index }
    }

    struct PositionedNode: Equatable, Identifiable, Sendable {
        let node: TaskRelationNode
        let columnIndex: Int
        let relativeStep: Int
        let frame: CGRect
        let primaryRelation: TaskRelationKind?
        /// 是否采用精简「经验参考 / 经验衍生」轻量卡片样式（与本任务硬工作流清单卡明确区分）。
        let isExperienceStyle: Bool
        let upstreamFoldToken: String?
        let isUpstreamCollapsed: Bool
        let hiddenUpstreamCount: Int
        let downstreamFoldToken: String?
        let isDownstreamCollapsed: Bool
        let hiddenDownstreamCount: Int

        var id: String { node.id }
        var leftPort: CGPoint { CGPoint(x: frame.minX, y: frame.midY) }
        var rightPort: CGPoint { CGPoint(x: frame.maxX, y: frame.midY) }
    }

    struct PositionedEdge: Equatable, Identifiable, Sendable {
        let id: String
        let fromID: String
        let toID: String
        let kind: TaskRelationKind
        let start: CGPoint
        let end: CGPoint
        let control1: CGPoint
        let control2: CGPoint
        let midPoint: CGPoint
        let touchesFocus: Bool
    }

    struct Graph: Equatable, Sendable {
        let focusNodeID: String
        let metrics: Metrics
        let columns: [ColumnHeader]
        let nodes: [PositionedNode]
        let edges: [PositionedEdge]
        let canvasSize: CGSize
        let focusFrame: CGRect
        /// 一键「收起间接」使用的折叠 token 集合（收起后仅保留距离当前清单 1 跳的直接上下游 + 当前清单，绝不隐藏当前清单自身！）
        let indirectFoldTokens: Set<String>
    }

    static func statsText(_ tree: TaskRelationTree) -> String {
        let indirect = tree.indirectCount
        if indirect > 0 {
            return "共 \(tree.totalRelatedCount) 个关联 · 含 \(indirect) 个间接"
        }
        return "共 \(tree.totalRelatedCount) 个关联"
    }

    static func layout(
        _ tree: TaskRelationTree,
        collapsed: Set<String> = [],
        availableWidth: CGFloat = 824
    ) -> Graph {
        let focusNodeID = "task:\(tree.focusTaskID)"

        // 0. 收集去重节点与稳定原序
        var orderedNodes: [TaskRelationNode] = []
        var nodeByID: [String: TaskRelationNode] = [:]
        var originalOrder: [String: Int] = [:]
        for node in tree.allNodes where nodeByID[node.id] == nil {
            originalOrder[node.id] = orderedNodes.count
            orderedNodes.append(node)
            nodeByID[node.id] = node
        }

        guard !orderedNodes.isEmpty else {
            let emptyMetrics = Metrics.adaptive(columnCount: 0, availableWidth: availableWidth)
            return Graph(
                focusNodeID: focusNodeID,
                metrics: emptyMetrics,
                columns: [],
                nodes: [],
                edges: [],
                canvasSize: .zero,
                focusFrame: .zero,
                indirectFoldTokens: []
            )
        }

        let anchorID: String = {
            if nodeByID[focusNodeID] != nil { return focusNodeID }
            if let explicitFocus = orderedNodes.first(where: \.isFocus) { return explicitFocus.id }
            return orderedNodes[0].id
        }()

        // 1. 提取有效边集（含空 edges 兼容兜底）并做确定性去环以保证严格 DAG
        let rawEdges = extractRawEdges(from: tree, nodeByID: nodeByID, focusNodeID: anchorID)
        let dagEdges = breakCyclesIfNeeded(
            edges: rawEdges,
            orderedNodeIDs: orderedNodes.map(\.id),
            originalOrder: originalOrder,
            anchorID: anchorID
        )

        // 构建有向与无向邻接结构
        var outgoing: [String: [TaskRelationEdge]] = [:]
        var incoming: [String: [TaskRelationEdge]] = [:]
        var undirectedNeighbors: [String: [String]] = [:]
        var undirectedSeen: [String: Set<String>] = [:]

        for edge in dagEdges {
            outgoing[edge.fromID, default: []].append(edge)
            incoming[edge.toID, default: []].append(edge)
            if undirectedSeen[edge.fromID, default: []].insert(edge.toID).inserted {
                undirectedNeighbors[edge.fromID, default: []].append(edge.toID)
            }
            if undirectedSeen[edge.toID, default: []].insert(edge.fromID).inserted {
                undirectedNeighbors[edge.toID, default: []].append(edge.fromID)
            }
        }

        for id in outgoing.keys {
            outgoing[id]?.sort { (originalOrder[$0.toID] ?? 0) < (originalOrder[$1.toID] ?? 0) }
        }
        for id in incoming.keys {
            incoming[id]?.sort { (originalOrder[$0.fromID] ?? 0) < (originalOrder[$1.fromID] ?? 0) }
        }
        for id in undirectedNeighbors.keys {
            undirectedNeighbors[id]?.sort { (originalOrder[$0] ?? 0) < (originalOrder[$1] ?? 0) }
        }

        // 2. 以 anchorID (step = 0) 为锚点分配严格单调的左 → 中 → 右列步长 relativeStep
        let topoOrder = topologicalSort(
            nodeIDs: orderedNodes.map(\.id),
            outgoing: outgoing,
            incoming: incoming,
            originalOrder: originalOrder
        )
        let stepsByID = assignRelativeSteps(
            topoOrder: topoOrder,
            anchorID: anchorID,
            outgoing: outgoing,
            incoming: incoming
        )

        // 3. 从 anchorID 向两侧外展的受限可达性与折叠 token 推导
        let sanitizedCollapsed = collapsed.filter {
            $0 != "up:\(anchorID)" && $0 != "down:\(anchorID)"
        }

        func computeVisibleIDs(activeTokens: Set<String>) -> Set<String> {
            var visited: Set<String> = [anchorID]
            var queue: [String] = [anchorID]
            var head = 0
            while head < queue.count {
                let curr = queue[head]
                head += 1
                let currStep = stepsByID[curr] ?? 0
                let blockLeft = curr != anchorID && activeTokens.contains("up:\(curr)")
                let blockRight = curr != anchorID && activeTokens.contains("down:\(curr)")

                for nbr in undirectedNeighbors[curr] ?? [] where !visited.contains(nbr) {
                    let nbrStep = stepsByID[nbr] ?? 0
                    if nbrStep < currStep && blockLeft { continue }
                    if nbrStep > currStep && blockRight { continue }
                    visited.insert(nbr)
                    queue.append(nbr)
                }
            }
            return visited
        }

        let allVisibleBaseline = computeVisibleIDs(activeTokens: [])

        // 同跳数节点的候选折叠集合（用于在菱形汇合/分叉拓扑中识别协同可折叠端口）
        var peerCandidateTokensByDistance: [Int: Set<String>] = [:]
        for node in orderedNodes where node.id != anchorID && node.distanceFromFocus > 0 {
            let step = stepsByID[node.id] ?? 0
            let hasLeftNbr = (undirectedNeighbors[node.id] ?? []).contains { (stepsByID[$0] ?? 0) < step }
            let hasRightNbr = (undirectedNeighbors[node.id] ?? []).contains { (stepsByID[$0] ?? 0) > step }
            if step < 0 && hasLeftNbr {
                peerCandidateTokensByDistance[node.distanceFromFocus, default: []].insert("up:\(node.id)")
            } else if step > 0 && hasLeftNbr {
                peerCandidateTokensByDistance[node.distanceFromFocus, default: []].insert("up:\(node.id)")
            }
            if step > 0 && hasRightNbr {
                peerCandidateTokensByDistance[node.distanceFromFocus, default: []].insert("down:\(node.id)")
            } else if step < 0 && hasRightNbr {
                peerCandidateTokensByDistance[node.distanceFromFocus, default: []].insert("down:\(node.id)")
            }
        }

        struct FoldMeta {
            var upstreamToken: String?
            var isUpstreamCollapsed: Bool
            var hiddenUpstreamCount: Int
            var downstreamToken: String?
            var isDownstreamCollapsed: Bool
            var hiddenDownstreamCount: Int
        }

        var foldMetaByID: [String: FoldMeta] = [:]
        var indirectFoldTokens: Set<String> = []

        for node in orderedNodes {
            guard node.id != anchorID else {
                foldMetaByID[node.id] = FoldMeta(
                    upstreamToken: nil,
                    isUpstreamCollapsed: false,
                    hiddenUpstreamCount: 0,
                    downstreamToken: nil,
                    isDownstreamCollapsed: false,
                    hiddenDownstreamCount: 0
                )
                continue
            }

            let nStep = stepsByID[node.id] ?? 0
            let hasLeftEdge = !(incoming[node.id] ?? []).isEmpty
                || (undirectedNeighbors[node.id] ?? []).contains { (stepsByID[$0] ?? 0) < nStep }
            let hasRightEdge = !(outgoing[node.id] ?? []).isEmpty
                || (undirectedNeighbors[node.id] ?? []).contains { (stepsByID[$0] ?? 0) > nStep }
            let peerTokens = peerCandidateTokensByDistance[node.distanceFromFocus] ?? []

            var upToken: String?
            var upCollapsed = false
            var upHidden = 0
            if hasLeftEdge {
                let candidate = "up:\(node.id)"
                let soloHidden = allVisibleBaseline.subtracting(computeVisibleIDs(activeTokens: [candidate])).count
                let withoutToken = sanitizedCollapsed.subtracting([candidate])
                let withToken = sanitizedCollapsed.union([candidate])
                let currentHidden = computeVisibleIDs(activeTokens: withoutToken)
                    .subtracting(computeVisibleIDs(activeTokens: withToken)).count
                let peerHidden: Int = {
                    guard soloHidden == 0, currentHidden == 0, peerTokens.contains(candidate) else { return 0 }
                    let peerWithout = peerTokens.subtracting([candidate])
                    return computeVisibleIDs(activeTokens: peerWithout)
                        .subtracting(computeVisibleIDs(activeTokens: peerTokens)).count
                }()
                let effectiveHidden = currentHidden > 0 ? currentHidden : (soloHidden > 0 ? soloHidden : peerHidden)
                if effectiveHidden > 0 {
                    upToken = candidate
                    upCollapsed = sanitizedCollapsed.contains(candidate)
                    upHidden = effectiveHidden
                    if node.distanceFromFocus == 1 {
                        indirectFoldTokens.insert(candidate)
                    }
                }
            }

            var downToken: String?
            var downCollapsed = false
            var downHidden = 0
            if hasRightEdge {
                let candidate = "down:\(node.id)"
                let soloHidden = allVisibleBaseline.subtracting(computeVisibleIDs(activeTokens: [candidate])).count
                let withoutToken = sanitizedCollapsed.subtracting([candidate])
                let withToken = sanitizedCollapsed.union([candidate])
                let currentHidden = computeVisibleIDs(activeTokens: withoutToken)
                    .subtracting(computeVisibleIDs(activeTokens: withToken)).count
                let peerHidden: Int = {
                    guard soloHidden == 0, currentHidden == 0, peerTokens.contains(candidate) else { return 0 }
                    let peerWithout = peerTokens.subtracting([candidate])
                    return computeVisibleIDs(activeTokens: peerWithout)
                        .subtracting(computeVisibleIDs(activeTokens: peerTokens)).count
                }()
                let effectiveHidden = currentHidden > 0 ? currentHidden : (soloHidden > 0 ? soloHidden : peerHidden)
                if effectiveHidden > 0 {
                    downToken = candidate
                    downCollapsed = sanitizedCollapsed.contains(candidate)
                    downHidden = effectiveHidden
                    if node.distanceFromFocus == 1 {
                        indirectFoldTokens.insert(candidate)
                    }
                }
            }

            foldMetaByID[node.id] = FoldMeta(
                upstreamToken: upToken,
                isUpstreamCollapsed: upCollapsed,
                hiddenUpstreamCount: upHidden,
                downstreamToken: downToken,
                isDownstreamCollapsed: downCollapsed,
                hiddenDownstreamCount: downHidden
            )
        }

        let visibleIDs = computeVisibleIDs(activeTokens: sanitizedCollapsed)
        let visibleEdges = dagEdges.filter { visibleIDs.contains($0.fromID) && visibleIDs.contains($0.toID) }

        // 识别硬工作流连通集（仅沿前置依赖 dependency 与退回衍生 handback 无向可达 anchorID 的清单节点）：
        // 凡不属于硬工作流连通集（即经由经验关联引入或衍生）或本身是独立知识卡的非焦点节点，均采用轻量「经验」卡片样式。
        let workflowConnectedIDs: Set<String> = {
            var wfAdj: [String: [String]] = [:]
            for edge in dagEdges where edge.kind != .experience {
                wfAdj[edge.fromID, default: []].append(edge.toID)
                wfAdj[edge.toID, default: []].append(edge.fromID)
            }
            var visited: Set<String> = [anchorID]
            var q: [String] = [anchorID]
            var idx = 0
            while idx < q.count {
                let curr = q[idx]
                idx += 1
                for nxt in wfAdj[curr] ?? [] where !visited.contains(nxt) {
                    visited.insert(nxt)
                    q.append(nxt)
                }
            }
            return visited
        }()

        // 4. 分列与列内 Barycenter 重心排序
        var columnBuckets: [Int: [String]] = [:]
        var isExperienceByID: [String: Bool] = [:]
        var heightByID: [String: CGFloat] = [:]
        for node in orderedNodes where visibleIDs.contains(node.id) {
            let step = stepsByID[node.id] ?? 0
            columnBuckets[step, default: []].append(node.id)
        }
        let sortedSteps = columnBuckets.keys.sorted()
        let metrics = Metrics.adaptive(columnCount: sortedSteps.count, availableWidth: availableWidth)
        for node in orderedNodes where visibleIDs.contains(node.id) {
            let isExp = !node.isFocus && node.id != anchorID
                && (node.isStandaloneKnowledge || !workflowConnectedIDs.contains(node.id))
            isExperienceByID[node.id] = isExp
            heightByID[node.id] = isExp ? metrics.experienceCardHeight : metrics.cardHeight
        }

        let orderedColumns = orderNodesWithinColumns(
            sortedSteps: sortedSteps,
            initialBuckets: columnBuckets,
            anchorID: anchorID,
            visibleEdges: visibleEdges,
            stepsByID: stepsByID,
            originalOrder: originalOrder
        )

        // 5. 计算垂直 Y 坐标（支持工作清单大卡与经验轻量卡异高混排：围绕水平主轴居中 + 父子重心微调 + 保序最小间距防重叠）
        let midYByID = assignVerticalCenters(
            sortedSteps: sortedSteps,
            orderedColumns: orderedColumns,
            anchorID: anchorID,
            visibleEdges: visibleEdges,
            stepsByID: stepsByID,
            heightByID: heightByID,
            metrics: metrics
        )

        // 6. 生成 ColumnHeader、PositionedNode 与 PositionedEdge
        var columnHeaders: [ColumnHeader] = []
        var positionedNodes: [PositionedNode] = []
        var positionedByID: [String: PositionedNode] = [:]
        var rowIndexByID: [String: Int] = [:]

        for (colIdx, step) in sortedSteps.enumerated() {
            let colNodeIDs = orderedColumns[step] ?? []
            let colX = metrics.canvasPaddingX + CGFloat(colIdx) * (metrics.cardWidth + metrics.columnGap)
            let centerX = colX + metrics.cardWidth * 0.5
            let headerTitle = columnTitle(for: step, nodeIDs: colNodeIDs, anchorID: anchorID)
            columnHeaders.append(
                ColumnHeader(
                    index: colIdx,
                    relativeStep: step,
                    title: headerTitle,
                    centerX: centerX,
                    width: metrics.cardWidth
                )
            )

            for (rowIdx, nid) in colNodeIDs.enumerated() {
                guard let node = nodeByID[nid] else { continue }
                rowIndexByID[nid] = rowIdx
                let nodeHeight = heightByID[nid] ?? metrics.cardHeight
                let midY = midYByID[nid] ?? (metrics.headerHeight + metrics.canvasPaddingY + nodeHeight * 0.5)
                let frame = CGRect(
                    x: colX,
                    y: midY - nodeHeight * 0.5,
                    width: metrics.cardWidth,
                    height: nodeHeight
                )
                let rel = resolvePrimaryRelation(
                    for: node,
                    anchorID: anchorID,
                    nodeByID: nodeByID,
                    incoming: incoming[nid] ?? [],
                    outgoing: outgoing[nid] ?? []
                )
                let fold = foldMetaByID[nid] ?? FoldMeta(
                    upstreamToken: nil,
                    isUpstreamCollapsed: false,
                    hiddenUpstreamCount: 0,
                    downstreamToken: nil,
                    isDownstreamCollapsed: false,
                    hiddenDownstreamCount: 0
                )
                let pNode = PositionedNode(
                    node: node,
                    columnIndex: colIdx,
                    relativeStep: step,
                    frame: frame,
                    primaryRelation: rel,
                    isExperienceStyle: isExperienceByID[nid] ?? false,
                    upstreamFoldToken: fold.upstreamToken,
                    isUpstreamCollapsed: fold.isUpstreamCollapsed,
                    hiddenUpstreamCount: fold.hiddenUpstreamCount,
                    downstreamFoldToken: fold.downstreamToken,
                    isDownstreamCollapsed: fold.isDownstreamCollapsed,
                    hiddenDownstreamCount: fold.hiddenDownstreamCount
                )
                positionedNodes.append(pNode)
                positionedByID[nid] = pNode
            }
        }

        let sortedVisibleEdges = visibleEdges.sorted { lhs, rhs in
            let lFromCol = positionedByID[lhs.fromID]?.columnIndex ?? 0
            let rFromCol = positionedByID[rhs.fromID]?.columnIndex ?? 0
            if lFromCol != rFromCol { return lFromCol < rFromCol }
            let lFromRow = rowIndexByID[lhs.fromID] ?? 0
            let rFromRow = rowIndexByID[rhs.fromID] ?? 0
            if lFromRow != rFromRow { return lFromRow < rFromRow }
            let lToCol = positionedByID[lhs.toID]?.columnIndex ?? 0
            let rToCol = positionedByID[rhs.toID]?.columnIndex ?? 0
            if lToCol != rToCol { return lToCol < rToCol }
            return (rowIndexByID[lhs.toID] ?? 0) < (rowIndexByID[rhs.toID] ?? 0)
        }

        var positionedEdges: [PositionedEdge] = []
        positionedEdges.reserveCapacity(sortedVisibleEdges.count)
        for edge in sortedVisibleEdges {
            guard let fromNode = positionedByID[edge.fromID],
                  let toNode = positionedByID[edge.toID] else { continue }
            let start = fromNode.rightPort
            let end = toNode.leftPort
            let dx = max(24, (end.x - start.x) * 0.5)
            let c1 = CGPoint(x: start.x + dx, y: start.y)
            let c2 = CGPoint(x: end.x - dx, y: end.y)
            let mid = CGPoint(
                x: 0.125 * start.x + 0.375 * c1.x + 0.375 * c2.x + 0.125 * end.x,
                y: 0.125 * start.y + 0.375 * c1.y + 0.375 * c2.y + 0.125 * end.y
            )
            positionedEdges.append(
                PositionedEdge(
                    id: edge.id,
                    fromID: edge.fromID,
                    toID: edge.toID,
                    kind: edge.kind,
                    start: start,
                    end: end,
                    control1: c1,
                    control2: c2,
                    midPoint: mid,
                    touchesFocus: edge.fromID == focusNodeID || edge.toID == focusNodeID
                        || edge.fromID == anchorID || edge.toID == anchorID
                )
            )
        }

        let maxX = positionedNodes.map(\.frame.maxX).max() ?? 0
        let maxY = positionedNodes.map(\.frame.maxY).max() ?? 0
        let canvasSize = CGSize(
            width: maxX + metrics.canvasPaddingX,
            height: maxY + metrics.canvasPaddingY
        )
        let focusFrame = positionedByID[focusNodeID]?.frame
            ?? positionedByID[anchorID]?.frame
            ?? .zero

        return Graph(
            focusNodeID: focusNodeID,
            metrics: metrics,
            columns: columnHeaders,
            nodes: positionedNodes,
            edges: positionedEdges,
            canvasSize: canvasSize,
            focusFrame: focusFrame,
            indirectFoldTokens: indirectFoldTokens
        )
    }

    // MARK: - 1. 边集提取与去环

    private static func relationPriority(_ kind: TaskRelationKind) -> Int {
        switch kind {
        case .handback: return 3
        case .dependency: return 2
        case .experience: return 1
        }
    }

    private static func extractRawEdges(
        from tree: TaskRelationTree,
        nodeByID: [String: TaskRelationNode],
        focusNodeID: String
    ) -> [TaskRelationEdge] {
        struct Pair: Hashable {
            let from: String
            let to: String
        }
        var bestKindByPair: [Pair: TaskRelationKind] = [:]
        var pairOrder: [Pair] = []

        func insert(from: String, to: String, kind: TaskRelationKind) {
            guard from != to, nodeByID[from] != nil, nodeByID[to] != nil else { return }
            let pair = Pair(from: from, to: to)
            if let existing = bestKindByPair[pair] {
                if relationPriority(kind) > relationPriority(existing) {
                    bestKindByPair[pair] = kind
                }
            } else {
                bestKindByPair[pair] = kind
                pairOrder.append(pair)
            }
        }

        if !tree.edges.isEmpty {
            for e in tree.edges {
                insert(from: e.fromID, to: e.toID, kind: e.kind)
            }
        } else {
            func walk(_ parent: TaskRelationNode) {
                for child in parent.children {
                    let kind = child.relationFromParent ?? .experience
                    insert(from: parent.id, to: child.id, kind: kind)
                    walk(child)
                }
            }
            for root in tree.roots {
                walk(root)
                if root.children.isEmpty, let relToFocus = root.relationToFocus, root.id != focusNodeID {
                    insert(from: root.id, to: focusNodeID, kind: relToFocus)
                }
            }
        }

        return pairOrder.compactMap { pair in
            guard let kind = bestKindByPair[pair] else { return nil }
            return TaskRelationEdge(fromID: pair.from, toID: pair.to, kind: kind)
        }
    }

    /// 若输入存在意外有向环，通过确定性 DFS 剔除回边（Back-Edge），确保后续最长路径与拓扑分配严格无环。
    private static func breakCyclesIfNeeded(
        edges: [TaskRelationEdge],
        orderedNodeIDs: [String],
        originalOrder: [String: Int],
        anchorID: String
    ) -> [TaskRelationEdge] {
        guard !edges.isEmpty else { return [] }
        var adj: [String: [TaskRelationEdge]] = [:]
        var inDegree: [String: Int] = Dictionary(uniqueKeysWithValues: orderedNodeIDs.map { ($0, 0) })
        for e in edges {
            adj[e.fromID, default: []].append(e)
            inDegree[e.toID, default: 0] += 1
        }
        for k in adj.keys {
            adj[k]?.sort { (originalOrder[$0.toID] ?? 0) < (originalOrder[$1.toID] ?? 0) }
        }

        // 起点优先级：入度为 0 的上游起点 -> 焦点节点 -> 其余节点按原序
        var startSeeds = orderedNodeIDs.filter { (inDegree[$0] ?? 0) == 0 }
        if !startSeeds.contains(anchorID) {
            startSeeds.append(anchorID)
        }
        for id in orderedNodeIDs where !startSeeds.contains(id) {
            startSeeds.append(id)
        }

        enum VisitState { case visiting, visited }
        var state: [String: VisitState] = [:]
        var backEdgeIDs: Set<String> = []

        func dfs(_ u: String) {
            state[u] = .visiting
            for edge in adj[u] ?? [] {
                switch state[edge.toID] {
                case .none:
                    dfs(edge.toID)
                case .some(.visiting):
                    backEdgeIDs.insert(edge.id)
                case .some(.visited):
                    break
                }
            }
            state[u] = .visited
        }

        for seed in startSeeds where state[seed] == nil {
            dfs(seed)
        }

        guard !backEdgeIDs.isEmpty else { return edges }
        return edges.filter { !backEdgeIDs.contains($0.id) }
    }

    // MARK: - 2. 拓扑排序与以焦点为锚点的左 → 中 → 右步长分配

    private static func topologicalSort(
        nodeIDs: [String],
        outgoing: [String: [TaskRelationEdge]],
        incoming: [String: [TaskRelationEdge]],
        originalOrder: [String: Int]
    ) -> [String] {
        var remInDegree: [String: Int] = [:]
        for id in nodeIDs {
            remInDegree[id] = incoming[id]?.count ?? 0
        }
        var ready = nodeIDs.filter { (remInDegree[$0] ?? 0) == 0 }
            .sorted { (originalOrder[$0] ?? 0) < (originalOrder[$1] ?? 0) }

        var result: [String] = []
        result.reserveCapacity(nodeIDs.count)

        while !ready.isEmpty {
            let curr = ready.removeFirst()
            result.append(curr)
            for edge in outgoing[curr] ?? [] {
                let next = edge.toID
                let newDeg = (remInDegree[next] ?? 1) - 1
                remInDegree[next] = newDeg
                if newDeg == 0 {
                    let nextOrd = originalOrder[next] ?? 0
                    let insertIdx = ready.firstIndex { (originalOrder[$0] ?? 0) > nextOrd } ?? ready.endIndex
                    ready.insert(next, at: insertIdx)
                }
            }
        }

        if result.count < nodeIDs.count {
            let existing = Set(result)
            for id in nodeIDs where !existing.contains(id) {
                result.append(id)
            }
        }
        return result
    }

    private static func assignRelativeSteps(
        topoOrder: [String],
        anchorID: String,
        outgoing: [String: [TaskRelationEdge]],
        incoming: [String: [TaskRelationEdge]]
    ) -> [String: Int] {
        // (a) 收集能有向到达 anchorID 的上游集合 U*（含 anchorID），计算 -longestPath(u -> anchor)
        var canReachAnchor: Set<String> = [anchorID]
        for u in topoOrder.reversed() {
            if u == anchorID { continue }
            if (outgoing[u] ?? []).contains(where: { canReachAnchor.contains($0.toID) }) {
                canReachAnchor.insert(u)
            }
        }

        var steps: [String: Int] = [anchorID: 0]
        for u in topoOrder.reversed() where u != anchorID && canReachAnchor.contains(u) {
            let childSteps = (outgoing[u] ?? []).compactMap { edge -> Int? in
                guard canReachAnchor.contains(edge.toID), let s = steps[edge.toID] else { return nil }
                return s - 1
            }
            if let minStep = childSteps.min() {
                steps[u] = minStep
            }
        }

        // (b) 收集从 anchorID 有向可达的下游集合 D*（含 anchorID），计算 +longestPath(anchor -> v)
        var reachableFromAnchor: Set<String> = [anchorID]
        for v in topoOrder where v != anchorID {
            if (incoming[v] ?? []).contains(where: { reachableFromAnchor.contains($0.fromID) }) {
                reachableFromAnchor.insert(v)
            }
        }
        for v in topoOrder where v != anchorID && reachableFromAnchor.contains(v) {
            let parentSteps = (incoming[v] ?? []).compactMap { edge -> Int? in
                guard reachableFromAnchor.contains(edge.fromID), let s = steps[edge.fromID] else { return nil }
                return s + 1
            }
            if let maxStep = parentSteps.max() {
                steps[v] = maxStep
            }
        }

        // (c) 迭代定位侧支节点（既非焦点祖先也非焦点后代）：
        //     - 正向拓扑序：可由已定位节点到达的下游侧支 step[v] = max(已定位父节点 step) + 1
        //     - 逆向拓扑序：仅指向已定位节点的上游侧支 step[u] = min(已定位子节点 step) - 1
        var progress = true
        while progress && steps.count < topoOrder.count {
            progress = false
            for v in topoOrder where steps[v] == nil {
                let positionedParents = (incoming[v] ?? []).compactMap { steps[$0.fromID] }
                if let maxParent = positionedParents.max() {
                    steps[v] = maxParent + 1
                    progress = true
                }
            }
            for u in topoOrder.reversed() where steps[u] == nil {
                let positionedChildren = (outgoing[u] ?? []).compactMap { steps[$0.toID] }
                if let minChild = positionedChildren.min() {
                    steps[u] = minChild - 1
                    progress = true
                }
            }
        }

        // 防御性兜底：若仍有完全孤立节点，按拓扑传播置于 0 列起
        for id in topoOrder where steps[id] == nil {
            let maxParent = (incoming[id] ?? []).compactMap { steps[$0.fromID] }.max()
            steps[id] = (maxParent.map { $0 + 1 }) ?? 0
        }

        // (d) 最终严格单调约束松弛：由于 V \ U* 绝无路径回到 U*，沿拓扑序推进非 U* 节点可 100% 保证
        //     每条有向边满足 step[from] < step[to] 且 anchorID 始终锁死在 step == 0！
        for v in topoOrder where !canReachAnchor.contains(v) {
            if let maxParent = (incoming[v] ?? []).compactMap({ steps[$0.fromID] }).max(),
               let curr = steps[v],
               curr <= maxParent {
                steps[v] = maxParent + 1
            }
        }

        return steps
    }

    // MARK: - 4. 列标题与主关系推导

    private static func columnTitle(for step: Int, nodeIDs: [String], anchorID: String) -> String {
        switch step {
        case 0:
            let onlyFocus = nodeIDs.count == 1 && nodeIDs.first == anchorID
            return onlyFocus ? "当前清单" : "当前清单 · 同级"
        case -1:
            return "直接上游"
        case let s where s <= -2:
            return "远端上游 (\(-s)跳)"
        case 1:
            return "直接下游"
        default:
            return "后续衍生 (\(step)跳)"
        }
    }

    private static func resolvePrimaryRelation(
        for node: TaskRelationNode,
        anchorID: String,
        nodeByID: [String: TaskRelationNode],
        incoming: [TaskRelationEdge],
        outgoing: [TaskRelationEdge]
    ) -> TaskRelationKind? {
        if node.isFocus || node.id == anchorID {
            return nil
        }

        let connected = incoming + outgoing

        if node.distanceFromFocus == 1 {
            let focusEdges = connected.filter { $0.fromID == anchorID || $0.toID == anchorID }
            if let best = focusEdges.max(by: { relationPriority($0.kind) < relationPriority($1.kind) }) {
                return best.kind
            }
            return node.relationToFocus ?? node.relationFromParent
        }

        // distanceFromFocus >= 2：优先选连接更靠近焦点的邻居（distanceFromFocus 更小者）的那条边
        let closerCandidates: [(dist: Int, priority: Int, kind: TaskRelationKind)] = connected.compactMap { edge in
            let otherID = edge.fromID == node.id ? edge.toID : edge.fromID
            guard let other = nodeByID[otherID], other.distanceFromFocus < node.distanceFromFocus else {
                return nil
            }
            return (other.distanceFromFocus, relationPriority(edge.kind), edge.kind)
        }
        if let bestCloser = closerCandidates.min(by: { lhs, rhs in
            if lhs.dist != rhs.dist { return lhs.dist < rhs.dist }
            return lhs.priority > rhs.priority
        }) {
            return bestCloser.kind
        }

        if let anyEdge = connected.max(by: { relationPriority($0.kind) < relationPriority($1.kind) }) {
            return anyEdge.kind
        }
        return node.relationFromParent ?? node.relationToFocus
    }

    // MARK: - 5. 列内 Barycenter 重心排序与零重叠垂直居中分配

    private static func orderNodesWithinColumns(
        sortedSteps: [Int],
        initialBuckets: [Int: [String]],
        anchorID: String,
        visibleEdges: [TaskRelationEdge],
        stepsByID: [String: Int],
        originalOrder: [String: Int]
    ) -> [Int: [String]] {
        var columns: [Int: [String]] = [:]

        // 先固定 step == 0 列：焦点置于核心位置，其余同级节点按原序围绕排列
        if let zeroNodes = initialBuckets[0] {
            var others = zeroNodes.filter { $0 != anchorID }
                .sorted { (originalOrder[$0] ?? 0) < (originalOrder[$1] ?? 0) }
            if zeroNodes.contains(anchorID) {
                let mid = others.count / 2
                others.insert(anchorID, at: mid)
                columns[0] = others
            } else {
                columns[0] = others
            }
        }

        // 建立可见无向邻接表
        var adj: [String: [String]] = [:]
        for e in visibleEdges {
            adj[e.fromID, default: []].append(e.toID)
            adj[e.toID, default: []].append(e.fromID)
        }

        // 计算某节点在当前各列中的归一化中心偏移（0 表示列中心，负在上、正在下）
        func normalizedSlot(of id: String, in currentCols: [Int: [String]]) -> Double? {
            guard let step = stepsByID[id],
                  let col = currentCols[step],
                  let idx = col.firstIndex(of: id) else { return nil }
            return Double(idx) - Double(col.count - 1) * 0.5
        }

        func sortColumn(
            _ step: Int,
            in currentCols: inout [Int: [String]],
            neighborFilter: (Int) -> Bool
        ) {
            guard let nodes = currentCols[step] ?? initialBuckets[step], nodes.count > 1 else {
                if currentCols[step] == nil, let single = initialBuckets[step] {
                    currentCols[step] = single
                }
                return
            }
            if step == 0 && nodes.contains(anchorID) {
                // 保持 anchorID 在中心，仅重排同列其他侧支节点
                let others = nodes.filter { $0 != anchorID }
                let sortedOthers = sortNodeList(
                    others,
                    adj: adj,
                    stepsByID: stepsByID,
                    currentCols: currentCols,
                    neighborFilter: neighborFilter,
                    originalOrder: originalOrder,
                    normalizedSlot: normalizedSlot
                )
                var merged = sortedOthers
                merged.insert(anchorID, at: merged.count / 2)
                currentCols[0] = merged
                return
            }
            currentCols[step] = sortNodeList(
                nodes,
                adj: adj,
                stepsByID: stepsByID,
                currentCols: currentCols,
                neighborFilter: neighborFilter,
                originalOrder: originalOrder,
                normalizedSlot: normalizedSlot
            )
        }

        // Pass 1：从 0 向左（-1, -2, ...）按右侧邻居重心排序；从 0 向右（+1, +2, ...）按左侧邻居重心排序
        let leftSteps = sortedSteps.filter { $0 < 0 }.sorted(by: >) // -1, -2, ...
        let rightSteps = sortedSteps.filter { $0 > 0 }.sorted(by: <) // +1, +2, ...

        for s in leftSteps {
            sortColumn(s, in: &columns) { $0 > s }
        }
        for s in rightSteps {
            sortColumn(s, in: &columns) { $0 < s }
        }
        for s in sortedSteps where columns[s] == nil {
            columns[s] = (initialBuckets[s] ?? []).sorted { (originalOrder[$0] ?? 0) < (originalOrder[$1] ?? 0) }
        }

        // Pass 2：双向邻接微调（使像 A-1 -> A-5 这种仅连左侧父节点的侧支自动贴近同父兄弟）
        for s in leftSteps.reversed() {
            sortColumn(s, in: &columns) { $0 != s }
        }
        for s in rightSteps.reversed() {
            sortColumn(s, in: &columns) { $0 != s }
        }
        for s in leftSteps {
            sortColumn(s, in: &columns) { $0 != s }
        }
        for s in rightSteps {
            sortColumn(s, in: &columns) { $0 != s }
        }

        return columns
    }

    private static func sortNodeList(
        _ nodes: [String],
        adj: [String: [String]],
        stepsByID: [String: Int],
        currentCols: [Int: [String]],
        neighborFilter: (Int) -> Bool,
        originalOrder: [String: Int],
        normalizedSlot: (String, [Int: [String]]) -> Double?
    ) -> [String] {
        var bucketByID: [String: Int] = [:]
        for id in nodes {
            let slots = (adj[id] ?? []).compactMap { nbr -> Double? in
                guard let nStep = stepsByID[nbr], neighborFilter(nStep) else { return nil }
                return normalizedSlot(nbr, currentCols)
            }
            let mean = slots.isEmpty ? 0.0 : (slots.reduce(0, +) / Double(slots.count))
            bucketByID[id] = Int((mean * 1_000_000.0).rounded())
        }

        return nodes.sorted { a, b in
            let ba = bucketByID[a] ?? 0
            let bb = bucketByID[b] ?? 0
            if ba != bb { return ba < bb }
            return (originalOrder[a] ?? 0) < (originalOrder[b] ?? 0)
        }
    }

    private static func assignVerticalCenters(
        sortedSteps: [Int],
        orderedColumns: [Int: [String]],
        anchorID: String,
        visibleEdges: [TaskRelationEdge],
        stepsByID: [String: Int],
        heightByID: [String: CGFloat],
        metrics: Metrics
    ) -> [String: CGFloat] {
        let topOriginY = metrics.headerHeight + metrics.canvasPaddingY
        func nodeHeight(_ id: String) -> CGFloat {
            heightByID[id] ?? metrics.cardHeight
        }
        func columnStackHeight(_ col: [String]) -> CGFloat {
            guard !col.isEmpty else { return 0 }
            return col.reduce(0) { $0 + nodeHeight($1) }
                + CGFloat(max(0, col.count - 1)) * metrics.rowGap
        }

        let maxColCardsHeight = max(
            metrics.cardHeight,
            sortedSteps.map { columnStackHeight(orderedColumns[$0] ?? []) }.max() ?? metrics.cardHeight
        )
        let spineY = topOriginY + maxColCardsHeight * 0.5

        // 1. 初始排布：每一列按各自卡片实际高度围绕统一水平中轴线 spineY 垂直居中
        var midY: [String: CGFloat] = [:]
        for step in sortedSteps {
            let col = orderedColumns[step] ?? []
            guard !col.isEmpty else { continue }
            let colHeight = columnStackHeight(col)
            var cursorTop = spineY - colHeight * 0.5
            for id in col {
                let h = nodeHeight(id)
                midY[id] = cursorTop + h * 0.5
                cursorTop += h + metrics.rowGap
            }
        }

        // 建立可见无向邻接
        var adj: [String: [String]] = [:]
        for e in visibleEdges {
            adj[e.fromID, default: []].append(e.toID)
            adj[e.toID, default: []].append(e.fromID)
        }

        // 2. 从中心列向两侧做父子重心微调 + 异高 1D 保序最小间距防重叠投影
        let leftSteps = sortedSteps.filter { $0 < 0 }.sorted(by: >)   // -1, -2, ...
        let rightSteps = sortedSteps.filter { $0 > 0 }.sorted(by: <)  // +1, +2, ...

        for step in leftSteps {
            guard let col = orderedColumns[step], !col.isEmpty else { continue }
            let desired: [CGFloat] = col.map { id in
                let rightNbrY = (adj[id] ?? []).compactMap { nbr -> CGFloat? in
                    guard let nStep = stepsByID[nbr], nStep > step else { return nil }
                    return midY[nbr]
                }
                guard !rightNbrY.isEmpty else { return midY[id] ?? spineY }
                return rightNbrY.reduce(0, +) / CGFloat(rightNbrY.count)
            }
            let heights = col.map { nodeHeight($0) }
            let projected = projectVariableMinimumSpacing(
                desired: desired,
                heights: heights,
                rowGap: metrics.rowGap
            )
            for (id, y) in zip(col, projected) {
                midY[id] = y
            }
        }

        for step in rightSteps {
            guard let col = orderedColumns[step], !col.isEmpty else { continue }
            let desired: [CGFloat] = col.map { id in
                let leftNbrY = (adj[id] ?? []).compactMap { nbr -> CGFloat? in
                    guard let nStep = stepsByID[nbr], nStep < step else { return nil }
                    return midY[nbr]
                }
                guard !leftNbrY.isEmpty else { return midY[id] ?? spineY }
                return leftNbrY.reduce(0, +) / CGFloat(leftNbrY.count)
            }
            let heights = col.map { nodeHeight($0) }
            let projected = projectVariableMinimumSpacing(
                desired: desired,
                heights: heights,
                rowGap: metrics.rowGap
            )
            for (id, y) in zip(col, projected) {
                midY[id] = y
            }
        }

        // 3. 全局平移使最顶卡片 minY 恰好落在 headerHeight + canvasPaddingY
        if let minTop = midY.map({ $0.value - nodeHeight($0.key) * 0.5 }).min() {
            let shiftY = topOriginY - minTop
            if abs(shiftY) > 1e-6 {
                for key in midY.keys {
                    midY[key, default: spineY] += shiftY
                }
            }
        }

        return midY
    }

    /// 异高 1D 保序最小间距投影（Pool Adjacent Violators）：
    /// 对不同高度（如 114pt 工作清单卡与 64pt 经验卡片混排）严格保持行序且保证相邻边缘净距 `>= rowGap`。
    private static func projectVariableMinimumSpacing(
        desired: [CGFloat],
        heights: [CGFloat],
        rowGap: CGFloat
    ) -> [CGFloat] {
        let n = desired.count
        guard n > 1, heights.count == n else { return desired }

        var prefix = Array(repeating: CGFloat.zero, count: n)
        for i in 1..<n {
            prefix[i] = prefix[i - 1] + (heights[i - 1] + heights[i]) * 0.5 + rowGap
        }

        struct IsoBlock {
            var startIndex: Int
            var endIndex: Int
            var sum: CGFloat
            var count: Int { endIndex - startIndex + 1 }
            var mean: CGFloat { sum / CGFloat(count) }
        }

        var stack: [IsoBlock] = []
        stack.reserveCapacity(n)
        for i in 0..<n {
            let z = desired[i] - prefix[i]
            var curr = IsoBlock(startIndex: i, endIndex: i, sum: z)
            while let prev = stack.last, prev.mean > curr.mean {
                stack.removeLast()
                curr = IsoBlock(
                    startIndex: prev.startIndex,
                    endIndex: curr.endIndex,
                    sum: prev.sum + curr.sum
                )
            }
            stack.append(curr)
        }

        var result = Array(repeating: CGFloat.zero, count: n)
        for block in stack {
            let m = block.mean
            for idx in block.startIndex...block.endIndex {
                result[idx] = m + prefix[idx]
            }
        }
        return result
    }
}
