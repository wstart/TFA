import AppKit
import SwiftUI
import SuperagentCore

// 任务卡内嵌 diff（TODOS「任务卡内嵌 diff」，设计评审 2026-11-08）：待评审时「看改动」不再离开卡，
// 在卡上按文件折叠显示工单分支相对分叉点的只读改动（`git diff <merge-base> tfa/<号>`）。
// 解析是纯函数（可测）；git 在后台线程跑；大 diff 按文件 / 总行数截断，完整的去终端看。

/// 一行改动。行号是旧 / 新文件里的行号（hunk 头和元信息行没有）。
struct DiffLine: Equatable {
    enum Kind: Equatable { case context, added, removed, hunk, meta }
    var kind: Kind
    var text: String
    var oldNo: Int?
    var newNo: Int?
}

/// 一个文件的改动。
struct FileDiff: Equatable, Identifiable {
    enum Change: String, Equatable { case modified = "M", added = "A", deleted = "D", renamed = "R", binary = "B" }
    var path: String
    /// 改名前的路径（只有改名时有）。
    var oldPath: String?
    var change: Change = .modified
    var lines: [DiffLine] = []
    var added = 0
    var removed = 0
    /// 行数超过上限，后面的没收进来（`added` / `removed` 仍是全量）。
    var truncated = false

    var id: String { path }
}

/// 一次加载的结果。
struct TaskDiffResult: Equatable {
    var files: [FileDiff] = []
    /// 总行数超过上限，后面的文件没收进来。
    var truncated = false
    /// 比较的两端：分叉点（短 sha）和工单分支。
    var base = ""
    var branch = ""
    /// 工单目录里没提交的文件数：不在 diff 里，合并时也不会带上（`mergeBranch` 会拒绝）。
    var uncommitted = 0
    /// 分支已经合并进主仓库当前分支（没有新提交）。
    var merged = false
    /// 失败原因（不是仓库、找不到分支……）。
    var error: String?

    var added: Int { files.reduce(0) { $0 + $1.added } }
    var removed: Int { files.reduce(0) { $0 + $1.removed } }
}

enum TaskDiff {
    static let maxLinesPerFile = 1500
    static let maxTotalLines = 20_000

    /// 解析 `git diff --no-color` 的统一格式输出。
    static func parse(_ text: String, maxLinesPerFile: Int = maxLinesPerFile, maxTotalLines: Int = maxTotalLines)
        -> (files: [FileDiff], truncated: Bool) {
        var files: [FileDiff] = []
        var current: FileDiff?
        var oldNo = 0, newNo = 0
        var total = 0
        var truncated = false

        func flush() { if let c = current { files.append(c) }; current = nil }
        func append(_ line: DiffLine) {
            guard var c = current else { return }
            if c.lines.count >= maxLinesPerFile || total >= maxTotalLines {
                c.truncated = true
                if total >= maxTotalLines { truncated = true }
            } else {
                c.lines.append(line)
                total += 1
            }
            current = c
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                flush()
                current = FileDiff(path: headerPath(line))
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("@@") {
                let (o, n) = hunkStarts(line)
                oldNo = o; newNo = n
                append(DiffLine(kind: .hunk, text: line))
            } else if line.hasPrefix("+++ ") || line.hasPrefix("--- ") {
                // 文件头：用 +++ b/… 定路径（比 diff --git 头可靠）；/dev/null 一侧不管。
                let p = String(line.dropFirst(4))
                if line.hasPrefix("+++ "), p != "/dev/null" { current?.path = strip(p) }
            } else if line.hasPrefix("new file mode") {
                current?.change = .added
            } else if line.hasPrefix("deleted file mode") {
                current?.change = .deleted
            } else if line.hasPrefix("rename from ") {
                current?.change = .renamed
                current?.oldPath = unquote(String(line.dropFirst("rename from ".count)))
            } else if line.hasPrefix("rename to ") {
                current?.path = unquote(String(line.dropFirst("rename to ".count)))
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                current?.change = .binary
            } else if line.hasPrefix("+") {
                current?.added += 1
                append(DiffLine(kind: .added, text: String(line.dropFirst()), newNo: newNo)); newNo += 1
            } else if line.hasPrefix("-") {
                current?.removed += 1
                append(DiffLine(kind: .removed, text: String(line.dropFirst()), oldNo: oldNo)); oldNo += 1
            } else if line.hasPrefix(" ") {
                append(DiffLine(kind: .context, text: String(line.dropFirst()), oldNo: oldNo, newNo: newNo)); oldNo += 1; newNo += 1
            } else if line.hasPrefix("\\") {
                append(DiffLine(kind: .meta, text: line))
            }
            // index / similarity / mode 等元信息行不显示。
        }
        flush()
        return (files, truncated)
    }

    /// `@@ -12,3 +14,5 @@ …` → (12, 14)。
    static func hunkStarts(_ line: String) -> (Int, Int) {
        func start(after mark: Character) -> Int {
            guard let i = line.firstIndex(of: mark) else { return 0 }
            let digits = line[line.index(after: i)...].prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
        return (start(after: "-"), start(after: "+"))
    }

    /// `diff --git a/x b/x` → `x`（文件头没有 +++ 时的兜底，比如纯改名、二进制）。
    private static func headerPath(_ line: String) -> String {
        let rest = String(line.dropFirst("diff --git ".count))
        if let r = rest.range(of: " b/", options: .backwards) { return unquote(String(rest[r.upperBound...])) }
        return unquote(rest)
    }

    private static func strip(_ p: String) -> String {
        // 路径带空格时 git 在 ---/+++ 行末加一个制表符（给 patch 用），去掉。
        var s = p
        if let tab = s.firstIndex(of: "\t") { s = String(s[..<tab]) }
        s = unquote(s)
        return s.hasPrefix("b/") || s.hasPrefix("a/") ? String(s.dropFirst(2)) : s
    }

    /// git 给带特殊字符的路径加双引号（`core.quotePath`）；加载时关了 quotePath，这里只去掉引号。
    private static func unquote(_ p: String) -> String {
        p.count >= 2 && p.hasPrefix("\"") && p.hasSuffix("\"") ? String(p.dropFirst().dropLast()) : p
    }

    /// 工单分支相对主仓库当前分支分叉点的改动（同 `git diff HEAD...branch`）。阻塞，在后台线程调。
    static func load(repo: String, branch: String, dir: String) -> TaskDiffResult {
        var r = TaskDiffResult(branch: branch)
        let git = "/usr/bin/git"
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !repo.isEmpty, FileManager.default.fileExists(atPath: repo) else {
            r.error = "目录不存在：\(repo)"; return r
        }
        let top = SuperagentTmux.exec(git, ["-C", repo, "rev-parse", "--show-toplevel"])
        guard top.status == 0 else { r.error = "\(repo) 不是 git 仓库"; return r }
        let toplevel = trimmed(top.out)
        func g(_ args: [String]) -> (status: Int32, out: String, err: String) {
            SuperagentTmux.exec(git, ["-C", toplevel, "-c", "core.quotePath=false"] + args)
        }
        guard g(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]).status == 0 else {
            r.error = "找不到分支 \(branch)"; return r
        }
        let base = g(["merge-base", "HEAD", branch])
        guard base.status == 0 else { r.error = "\(branch) 和当前分支没有共同的提交"; return r }
        let baseSHA = trimmed(base.out)
        r.base = String(baseSHA.prefix(8))
        r.merged = g(["merge-base", "--is-ancestor", branch, "HEAD"]).status == 0
        let diff = g(["diff", "--no-color", "--no-ext-diff", "-M", baseSHA, branch])
        guard diff.status == 0 else { r.error = "git diff 失败：\(trimmed(diff.err))"; return r }
        let parsed = parse(diff.out)
        r.files = parsed.files
        r.truncated = parsed.truncated
        if !dir.isEmpty, FileManager.default.fileExists(atPath: dir) {
            r.uncommitted = SuperagentTmux.exec(git, ["-C", dir, "status", "--porcelain"]).out
                .split(separator: "\n").filter { !$0.isEmpty }.count
        }
        return r
    }

    /// 能内嵌看改动的工单：交付了（结束或报了 ready）的开发工单、有分支（评审工单只审不改，不算）。按工单号。
    static func tickets(_ view: TaskView) -> [TicketView] {
        view.tickets.filter {
            $0.ticket.reviewOf == nil && !$0.ticket.branch.isEmpty
                && ($0.ticket.status == .done || $0.ticket.reportState == .ready || $0.ticket.isOpen)
        }
    }
}

extension AppModel {
    /// 「看改动」：打开任务卡并在卡上展开工单 `ticket` 的改动；已经在展开同一张就收起。
    func showTaskDiff(task: Int64, ticket: Int64) {
        if worklistSelected, worklistTaskID == task, !worklistShowsSettings {
            worklistDiffTicketID = worklistDiffTicketID == ticket ? nil : ticket
            return
        }
        openWorklist(task: task)
        worklistDiffTicketID = ticket
    }
}

// MARK: - 视图

/// 任务卡上的「改动」区：头（工单 · 分支 · 文件数 +/−，切换工单、去终端、收起）+ 按文件折叠的只读 diff。
struct TaskDiffSection: View {
    @Environment(AppModel.self) private var appModel
    let view: TaskView
    let ticketID: Int64
    @State private var result: TaskDiffResult?
    @State private var expanded: Set<String> = []

    private var ticket: TicketView? { view.ticket(ticketID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let r = result {
                content(r)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("读取改动…").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
        .task(id: ticketID) { await reload() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("工单 #\(ticketID) 的改动")
    }

    private func reload() async {
        result = nil
        guard let t = ticket?.ticket else { result = TaskDiffResult(error: "找不到工单 #\(ticketID)"); return }
        let repo = t.repo.isEmpty ? (t.dir.isEmpty ? view.task.scope : t.dir) : t.repo
        let r = await Task.detached(priority: .userInitiated) { TaskDiff.load(repo: repo, branch: t.branch, dir: t.dir) }.value
        // 文件少、改动小就全展开；否则全收起，人挑着看。
        let small = r.files.count <= 3 && r.files.reduce(0) { $0 + $1.lines.count } <= 300
        expanded = small ? Set(r.files.map(\.id)) : []
        result = r
    }

    private var header: some View {
        let others = TaskDiff.tickets(view)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("改动").font(.system(size: 12, weight: .semibold)).tracking(1).foregroundStyle(Theme.textTertiary)
                .accessibilityAddTraits(.isHeader)
            if others.count > 1 {
                Menu("工单 #\(ticketID)") {
                    ForEach(others, id: \.id) { t in
                        Button("工单 #\(t.id) · \(t.ticket.title)") { appModel.worklistDiffTicketID = t.id }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().font(.system(size: 13))
            } else {
                Text("工单 #\(ticketID)").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            if let b = ticket?.ticket.branch, !b.isEmpty {
                Text(b).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            if let r = result, r.error == nil, !r.files.isEmpty {
                Text("\(r.files.count) 个文件").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                Text("+\(r.added)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.Status.positive)
                Text("−\(r.removed)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.Status.error)
            }
            Spacer(minLength: 0)
            if let r = result, r.files.count > 1 {
                Button(expanded.count == r.files.count ? "全部收起" : "全部展开") {
                    expanded = expanded.count == r.files.count ? [] : Set(r.files.map(\.id))
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            if let report = ticket?.ticket.reportPath, !report.isEmpty {
                Button("报告") { NSWorkspace.shared.open(URL(fileURLWithPath: report)) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .help("打开报告 \(report)")
            }
            Button("终端") { appModel.goToTicket(ticketID) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .help("前往工单 #\(ticketID) 的终端")
            Button { appModel.worklistDiffTicketID = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                .help("收起改动").accessibilityLabel("收起改动")
        }
    }

    @ViewBuilder private func content(_ r: TaskDiffResult) -> some View {
        if let e = r.error {
            Text(e).font(.system(size: 13)).foregroundStyle(Theme.Status.error)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if r.files.isEmpty {
                    Text(r.merged ? "\(r.branch) 已经合并进当前分支，没有待合并的改动。" : "\(r.branch) 相对分叉点 \(r.base) 没有改动。")
                        .font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                }
                if r.uncommitted > 0 {
                    Text("工单目录还有 \(r.uncommitted) 个没提交的文件，不在这里，合并时也不会带上；打回让执行者提交。")
                        .font(.system(size: 12)).foregroundStyle(Theme.Status.attention)
                }
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(r.files) { f in fileBlock(f) }
                }
                if r.truncated {
                    Text("改动太多，后面的文件没显示；完整改动去终端看（git diff \(r.base) \(r.branch)）。")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private func fileBlock(_ f: FileDiff) -> some View {
        let open = expanded.contains(f.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { expanded.remove(f.id) } else { expanded.insert(f.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary).frame(width: 12)
                    Text(f.change.rawValue).font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(f.change == .deleted ? Theme.Status.error : f.change == .added ? Theme.Status.positive : Theme.textTertiary)
                        .frame(width: 12)
                    Text(f.oldPath.map { "\($0) → \(f.path)" } ?? f.path)
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).truncationMode(.head).help(f.path)
                    Spacer(minLength: 8)
                    if f.change != .binary {
                        Text("+\(f.added)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.Status.positive)
                        Text("−\(f.removed)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.Status.error)
                    }
                }
                .padding(.vertical, 7).padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(f.path)，增加 \(f.added) 行，删除 \(f.removed) 行，\(open ? "收起" : "展开")")
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    if f.change == .binary {
                        Text("二进制文件，不显示内容。").font(.system(size: 12)).foregroundStyle(Theme.textTertiary).padding(8)
                    } else if f.lines.isEmpty {
                        Text(f.change == .renamed ? "只改了名。" : "没有文本改动（可能只改了权限）。")
                            .font(.system(size: 12)).foregroundStyle(Theme.textTertiary).padding(8)
                    }
                    ForEach(Array(f.lines.enumerated()), id: \.offset) { _, l in DiffLineRow(line: l) }
                    if f.truncated {
                        Text("这个文件改动太大，只显示前 \(f.lines.count) 行；完整的去终端看。")
                            .font(.system(size: 12)).foregroundStyle(Theme.textTertiary).padding(8)
                    }
                }
                .background(Theme.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border.opacity(0.7), lineWidth: 1))
                .textSelection(.enabled)
            }
        }
    }
}

/// 一行：旧行号 · 新行号 · 标记 · 文字（等宽，自动换行）。增绿删红，hunk 头石灰底。
private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            number(line.oldNo)
            number(line.newNo)
            Text(mark).frame(width: 14, alignment: .center).foregroundStyle(tint)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .hunk || line.kind == .meta ? Theme.textTertiary : Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .padding(.trailing, 8)
        .background(background)
    }

    private var mark: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        default: return " "
        }
    }

    private var tint: Color {
        switch line.kind {
        case .added: return Theme.Status.positive
        case .removed: return Theme.Status.error
        default: return Theme.textTertiary
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: return Theme.Status.positive.opacity(0.10)
        case .removed: return Theme.Status.error.opacity(0.09)
        case .hunk: return Theme.chrome
        default: return .clear
        }
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "").foregroundStyle(Theme.Colors.pewter)
            .frame(width: 40, alignment: .trailing).padding(.trailing, 6)
    }
}
