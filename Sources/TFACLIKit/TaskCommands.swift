import Foundation
import SuperagentCore

/// `tfa task …`：工作清单（需求文档 §6）。任务号接受 `A-12` / `a12` / `12`（注意事项 B-09）。
/// 谁来做只由人决定（注意事项 E-01 / H-01）：主管终端（`TFA_ROLE=router`）只能 add / list / show，执行终端一律不能改清单。
extension TFACommand {
    static func task(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        guard let sub = args.first else {
            throw CLIError.usage("缺少子命令（add / list / show / relate / assign / done / approve / reject / cancel）", command: "task")
        }
        let rest = args.dropFirst()
        switch sub {
        case "add": return try taskAdd(rest, c)
        case "list": return try taskList(rest, c)
        case "show": return try taskShow(rest, c)
        case "relate": return try taskRelate(rest, c)
        case "assign": return try taskAssign(rest, c)
        case "done": return try taskDone(rest, c)
        case "approve": return try taskApprove(rest, c)
        case "reject": return try taskReject(rest, c)
        case "cancel": return try taskCancel(rest, c)
        case "-h", "--help": throw CLIError.help("task")
        default: throw CLIError.usage("未知的子命令 task \(sub)", command: "task")
        }
    }

    // MARK: - 建任务（人 / 主管）

    private static func taskAdd(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "task add"
        let a = try parse(args, cmd, values: ["title", "request", "scope", "item", "items", "suggest", "assign-all", "priority", "due", "dep", "relate", "note"],
                          repeatable: ["item", "suggest", "dep", "relate"])
        try noPositional(a, cmd)
        try c.requireNotWorker(cmd)
        guard let title = a.value("title") else { throw CLIError.usage("缺少 --title（任务标题）", command: cmd) }
        var items = a.values["item"] ?? []
        if let v = a.value("items") {
            guard v == "-" else { throw CLIError.usage("--items 只支持 -（从 stdin 读，一行一项）：\(v)", command: cmd) }
            items += itemLines(c.piped() ?? "")
        }
        // 原文省略时从 stdin 读；stdin 已被 --items - 用掉时原文只能用 --request（空就用标题）。
        let request = a.value("request") ?? (a.value("items") == nil ? c.piped() : nil) ?? ""
        let priority = try a.value("priority").map { try parsePriority($0, cmd) } ?? TaskPriority.medium
        let due = try a.value("due").map { try parseDue($0, cmd) }
        let deps = try (a.values["dep"] ?? []).flatMap { try taskIDs($0, cmd, flag: "--dep") }
        let related = try parseKnowledgeRefs(a.values["relate"] ?? [], cmd, flag: "--relate")
        let scope = try a.value("scope").map(c.directory) ?? ""
        // 建议只是「谁来做」的默认值，不分配、不建工单（注意事项 E-02）；写法先查，角色名要在库里查。
        let count = max(items.count, 1)
        var suggestions: [Int: String] = [:]
        for raw in a.values["suggest"] ?? [] {
            for pair in raw.split(whereSeparator: { $0 == "," || $0 == "，" }) {
                let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, let ord = Int(parts[0]), ord > 0, !parts[1].isEmpty else {
                    throw CLIError.usage("--suggest 要写成 序号=角色（如 3=助理,4=开发）：\(pair)", command: cmd)
                }
                guard ord <= count else { throw CLIError.usage("--suggest 的第 \(ord) 项不存在（清单只有 \(count) 项）", command: cmd) }
                suggestions[ord] = parts[1]
            }
        }
        let engine = try c.engine()
        for name in suggestions.values { _ = try assignee(engine, name, flag: "--suggest") }
        let assignAll = try a.value("assign-all").map { try assignee(engine, $0, flag: "--assign-all") }
        let by = c.isRouter ? "主管" : "你"
        let task = try engine.createTask(.init(title: title, request: request, source: c.isRouter ? .router : .manual, scope: scope,
                                               items: items, suggestions: suggestions, priority: priority, due: due, deps: deps,
                                               related: related, note: a.value("note") ?? "", by: by))
        var out = "已加入你的清单：\(task.label)「\(task.title)」，\(count) 项"
        if !related.isEmpty { out += "（已关联经验 \(related.map(\.label).joined(separator: "、"))）" }
        if let (to, role) = assignAll {
            // 人明确说「直接让 Agent 做」：建完就把全部项交出去（§5.4）。
            let ords = try engine.store.items(task.id).map(\.ord)
            let tickets = try engine.assign(task.id, ords.map { SuperagentEngine.Allocation(ord: $0, to: to) }, oneTicket: true, by: by)
            out += to == .you ? "，全部标为你的。\n" : "，全部交给「\(to.label)」：\(ticketsPhrase(tickets, role))。\n"
        } else {
            out += "，去定谁来做。\n"
        }
        return Outcome(out: out, changed: true)
    }

    /// `--items -` 的 stdin：一行一项；去掉行首的编号或项目符号（`1.`、`-`），空行跳过。
    static func itemLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var s = line.trimmingCharacters(in: .whitespaces)
            if let r = s.range(of: #"^(\d+[.、)]|[-*•])\s*"#, options: .regularExpression) { s.removeSubrange(r) }
            return s.isEmpty ? nil : s
        }
    }

    // MARK: - 读

    private static func taskList(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "task list"
        let a = try parse(args, cmd, values: ["scope", "stage"], flags: ["needs-you"])
        try noPositional(a, cmd)
        try requireNotWorkerRead(c, cmd)
        let scope = a.value("scope").map { resolve($0, cwd: c.cwd) ?? $0 }
        return Outcome(out: try Views.tasks(c.engine(), needsYou: a.flags.contains("needs-you"), scope: scope, stage: a.value("stage")))
    }

    private static func taskShow(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "task show"
        let a = try parse(args, cmd)
        let id = try taskID(onePositional(a, cmd, "任务号"), cmd)
        try requireNotWorkerRead(c, cmd)
        let engine = try c.engine()
        _ = try requireTask(engine, id)
        return Outcome(out: try Views.task(engine, id))
    }

    private static func taskRelate(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "task relate"
        let a = try parse(args, cmd, flags: ["remove"])
        try c.requireNotWorker(cmd)
        guard a.positional.count >= 2 else {
            throw CLIError.usage("用法：tfa task relate <任务号 A-20> <关联的 A-12 或 K-3>... [--remove]", command: cmd)
        }
        let id = try taskID(a.positional[0], cmd)
        let refs = try parseKnowledgeRefs(Array(a.positional.dropFirst()), cmd, flag: "关联编号")
        let who = c.isRouter ? "主管" : "你"
        let remove = a.flags.contains("remove")
        let changed = try c.engine().updateTaskKnowledgeLinks(id, refs: refs, remove: remove, by: who)
        if changed.isEmpty {
            return Outcome(out: "任务 A-\(id) 的关联经验没有变化。\n")
        }
        let labels = changed.map { "\($0.displayLabel)「\($0.title)」" }.joined(separator: "、")
        return Outcome(out: "已为任务 A-\(id) \(remove ? "移除" : "关联")历史经验：\(labels)。\n", changed: true)
    }

    // MARK: - 清单里的决定（只给人）

    private static func taskAssign(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "task assign"
        let a = try parse(args, cmd, values: ["item", "to"], flags: ["one-ticket", "per-item"], repeatable: ["item"])
        let id = try taskID(onePositional(a, cmd, "任务号"), cmd)
        try c.requirePerson(cmd)
        let ords = try ords(a, cmd)
        guard let to = a.value("to") else { throw CLIError.usage("缺少 --to（你，或 tfa read roles 里的角色名）", command: cmd) }
        if a.flags.contains("one-ticket"), a.flags.contains("per-item") { throw CLIError.usage("--one-ticket 和 --per-item 只能选一个", command: cmd) }
        let engine = try c.engine()
        let task = try requireTask(engine, id)
        let (who, role) = try assignee(engine, to, flag: "--to")
        let tickets = try engine.assign(id, ords.map { SuperagentEngine.Allocation(ord: $0, to: who) }, oneTicket: !a.flags.contains("per-item"), by: "你")
        let which = "\(task.label) 第 \(ords.map(String.init).joined(separator: "、")) 项"
        if who == .you { return Outcome(out: "已标为你的：\(which)。\n", changed: true) }
        return Outcome(out: "已交给「\(who.label)」：\(which) → \(ticketsPhrase(tickets, role))。\n", changed: true)
    }

    private static func taskDone(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "task done"
        let a = try parse(args, cmd, values: ["item"], flags: ["undo"], repeatable: ["item"])
        let id = try taskID(onePositional(a, cmd, "任务号"), cmd)
        try c.requirePerson(cmd)
        let ords = try ords(a, cmd)
        let engine = try c.engine()
        let before = try requireTask(engine, id)
        let undo = a.flags.contains("undo")
        for ord in ords { try engine.setItemDone(id, ord: ord, done: !undo, by: "你") }
        let after = try requireTask(engine, id)
        let items = try engine.store.items(id)
        var out = "\(undo ? "已取消勾选" : "已勾掉")：\(before.label) 第 \(ords.map(String.init).joined(separator: "、")) 项（\(items.filter { $0.status == .done }.count)/\(items.count)）。"
        if after.stage != before.stage || after.status != before.status {
            out += after.isOpen ? "任务进入「\(after.stage)」。" : "任务\(after.status.label)。"
        }
        return Outcome(out: out + "\n", changed: true)
    }

    private static func taskApprove(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "task approve"
        let a = try parse(args, cmd)
        let id = try taskID(onePositional(a, cmd, "任务号"), cmd)
        try c.requirePerson(cmd)
        let engine = try c.engine()
        let task = try requireTask(engine, id)
        try engine.approveTask(id, by: "你")
        return Outcome(out: "已通过 \(task.label)「\(task.title)」：任务完成。\n", changed: true)
    }

    private static func taskReject(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "task reject"
        let a = try parse(args, cmd, values: ["reason"])
        let id = try taskID(onePositional(a, cmd, "任务号"), cmd)
        try c.requirePerson(cmd)
        guard let reason = a.value("reason") ?? c.piped() else { throw CLIError.usage("缺少 --reason（打回意见；也可从 stdin 传入）", command: cmd) }
        let engine = try c.engine()
        let task = try requireTask(engine, id)
        try engine.rejectTask(id, text: reason, by: "你")
        return Outcome(out: "已打回 \(task.label)「\(task.title)」：回到进行中，意见已送给原工单（没有工单的成为新清单项）。\n", changed: true)
    }

    private static func taskCancel(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "task cancel"
        let a = try parse(args, cmd)
        let id = try taskID(onePositional(a, cmd, "任务号"), cmd)
        try c.requirePerson(cmd)
        let engine = try c.engine()
        let task = try requireTask(engine, id)
        try engine.cancelTask(id, by: "你")
        return Outcome(out: "已取消 \(task.label)「\(task.title)」，名下打开的工单一并停止。\n", changed: true)
    }

    // MARK: - 参数

    private static func taskID(_ s: String, _ command: String) throws -> Int64 {
        guard let id = WorkTask.parseID(s) else { throw CLIError.usage("任务号要写成 A-12 或 12：\(s)", command: command) }
        return id
    }

    /// `--dep A-11,A-12` / 重复的 `--dep`。
    private static func taskIDs(_ raw: String, _ command: String, flag: String) throws -> [Int64] {
        try raw.split(whereSeparator: { $0 == "," || $0 == "，" }).map { part in
            guard let id = WorkTask.parseID(String(part)) else { throw CLIError.usage("\(flag) 要写任务号（如 A-11）：\(raw)", command: command) }
            return id
        }
    }

    /// `--item 3,4 --item 5` → [3, 4, 5]（清单项序号 `ord`，从 1 起，去重）。
    private static func ords(_ a: Args, _ command: String) throws -> [Int] {
        guard let raws = a.values["item"], !raws.isEmpty else { throw CLIError.usage("缺少 --item（清单项序号，如 3,4）", command: command) }
        var out: [Int] = []
        for raw in raws {
            for part in raw.split(whereSeparator: { $0 == "," || $0 == "，" }) {
                guard let n = Int(part.trimmingCharacters(in: .whitespaces)), n > 0 else {
                    throw CLIError.usage("--item 要写清单项序号（如 3,4）：\(raw)", command: command)
                }
                if !out.contains(n) { out.append(n) }
            }
        }
        guard !out.isEmpty else { throw CLIError.usage("--item 不能为空", command: command) }
        return out
    }

    private static func parsePriority(_ s: String, _ command: String) throws -> TaskPriority {
        switch s {
        case "高", "high": return .high
        case "中", "medium": return .medium
        case "低", "low": return .low
        default: throw CLIError.usage("--priority 只能是 高|中|低：\(s)", command: command)
        }
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()

    /// `YYYY-MM-DD` → 当天 0 点（本地时区）。
    private static func parseDue(_ s: String, _ command: String) throws -> Double {
        guard s.count == 10, let d = dayFormat.date(from: s) else { throw CLIError.usage("--due 要写成 YYYY-MM-DD：\(s)", command: command) }
        return d.timeIntervalSince1970
    }

    /// `你` → 你；角色名 → 该角色的 Agent；都不是就报错并列出现有角色（注意事项 E-02）。
    private static func assignee(_ engine: SuperagentEngine, _ name: String, flag: String) throws -> (Assignee, Role?) {
        if name == "你" { return (.you, nil) }
        guard let role = try engine.store.role(name) else {
            throw SuperagentError("\(flag) 里没有角色「\(name)」：写「你」或下面的角色名。\n" + (try Views.roles(engine)).trimmingCharacters(in: .newlines))
        }
        return (.agent(role: role.name), role)
    }

    /// 执行终端看不到别人的项是谁在做、别人的工单号（注意事项 D-06）：任务只能从 `tfa read ticket` 看自己负责的部分。
    private static func requireNotWorkerRead(_ c: Context, _ command: String) throws {
        if c.inWorkerTerminal { throw SuperagentError("执行终端用 tfa read ticket 看自己负责的清单项，不能用 tfa \(command)") }
    }

    private static func requireTask(_ engine: SuperagentEngine, _ id: Int64) throws -> WorkTask {
        guard let t = try engine.store.task(id) else { throw SuperagentError("任务 A-\(id) 不存在") }
        return t
    }

    /// `工单 #13，执行终端即将启动` / `工单 #13，交给常驻「助理」，它空闲时送达`。
    private static func ticketsPhrase(_ tickets: [Ticket], _ role: Role?) -> String {
        guard !tickets.isEmpty else { return "没有建工单" }
        let ids = tickets.map { "#\($0.id)" }.joined(separator: "、")
        let target = role?.standing == true ? "交给常驻「\(role!.name)」，它空闲时送达" : "执行终端即将启动"
        return "工单 \(ids)，\(target)"
    }
}
