import SwiftUI
import SuperagentCore

// MARK: - 状态色与关联语义图标映射

extension TaskRelationStatusTone {
    var tint: Color {
        switch self {
        case .positive: return Theme.Status.positive
        case .attention: return Theme.Status.attention
        case .error: return Theme.Status.error
        case .active: return Theme.Status.active
        case .neutral: return Theme.Status.neutral
        }
    }
}

extension TaskRelationKind {
    var symbol: String {
        switch self {
        case .dependency: return "arrow.turn.down.right"
        case .handback: return "arrow.uturn.backward"
        case .experience: return "sparkles"
        }
    }
}

// MARK: - 兼容 macOS 14 的画布宽度测量

private struct MindmapCanvasWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

// MARK: - 任务详情页「关联清单脉络」横向思维导图卡片

struct TaskRelationTreeCard: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let view: TaskView
    let editable: Bool

    @State private var collapsedTokens: Set<String> = []
    @State private var showLinkPicker = false
    @State private var hoveredNodeID: String? = nil
    @State private var availableCanvasWidth: CGFloat = 824

    var body: some View {
        let sa = appModel.superagent
        // 显式追踪 tasks 与 knowledge 快照，确保任意直接/间接关联节点状态变化时思维导图实时刷新
        let _ = (sa.tasks.count, sa.knowledge.count)
        if let tree = sa.taskRelationTree(view.id), tree.totalRelatedCount > 0 {
            let graph = TaskRelationGraphLayout.layout(
                tree,
                collapsed: collapsedTokens,
                availableWidth: availableCanvasWidth
            )

            VStack(alignment: .leading, spacing: 0) {
                headerBar(tree: tree, graph: graph)
                    .padding(.horizontal, 18)
                    .padding(.top, 15)
                    .padding(.bottom, 12)

                Hairline()

                mindmapCanvas(graph: graph)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
            .saCard(padding: 0)
            .onChange(of: view.id) { _, _ in
                collapsedTokens.removeAll()
                hoveredNodeID = nil
            }
        }
    }

    // MARK: - 顶部工具栏

    private func headerBar(tree: TaskRelationTree, graph: TaskRelationGraphLayout.Graph) -> some View {
        let sa = appModel.superagent
        let stats = TaskRelationGraphLayout.statsText(tree)
        let canToggleIndirect = !graph.indirectFoldTokens.isEmpty || !collapsedTokens.isEmpty

        return HStack(alignment: .center, spacing: 10) {
            SectionLabel(title: "关联清单脉络")

            Text(stats)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 5))
                .accessibilityLabel(stats)

            Spacer(minLength: 8)

            ViewThatFits(in: .horizontal) {
                edgeLegend
                    .padding(.trailing, 4)
                EmptyView()
            }

            if canToggleIndirect {
                Button(collapsedTokens.isEmpty ? "只看直接关联" : "展开全部脉络") {
                    Theme.Motion.run(Theme.Motion.layout, reduceMotion: reduceMotion) {
                        if collapsedTokens.isEmpty {
                            collapsedTokens = graph.indirectFoldTokens
                        } else {
                            collapsedTokens.removeAll()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(collapsedTokens.isEmpty ? "收起 2 跳及以上的远端关联分支，聚焦直接上下游" : "展开全部直接与间接关联脉络")
            }

            if editable {
                Button("管理关联…") {
                    showLinkPicker = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("添加或移除关联的历史已完成任务总结与经验卡片")
                .popover(isPresented: $showLinkPicker, arrowEdge: .bottom) {
                    KnowledgeLinkPicker(
                        currentTaskID: view.id,
                        preferredScope: view.task.scope,
                        selectedIDs: Binding(
                            get: { Set(view.relatedKnowledge.map(\.knowledgeID)) },
                            set: { sa.setTaskKnowledgeLinks(view.id, knowledgeIDs: Array($0).sorted()) }
                        ),
                        onOpenTask: { tid in
                            showLinkPicker = false
                            appModel.openWorklist(task: tid)
                        }
                    )
                    .environment(appModel)
                }
            }
        }
    }

    private var edgeLegend: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 5) {
                LegendSampleLine(dashed: false)
                Text("任务清单（依赖 / 退回）")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: 5) {
                LegendSampleLine(dashed: true)
                Text("✦ 经验参考 / 衍生")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    // MARK: - 横向思维导图画布

    private func mindmapCanvas(graph: TaskRelationGraphLayout.Graph) -> some View {
        let needsHorizontalScroll = graph.canvasSize.width > availableCanvasWidth + 4
        let connectedIDs = Self.connectedNodeIDs(for: hoveredNodeID, in: graph.edges)

        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: needsHorizontalScroll) {
                ZStack(alignment: .center) {
                    dotGridBackground

                    ZStack(alignment: .topLeading) {
                        focusScrollAnchor(graph: graph)

                        columnStageLayer(graph: graph)

                        edgesCanvasLayer(graph: graph, connectedIDs: connectedIDs)

                        nodesLayer(graph: graph, connectedIDs: connectedIDs)

                        foldHandlesLayer(graph: graph)
                    }
                    .frame(width: graph.canvasSize.width, height: graph.canvasSize.height, alignment: .topLeading)
                }
                .frame(minWidth: availableCanvasWidth, minHeight: graph.canvasSize.height, alignment: .center)
            }
            .onAppear {
                scrollToFocusIfNeeded(proxy: proxy, graph: graph, animated: false)
            }
            .onChange(of: view.id) { _, _ in
                DispatchQueue.main.async {
                    scrollToFocusIfNeeded(proxy: proxy, graph: graph, animated: false)
                }
            }
            .onChange(of: graph.canvasSize.width) { oldWidth, newWidth in
                if oldWidth <= availableCanvasWidth + 4, newWidth > availableCanvasWidth + 4 {
                    DispatchQueue.main.async {
                        scrollToFocusIfNeeded(proxy: proxy, graph: graph, animated: true)
                    }
                }
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: MindmapCanvasWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(MindmapCanvasWidthKey.self) { newWidth in
            guard newWidth >= 240, abs(newWidth - availableCanvasWidth) > 1 else { return }
            availableCanvasWidth = newWidth
        }
        .background(Theme.chrome.opacity(0.45), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private var dotGridBackground: some View {
        Canvas { context, size in
            let spacing: CGFloat = 20
            let radius: CGFloat = 0.8
            let diameter = radius * 2
            var dots = Path()
            var y: CGFloat = 12
            while y < size.height {
                var x: CGFloat = 12
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: diameter, height: diameter))
                    x += spacing
                }
                y += spacing
            }
            context.fill(dots, with: .color(Theme.borderStrong.opacity(0.28)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 精确对齐 `graph.focusFrame` 水平区间的不可见滚动锚点，保证超宽拓扑打开时自动居中「当前清单」。
    private func focusScrollAnchor(graph: TaskRelationGraphLayout.Graph) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: max(0, graph.focusFrame.minX), height: 1)
            Color.clear
                .frame(width: max(1, graph.focusFrame.width), height: 1)
                .id(graph.focusNodeID)
            Spacer(minLength: 0)
        }
        .frame(width: graph.canvasSize.width, height: 1, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func scrollToFocusIfNeeded(
        proxy: ScrollViewProxy,
        graph: TaskRelationGraphLayout.Graph,
        animated: Bool
    ) {
        guard graph.canvasSize.width > availableCanvasWidth + 4 else { return }
        if animated {
            Theme.Motion.run(Theme.Motion.layout, reduceMotion: reduceMotion) {
                proxy.scrollTo(graph.focusNodeID, anchor: .center)
            }
        } else {
            proxy.scrollTo(graph.focusNodeID, anchor: .center)
        }
    }

    // MARK: - 列阶段顶栏与焦点垂直底带

    private func columnStageLayer(graph: TaskRelationGraphLayout.Graph) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(graph.columns) { col in
                if col.relativeStep == 0 {
                    let bandWidth = min(graph.canvasSize.width - 12, col.width + 16)
                    let bandHeight = max(24, graph.canvasSize.height - 12)
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(Theme.surface2.opacity(0.38))
                        .frame(width: bandWidth, height: bandHeight)
                        .position(x: col.centerX, y: graph.canvasSize.height * 0.5)
                }

                Group {
                    if col.relativeStep == 0 {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Theme.brand)
                                .frame(width: 5, height: 5)
                            Text(col.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    } else {
                        Text(col.title)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .lineLimit(1)
                .fixedSize()
                .position(x: col.centerX, y: 14)
            }
        }
        .frame(width: graph.canvasSize.width, height: graph.canvasSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - 三次贝塞尔曲线连线层

    private func edgesCanvasLayer(
        graph: TaskRelationGraphLayout.Graph,
        connectedIDs: Set<String>
    ) -> some View {
        let hoveredID = hoveredNodeID
        let hasLeftHandleIDs = Set(
            graph.nodes.compactMap { $0.upstreamFoldToken != nil ? $0.id : nil }
        )
        let baseEdges = graph.edges.sorted { lhs, rhs in
            if lhs.touchesFocus != rhs.touchesFocus { return !lhs.touchesFocus }
            return false
        }
        let highlightedEdges = hoveredID.map { hid in
            graph.edges.filter { $0.fromID == hid || $0.toID == hid }
        } ?? []

        return ZStack {
            // 底层常规边：悬停任意节点时整体随节点卡片同步平滑降噪（避免 Canvas 单帧硬跳）
            Canvas { context, _ in
                for edge in baseEdges {
                    let lineWidth: CGFloat = edge.touchesFocus ? 1.65 : 1.35
                    let strokeColor: Color = edge.touchesFocus ? Theme.borderStrong : Theme.borderStrong.opacity(0.75)
                    Self.drawEdge(
                        edge,
                        in: &context,
                        hasLeftHandleIDs: hasLeftHandleIDs,
                        lineWidth: lineWidth,
                        strokeColor: strokeColor
                    )
                }
            }
            .opacity(hoveredID == nil ? 1.0 : 0.34)
            .animation(Theme.Motion.value(Theme.Motion.snap, reduceMotion: reduceMotion), value: hoveredID != nil)

            // 顶层高亮边：与悬停节点相连的链路平滑浮现并始终压在顶层
            Canvas { context, _ in
                for edge in highlightedEdges {
                    Self.drawEdge(
                        edge,
                        in: &context,
                        hasLeftHandleIDs: hasLeftHandleIDs,
                        lineWidth: 2.0,
                        strokeColor: Theme.brand
                    )
                }
            }
            .opacity(hoveredID == nil ? 0.0 : 1.0)
            .animation(Theme.Motion.value(Theme.Motion.snap, reduceMotion: reduceMotion), value: hoveredID)
        }
        .frame(width: graph.canvasSize.width, height: graph.canvasSize.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func drawEdge(
        _ edge: TaskRelationGraphLayout.PositionedEdge,
        in context: inout GraphicsContext,
        hasLeftHandleIDs: Set<String>,
        lineWidth: CGFloat,
        strokeColor: Color
    ) {
        let strokeStyle: StrokeStyle
        if edge.kind == .experience {
            strokeStyle = StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [5, 3.5])
        } else {
            strokeStyle = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        }

        // 若目标节点左端口挂有折叠按钮，终点提前停靠在折叠按钮左缘，避免微箭头被遮挡
        let arrowTip = hasLeftHandleIDs.contains(edge.toID)
            ? CGPoint(x: max(edge.start.x + 8, edge.end.x - 9.5), y: edge.end.y)
            : edge.end

        var curve = Path()
        curve.move(to: edge.start)
        curve.addCurve(to: arrowTip, control1: edge.control1, control2: edge.control2)
        context.stroke(curve, with: .color(strokeColor), style: strokeStyle)

        // 起点：4.5pt 实心发送端口圆点
        let startDotRect = CGRect(
            x: edge.start.x - 2.25,
            y: edge.start.y - 2.25,
            width: 4.5,
            height: 4.5
        )
        context.fill(Path(ellipseIn: startDotRect), with: .color(strokeColor))

        // 终点：指向右侧（沿末端切线方向）的 5pt 翼长微箭头
        let dx = arrowTip.x - edge.control2.x
        let dy = arrowTip.y - edge.control2.y
        let angle = hypot(dx, dy) > 0.5 ? atan2(dy, dx) : 0
        let wingLength: CGFloat = 5.0
        let wingSpread: CGFloat = 0.50
        let p1 = CGPoint(
            x: arrowTip.x - wingLength * cos(angle - wingSpread),
            y: arrowTip.y - wingLength * sin(angle - wingSpread)
        )
        let p2 = CGPoint(
            x: arrowTip.x - wingLength * cos(angle + wingSpread),
            y: arrowTip.y - wingLength * sin(angle + wingSpread)
        )
        var arrow = Path()
        arrow.move(to: p1)
        arrow.addLine(to: arrowTip)
        arrow.addLine(to: p2)
        context.stroke(
            arrow,
            with: .color(strokeColor),
            style: StrokeStyle(lineWidth: max(1.4, lineWidth), lineCap: .round, lineJoin: .round)
        )
    }

    // MARK: - 节点卡片与左右折叠端口层

    private func nodesLayer(
        graph: TaskRelationGraphLayout.Graph,
        connectedIDs: Set<String>
    ) -> some View {
        let sa = appModel.superagent
        // 注意：不在 ForEach 内重复使用裸 `positioned.id` 作为显式 `.id`，避免与 `focusScrollAnchor` 的 `focusNodeID` 冲突
        return ZStack(alignment: .topLeading) {
            ForEach(graph.nodes, id: \.nodeKeyForView) { positioned in
                let isSelfHovered = hoveredNodeID == positioned.id
                let isAdjacentHovered = hoveredNodeID != nil && connectedIDs.contains(positioned.id)
                let isDimmed = hoveredNodeID != nil && !connectedIDs.contains(positioned.id)

                Group {
                    if positioned.isExperienceStyle {
                        ExperienceRelationCard(
                            positioned: positioned,
                            editable: editable,
                            isSelfHovered: isSelfHovered,
                            isAdjacentHovered: isAdjacentHovered,
                            isDimmed: isDimmed,
                            onHoverChanged: { hovering in
                                Theme.Motion.run(Theme.Motion.snap, reduceMotion: reduceMotion) {
                                    if hovering {
                                        hoveredNodeID = positioned.id
                                    } else if hoveredNodeID == positioned.id {
                                        hoveredNodeID = nil
                                    }
                                }
                            },
                            onNavigate: { navigate(to: positioned.node) },
                            onUnlink: { kid in
                                sa.removeTaskKnowledgeLink(view.id, knowledgeID: kid)
                            }
                        )
                    } else {
                        TaskRelationNodeCard(
                            positioned: positioned,
                            editable: editable,
                            isSelfHovered: isSelfHovered,
                            isAdjacentHovered: isAdjacentHovered,
                            isDimmed: isDimmed,
                            onHoverChanged: { hovering in
                                Theme.Motion.run(Theme.Motion.snap, reduceMotion: reduceMotion) {
                                    if hovering {
                                        hoveredNodeID = positioned.id
                                    } else if hoveredNodeID == positioned.id {
                                        hoveredNodeID = nil
                                    }
                                }
                            },
                            onNavigate: { navigate(to: positioned.node) },
                            onUnlink: { kid in
                                sa.removeTaskKnowledgeLink(view.id, knowledgeID: kid)
                            }
                        )
                    }
                }
                .position(x: positioned.frame.midX, y: positioned.frame.midY)
            }
        }
        .frame(width: graph.canvasSize.width, height: graph.canvasSize.height, alignment: .topLeading)
    }

    private func foldHandlesLayer(graph: TaskRelationGraphLayout.Graph) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(graph.nodes, id: \.nodeKeyForFoldLayer) { positioned in
                if let upToken = positioned.upstreamFoldToken {
                    MindmapFoldHandle(
                        direction: .upstream,
                        isCollapsed: positioned.isUpstreamCollapsed,
                        hiddenCount: positioned.hiddenUpstreamCount,
                        nodeLabel: positioned.node.label,
                        onHoverChanged: { hovering in
                            Theme.Motion.run(Theme.Motion.snap, reduceMotion: reduceMotion) {
                                if hovering {
                                    hoveredNodeID = positioned.id
                                } else if hoveredNodeID == positioned.id {
                                    hoveredNodeID = nil
                                }
                            }
                        },
                        action: { toggleFoldToken(upToken) }
                    )
                    .position(x: positioned.leftPort.x, y: positioned.leftPort.y)
                }

                if let downToken = positioned.downstreamFoldToken {
                    MindmapFoldHandle(
                        direction: .downstream,
                        isCollapsed: positioned.isDownstreamCollapsed,
                        hiddenCount: positioned.hiddenDownstreamCount,
                        nodeLabel: positioned.node.label,
                        onHoverChanged: { hovering in
                            Theme.Motion.run(Theme.Motion.snap, reduceMotion: reduceMotion) {
                                if hovering {
                                    hoveredNodeID = positioned.id
                                } else if hoveredNodeID == positioned.id {
                                    hoveredNodeID = nil
                                }
                            }
                        },
                        action: { toggleFoldToken(downToken) }
                    )
                    .position(x: positioned.rightPort.x, y: positioned.rightPort.y)
                }
            }
        }
        .frame(width: graph.canvasSize.width, height: graph.canvasSize.height, alignment: .topLeading)
    }

    // MARK: - 交互辅助

    private func toggleFoldToken(_ token: String) {
        Theme.Motion.run(Theme.Motion.layout, reduceMotion: reduceMotion) {
            if collapsedTokens.contains(token) {
                collapsedTokens.remove(token)
            } else {
                collapsedTokens.insert(token)
            }
        }
    }

    private func navigate(to node: TaskRelationNode) {
        guard !node.isFocus else { return }
        if let tid = node.taskID {
            appModel.openWorklist(task: tid)
        } else if let kid = node.knowledgeID {
            appModel.openKnowledgeBase(entryID: kid)
        }
    }

    private static func connectedNodeIDs(
        for hoveredID: String?,
        in edges: [TaskRelationGraphLayout.PositionedEdge]
    ) -> Set<String> {
        guard let hoveredID else { return [] }
        var ids: Set<String> = [hoveredID]
        for edge in edges {
            if edge.fromID == hoveredID { ids.insert(edge.toID) }
            if edge.toID == hoveredID { ids.insert(edge.fromID) }
        }
        return ids
    }
}

private extension TaskRelationGraphLayout.PositionedNode {
    var nodeKeyForView: String { "card:\(id)" }
    var nodeKeyForFoldLayer: String { "fold:\(id)" }
}

// MARK: - 极简「经验参考 / 经验衍生」轻量便签卡（与工作清单实体卡片明显区分）

private struct ExperienceRelationCard: View {
    let positioned: TaskRelationGraphLayout.PositionedNode
    let editable: Bool
    let isSelfHovered: Bool
    let isAdjacentHovered: Bool
    let isDimmed: Bool
    let onHoverChanged: (Bool) -> Void
    let onNavigate: () -> Void
    let onUnlink: (Int64) -> Void

    private var node: TaskRelationNode { positioned.node }

    private var badgeText: String {
        let base: String
        if positioned.relativeStep > 0 {
            base = "经验衍生"
        } else if node.isStandaloneKnowledge {
            base = "经验卡"
        } else {
            base = "经验参考"
        }
        return node.isIndirect ? "\(base)·间接" : base
    }

    var body: some View {
        let summaryText = node.summary.isEmpty ? "点击查看经验摘要" : node.summary

        VStack(alignment: .leading, spacing: 5) {
            // 第 1 行：✦ 经验轻标签 + 编号 + 单行标题 + 悬停移除按钮
            HStack(alignment: .center, spacing: 5) {
                HStack(spacing: 2.5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 8.5, weight: .semibold))
                    Text(badgeText)
                        .font(.system(size: 9.5, weight: .medium))
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Theme.accent.opacity(0.38), in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()

                Text(node.label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()

                Text(node.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if editable, let unlinkKBID = node.canUnlinkFromFocus {
                    Button {
                        onUnlink(unlinkKBID)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 16, height: 16)
                            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(isSelfHovered ? 1 : 0)
                    .allowsHitTesting(isSelfHovered)
                    .help("移除当前清单与 \(node.label) 的经验关联")
                    .accessibilityLabel("移除 \(node.label) 经验关联")
                }
            }

            // 第 2 行：一句话核心经验（极简 1 行，无进度条与状态框干扰）
            Text(summaryText)
                .font(.system(size: 11))
                .foregroundStyle(node.summary.isEmpty ? Theme.textTertiary.opacity(0.7) : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .frame(width: positioned.frame.width, height: positioned.frame.height, alignment: .center)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.canvas)
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.accent.opacity(isSelfHovered ? 0.28 : 0.16))
            }
        }
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(
                topLeadingRadius: Theme.Radius.sm,
                bottomLeadingRadius: Theme.Radius.sm,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
            .fill(Theme.accent)
            .frame(width: 3.5)
            .allowsHitTesting(false)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .strokeBorder(
                    isSelfHovered || isAdjacentHovered ? Theme.brand.opacity(0.65) : Theme.borderStrong.opacity(0.85),
                    style: StrokeStyle(
                        lineWidth: isSelfHovered || isAdjacentHovered ? 1.25 : 1.0,
                        lineCap: .round,
                        dash: [4, 3]
                    )
                )
        )
        .opacity(isDimmed ? 0.52 : 1.0)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .onHover(perform: onHoverChanged)
        .onTapGesture(perform: onNavigate)
        .help(tooltipText)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(badgeText)，\(node.label) \(node.title)，\(node.summary)")
    }

    private var tooltipText: String {
        let header = "[\(badgeText)] \(node.label) \(node.title)"
        let actionHint = node.isStandaloneKnowledge ? "点击在知识库中查看 \(node.label)" : "点击查看历史任务 \(node.label)"
        if node.summary.isEmpty {
            return "\(header)\n\n\(actionHint)"
        }
        return "\(header)\n\(node.summary)\n\n\(actionHint)"
    }
}

// MARK: - 四层定宽任务工作清单卡片

private struct TaskRelationNodeCard: View {
    let positioned: TaskRelationGraphLayout.PositionedNode
    let editable: Bool
    let isSelfHovered: Bool
    let isAdjacentHovered: Bool
    let isDimmed: Bool
    let onHoverChanged: (Bool) -> Void
    let onNavigate: () -> Void
    let onUnlink: (Int64) -> Void

    private var node: TaskRelationNode { positioned.node }

    private var effectiveRelation: TaskRelationKind? {
        positioned.primaryRelation ?? node.relationToFocus ?? node.relationFromParent
    }

    var body: some View {
        let summaryText = node.summary.isEmpty ? "暂无摘要" : node.summary

        VStack(alignment: .leading, spacing: 4) {
            // 第 1 层：顶部元信息栏（编号 + 当前/间接标识 + 状态标签 + 悬停解除关联）
            HStack(alignment: .center, spacing: 5) {
                Text(node.label)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(node.isFocus ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1.5)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()

                if node.isFocus {
                    Text("当前")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.onBrand)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1.5)
                        .background(Theme.brand, in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize()
                } else if node.isIndirect {
                    Text("间接")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1.5)
                        .background(Theme.accent.opacity(0.32), in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize()
                        .help("距离当前清单 \(node.distanceFromFocus) 跳的间接关联节点")
                }

                Spacer(minLength: 4)

                StateTag(text: node.statusText, tint: node.statusTone.tint)
                    .fixedSize()

                if editable, let unlinkKBID = node.canUnlinkFromFocus {
                    Button {
                        onUnlink(unlinkKBID)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 18, height: 18)
                            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(isSelfHovered ? 1 : 0)
                    .allowsHitTesting(isSelfHovered)
                    .help("移除当前清单与 \(node.label) 的经验关联")
                    .accessibilityLabel("移除 \(node.label) 经验关联")
                }
            }

            // 第 2 层：清单标题（独占整行宽度）
            Text(node.title)
                .font(.system(size: 12.5, weight: node.isFocus ? .semibold : .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(node.title)

            // 第 3 层：两行高信噪比简介
            Text(summaryText)
                .font(.system(size: 11))
                .lineSpacing(1.5)
                .lineLimit(2)
                .truncationMode(.tail)
                .foregroundStyle(node.summary.isEmpty ? Theme.textTertiary.opacity(0.65) : Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
                .help(node.summary.isEmpty ? "" : node.summary)

            Spacer(minLength: 0)

            // 第 4 层：底部关系语义 + 微型进度条栏
            HStack(alignment: .center, spacing: 6) {
                if node.isFocus {
                    Text("当前查看")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                } else if let rel = effectiveRelation {
                    HStack(spacing: 3.5) {
                        Image(systemName: rel.symbol)
                            .font(.system(size: 9, weight: .semibold))
                        Text(rel.label)
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.textTertiary)
                } else if node.isStandaloneKnowledge {
                    HStack(spacing: 3.5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .semibold))
                        Text("经验卡片")
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: 4)

                if !node.isStandaloneKnowledge, node.totalCount > 0 {
                    HStack(spacing: 5) {
                        MiniProgressCapsule(done: node.doneCount, total: node.totalCount)
                        Text("\(node.doneCount)/\(node.totalCount)")
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .fixedSize()
                    .help("清单进度：已完成 \(node.doneCount) 项，共 \(node.totalCount) 项")
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(width: positioned.frame.width, height: positioned.frame.height, alignment: .topLeading)
        .background(cardSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(alignment: .bottom) {
            if node.isFocus {
                // 无阴影纸面层次：焦点卡底部极轻柔炭黑内衬细边，强化中心锚点质感
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: Theme.Radius.md,
                    bottomTrailingRadius: Theme.Radius.md,
                    topTrailingRadius: 0
                )
                .fill(Theme.brand.opacity(0.08))
                .frame(height: 3)
                .allowsHitTesting(false)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(borderColor, lineWidth: borderLineWidth)
        )
        .opacity(isDimmed ? 0.58 : 1.0)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .onHover(perform: onHoverChanged)
        .onTapGesture {
            if !node.isFocus { onNavigate() }
        }
        .help(cardTooltip)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    private var cardSurface: Color {
        if node.isFocus {
            return Theme.surface
        }
        if isSelfHovered {
            return Theme.surface
        }
        if node.isIndirect {
            return Theme.surface.opacity(0.88)
        }
        return Theme.surface
    }

    private var borderColor: Color {
        if node.isFocus {
            return Theme.brand
        }
        if isSelfHovered || isAdjacentHovered {
            return Theme.borderStrong
        }
        return Theme.border
    }

    private var borderLineWidth: CGFloat {
        if node.isFocus { return 1.6 }
        if isSelfHovered || isAdjacentHovered { return 1.2 }
        return 1.0
    }

    private var cardTooltip: String {
        let header = "\(node.label) \(node.title)"
        if node.isFocus {
            return node.summary.isEmpty ? "当前正在查看的清单：\(header)" : "\(header)\n\(node.summary)"
        }
        let actionHint = node.isStandaloneKnowledge ? "点击在知识库中查看 \(node.label)" : "点击跳转到清单 \(node.label)"
        if node.summary.isEmpty {
            return "\(header)\n\n\(actionHint)"
        }
        return "\(header)\n\(node.summary)\n\n\(actionHint)"
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if node.isFocus {
            parts.append("当前清单")
        } else if node.isIndirect {
            parts.append("间接关联")
        }
        if let rel = effectiveRelation {
            parts.append(rel.label)
        }
        parts.append("\(node.label) \(node.title)")
        parts.append(node.statusText)
        if !node.isStandaloneKnowledge, node.totalCount > 0 {
            parts.append("进度 \(node.doneCount)/\(node.totalCount)")
        }
        if !node.summary.isEmpty {
            parts.append(node.summary)
        }
        return parts.joined(separator: "，")
    }
}

// MARK: - 微型胶囊进度条与图例微件

private struct MiniProgressCapsule: View {
    let done: Int
    let total: Int

    private let trackWidth: CGFloat = 28
    private let trackHeight: CGFloat = 4

    var body: some View {
        let ratio = total > 0 ? min(1, max(0, CGFloat(done) / CGFloat(total))) : 0
        let fillTint = (total > 0 && done >= total) ? Theme.Status.positive : Theme.brand

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.surface2)
            if ratio > 0 {
                RoundedRectangle(cornerRadius: 2)
                    .fill(fillTint)
                    .frame(width: max(3, trackWidth * ratio))
            }
        }
        .frame(width: trackWidth, height: trackHeight)
        .accessibilityHidden(true)
    }
}

private struct LegendSampleLine: View {
    let dashed: Bool

    var body: some View {
        Canvas { context, size in
            let midY = size.height * 0.5
            var line = Path()
            line.move(to: CGPoint(x: 1, y: midY))
            line.addLine(to: CGPoint(x: size.width - 1, y: midY))
            let style = dashed
                ? StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3.5, 2.5])
                : StrokeStyle(lineWidth: 1.5, lineCap: .round)
            context.stroke(line, with: .color(Theme.borderStrong), style: style)
        }
        .frame(width: 18, height: 8)
    }
}

// MARK: - 左右端口折叠气泡按钮（Mindmap Fold Handles）

private struct MindmapFoldHandle: View {
    enum Direction {
        case upstream
        case downstream
    }

    let direction: Direction
    let isCollapsed: Bool
    let hiddenCount: Int
    let nodeLabel: String
    let onHoverChanged: (Bool) -> Void
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if isCollapsed {
                    Text("+\(max(1, hiddenCount))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Theme.onBrand)
                        .padding(.horizontal, 5.5)
                        .frame(height: 20)
                        .background(Theme.brand, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Theme.surface, lineWidth: 1.2)
                        )
                } else {
                    Text(direction == .upstream ? "‹" : "›")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                        .frame(width: 18, height: 20)
                        .background(hovering ? Theme.surface2 : Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(hovering ? Theme.brand : Theme.borderStrong, lineWidth: 1)
                        )
                }
            }
            .scaleEffect(hovering && !reduceMotion ? 1.06 : 1.0)
            .animation(Theme.Motion.value(Theme.Motion.micro, reduceMotion: reduceMotion), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHover in
            hovering = isHover
            onHoverChanged(isHover)
        }
        .help(tooltipText)
        .accessibilityLabel(tooltipText)
    }

    private var tooltipText: String {
        switch (direction, isCollapsed) {
        case (.upstream, true):
            return "展开 \(nodeLabel) 左侧 \(max(1, hiddenCount)) 个上游关联节点"
        case (.upstream, false):
            return "收起 \(nodeLabel) 左侧上游关联分支"
        case (.downstream, true):
            return "展开 \(nodeLabel) 右侧 \(max(1, hiddenCount)) 个下游关联节点"
        case (.downstream, false):
            return "收起 \(nodeLabel) 右侧下游关联分支"
        }
    }
}
