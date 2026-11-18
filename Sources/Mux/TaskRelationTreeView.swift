import SwiftUI
import SuperagentCore

// MARK: - 树形展平与导轨纯函数布局（可独立单测）

enum TaskRelationTreeLayout {
    struct Row: Equatable, Identifiable {
        let node: TaskRelationNode
        let depth: Int
        /// 长度 = `max(0, depth - 1)`；第 `k` 位表示第 `k` 层祖先下方是否还有未画完的同级兄弟节点（决定该缩进列是否画全高竖线）。
        let ancestorContinues: [Bool]
        /// `depth > 0` 时表示是否为父节点的最后一个子节点（最后一项只画上半截竖线 + 圆角折线 `╰─`，不画多余下半截竖线）。
        let isLastChild: Bool
        let hasChildren: Bool
        let isCollapsed: Bool
        let hiddenDescendantCount: Int

        var id: String { node.id }
    }

    /// 收集树中所有包含子节点的父节点 ID（用于「全部收起 / 全部展开」）。
    static func collapsibleIDs(_ tree: TaskRelationTree) -> Set<String> {
        var ids: Set<String> = []
        func walk(_ node: TaskRelationNode) {
            if !node.children.isEmpty {
                ids.insert(node.id)
                for c in node.children { walk(c) }
            }
        }
        for r in tree.roots { walk(r) }
        return ids
    }

    /// 统计胶囊文案：`共 N 个关联` 或 `共 N 个关联 · 含 M 个间接`。
    static func statsText(_ tree: TaskRelationTree) -> String {
        let indirect = tree.indirectCount
        if indirect > 0 {
            return "共 \(tree.totalRelatedCount) 个关联 · 含 \(indirect) 个间接"
        }
        return "共 \(tree.totalRelatedCount) 个关联"
    }

    /// 按当前折叠集合前序展平可见节点行，并精确计算每一层的树形导轨延续标记。
    static func flatten(_ tree: TaskRelationTree, collapsed: Set<String> = []) -> [Row] {
        var rows: [Row] = []

        func descendantCount(_ node: TaskRelationNode) -> Int {
            node.children.reduce(node.children.count) { $0 + descendantCount($1) }
        }

        func visit(_ node: TaskRelationNode, depth: Int, ancestorContinues: [Bool], isLastChild: Bool) {
            let hasKids = !node.children.isEmpty
            let isFolded = hasKids && collapsed.contains(node.id)
            rows.append(
                Row(
                    node: node,
                    depth: depth,
                    ancestorContinues: ancestorContinues,
                    isLastChild: isLastChild,
                    hasChildren: hasKids,
                    isCollapsed: isFolded,
                    hiddenDescendantCount: isFolded ? descendantCount(node) : 0
                )
            )
            guard hasKids, !isFolded else { return }
            let nextAncestors = depth == 0 ? [] : (ancestorContinues + [!isLastChild])
            for (idx, child) in node.children.enumerated() {
                visit(
                    child,
                    depth: depth + 1,
                    ancestorContinues: nextAncestors,
                    isLastChild: idx == node.children.count - 1
                )
            }
        }

        for (idx, root) in tree.roots.enumerated() {
            visit(root, depth: 0, ancestorContinues: [], isLastChild: idx == tree.roots.count - 1)
        }
        return rows
    }
}

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

// MARK: - 任务详情页「关联清单脉络」树状图卡片

struct TaskRelationTreeCard: View {
    @Environment(AppModel.self) private var appModel
    let view: TaskView
    let editable: Bool

    @State private var collapsedIDs: Set<String> = []
    @State private var showLinkPicker = false

    var body: some View {
        let sa = appModel.superagent
        // 显式追踪 tasks 与 knowledge 快照，确保任意直接/间接关联节点状态变化时树状图实时刷新
        let _ = (sa.tasks.count, sa.knowledge.count)
        if let tree = sa.taskRelationTree(view.id), tree.totalRelatedCount > 0 {
            let collapsible = TaskRelationTreeLayout.collapsibleIDs(tree)
            let allCollapsed = !collapsible.isEmpty && collapsible.isSubset(of: collapsedIDs)
            let rows = TaskRelationTreeLayout.flatten(tree, collapsed: collapsedIDs)

            VStack(alignment: .leading, spacing: 0) {
                headerBar(tree: tree, collapsible: collapsible, allCollapsed: allCollapsed)
                    .padding(.horizontal, 18)
                    .padding(.top, 15)
                    .padding(.bottom, 12)

                Hairline()

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        TaskRelationTreeRowView(
                            row: row,
                            focusTaskID: view.id,
                            editable: editable,
                            onToggleCollapse: {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    if collapsedIDs.contains(row.id) {
                                        collapsedIDs.remove(row.id)
                                    } else {
                                        collapsedIDs.insert(row.id)
                                    }
                                }
                            },
                            onNavigate: { navigate(to: row.node) },
                            onUnlink: { kid in
                                sa.removeTaskKnowledgeLink(view.id, knowledgeID: kid)
                            }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .saCard(padding: 0)
            .onChange(of: view.id) { _, _ in
                collapsedIDs.removeAll()
            }
        }
    }

    private func headerBar(tree: TaskRelationTree, collapsible: Set<String>, allCollapsed: Bool) -> some View {
        let sa = appModel.superagent
        return HStack(alignment: .center, spacing: 10) {
            SectionLabel(title: "关联清单脉络")

            Text(TaskRelationTreeLayout.statsText(tree))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 5))
                .accessibilityLabel(TaskRelationTreeLayout.statsText(tree))

            Spacer(minLength: 8)

            if tree.allNodes.count > 3, !collapsible.isEmpty {
                Button(allCollapsed ? "全部展开" : "全部收起") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if allCollapsed {
                            collapsedIDs.removeAll()
                        } else {
                            collapsedIDs = collapsible
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(allCollapsed ? "展开全部关联层级" : "收起所有子节点层级")
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

    private func navigate(to node: TaskRelationNode) {
        guard !node.isFocus else { return }
        if let tid = node.taskID {
            appModel.openWorklist(task: tid)
        } else if let kid = node.knowledgeID {
            appModel.openKnowledgeBase(entryID: kid)
        }
    }
}

// MARK: - 单行树节点（左侧原生导轨线 + 右侧节点卡片）

private struct TaskRelationTreeRowView: View {
    let row: TaskRelationTreeLayout.Row
    let focusTaskID: Int64
    let editable: Bool
    let onToggleCollapse: () -> Void
    let onNavigate: () -> Void
    let onUnlink: (Int64) -> Void

    @State private var hovering = false

    private static let stepWidth: CGFloat = 24
    private static let railOffsetX: CGFloat = 11

    private var node: TaskRelationNode { row.node }

    /// 有效展示的关系标签：优先取父->子关系；若作为次级汇合根无子节点但与当前任务直接关联，展示其对当前任务的关系。
    private var displayedRelation: TaskRelationKind? {
        if let rel = node.relationFromParent { return rel }
        if row.depth == 0, node.children.isEmpty { return node.relationToFocus }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if row.depth > 0 {
                TreeConnectorGutter(
                    depth: row.depth,
                    ancestorContinues: row.ancestorContinues,
                    isLastChild: row.isLastChild,
                    stepWidth: Self.stepWidth,
                    railOffsetX: Self.railOffsetX
                )
                .frame(width: CGFloat(row.depth) * Self.stepWidth)
            }

            nodeCard
                .padding(.vertical, 4)
                .background(alignment: .bottomLeading) {
                    // 若当前节点展开了子节点，补齐卡片底边到行底 4pt 的垂直起始导轨线，使父子连接零断点
                    if row.hasChildren, !row.isCollapsed {
                        Rectangle()
                            .fill(Theme.borderStrong)
                            .frame(width: 1.5, height: 4)
                            .offset(x: Self.railOffsetX)
                            .accessibilityHidden(true)
                    }
                }
        }
    }

    private var nodeCard: some View {
        let summaryText = node.summary.isEmpty ? "暂无摘要" : node.summary
        return VStack(alignment: .leading, spacing: 6) {
            // 1) 首行：关系胶囊 + 距离徽标 + 等宽编号 + 标题 + 进度 + StateTag + 折叠箭头 + 移除按钮
            HStack(alignment: .center, spacing: 6) {
                if let rel = displayedRelation {
                    HStack(spacing: 3) {
                        Image(systemName: rel.symbol)
                            .font(.system(size: 9, weight: .semibold))
                        Text(rel.label)
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4))
                }

                if node.isFocus {
                    Text("当前任务")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.onBrand)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.brand, in: RoundedRectangle(cornerRadius: 4))
                } else if node.isIndirect {
                    Text("间接")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.32), in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.borderStrong.opacity(0.7), lineWidth: 0.8))
                        .help("距离当前任务 \(node.distanceFromFocus) 跳的间接关联节点")
                }

                Text(node.label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(node.isFocus ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4))

                Text(node.title)
                    .font(.system(size: 13, weight: node.isFocus ? .semibold : .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(node.title)

                Spacer(minLength: 6)

                if !node.isStandaloneKnowledge, node.totalCount > 0 {
                    Text("\(node.doneCount)/\(node.totalCount)")
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                        .help("清单进度：已完成 \(node.doneCount) 项，共 \(node.totalCount) 项")
                }

                StateTag(text: node.statusText, tint: node.statusTone.tint)

                if row.hasChildren {
                    Button(action: onToggleCollapse) {
                        HStack(spacing: 3) {
                            if row.isCollapsed, row.hiddenDescendantCount > 0 {
                                Text("+\(row.hiddenDescendantCount)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(row.isCollapsed ? 0 : 90))
                        }
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 5)
                        .frame(height: 20)
                        .background(row.isCollapsed ? Theme.surface2 : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(row.isCollapsed ? "展开下级关联节点（\(row.hiddenDescendantCount) 个）" : "收起下级关联节点")
                    .accessibilityLabel(row.isCollapsed ? "展开 \(node.label) 子节点" : "收起 \(node.label) 子节点")
                }

                if editable, let unlinkKBID = node.canUnlinkFromFocus {
                    Button {
                        onUnlink(unlinkKBID)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 20, height: 20)
                            .background(hovering ? Theme.surface2 : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("移除当前任务与 \(node.label) 的经验关联")
                    .accessibilityLabel("移除 \(node.label) 经验关联")
                }
            }

            // 2) 第二行：简介摘要（最多 2 行，悬停全文，空时显示柔和占位）
            Text(summaryText)
                .font(.system(size: 12))
                .foregroundStyle(node.summary.isEmpty ? Theme.textTertiary.opacity(0.75) : Theme.textSecondary)
                .lineSpacing(2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(node.summary.isEmpty ? "" : node.summary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(node.isFocus ? Theme.brand : (hovering && !node.isFocus ? Theme.borderStrong : Theme.border),
                        lineWidth: node.isFocus ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .onHover { hovering = $0 }
        .onTapGesture {
            if !node.isFocus { onNavigate() }
        }
        .help(cardTooltip)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    private var cardBackground: Color {
        if node.isFocus {
            return Theme.surface2.opacity(0.45)
        }
        if hovering {
            return Theme.chrome
        }
        if node.isIndirect {
            return Theme.chrome.opacity(0.45)
        }
        return Theme.surface
    }

    private var cardTooltip: String {
        if node.isFocus {
            return node.summary.isEmpty ? "当前正在查看的任务 \(node.label)" : node.summary
        }
        let actionHint = node.isStandaloneKnowledge ? "点击在知识库中查看 \(node.label)" : "点击跳转到任务 \(node.label)"
        return node.summary.isEmpty ? actionHint : "\(node.summary)\n\n\(actionHint)"
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if let rel = displayedRelation { parts.append(rel.label) }
        if node.isFocus { parts.append("当前任务") } else if node.isIndirect { parts.append("间接关联") }
        parts.append("\(node.label) \(node.title)")
        parts.append(node.statusText)
        if !node.isStandaloneKnowledge, node.totalCount > 0 {
            parts.append("进度 \(node.doneCount)/\(node.totalCount)")
        }
        if !node.summary.isEmpty { parts.append(node.summary) }
        return parts.joined(separator: "，")
    }
}

// MARK: - 原生 SwiftUI 树形导轨连接线（垂直竖线 + 圆角横折线 `╰─`）

private struct TreeConnectorGutter: View {
    let depth: Int
    let ancestorContinues: [Bool]
    let isLastChild: Bool
    let stepWidth: CGFloat
    let railOffsetX: CGFloat

    /// 对齐右侧节点卡片首行垂直中心（4pt 顶部间距 + 9pt 卡片上内边距 + ~10pt 首行半高 = 23pt）。
    private let elbowY: CGFloat = 23
    private let cornerRadius: CGFloat = 6

    var body: some View {
        Canvas { context, size in
            let strokeStyle = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            let railColor = Theme.borderStrong

            // 1. 祖先层级的贯穿竖线（仅在对应祖先仍有未画完的后续兄弟时绘制）
            if depth > 1 {
                for col in 0..<(depth - 1) where col < ancestorContinues.count && ancestorContinues[col] {
                    let x = CGFloat(col) * stepWidth + railOffsetX
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(railColor), style: strokeStyle)
                }
            }

            // 2. 当前父节点连接到本节点的竖线 + 圆角横折线 `╰─`（最后一项不画下半截竖线）
            let col = depth - 1
            let x = CGFloat(col) * stepWidth + railOffsetX
            let targetY = min(elbowY, max(10, size.height * 0.5))
            let endX = max(x + 4, CGFloat(depth) * stepWidth - 4)
            let r = min(cornerRadius, targetY, max(2, endX - x))

            if !isLastChild {
                var trunk = Path()
                trunk.move(to: CGPoint(x: x, y: 0))
                trunk.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(trunk, with: .color(railColor), style: strokeStyle)
            }

            var branch = Path()
            if isLastChild {
                branch.move(to: CGPoint(x: x, y: 0))
                branch.addLine(to: CGPoint(x: x, y: targetY - r))
            } else {
                branch.move(to: CGPoint(x: x, y: max(0, targetY - r)))
            }
            branch.addQuadCurve(
                to: CGPoint(x: x + r, y: targetY),
                control: CGPoint(x: x, y: targetY)
            )
            branch.addLine(to: CGPoint(x: endX, y: targetY))
            context.stroke(branch, with: .color(railColor), style: strokeStyle)
        }
        .accessibilityHidden(true)
    }
}
