import Foundation

let axisVersion = "0.1.0"

let usage = """
axis-claude \(axisVersion) — 终端编码助手（后端：本地 axis-model）

用法：
  axis-claude [选项]                进入交互模式
  axis-claude -p "<提示>" [选项]     非交互：执行一轮后输出结果并退出

选项：
  -p, --print [提示]        非交互模式（未给提示时从 stdin 读取）
  -c, --continue            恢复当前目录最近一次对话
      --resume <id>         恢复指定对话（~/.axis-claude/sessions 下的文件名）
      --ask                 Write/Edit/Bash 执行前逐次询问（默认自动允许）
  -h, --help                显示帮助
  -v, --version             显示版本

环境变量：
  AXIS_BASE_URL / ANTHROPIC_BASE_URL     默认 http://127.0.0.1:1234
  AXIS_MODEL                             默认 axis_model
  AXIS_AUTH_TOKEN / ANTHROPIC_AUTH_TOKEN 默认 dummy
  AXIS_MAX_TOKENS                        默认 8192

交互命令：/help  /clear（新对话）  /exit
"""

struct Options {
    var printMode = false
    var prompt: String?
    var continueLast = false
    var resumeID: String?
    var autoApprove = true
}

func parseOptions(_ args: [String]) -> Options {
    var o = Options()
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "-p", "--print":
            o.printMode = true
            if i + 1 < args.count, !args[i + 1].hasPrefix("-") { o.prompt = args[i + 1]; i += 1 }
        case "-c", "--continue": o.continueLast = true
        case "--resume":
            guard i + 1 < args.count else { err("--resume 需要对话 id\n"); exit(2) }
            o.resumeID = args[i + 1]; i += 1
        case "--yes", "--dangerously-skip-permissions": o.autoApprove = true // 旧参数，现为默认
        case "--ask": o.autoApprove = false
        case "-h", "--help": out(usage + "\n"); exit(0)
        case "-v", "--version": out("axis-claude \(axisVersion)\n"); exit(0)
        default:
            if o.printMode, o.prompt == nil, !a.hasPrefix("-") { o.prompt = a }
            else { err("未知参数：\(a)\n\n\(usage)\n"); exit(2) }
        }
        i += 1
    }
    return o
}

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
let config = APIConfig.fromEnvironment()
let store = SessionStore(root: SessionStore.defaultRoot)
let systemPrompt = SystemPrompt.build(cwd: cwd)

var record = SessionRecord(id: SessionStore.newID(), cwd: cwd.path, createdAt: Date(), updatedAt: Date(), messages: [])
if let id = options.resumeID {
    guard let r = store.load(id: id, cwd: cwd) else { err("找不到对话 \(id)（当前目录：\(cwd.path)）\n"); exit(1) }
    record = r
} else if options.continueLast {
    if let r = store.latest(for: cwd) { record = r } else { err("当前目录没有可恢复的对话，开始新对话\n") }
}

let ui = ConsoleUI(printMode: options.printMode)
let reader = LineReader()
let permission: PermissionCheck
if options.autoApprove {
    permission = { _, _ in .allow }
} else if options.printMode {
    permission = { _, summary in
        err("已拒绝 \(summary)：--ask 模式下非交互运行无法询问\n")
        return .deny(reason: "非交互模式下无法询问授权（--ask），操作被拒绝")
    }
} else {
    permission = ui.permissionChecker(reader: reader)
}

func makeAgent(_ r: SessionRecord) -> Agent {
    let a = Agent(config: config, transport: HTTPTransport(config: config, sessionID: r.id),
                  systemPrompt: systemPrompt, cwd: cwd, ui: ui, permission: permission)
    a.messages = r.messages
    return a
}

var agent = makeAgent(record)

@MainActor
func persist() {
    guard !agent.messages.isEmpty else { return }
    record.messages = agent.messages
    record.updatedAt = Date()
    do { try store.save(record) } catch { err(Style.red("保存对话失败：\(error.localizedDescription)") + "\n") }
}

enum TurnOutcome { case done(String), interrupted, failed(Error) }

/// Runs one user turn in a child task so SIGINT can cancel it without exiting the program.
@MainActor
func runTurn(_ text: String) async -> TurnOutcome {
    let a = agent
    let task = Task { try await a.runTurn(text) }
    Interrupts.shared.setHandler { task.cancel() }
    let result = await task.result
    Interrupts.shared.setHandler(nil)
    persist()
    switch result {
    case .success(let t): return .done(t)
    case .failure(let e) where e is CancellationError: return .interrupted
    case .failure(let e): return .failed(e)
    }
}

Interrupts.shared.install()

// MARK: - Non-interactive

if options.printMode {
    var prompt = options.prompt ?? ""
    if prompt.isEmpty, isatty(0) == 0 {
        prompt = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        err("-p 需要提示内容\n"); exit(2)
    }
    switch await runTurn(prompt) {
    case .done(let text):
        out(text.hasSuffix("\n") ? text : text + "\n")
        exit(0)
    case .interrupted:
        err("已中断\n"); exit(130)
    case .failed(let e):
        err("\(e)\n"); exit(1)
    }
}

// MARK: - REPL

out(Style.bold("axis-claude \(axisVersion)") + Style.dim(" · \(config.model) @ \(config.baseURL.absoluteString) · \(cwd.path)") + "\n")
if !record.messages.isEmpty { out("已恢复上次对话（\(record.messages.count) 条消息）\n") }
out(Style.dim("输入 /help 查看命令，行尾 \\ 换行续写，Ctrl-C 中断，Ctrl-D 退出") + "\n")

var pendingExit = false
repl: while true {
    out("\n> ")
    var lines: [String] = []
    var input: LineInput
    while true {
        input = reader.readLine()
        guard case .line(let l) = input, l.hasSuffix("\\") else { break }
        lines.append(String(l.dropLast()))
        out("  ")
    }
    switch input {
    case .eof:
        out("\n")
        break repl
    case .interrupted:
        if pendingExit { out("\n"); break repl }
        pendingExit = true
        out("\n" + Style.dim("（再按一次 Ctrl-C 退出）"))
        continue repl
    case .line(let l):
        lines.append(l)
    }
    pendingExit = false
    let text = lines.joined(separator: "\n")
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { continue }

    switch trimmed {
    case "/exit", "/quit":
        break repl
    case "/help":
        out(usage + "\n")
        continue repl
    case "/clear":
        record = SessionRecord(id: SessionStore.newID(), cwd: cwd.path, createdAt: Date(), updatedAt: Date(), messages: [])
        agent = makeAgent(record)
        out(Style.dim("已开始新对话") + "\n")
        continue repl
    default:
        if trimmed.hasPrefix("/") && !trimmed.contains(" ") && !trimmed.dropFirst().contains("/") {
            out(Style.red("未知命令 \(trimmed)，输入 /help 查看") + "\n")
            continue repl
        }
    }

    switch await runTurn(text) {
    case .done:
        break
    case .interrupted:
        out("\n" + Style.red("⎿ 已中断") + "\n")
    case .failed(let e):
        out("\n" + Style.red("✗ \(e)") + "\n")
    }
}
exit(0)
