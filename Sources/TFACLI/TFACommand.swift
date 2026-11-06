import Foundation
import SuperagentCore

/// `tfa` 的全部逻辑：解析参数 → 调 `SuperagentEngine`（写）或读视图 → 返回要打印的内容。
/// 不碰进程级状态（环境、cwd、stdin 由 main.swift 传入；打印、通知、退出码也由它处理），便于测试。
/// 输出给 LLM agent 读：短、中文、无歧义。
enum TFACommand {
    struct Outcome: Equatable {
        var code: Int32 = 0
        var out = ""
        var err = ""
        /// 写入成功：main 发 Darwin 通知，App 立刻跑一轮 Pass。
        var changed = false
    }

    /// `stdin`：管道 / heredoc 传入的文本；stdin 是终端或没有数据时返回 nil。只在缺少必需的长文本时才调用。
    static func run(_ args: [String], env: [String: String], cwd: String, stdin: @escaping () -> String?) -> Outcome {
        let c = Context(env: env, cwd: cwd, stdin: stdin)
        do {
            return try dispatch(args[...], c)
        } catch CLIError.help(let command) {
            return Outcome(out: help(command))
        } catch CLIError.usage(let message, let command) {
            let lines = usageLines(command)
            let usage = lines.count == 1 ? "用法：\(lines[0])" : "用法：\n" + lines.map { "  " + $0 }.joined(separator: "\n")
            return Outcome(code: 2, err: "tfa: \(message)\n\(usage)\n")
        } catch let e as SuperagentError {
            return Outcome(code: 1, err: "tfa: \(e.message)\n")
        } catch {
            return Outcome(code: 1, err: "tfa: \(error)\n")
        }
    }

    struct Context {
        let env: [String: String]
        let cwd: String
        let stdin: () -> String?

        /// 每条命令开一个连接（CLI 是短进程）。`TFA_HOME` 取自传入的环境。
        func engine() throws -> SuperagentEngine {
            SuperagentEngine(store: try SuperagentStore(url: SuperagentPaths.home(environment: env).appendingPathComponent("superagent.db")))
        }

        /// 省略的长文本从 stdin 读；空白视为没有。
        func piped() -> String? {
            guard let s = stdin(), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }

        /// 执行者命令的工单：`--ticket N`，否则 `$TFA_TICKET`。
        func workerTicket(_ a: Args, _ command: String) throws -> Int64 {
            if let v = a.value("ticket") { return try ticketID(v, command) }
            guard let v = env["TFA_TICKET"], !v.isEmpty else { throw SuperagentError("不在工单终端里（没有 TFA_TICKET）") }
            guard let id = parseTicketID(v) else { throw SuperagentError("TFA_TICKET 不是工单号：\(v)") }
            return id
        }

        /// 绝对、解析过符号链接的已有目录。
        func directory(_ path: String) throws -> String {
            guard let p = resolve(path, cwd: cwd) else { throw SuperagentError("目录不存在：\(path)") }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else {
                throw SuperagentError("不是目录：\(path)")
            }
            return p
        }
    }

    enum CLIError: Error {
        /// 命令行本身不成立（未知命令 / 参数、缺参数、取值不合法）→ 退出码 2，附该子命令的用法。
        case usage(String, command: String)
        case help(String)
    }

    // MARK: - 分发

    private static func dispatch(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        guard let head = args.first else { return Outcome(out: help("")) }
        let rest = args.dropFirst()
        switch head {
        case "help", "-h", "--help": return Outcome(out: help(""))
        case "read": return try read(rest, c)
        case "route":
            guard let sub = rest.first else { throw CLIError.usage("缺少子命令（accept / attach / stop / ignore）", command: "route") }
            let more = rest.dropFirst()
            switch sub {
            case "accept": return try accept(more, c)
            case "attach": return try attach(more, c)
            case "stop": return try stop(more, c)
            case "ignore": return try ignore(more, c)
            case "-h", "--help": throw CLIError.help("route")
            default: throw CLIError.usage("未知的子命令 route \(sub)", command: "route")
            }
        case "request-status": return try requestStatus(rest, c)
        case "retry": return try retry(rest, c)
        case "eval":
            guard let sub = rest.first else { throw CLIError.usage("缺少子命令 decide", command: "eval") }
            switch sub {
            case "decide": return try decide(rest.dropFirst(), c)
            case "-h", "--help": throw CLIError.help("eval")
            default: throw CLIError.usage("未知的子命令 eval \(sub)", command: "eval")
            }
        case "ack": return try ack(rest, c)
        case "report": return try report(rest, c)
        case "handback": return try handback(rest, c)
        default:
            return Outcome(code: 2, err: "tfa: 未知命令 \(head)\n\n" + help(""))
        }
    }

    // MARK: - 读

    private static func read(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let a = try parse(args, "read", values: ["ticket"])
        let resource = a.positional.first
        if resource != "ticket", a.positional.count > 1 { throw CLIError.usage("多余的参数：\(a.positional.dropFirst().joined(separator: " "))", command: "read") }
        switch resource {
        case nil:
            // 执行终端里（有 TFA_TICKET）读本工单；主管读概览。
            if a.value("ticket") != nil || !(c.env["TFA_TICKET"] ?? "").isEmpty {
                return Outcome(out: try Views.ticket(c.engine(), c.workerTicket(a, "read")))
            }
            return Outcome(out: try Views.overview(c.engine()))
        case "ticket":
            guard a.positional.count <= 2 else { throw CLIError.usage("多余的参数：\(a.positional.dropFirst(2).joined(separator: " "))", command: "read") }
            let id: Int64
            if a.positional.count == 2 {
                id = try ticketID(a.positional[1], "read")
            } else if a.value("ticket") != nil || !(c.env["TFA_TICKET"] ?? "").isEmpty {
                id = try c.workerTicket(a, "read")
            } else {
                throw CLIError.usage("缺少工单号", command: "read")
            }
            return Outcome(out: try Views.ticket(c.engine(), id))
        case "candidates": return Outcome(out: try Views.candidates(c.engine()))
        case "rules": return Outcome(out: try Views.rules(c.engine()))
        default:
            throw CLIError.usage("未知的资源 \(resource!)（可用：ticket、candidates、rules）", command: "read")
        }
    }

    // MARK: - 主管

    private static func accept(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "route accept"
        let a = try parse(args, cmd, values: ["title", "request", "dir", "note", "trigger"], flags: ["no-worktree"])
        try noPositional(a, cmd)
        guard let title = a.value("title") else { throw CLIError.usage("缺少 --title（工单标题）", command: cmd) }
        let trigger = a.value("trigger").map(triggerID)
        // 接候选时请求原文和目录可以省略（沿用候选的）。
        let request = a.value("request") ?? (trigger == nil ? c.piped() : nil)
        guard request != nil || trigger != nil else { throw CLIError.usage("缺少 --request（请求原文；也可从 stdin 传入）", command: cmd) }
        let repo = try a.value("dir").map(c.directory) ?? (trigger == nil ? c.directory(c.cwd) : "")
        let engine = try c.engine()
        let existed = try trigger.flatMap { try engine.store.trigger($0)?.ticketID } != nil
        let t = try engine.accept(.init(title: title, request: request ?? "", repo: repo, note: a.value("note") ?? "",
                                        worktree: a.flags.contains("no-worktree") ? false : nil, triggerID: trigger))
        if existed, let trigger { return Outcome(out: "候选 \(trigger) 已经接过单：#\(t.id)「\(t.title)」，没有重复建单。\n") }
        return Outcome(out: "已接单 #\(t.id)「\(t.title)」：执行终端即将启动。\n", changed: true)
    }

    private static func attach(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "route attach"
        let a = try parse(args, cmd, values: ["request"])
        let id = try ticketID(onePositional(a, cmd, "工单号"), cmd)
        guard let text = a.value("request") ?? c.piped() else { throw CLIError.usage("缺少 --request（要转达的原文；也可从 stdin 传入）", command: cmd) }
        let engine = try c.engine()
        let wasOpen = try engine.store.ticket(id)?.isOpen ?? true
        try engine.attach(id, text: text)
        return Outcome(out: "已转达给 \(try name(engine, id))\(wasOpen ? "" : "（工单已重新打开）")：会送进它的执行终端。\n", changed: true)
    }

    private static func stop(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "route stop"
        let a = try parse(args, cmd, values: ["reason"])
        let id = try ticketID(onePositional(a, cmd, "工单号"), cmd)
        let engine = try c.engine()
        try engine.stop(id, by: "主管", reason: a.value("reason") ?? "")
        return Outcome(out: "已停止 \(try name(engine, id))。\n", changed: true)
    }

    private static func ignore(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "route ignore"
        let a = try parse(args, cmd, values: ["trigger", "reason"])
        try noPositional(a, cmd)
        guard let trigger = a.value("trigger").map(triggerID) else { throw CLIError.usage("缺少 --trigger（候选号，如 t3）", command: cmd) }
        guard let reason = a.value("reason") else { throw CLIError.usage("缺少 --reason（不接的原因）", command: cmd) }
        try c.engine().ignore(trigger: trigger, reason: reason)
        return Outcome(out: "已忽略候选 \(trigger)。\n", changed: true)
    }

    private static func requestStatus(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "request-status"
        let a = try parse(args, cmd)
        let id = try ticketID(onePositional(a, cmd, "工单号"), cmd)
        let engine = try c.engine()
        try engine.requestStatus(id)
        return Outcome(out: "已请 \(try name(engine, id))回报状态。\n", changed: true)
    }

    private static func retry(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "retry"
        let a = try parse(args, cmd)
        let id = try ticketID(onePositional(a, cmd, "工单号"), cmd)
        let engine = try c.engine()
        try engine.retry(id, by: "主管")
        return Outcome(out: "已重试 \(try name(engine, id))：会重新派给执行终端。\n", changed: true)
    }

    private static func decide(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "eval decide"
        let a = try parse(args, cmd, values: ["trigger", "version", "rule", "decision", "title", "reason"], repeatable: ["rule"])
        try noPositional(a, cmd)
        guard let trigger = a.value("trigger").map(triggerID) else { throw CLIError.usage("缺少 --trigger（候选号，如 t3）", command: cmd) }
        guard let version = a.value("version") else { throw CLIError.usage("缺少 --version（tfa read rules 里的规则版本）", command: cmd) }
        var verdicts: [String: RuleVerdict] = [:]
        for raw in a.values["rule"] ?? [] {
            let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, let v = RuleVerdict(rawValue: parts[1]) else {
                throw CLIError.usage("--rule 要写成 规则id=match|no_match|requires_design_decision：\(raw)", command: cmd)
            }
            guard verdicts.updateValue(v, forKey: parts[0]) == nil else { throw CLIError.usage("规则 \(parts[0]) 判断了两次", command: cmd) }
        }
        let accept: Bool
        switch a.value("decision") {
        case "accept": accept = true
        case "ignore": accept = false
        case nil: throw CLIError.usage("缺少 --decision accept|ignore", command: cmd)
        case let d?: throw CLIError.usage("--decision 只能是 accept 或 ignore：\(d)", command: cmd)
        }
        guard let reason = a.value("reason") else { throw CLIError.usage("缺少 --reason（一句研判理由）", command: cmd) }
        let engine = try c.engine()
        let ticket = try engine.decide(.init(triggerID: trigger, version: version, verdicts: verdicts, accept: accept,
                                             title: a.value("title") ?? "", reason: reason))
        if let t = ticket { return Outcome(out: "已接单 #\(t.id)「\(t.title)」（规则研判通过）：执行终端即将启动。\n", changed: true) }
        if accept {
            return Outcome(out: "只观察：候选 \(trigger) 记为 would_accept，没有建工单（接单模式「\(try engine.store.acceptMode().label)」）。\n", changed: true)
        }
        return Outcome(out: "已忽略候选 \(trigger)。\n", changed: true)
    }

    // MARK: - 执行者

    private static func ack(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let a = try parse(args, "ack", values: ["ticket"])
        let text = a.positional.joined(separator: " ")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.usage("缺少确认内容：一句话说清在改什么、预期结果", command: "ack")
        }
        let id = try c.workerTicket(a, "ack")
        let first = try c.engine().ack(id, text: text)
        return first ? Outcome(out: "已确认。\n", changed: true) : Outcome(out: "已确认过，不再重复。\n")
    }

    private static func report(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "report"
        let a = try parse(args, cmd, values: ["ticket", "state", "summary", "ask", "report"])
        try noPositional(a, cmd)
        guard let raw = a.value("state") else { throw CLIError.usage("缺少 --state", command: cmd) }
        guard let state = ReportState(rawValue: raw) else {
            throw CLIError.usage("--state 只能是 progress|ready|blocked|failed|dropped：\(raw)", command: cmd)
        }
        guard let summary = a.value("summary") else { throw CLIError.usage("缺少 --summary（一句话结果）", command: cmd) }
        let id = try c.workerTicket(a, cmd)
        let path = try a.value("report").map { p -> String in
            guard let r = resolve(p, cwd: c.cwd) else { throw SuperagentError("报告文件不存在：\(p)") }
            return r
        }
        let ask = a.value("ask")
        try c.engine().report(id, .init(state: state, summary: summary, ask: ask, reportPath: path))
        let asked = !(ask ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let tail = state == .dropped ? "：工单已结束，停止工作。" : asked ? "，问题会转给人。" : "。"
        return Outcome(out: "已回报 \(state.rawValue)\(tail)\n", changed: true)
    }

    private static func handback(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "handback"
        let a = try parse(args, cmd, values: ["ticket", "reason", "request"])
        try noPositional(a, cmd)
        guard let reason = a.value("reason") else { throw CLIError.usage("缺少 --reason（一句退回原因）", command: cmd) }
        guard let request = a.value("request") ?? c.piped() else {
            throw CLIError.usage("缺少 --request（要退回的请求原文；也可从 stdin 传入）", command: cmd)
        }
        let id = try c.workerTicket(a, cmd)
        let trigger = try c.engine().handback(id, request: request, reason: reason)
        return Outcome(out: "已退回：候选 \(trigger)，由主管决定是否接单；不要在本工单里做它。\n", changed: true)
    }

    // MARK: - 参数

    struct Args {
        var positional: [String] = []
        var values: [String: [String]] = [:]
        var flags: Set<String> = []
        func value(_ name: String) -> String? { values[name]?.last }
    }

    /// `--flag 值` 和 `--flag=值`；值总是取下一个参数（可以以 - 开头）；`--` 之后全是位置参数。
    static func parse(_ args: ArraySlice<String>, _ command: String, values valued: Set<String> = [],
                      flags: Set<String> = [], repeatable: Set<String> = []) throws -> Args {
        var a = Args()
        var i = args.startIndex
        var positionalOnly = false
        while i < args.endIndex {
            let arg = args[i]
            i += 1
            if positionalOnly || (!arg.hasPrefix("--") && arg != "-h") { a.positional.append(arg); continue }
            if arg == "--" { positionalOnly = true; continue }
            if arg == "-h" || arg == "--help" { throw CLIError.help(command) }
            var name = String(arg.dropFirst(2))
            var inline: String?
            if let eq = name.firstIndex(of: "=") {
                inline = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
            }
            if flags.contains(name) {
                guard inline == nil else { throw CLIError.usage("--\(name) 不带值", command: command) }
                a.flags.insert(name)
            } else if valued.contains(name) {
                let value: String
                if let inline {
                    value = inline
                } else {
                    guard i < args.endIndex else { throw CLIError.usage("--\(name) 缺少值", command: command) }
                    value = args[i]
                    i += 1
                }
                if a.values[name] != nil, !repeatable.contains(name) { throw CLIError.usage("--\(name) 只能给一次", command: command) }
                a.values[name, default: []].append(value)
            } else {
                throw CLIError.usage("未知参数 --\(name)", command: command)
            }
        }
        return a
    }

    private static func noPositional(_ a: Args, _ command: String) throws {
        guard a.positional.isEmpty else { throw CLIError.usage("多余的参数：\(a.positional.joined(separator: " "))", command: command) }
    }

    private static func onePositional(_ a: Args, _ command: String, _ what: String) throws -> String {
        guard let first = a.positional.first else { throw CLIError.usage("缺少\(what)", command: command) }
        guard a.positional.count == 1 else { throw CLIError.usage("多余的参数：\(a.positional.dropFirst().joined(separator: " "))", command: command) }
        return first
    }

    /// `12` 或 `#12`。
    static func parseTicketID(_ s: String) -> Int64? {
        let digits = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard let id = Int64(digits), id > 0 else { return nil }
        return id
    }

    private static func ticketID(_ s: String, _ command: String) throws -> Int64 {
        guard let id = parseTicketID(s) else { throw CLIError.usage("工单号要写成数字：\(s)", command: command) }
        return id
    }

    /// `t3`；只写数字时补上 t。
    static func triggerID(_ s: String) -> String {
        !s.isEmpty && s.allSatisfy(\.isNumber) ? "t" + s : s
    }

    /// 绝对、解析过符号链接的路径；不存在 → nil。相对路径按 `cwd` 解析。
    static func resolve(_ path: String, cwd: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
        guard let p = realpath(absolute, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    private static func name(_ engine: SuperagentEngine, _ id: Int64) throws -> String {
        "#\(id)「\(try engine.store.ticket(id)?.title ?? "")」"
    }

    // MARK: - 用法

    private struct Entry {
        let command: String
        let usage: String
        let about: String
        let worker: Bool
    }

    private static let entries: [Entry] = [
        Entry(command: "read", usage: "tfa read", about: "概览：需要你的工单 → 其他打开的工单 → 待决定的候选", worker: false),
        Entry(command: "read ticket", usage: "tfa read ticket [<id>]", about: "工单详情：原始请求、全部消息、最新回报、时间线", worker: false),
        Entry(command: "read candidates", usage: "tfa read candidates", about: "待决定的候选（退回 / 定时 / 推断），附接单或研判命令", worker: false),
        Entry(command: "read rules", usage: "tfa read rules", about: "接单模式、规则版本、启用的规则", worker: false),
        Entry(command: "route accept",
              usage: "tfa route accept --title T [--request 原文] [--dir 目录] [--note 备注] [--no-worktree] [--trigger tN]",
              about: "接单并启动执行终端。--dir 默认当前目录；接候选（--trigger）时可省略 --request / --dir", worker: false),
        Entry(command: "route attach", usage: "tfa route attach <id> [--request 原文]", about: "把人的明确请求转达给已有工单", worker: false),
        Entry(command: "route stop", usage: "tfa route stop <id> [--reason 原因]", about: "停止工单（只在人明确要求时）", worker: false),
        Entry(command: "route ignore", usage: "tfa route ignore --trigger tN --reason 原因", about: "不接一个候选", worker: false),
        Entry(command: "request-status", usage: "tfa request-status <id>", about: "请停下没回报的执行者回报状态", worker: false),
        Entry(command: "retry", usage: "tfa retry <id>", about: "重试受阻 / 失败 / 送达失败 / 停下未回报 / 空闲的工单", worker: false),
        Entry(command: "eval decide",
              usage: "tfa eval decide --trigger tN --version V --rule id=match|no_match|requires_design_decision [--rule …] --decision accept|ignore [--title T] --reason 原因",
              about: "研判推断出的候选：每条启用的规则判断一次；方向不明确就 requires_design_decision 并 ignore", worker: false),
        Entry(command: "read", usage: "tfa read", about: "读本工单（同 tfa read ticket）：开工前先读", worker: true),
        Entry(command: "ack", usage: "tfa ack \"<在改什么，预期结果>\"", about: "开始实质工作前确认一次", worker: true),
        Entry(command: "report",
              usage: "tfa report --state progress|ready|blocked|failed|dropped --summary 摘要 [--ask 一个问题] [--report 文件]",
              about: "结构化回报；要人决定就加 --ask（ready / dropped 不能带）", worker: true),
        Entry(command: "handback", usage: "tfa handback --reason 原因 [--request 原文]", about: "退回超出本工单范围的请求，成为主管的新候选", worker: true),
    ]

    private static func matches(_ e: Entry, _ command: String) -> Bool {
        command.isEmpty || e.command == command || e.command.hasPrefix(command + " ")
    }

    static func usageLines(_ command: String) -> [String] {
        var seen = Set<String>()
        return entries.filter { matches($0, command) }.map(\.usage).filter { seen.insert($0).inserted }
    }

    static func help(_ command: String) -> String {
        func section(_ list: [Entry]) -> String {
            list.map { "  \($0.usage)\n      \($0.about)\n" }.joined()
        }
        let picked = entries.filter { matches($0, command) }
        let router = picked.filter { !$0.worker }, worker = picked.filter(\.worker)
        var s = command.isEmpty ? "tfa — 主管和执行终端与 TFA 交互的命令行\n\n" : ""
        if !router.isEmpty { s += "主管：\n" + section(router) }
        if !worker.isEmpty { s += (router.isEmpty ? "" : "\n") + "执行者（工单号取 --ticket N，否则 $TFA_TICKET）：\n" + section(worker) }
        if command.isEmpty {
            s += "\n长文本用 --flag 值 或 --flag=值；省略 --request 时从 stdin 读（可用 heredoc）。工单号写 12 或 \"#12\"。\n"
            s += "出错退出码 1，用法错误退出码 2。\n"
        }
        return s
    }
}
