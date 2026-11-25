import AppKit
import SwiftUI
import SuperagentCore

// 项目知识库浏览、已完成任务总结卡片、新建/编辑经验弹窗、跨任务经验关联选择器。

struct KnowledgeBrowserView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let search: String
    let showingNewEntry: Binding<Bool>

    @State private var selectedProject: String?
    @State private var selectedTag: String?
    @State private var editingEntry: KnowledgeEntry?
    @State private var expandedIDs: Set<Int64> = []
    @State private var archivedUndo: (id: Int64, title: String)?
    @State private var undoDismissTask: Task<Void, Never>?

    var body: some View {
        let sa = appModel.superagent
        let projects = Self.projects(from: sa.knowledge)
        let tags = Self.topTags(from: sa.knowledge, project: selectedProject)
        let filtered = Self.filter(sa.knowledge, search: search, project: selectedProject, tag: selectedTag, engine: sa.engine)
        let pinned = filtered.filter(\.entry.pinned)
        let regular = filtered.filter { !$0.entry.pinned }

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                if let e = sa.actionError {
                    Banner(text: e) {
                        Theme.Motion.run(Theme.Motion.panel, reduceMotion: reduceMotion) {
                            sa.actionError = nil
                        }
                    }
                    .transition(Theme.Motion.reveal(edge: .top, reduceMotion: reduceMotion))
                }

                if let undo = archivedUndo {
                    HStack(spacing: Theme.Space.md) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                        Text("已归档「\(undo.title)」")
                            .font(.callout)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Button("撤销") {
                            undoDismissTask?.cancel()
                            undoDismissTask = nil
                            sa.setKnowledgeArchived(undo.id, archived: false)
                            Theme.Motion.run(Theme.Motion.panel, reduceMotion: reduceMotion) {
                                archivedUndo = nil
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button {
                            undoDismissTask?.cancel()
                            undoDismissTask = nil
                            Theme.Motion.run(Theme.Motion.panel, reduceMotion: reduceMotion) {
                                archivedUndo = nil
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PaperPressButtonStyle(hoverWash: true, cornerRadius: 4))
                        .help("关闭提示")
                        .accessibilityLabel("关闭提示")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.border, lineWidth: 1))
                    .transition(Theme.Motion.reveal(edge: .top, reduceMotion: reduceMotion))
                }

                if sa.unindexedDoneCount > 0 {
                    backfillBanner(count: sa.unindexedDoneCount)
                }

                if !sa.knowledge.isEmpty || selectedProject != nil || selectedTag != nil {
                    filterBar(projects: projects, tags: tags)
                }

                if sa.knowledge.isEmpty {
                    emptyState
                } else if filtered.isEmpty {
                    Text("没有匹配当前筛选条件的经验卡片。")
                        .font(Theme.Font.emptyBody)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Space.xxxl)
                } else {
                    if !pinned.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            HStack(spacing: Theme.Space.sm) {
                                Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(Theme.brand)
                                Text("置顶常驻经验").font(Theme.Font.sectionHeader).foregroundStyle(Theme.textPrimary)
                                CountBadge(count: pinned.count)
                                Text("同项目派发新工单时自动附带")
                                    .font(.caption).foregroundStyle(Theme.textTertiary)
                            }
                            ForEach(pinned) { kv in
                                KnowledgeCardRow(
                                    view: kv,
                                    expanded: isExpanded(kv.id),
                                    toggleExpand: { toggle(kv.id) },
                                    edit: { editingEntry = kv.entry },
                                    archive: { archiveWithUndo(id: kv.entry.id, title: kv.entry.title) }
                                )
                            }
                        }
                    }

                    if !regular.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            HStack(spacing: Theme.Space.sm) {
                                Text(pinned.isEmpty ? "全部知识沉淀" : "按时间沉淀")
                                    .font(Theme.Font.sectionHeader).foregroundStyle(Theme.textPrimary)
                                CountBadge(count: regular.count)
                                if sa.knowledgeRefining {
                                    Text("· 后台正在提炼总结…").font(.caption).foregroundStyle(Theme.textTertiary)
                                }
                            }
                            ForEach(regular) { kv in
                                KnowledgeCardRow(
                                    view: kv,
                                    expanded: isExpanded(kv.id),
                                    toggleExpand: { toggle(kv.id) },
                                    edit: { editingEntry = kv.entry },
                                    archive: { archiveWithUndo(id: kv.entry.id, title: kv.entry.title) }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .animation(Theme.Motion.value(Theme.Motion.panel, reduceMotion: reduceMotion), value: archivedUndo?.id)
        .onAppear { focusRequestedEntry() }
        .onDisappear {
            undoDismissTask?.cancel()
            undoDismissTask = nil
        }
        .onChange(of: appModel.worklistFocusedKnowledgeID) { _, _ in focusRequestedEntry() }
        .sheet(item: $editingEntry) { entry in
            KnowledgeEditSheet(existing: entry).environment(appModel)
        }
        .sheet(isPresented: showingNewEntry) {
            KnowledgeEditSheet(existing: nil, initialScope: selectedProject ?? WorkspaceStore.shared.selected?.path ?? "")
                .environment(appModel)
        }
    }

    private func archiveWithUndo(id: Int64, title: String) {
        let sa = appModel.superagent
        sa.setKnowledgeArchived(id, archived: true)
        undoDismissTask?.cancel()
        Theme.Motion.run(Theme.Motion.panel, reduceMotion: reduceMotion) {
            archivedUndo = (id: id, title: title)
        }
        undoDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, archivedUndo?.id == id else { return }
            Theme.Motion.run(Theme.Motion.echo, reduceMotion: reduceMotion) {
                archivedUndo = nil
            }
            undoDismissTask = nil
        }
    }

    private func isExpanded(_ id: Int64) -> Bool { expandedIDs.contains(id) }
    private func toggle(_ id: Int64) {
        Theme.Motion.run(Theme.Motion.panel, reduceMotion: reduceMotion) {
            if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
        }
    }

    private func focusRequestedEntry() {
        guard let target = appModel.worklistFocusedKnowledgeID else { return }
        expandedIDs.insert(target)
        appModel.worklistFocusedKnowledgeID = nil
    }

    private func backfillBanner(count: Int) -> some View {
        let sa = appModel.superagent
        return HStack(alignment: .center, spacing: Theme.Space.md) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 15))
                .foregroundStyle(Theme.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text("发现 \(count) 个已完成的旧任务还没有总结入库")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("可一键汇总它们的工单成果生成知识卡，并同步到本地 Markdown 目录。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Button("快速汇总") { sa.backfillCompletedTasks(aiRefine: false) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("不调用模型，立即按工单交付和清单生成基础总结卡")
            Button("AI 提炼补齐") { sa.backfillCompletedTasks(aiRefine: true) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("先立即入库基础总结，再由后台模型逐张提炼高信噪比结论与避坑点")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.border, lineWidth: 1))
    }

    private func filterBar(projects: [String], tags: [String]) -> some View {
        let sa = appModel.superagent
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: Theme.Space.md) {
                Menu {
                    Button {
                        Theme.Motion.run(Theme.Motion.snap, reduceMotion: reduceMotion) {
                            selectedProject = nil
                        }
                    } label: {
                        if selectedProject == nil { Label("全部项目", systemImage: "checkmark") } else { Text("全部项目") }
                    }
                    if !projects.isEmpty { Divider() }
                    ForEach(projects, id: \.self) { p in
                        let name = WorklistSections.projectName(p)
                        Button {
                            Theme.Motion.run(Theme.Motion.snap, reduceMotion: reduceMotion) {
                                selectedProject = p
                            }
                        } label: {
                            if selectedProject == p { Label(name, systemImage: "checkmark") } else { Text(name) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder").font(.system(size: 11))
                        Text(selectedProject.map(WorklistSections.projectName) ?? "全部项目")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(selectedProject == nil ? Theme.textSecondary : Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.border, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tags, id: \.self) { tag in
                                let active = selectedTag == tag
                                Button {
                                    Theme.Motion.run(Theme.Motion.snap, reduceMotion: reduceMotion) {
                                        selectedTag = active ? nil : tag
                                    }
                                } label: {
                                    Text("#\(tag)")
                                        .font(.system(size: 11, weight: active ? .semibold : .regular))
                                        .foregroundStyle(active ? Theme.onBrand : Theme.textSecondary)
                                        .padding(.horizontal, 8)
                                        .frame(height: 22)
                                        .background(active ? Theme.brand : Theme.surface2, in: Capsule())
                                }
                                .buttonStyle(PaperPressButtonStyle())
                            }
                        }
                    }
                }

                Spacer(minLength: 4)

                Button {
                    let dir = sa.knowledgeBaseDir
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                } label: {
                    Label("打开目录", systemImage: "folder.badge.gearshape")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("在访达中打开本地 Markdown 知识库镜像：\(sa.knowledgeBaseDir.path)")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.lg) {
            Image(systemName: "books.vertical")
                .font(.system(size: 28))
                .foregroundStyle(Theme.textTertiary)
            Text("知识库还是空的。任务完成后会自动提炼总结沉淀到这里，下次建新任务可直接关联复用。")
                .font(Theme.Font.emptyBody)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            HStack(spacing: Theme.Space.md) {
                Button("回到清单") { appModel.worklistTab = .tasks }
                Button {
                    showingNewEntry.wrappedValue = true
                } label: {
                    Label("记一条经验", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xxxl)
    }

    private static func projects(from list: [KnowledgeView]) -> [String] {
        var seen: [String] = []
        for kv in list where !kv.entry.scope.isEmpty && !seen.contains(kv.entry.scope) {
            seen.append(kv.entry.scope)
        }
        return seen.sorted { WorklistSections.projectName($0) < WorklistSections.projectName($1) }
    }

    private static func topTags(from list: [KnowledgeView], project: String?) -> [String] {
        var counts: [String: Int] = [:]
        for kv in list {
            if let project, kv.entry.scope != project { continue }
            for t in kv.entry.tags { counts[t, default: 0] += 1 }
        }
        return counts.sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
            .prefix(10)
            .map(\.key)
    }

    private static func filter(_ list: [KnowledgeView], search: String, project: String?, tag: String?,
                               engine: SuperagentEngine?) -> [KnowledgeView] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty, let engine,
           let matched = try? engine.searchKnowledgeViews(query: q, preferredScope: project ?? "",
                                                          strictScope: project != nil, tag: tag, limit: 100) {
            return matched
        }
        return list.filter { kv in
            if let project, kv.entry.scope != project { return false }
            if let tag, !kv.entry.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { return false }
            if !q.isEmpty {
                let hay = ([kv.entry.displayLabel, kv.entry.title, kv.entry.tldr] + kv.entry.outcomes + kv.entry.pitfalls + kv.entry.tags)
                    .joined(separator: "\n").lowercased()
                if !hay.contains(q.lowercased()) { return false }
            }
            return true
        }
    }
}

// MARK: - 知识库单张卡片

private struct KnowledgeCardRow: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let view: KnowledgeView
    let expanded: Bool
    let toggleExpand: () -> Void
    let edit: () -> Void
    let archive: () -> Void
    @State private var isHovered = false

    var body: some View {
        let sa = appModel.superagent
        let e = view.entry
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    if let tid = e.taskID {
                        appModel.openWorklist(task: tid)
                    } else {
                        toggleExpand()
                    }
                } label: {
                    Text(e.displayLabel)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help(e.taskID != nil ? "打开来源任务 \(e.displayLabel)" : "独立经验卡片 \(e.kbLabel)")

                Text(e.title)
                    .font(Theme.Font.rowTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                if e.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.brand)
                        .help("已置顶为该项目常驻经验")
                }

                if e.needsRefine {
                    Text("提炼中…")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                } else if e.aiRefined {
                    Text("✦ AI 总结")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: 8)

                if !e.scope.isEmpty {
                    Text(e.projectName)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }

                Button("接着做…") {
                    let ref: KnowledgeRef = e.taskID.map { .task($0) } ?? .knowledge(e.id)
                    appModel.startDerivedTask(scope: e.scope, ref: ref, refTitle: e.title)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("基于这条经验新建后续任务，自动带上项目目录与经验关联")

                Menu {
                    Button(e.pinned ? "取消置顶常驻" : "置顶为项目常驻经验") {
                        sa.setKnowledgePinned(e.id, pinned: !e.pinned)
                    }
                    Button("编辑总结…", action: edit)
                    if e.taskID != nil {
                        Button("重新 AI 提炼") { sa.refineKnowledge(e.id) }
                        Button("查看原任务 \(e.displayLabel)") {
                            if let tid = e.taskID { appModel.openWorklist(task: tid) }
                        }
                    }
                    if !e.mdPath.isEmpty, FileManager.default.fileExists(atPath: e.mdPath) {
                        Button("打开 Markdown 文件") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: e.mdPath))
                        }
                    }
                    Divider()
                    Button("归档隐藏", role: .destructive, action: archive)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if !e.tldr.isEmpty {
                Text(e.tldr)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(3)
                    .lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !expanded, let firstPitfall = e.pitfalls.first {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Status.attention)
                        .padding(.top, 2)
                    Text("避坑：\(firstPitfall)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Hairline()
                    KnowledgeBodySections(entry: e, derivedTasks: view.derivedTasks)
                }
                .transition(Theme.Motion.reveal(edge: .top, reduceMotion: reduceMotion))
            }

            HStack(alignment: .center, spacing: 6) {
                ForEach(e.tags.prefix(5), id: \.self) { tag in
                    Text("#\(tag)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4))
                }
                if !view.derivedTasks.isEmpty {
                    Text("被 \(view.derivedTasks.count) 个后续任务关联")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 4)
                Button(expanded ? "收起详情" : "展开详情") { toggleExpand() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(e.pinned || isHovered ? Theme.borderStrong : Theme.border, lineWidth: 1)
        )
        .animation(Theme.Motion.value(Theme.Motion.micro, reduceMotion: reduceMotion), value: isHovered)
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
        .onTapGesture { toggleExpand() }
    }
}

// MARK: - 任务详情页顶部的「任务总结与知识沉淀」卡片

struct TaskSummaryCard: View {
    @Environment(AppModel.self) private var appModel
    let view: TaskView
    @State private var editing: KnowledgeEntry?

    var body: some View {
        let sa = appModel.superagent
        if let e = view.knowledge {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                    Text("任务总结与知识沉淀")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.textSecondary)

                    if e.needsRefine {
                        Text("· AI 正在提炼…").font(.caption).foregroundStyle(Theme.textTertiary)
                    } else if e.pinned {
                        Text("· 已置顶常驻").font(.caption).foregroundStyle(Theme.brand)
                    }

                    Spacer(minLength: 8)

                    Button(e.pinned ? "取消置顶" : "置顶常驻") {
                        sa.setKnowledgePinned(e.id, pinned: !e.pinned)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("置顶后，同项目下的后续新工单会自动附带这条经验摘要")

                    Button("重新提炼") { sa.summarizeTask(view.id, force: true) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(e.needsRefine)

                    Button("编辑…") { editing = e }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                    Button("接着做…") {
                        appModel.startDerivedTask(scope: view.task.scope, ref: .task(view.id), refTitle: view.task.title)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("新建后续任务，自动继承目录并关联本次任务的总结经验")
                }

                if !e.tldr.isEmpty {
                    Text(e.tldr)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                KnowledgeBodySections(entry: e, derivedTasks: view.derivedTasks)
            }
            .saCard()
            .sheet(item: $editing) { entry in
                KnowledgeEditSheet(existing: entry).environment(appModel)
            }
        } else if !view.task.isOpen {
            // 历史旧完成任务尚未总结，或已取消/已放弃的任务想手动沉淀教训
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "book.closed")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                Text(view.task.status == .done
                     ? "这张历史已完成任务还没有生成知识卡片。"
                     : "任务已结束，若有值得复用的排查结论或踩坑经验可沉淀到知识库。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                Button("生成总结入库") {
                    sa.summarizeTask(view.id, force: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if view.task.status == .done {
                    Button("接着做…") {
                        appModel.startDerivedTask(scope: view.task.scope, ref: .task(view.id), refTitle: view.task.title)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.border, lineWidth: 1))
        }
    }
}

private struct KnowledgeBodySections: View {
    @Environment(AppModel.self) private var appModel
    let entry: KnowledgeEntry
    let derivedTasks: [DerivedTaskSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !entry.outcomes.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("交付要点").font(.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                    ForEach(entry.outcomes, id: \.self) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(Theme.textTertiary)
                            Text(item)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if !entry.pitfalls.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("踩坑与关键决策（下次关联时自动提示 Agent）")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Status.attention)
                    ForEach(entry.pitfalls, id: \.self) { pit in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Status.attention)
                                .padding(.top, 3)
                            Text(pit)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Status.attention.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            }

            if !entry.files.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("涉及文件").font(.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                    FlowLayout(spacing: 6) {
                        ForEach(entry.files, id: \.self) { file in
                            Text(file)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4))
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if !derivedTasks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("后续关联任务").font(.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                    FlowLayout(spacing: 6) {
                        ForEach(derivedTasks) { dt in
                            Button {
                                appModel.openWorklist(task: dt.id)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.turn.down.right").font(.system(size: 10))
                                    Text("\(dt.label) \(dt.title)")
                                        .lineLimit(1)
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.horizontal, 8)
                                .frame(height: 22)
                                .background(Theme.chrome, in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 新建 / 编辑知识经验弹窗

struct KnowledgeEditSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let existing: KnowledgeEntry?
    var initialScope: String = ""

    @State private var title = ""
    @State private var scope = ""
    @State private var tldr = ""
    @State private var outcomesText = ""
    @State private var pitfallsText = ""
    @State private var filesText = ""
    @State private var tagsText = ""
    @State private var pinned = false
    @State private var error: String?

    var body: some View {
        let sa = appModel.superagent
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text(existing == nil ? "记一条项目经验" : "编辑知识总结 · \(existing!.displayLabel)")
                .font(Theme.Font.headerTitle)

            Field(title: "标题") {
                TextField("简短说明主题，如：agy 空闲心跳与断网续跑处理", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            Field(title: "一句话结论") {
                TextEditor(text: $tldr).editorBox().frame(height: 54)
            }

            HStack(alignment: .top, spacing: Theme.Space.lg) {
                Field(title: "交付要点 / 解决方案（每行一条）") {
                    TextEditor(text: $outcomesText).editorBox().frame(height: 92)
                }
                Field(title: "踩坑与关键决策（每行一条，优先提示给 Agent）") {
                    TextEditor(text: $pitfallsText).editorBox().frame(height: 92)
                }
            }

            HStack(alignment: .top, spacing: Theme.Space.lg) {
                Field(title: "关键文件路径（每行一个，可选）") {
                    TextEditor(text: $filesText).editorBox().frame(height: 64)
                }
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Field(title: "标签（逗号分隔）") {
                        TextField("如：agy, tmux, 重试", text: $tagsText)
                            .textFieldStyle(.roundedBorder)
                    }
                    Field(title: "所属项目目录") {
                        HStack(spacing: Theme.Space.sm) {
                            Text(scope.isEmpty ? "通用经验" : tilde(scope))
                                .font(.caption.monospaced())
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            if !scope.isEmpty {
                                Button("清除") { scope = "" }.controlSize(.small)
                            }
                            Button("选择…") {
                                if let p = pickFolder(from: scope, message: "这条经验归属的项目目录") { scope = p }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Toggle("置顶为该项目常驻经验（同项目新建工单时自动附带摘要）", isOn: $pinned)
                .toggleStyle(.checkbox)
                .font(.callout)

            SheetButtons(
                error: error,
                confirm: "保存",
                enabled: !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                disabledReason: "请先填写经验标题",
                shortcut: KeyboardShortcut(.return, modifiers: .command)
            ) {
                let draft = KnowledgeDraft(
                    scope: scope,
                    title: title,
                    tldr: tldr,
                    outcomes: NewTaskSheet.parseItems(outcomesText),
                    pitfalls: NewTaskSheet.parseItems(pitfallsText),
                    files: NewTaskSheet.parseItems(filesText),
                    tags: tagsText.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace }).map(String.init),
                    pinned: pinned
                )
                sa.actionError = nil
                let saved = sa.saveKnowledge(id: existing?.id, draft: draft)
                if let err = sa.actionError {
                    error = err
                } else if saved != nil {
                    dismiss()
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 620)
        .onAppear {
            if let e = existing {
                title = e.title
                scope = e.scope
                tldr = e.tldr
                outcomesText = e.outcomes.joined(separator: "\n")
                pitfallsText = e.pitfalls.joined(separator: "\n")
                filesText = e.files.joined(separator: "\n")
                tagsText = e.tags.joined(separator: ", ")
                pinned = e.pinned
            } else {
                scope = initialScope
            }
        }
    }
}

// MARK: - 任务详情 / 新建任务共用的「关联历史经验」选择器

struct KnowledgeLinkPicker: View {
    @Environment(AppModel.self) private var appModel
    let currentTaskID: Int64?
    let preferredScope: String
    @Binding var selectedIDs: Set<Int64>
    var onOpenTask: ((Int64) -> Void)?

    @State private var query = ""

    var body: some View {
        let sa = appModel.superagent
        let candidates = Self.candidates(sa: sa, query: query, preferredScope: preferredScope, excludingTask: currentTaskID)

        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("关联历史任务总结 / 经验卡")
                    .font(Theme.Font.sectionHeader)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if !selectedIDs.isEmpty {
                    Button("清空") { selectedIDs.removeAll() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            TextField("搜索标题、标签、文件名或编号（如 A-14）", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            if candidates.isEmpty {
                Text(sa.knowledge.isEmpty ? "知识库暂无已沉淀的任务总结。" : "没有匹配的历史经验。")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(candidates) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Toggle("", isOn: Binding(
                                    get: { selectedIDs.contains(entry.id) },
                                    set: { on in
                                        if on { selectedIDs.insert(entry.id) } else { selectedIDs.remove(entry.id) }
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(entry.displayLabel)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(Theme.textTertiary)
                                        Text(entry.title)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(Theme.textPrimary)
                                            .lineLimit(1)
                                        if entry.pinned {
                                            Image(systemName: "pin.fill")
                                                .font(.system(size: 9))
                                                .foregroundStyle(Theme.brand)
                                        }
                                    }
                                    if !entry.tldr.isEmpty {
                                        Text(entry.tldr)
                                            .font(.caption)
                                            .foregroundStyle(Theme.textSecondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 4)
                                if let tid = entry.taskID, let onOpenTask {
                                    Button("查看") { onOpenTask(tid) }
                                        .buttonStyle(.borderless)
                                        .font(.caption)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(Theme.Space.md)
        .frame(width: 400)
    }

    private static func candidates(sa: SuperagentRuntime, query: String, preferredScope: String, excludingTask: Int64?) -> [KnowledgeEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty, let engine = sa.engine,
           let hits = try? engine.store.searchKnowledge(query: q, preferredScope: preferredScope, limit: 30) {
            return hits.filter { $0.taskID != excludingTask }
        }
        return sa.knowledge.map(\.entry)
            .filter { $0.taskID != excludingTask }
            .sorted { a, b in
                let aSame = !preferredScope.isEmpty && a.scope == preferredScope
                let bSame = !preferredScope.isEmpty && b.scope == preferredScope
                if aSame != bSame { return aSame && !bSame }
                if a.pinned != b.pinned { return a.pinned && !b.pinned }
                return a.updatedAt > b.updatedAt
            }
    }
}

// MARK: - 清单项内嵌展开摘要抽屉 + 编辑弹窗 + 工单持久化归档弹窗

struct ItemSummaryDrawer: View {
    @Environment(AppModel.self) private var appModel
    let view: TaskView
    let item: Item
    let summary: String
    let editSummary: () -> Void

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        let ticketView = item.ticketID.flatMap { view.ticket($0) }
        let reviews = item.ticketID.map { tid in
            view.tickets.filter { $0.ticket.reviewOf == tid && !$0.ticket.reportSummary.isEmpty }
        } ?? []
        let sessionName = ticketView?.ticket.session ?? ""
        let liveSession = appModel.hasLiveLocalTmuxSession(sessionName)
        let isStanding = ticketView.map { appModel.superagent.role(for: $0.ticket).standing } ?? false

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                if let doneBy = item.doneBy, !doneBy.isEmpty {
                    Text("由「\(doneBy)」完成")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("执行记录")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                if let doneAt = item.doneAt {
                    Text("· \(Self.dateFmt.string(from: Date(timeIntervalSince1970: doneAt)))")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                if let tv = ticketView, !tv.ticket.isOpen, !liveSession {
                    Text("· 终端已关闭，摘要已归档")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: 8)

                if let tv = ticketView {
                    if !tv.ticket.branch.isEmpty {
                        Button("看改动") {
                            appModel.showTaskDiff(task: view.id, ticket: tv.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    if let rp = tv.ticket.reportPath, !rp.isEmpty, FileManager.default.fileExists(atPath: rp) {
                        Button("打开报告") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: rp))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    Button("工单 #\(tv.id) 归档…") {
                        appModel.inspectingTicket = .init(ticketID: tv.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    if liveSession && (tv.ticket.isOpen || !isStanding) {
                        Button("打开终端") {
                            appModel.goToTicket(tv.id, forceTerminal: true)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }

                Button("编辑摘要…", action: editSummary)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }

            if let ack = ticketView?.ticket.ack, !ack.isEmpty {
                Text("目标确认：\(ack)")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .textSelection(.enabled)
            }

            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(item.assignee == .you
                     ? "这项由你手动勾选完成，还没有填写备注；可点右上角「编辑摘要…」记录处理结果。"
                     : "这项暂无保存的文字摘要；可点「工单归档…」查看消息与时间线，或手动补记摘要。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }

            if let lastReview = reviews.last {
                Hairline()
                VStack(alignment: .leading, spacing: 4) {
                    Text("评审工单 #\(lastReview.id) 核对结论")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(lastReview.ticket.reportSummary)
                        .font(.system(size: 12))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .padding(.leading, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }
}

struct ItemSummarySheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let taskID: Int64
    let item: Item

    @State private var text = ""

    var body: some View {
        let sa = appModel.superagent
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("第 \(item.ord) 项摘要 · A-\(taskID)")
                .font(Theme.Font.headerTitle)
            Text(item.text)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
            TextEditor(text: $text)
                .editorBox()
                .frame(minHeight: 160)
            SheetButtons(
                error: nil,
                confirm: "保存摘要",
                enabled: true,
                shortcut: KeyboardShortcut(.return, modifiers: .command)
            ) {
                sa.editItemSummary(taskID, ord: item.ord, summary: text)
                dismiss()
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 520)
        .onAppear {
            if !item.summary.isEmpty {
                text = item.summary
            } else if let tv = sa.task(taskID) {
                text = TaskCard.effectiveItemSummary(item: item, in: tv)
            }
        }
    }
}

struct TicketArchiveSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let ticketID: Int64

    @State private var showTerminalSnapshot = false

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        let sa = appModel.superagent
        let ticketView = sa.views.first(where: { $0.id == ticketID }) ?? (try? sa.engine?.view(ticketID))
        let inputs = sa.inputs(ticketID)
        let events = sa.events(ticketID)
        let archive = (try? sa.engine?.store.ticketArchive(ticketID)) ?? nil

        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            if let tv = ticketView {
                let t = tv.ticket
                let liveSession = appModel.hasLiveLocalTmuxSession(t.session)

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("工单 #\(t.id)")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4))
                            Text(t.title)
                                .font(Theme.Font.headerTitle)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(2)
                        }
                        HStack(spacing: 8) {
                            Text("角色：\(t.role)")
                            Text("· 状态：\(tv.stage.label)")
                            if let taskID = t.taskID {
                                Button("所属任务 A-\(taskID)") {
                                    dismiss()
                                    appModel.openWorklist(task: taskID)
                                }
                                .buttonStyle(.borderless)
                            }
                            if !t.branch.isEmpty {
                                Text("· 分支 \(t.branch)").font(.caption.monospaced())
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 8)
                    if let rp = t.reportPath, !rp.isEmpty, FileManager.default.fileExists(atPath: rp) {
                        Button("打开报告附件") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: rp))
                        }
                        .controlSize(.small)
                    }
                    if liveSession {
                        Button("打开终端（\(t.session)）") {
                            let id = t.id
                            dismiss()
                            appModel.goToTicket(id, forceTerminal: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Text("终端会话已关闭 · 已归档")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 4)
                    }
                }

                Hairline()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !t.ack.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("开工确认").font(.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                                Text(t.ack)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textPrimary)
                                    .textSelection(.enabled)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("保存的执行摘要 / 最终回报").font(.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                            Text(t.reportSummary.isEmpty ? "（该工单未留下文字回报摘要）" : t.reportSummary)
                                .font(.system(size: 13))
                                .lineSpacing(4)
                                .foregroundStyle(t.reportSummary.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.border, lineWidth: 1))
                                .textSelection(.enabled)
                        }

                        if !inputs.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("往来消息（\(inputs.count) 条）").font(.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                                ForEach(inputs, id: \.id) { msg in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(msg.kind == .human ? "你" : "TFA 系统") · \(Self.timeFmt.string(from: Date(timeIntervalSince1970: msg.createdAt)))")
                                            .font(.caption2)
                                            .foregroundStyle(Theme.textTertiary)
                                        Text(msg.text)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.textSecondary)
                                            .textSelection(.enabled)
                                    }
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.surface2.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }

                        if let archive, !archive.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Button {
                                    showTerminalSnapshot.toggle()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 9, weight: .semibold))
                                            .rotationEffect(.degrees(showTerminalSnapshot ? 90 : 0))
                                        Text("归档终端输出快照")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .foregroundStyle(Theme.textSecondary)
                                }
                                .buttonStyle(.plain)

                                if showTerminalSnapshot {
                                    Text(archive)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Theme.textSecondary)
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 6))
                                        .textSelection(.enabled)
                                }
                            }
                        }

                        if !events.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("执行时间线（\(events.count) 条）").font(.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                                ForEach(events.prefix(25), id: \.id) { ev in
                                    Text("\(Self.timeFmt.string(from: Date(timeIntervalSince1970: ev.at)))  [\(ev.kind)]  \(ev.text)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Theme.textTertiary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
            } else {
                Text("找不到工单 #\(ticketID) 的记录。")
                    .foregroundStyle(Theme.textTertiary)
            }

            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 640)
    }
}
