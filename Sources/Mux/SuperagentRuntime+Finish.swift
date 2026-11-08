import Foundation
import SuperagentCore

// 完成任务确认单（设计评审 2026-11-08，5A）的数据：引擎给要合并的工单和没做完的项，目标分支在任务 scope 目录算。

extension SuperagentRuntime {
    /// 要合并的分支 → 目标分支、没有分支的工单、没做完的项；任务不在清单里为 nil。目标分支 = scope 目录（没有就取第一张工单
    /// 的仓库）的 `git rev-parse --abbrev-ref HEAD`；算不出写「当前分支」。git 在后台线程跑，不卡界面。
    func finishPlan(_ taskID: Int64) async -> FinishPlan? {
        guard let view = task(taskID) else { return nil }
        let dir = view.task.scope.isEmpty ? (view.tickets.first { !$0.ticket.repo.isEmpty }?.ticket.repo ?? "") : view.task.scope
        let target = await Task.detached(priority: .userInitiated) { Self.currentBranch(in: dir) }.value
        if let engine, let preview = try? engine.finishPreview(view.id) {
            return FinishPlan(preview: preview, target: target)
        }
        return FinishPlan.derive(view, target: target)
    }

    /// `dir` 所在仓库当前的分支名；不是仓库、目录不存在、分离 HEAD（输出 `HEAD`）都是 nil。
    nonisolated static func currentBranch(in dir: String) -> String? {
        guard !dir.isEmpty, FileManager.default.fileExists(atPath: dir) else { return nil }
        let r = SuperagentTmux.exec("/usr/bin/git", ["-C", dir, "rev-parse", "--abbrev-ref", "HEAD"])
        guard r.status == 0 else { return nil }
        let name = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "HEAD" ? nil : name
    }
}
