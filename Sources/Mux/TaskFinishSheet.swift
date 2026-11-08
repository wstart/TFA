import SwiftUI
import SuperagentCore

// 完成任务的确认单（设计评审 2026-11-08，5A）：点「完成任务…」先看清会发生什么——要合并的分支 → 目标分支、
// 没有分支的工单（随任务结单）、没做完的项（有则警告）；主按钮「合并并完成」走现有 `approveTask`。

/// 确认单的数据（纯数据，可测）。
struct FinishPlan: Equatable {
    struct Branch: Equatable {
        let ticketID: Int64
        let branch: String
        let title: String
    }
    struct Bare: Equatable {
        let ticketID: Int64
        let title: String
    }

    /// 要合并的分支（按工单号）。
    var branches: [Branch]
    /// 没有分支的工单：只随任务结单，不合并。
    var withoutBranch: [Bare]
    /// 没做完的清单项（序号）。
    var unfinishedOrds: [Int]
    /// 目标分支；算不出（不是仓库、分离 HEAD）就写「当前分支」。
    var target: String

    static let unknownTarget = "当前分支"

    /// 从引擎的 `finishPreview` 建：`branch` 为 nil / 空 = 没有分支。
    init(preview: FinishPreview, target: String?) {
        var branches: [Branch] = [], bare: [Bare] = []
        for t in preview.tickets.sorted(by: { $0.ticketID < $1.ticketID }) {
            if let b = t.branch, !b.isEmpty { branches.append(Branch(ticketID: t.ticketID, branch: b, title: t.title)) }
            else { bare.append(Bare(ticketID: t.ticketID, title: t.title)) }
        }
        self.branches = branches
        self.withoutBranch = bare
        self.unfinishedOrds = preview.unfinishedOrds.sorted()
        let target = (target ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.target = target.isEmpty ? Self.unknownTarget : target
    }

    /// 引擎不可用时从读视图推（同 `finishPreview` 的口径：交付了的非评审工单——done 或 ready）。
    static func derive(_ view: TaskView, target: String?) -> FinishPlan {
        let tickets = view.tickets
            .filter { $0.ticket.reviewOf == nil && ($0.ticket.status == .done || ($0.ticket.isOpen && $0.ticket.reportState == .ready)) }
            .map { (ticketID: $0.id, branch: $0.ticket.branch.isEmpty ? nil : $0.ticket.branch, title: $0.ticket.title) }
        return FinishPlan(preview: FinishPreview(tickets: tickets, unfinishedOrds: view.items.filter { $0.status != .done }.map(\.ord)),
                          target: target)
    }

    /// 「tfa/12、tfa/13 → main」；没有分支为 nil。
    var mergeLine: String? {
        branches.isEmpty ? nil : branches.map(\.branch).joined(separator: "、") + " → " + target
    }
    /// 「第 4 项还没做完」。
    var unfinishedLine: String? {
        unfinishedOrds.isEmpty ? nil : "\(WorklistText.ords(unfinishedOrds))还没做完"
    }
    var confirmTitle: String { branches.isEmpty ? "完成任务" : "合并并完成" }
    /// 成功后清单行的回声（3A）：「已完成 · tfa/12 已合并到 main」/「已完成」。
    var echo: String {
        branches.isEmpty ? "已完成" : "已完成 · " + branches.map(\.branch).joined(separator: "、") + " 已合并到 " + target
    }
}

/// 只依赖任务号：清单行和任务卡都用 `.sheet(item: $finishing) { TaskFinishSheet(taskID: $0.taskID) }` 呈现同一张单。
struct TaskFinishSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let taskID: Int64
    @State private var plan: FinishPlan?
    @State private var error: String?
    @State private var running = false

    /// `plan` 给了就不去问引擎 / git（快照、测试）。
    init(taskID: Int64, plan: FinishPlan? = nil) {
        self.taskID = taskID
        _plan = State(initialValue: plan)
    }

    var body: some View {
        let sa = appModel.superagent
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("完成任务 A-\(taskID) \(sa.task(taskID)?.task.title ?? "")").font(Theme.Font.headerTitle).lineLimit(2)
            if let plan {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("要合并的分支").font(Theme.Font.sectionHeader).foregroundStyle(Theme.textTertiary)
                    if plan.branches.isEmpty {
                        Text("没有要合并的分支。").font(.callout).foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(plan.branches, id: \.ticketID) { b in
                            HStack(spacing: Theme.Space.md) {
                                Text(b.branch).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                                    .padding(.horizontal, 7).frame(height: 22)
                                    .background(Theme.chrome, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                                Text("工单 #\(b.ticketID) \(b.title)").font(.callout).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        HStack(spacing: Theme.Space.sm) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                                .accessibilityHidden(true)
                            Text("合并到 ").font(.callout).foregroundStyle(Theme.textSecondary)
                                + Text(plan.target).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                        }
                        .accessibilityLabel("合并到 \(plan.target)")
                    }
                }
                if !plan.withoutBranch.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Text("没有分支的工单（随任务结单）").font(Theme.Font.sectionHeader).foregroundStyle(Theme.textTertiary)
                        ForEach(plan.withoutBranch, id: \.ticketID) { t in
                            Text("工单 #\(t.ticketID) \(t.title)").font(.callout).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                    }
                }
                if let line = plan.unfinishedLine {
                    HStack(spacing: Theme.Space.sm) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 11, weight: .medium))
                            .accessibilityHidden(true)
                        Text(line).font(.callout)
                    }
                    .foregroundStyle(Theme.Status.attention)
                    .accessibilityLabel("警告：\(line)")
                }
            } else {
                HStack(spacing: Theme.Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("在看要合并的分支…").font(.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            SheetButtons(error: error, confirm: running ? "合并中…" : (plan?.confirmTitle ?? "合并并完成"),
                         enabled: plan != nil && error == nil && !running && !sa.mergingTasks.contains(taskID)) { confirm(sa) }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
        .task {
            guard plan == nil else { return }
            if let p = await sa.finishPlan(taskID) { plan = p } else { error = "任务 A-\(taskID) 不在清单里" }
        }
    }

    /// 现有 `approveTask`：全部合并成功才结束任务，runtime 把「已完成 · …」回声给清单行（3A）；合不了（`mergeError`）或
    /// 引擎拒绝（`actionErrors`）的原因留在单里，任务留在待评审。
    private func confirm(_ sa: SuperagentRuntime) {
        guard plan != nil, !running else { return }
        running = true
        error = nil
        sa.mergeError = nil
        sa.actionErrors[taskID] = nil
        Task { @MainActor in
            await sa.approveTask(taskID).value
            running = false
            if let e = sa.mergeError ?? sa.actionErrors[taskID] {
                sa.mergeError = nil
                sa.actionErrors[taskID] = nil
                error = e
                return
            }
            dismiss()
        }
    }
}
