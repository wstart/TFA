import Foundation

/// Rendering hooks for the agent loop (console in the CLI, silent in tests).
protocol AgentUI: AnyObject {
    func requestStarted()
    func streamEvent(_ event: StreamEvent)
    func responseFinished(_ message: AssistantMessage)
    func toolStarted(_ summary: String)
    func toolFinished(_ result: ToolResult)
}

enum PermissionDecision: Equatable {
    case allow
    /// `reason` becomes the error tool_result sent back to the model.
    case deny(reason: String)
}

/// Asks whether a mutating tool call may run. `summary` is the one-line call description.
typealias PermissionCheck = (_ tool: Tool, _ summary: String) async -> PermissionDecision

final class Agent {
    static let maxToolRounds = 50

    let config: APIConfig
    let transport: Transport
    let tools: [Tool]
    let systemPrompt: String
    let cwd: URL
    let ui: AgentUI
    let permission: PermissionCheck
    var messages: [Message] = []
    /// Called (off the main actor) with a snapshot of `messages` after each tool round, so the CLI
    /// can save progress mid-turn.
    var onProgress: (([Message]) -> Void)?
    /// Tokens used by the most recent `runTurn` (all its requests), and the conversation's size
    /// after its last reply — shown after each turn.
    private(set) var turnUsage = Usage()
    private(set) var contextTokens = 0
    /// Consecutive replies cut by max_tokens that the agent auto-continues before giving up.
    static let maxTruncatedContinues = 2

    init(config: APIConfig, transport: Transport, tools: [Tool] = Tools.all, systemPrompt: String,
         cwd: URL, ui: AgentUI, permission: @escaping PermissionCheck) {
        self.config = config
        self.transport = transport
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.cwd = cwd
        self.ui = ui
        self.permission = permission
    }

    /// Runs one user turn: request → execute tool_use blocks → send tool_results → repeat until the
    /// model stops asking for tools. Returns the final assistant text.
    ///
    /// On cancellation the history is kept valid: pending tool_use blocks get error results, and a
    /// trailing user message is merged with the next user input instead of breaking alternation.
    @discardableResult
    func runTurn(_ userText: String) async throws -> String {
        appendUser([.text(userText)])
        let toolSchemas = tools.map(\.schema)
        var lastText = ""
        var truncations = 0
        turnUsage = Usage()

        for _ in 0..<Self.maxToolRounds {
            try Task.checkCancellation()
            ui.requestStarted()
            let request = MessagesRequest(model: config.model, max_tokens: config.maxTokens,
                                          system: systemPrompt, messages: messages, tools: toolSchemas)
            let reply = try await transport.send(request) { [ui] in ui.streamEvent($0) }
            ui.responseFinished(reply)
            turnUsage = turnUsage + reply.usage
            if reply.usage.context > 0 { contextTokens = reply.usage.context }
            // An empty text block is rejected by Anthropic-compatible servers; keep a placeholder.
            messages.append(Message(role: "assistant", content: reply.content.isEmpty ? [.text("…")] : reply.content))
            lastText = reply.text

            let uses = reply.content.compactMap { block -> (String, String, JSONValue)? in
                if case .toolUse(let id, let name, let input) = block { return (id, name, input) }
                return nil
            }
            if uses.isEmpty {
                // Cut off by max_tokens (possibly mid tool call, which was dropped): say so and let the
                // model continue, a bounded number of times.
                if reply.stopReason == "max_tokens", truncations < Self.maxTruncatedContinues {
                    truncations += 1
                    appendUser([.text("（上一条回复达到 max_tokens 上限被截断。如果当时在写工具调用，它没有执行：请把内容拆成更小的步骤重新调用；否则请从中断处继续。）")])
                    onProgress?(messages)
                    continue
                }
                return lastText
            }
            truncations = 0

            var results: [ContentBlock] = []
            var cancelled = false
            for (id, name, input) in uses {
                if cancelled || Task.isCancelled {
                    cancelled = true
                    results.append(.toolResult(toolUseID: id, content: "用户中断", isError: true))
                    continue
                }
                let r = await execute(name: name, input: input)
                if Task.isCancelled { cancelled = true }
                results.append(.toolResult(toolUseID: id, content: r.content, isError: r.isError))
            }
            appendUser(results)
            onProgress?(messages)
            if cancelled { throw CancellationError() }
        }
        appendUser([.text("（已达到单轮 \(Self.maxToolRounds) 次工具调用上限，已停止）")])
        return lastText
    }

    private func execute(name: String, input: JSONValue) async -> ToolResult {
        guard let tool = tools.first(where: { $0.name == name }) else {
            let r = ToolResult(content: "未知工具：\(name)", isError: true)
            ui.toolStarted("\(name)(?)")
            ui.toolFinished(r)
            return r
        }
        let args = ToolInput(raw: input)
        let summary = tool.summary(args)
        ui.toolStarted(summary)
        if tool.mutating, case .deny(let reason) = await permission(tool, summary) {
            let r = ToolResult(content: reason, isError: true)
            ui.toolFinished(r)
            return r
        }
        let r: ToolResult
        do {
            r = try await tool.run(args, cwd)
        } catch is CancellationError {
            r = ToolResult(content: "用户中断", isError: true)
        } catch let e as ToolError {
            r = ToolResult(content: e.message, isError: true)
        } catch {
            r = ToolResult(content: error.localizedDescription, isError: true)
        }
        ui.toolFinished(r)
        return r
    }

    /// `/compact`: ask the model to summarize the conversation, then replace the history with that
    /// summary so a long session stops growing toward the context limit. The request is the full
    /// history + one instruction with the SAME system prompt and tools, so the server's prefix cache
    /// covers everything but the instruction. Returns the summary (nil when there was nothing to do).
    @discardableResult
    func compact() async throws -> String? {
        guard messages.count >= 2 else { return nil }
        var history = Self.closingDanglingToolUses(messages)
        let instruction = ContentBlock.text("""
            请把以上对话压缩成一份供你自己继续工作的摘要（不要调用工具）。包括：用户的目标和要求、\
            已完成的改动（文件路径与要点）、关键结论与决定、未完成的事项和下一步。只输出摘要。
            """)
        if history.last?.role == "user" { history[history.count - 1].content.append(instruction) }
        else { history.append(Message(role: "user", content: [instruction])) }
        ui.requestStarted()
        let request = MessagesRequest(model: config.model, max_tokens: config.maxTokens, system: systemPrompt,
                                      messages: history, tools: tools.map(\.schema))
        let reply = try await transport.send(request) { [ui] in ui.streamEvent($0) }
        ui.responseFinished(reply)
        let summary = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw APIError.badResponse("模型没有返回摘要，对话未压缩") }
        messages = [
            Message(role: "user", content: [.text("（以下是此前对话的摘要，请据此继续）\n\n" + summary)]),
            Message(role: "assistant", content: [.text("好的，我已了解之前的进展。")]),
        ]
        contextTokens = 0
        return summary
    }

    /// `messages` made resumable when the process is about to die mid-tool: an assistant turn whose
    /// tool calls never got results would be rejected by the server on `--continue`, so each gets an
    /// error result.
    static func closingDanglingToolUses(_ messages: [Message]) -> [Message] {
        guard let last = messages.last, last.role == "assistant" else { return messages }
        let ids = last.content.compactMap { block -> String? in
            if case .toolUse(let id, _, _) = block { return id }
            return nil
        }
        guard !ids.isEmpty else { return messages }
        return messages + [Message(role: "user", content: ids.map {
            .toolResult(toolUseID: $0, content: "进程被终止，工具未完成", isError: true)
        })]
    }

    private func appendUser(_ blocks: [ContentBlock]) {
        if messages.last?.role == "user" {
            messages[messages.count - 1].content += blocks
        } else {
            messages.append(Message(role: "user", content: blocks))
        }
    }
}

// MARK: - System prompt

enum SystemPrompt {
    static let memoryCap = 20_000

    /// Builds a byte-stable prompt for `cwd` (no timestamps) so the server's prefix cache hits
    /// across turns and sessions.
    static func build(cwd: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        var s = """
        You are axis-claude, a coding assistant running in the user's terminal. You help with \
        software engineering tasks by reading, searching, editing files and running commands \
        through the provided tools.

        Environment:
        - Working directory: \(cwd.path)
        - Platform: macOS (darwin)

        Guidelines:
        - Be concise. Answer in the user's language.
        - Use tools instead of guessing: read files before editing them, search with Glob/Grep.
        - Prefer Edit for small changes to existing files; use Write for new files.
        - Relative paths resolve against the working directory.
        - Bash runs non-interactively; avoid commands that wait for input.
        - When the task is done, reply with a short summary of what changed.
        """
        let files: [(String, URL)] = [
            ("~/.claude/CLAUDE.md", home.appendingPathComponent(".claude/CLAUDE.md")),
            ("CLAUDE.md", cwd.appendingPathComponent("CLAUDE.md")),
            ("AGENTS.md", cwd.appendingPathComponent("AGENTS.md")),
        ]
        for (label, url) in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let body = text.count > memoryCap ? String(text.prefix(memoryCap)) + "\n…(truncated)" : text
            s += "\n\n# Instructions from \(label)\n\n" + body
        }
        return s
    }

    static func resolve(cwd: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        options: CLIOptions) throws -> String {
        var s = options.systemPromptOverride ?? build(cwd: cwd, home: home)
        for extra in options.appendedSystemPrompts where !extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s += "\n\n" + extra
        }
        for rawPath in options.appendedSystemPromptFiles {
            let url = resolvePath(rawPath, cwd: cwd)
            let text: String
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw CLIOptionsError("无法读取 system prompt 文件 \(url.path)：\(error.localizedDescription)")
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                s += "\n\n" + text
            }
        }
        return s
    }
}

// MARK: - CLI options & tool policy

struct CLIOptionsError: Error, Equatable, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

enum PermissionMode: Equatable {
    case autoApprove
    case ask
    case dontAsk
}

struct AllowedToolRule: Equatable {
    var tool: String
    /// Nil = allow any call of `tool`; non-nil (for `Bash(<prefix> *)`) = restrict `command` to this prefix.
    var commandPrefix: String?

    static func parseList(_ spec: String) -> [AllowedToolRule] {
        var items: [String] = []
        var current = ""
        var depth = 0
        for ch in spec {
            if ch == "(" { depth += 1; current.append(ch) }
            else if ch == ")" { depth = max(0, depth - 1); current.append(ch) }
            else if ch == "," && depth == 0 { items.append(current); current = "" }
            else { current.append(ch) }
        }
        items.append(current)
        return items.compactMap { raw -> AllowedToolRule? in
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }
            if let open = s.firstIndex(of: "("), s.hasSuffix(")") {
                let name = String(s[..<open]).trimmingCharacters(in: .whitespaces)
                let inside = String(s[s.index(after: open)..<s.index(before: s.endIndex)]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                if inside.isEmpty || inside == "*" {
                    return AllowedToolRule(tool: name, commandPrefix: nil)
                }
                if inside.hasSuffix(" *") {
                    let p = String(inside.dropLast(2)).trimmingCharacters(in: .whitespaces)
                    return AllowedToolRule(tool: name, commandPrefix: p.isEmpty ? nil : p)
                }
                if inside.hasSuffix("*") {
                    let p = String(inside.dropLast()).trimmingCharacters(in: .whitespaces)
                    return AllowedToolRule(tool: name, commandPrefix: p.isEmpty ? nil : p)
                }
                return AllowedToolRule(tool: name, commandPrefix: inside)
            }
            return AllowedToolRule(tool: s, commandPrefix: nil)
        }
    }
}

struct CLIOptions: Equatable {
    var printMode = false
    var prompt: String?
    var continueLast = false
    var resumeID: String?
    var permissionMode: PermissionMode = .autoApprove
    var model: String?
    var systemPromptOverride: String?
    var appendedSystemPrompts: [String] = []
    var appendedSystemPromptFiles: [String] = []
    var explicitTools: Set<String>?
    var disallowedTools: Set<String> = []
    var allowedTools: [AllowedToolRule] = []
    var persistSession = true
    var outputFormat = "text"
    var showHelp = false
    var showVersion = false

    static func parse(_ args: [String]) throws -> CLIOptions {
        var o = CLIOptions()
        var i = 0
        var literalRest = false

        func requireValue(_ flag: String) throws -> String {
            guard i + 1 < args.count else { throw CLIOptionsError("\(flag) 需要参数") }
            i += 1
            return args[i]
        }

        func parseToolNames(_ spec: String) -> Set<String> {
            let parts = spec.components(separatedBy: CharacterSet(charactersIn: ", \t\n"))
            var names: Set<String> = []
            for p in parts {
                let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let base = trimmed.split(separator: "(", maxSplits: 1).first.map(String.init) ?? trimmed
                if !base.isEmpty { names.insert(base.lowercased()) }
            }
            return names
        }

        while i < args.count {
            let a = args[i]
            if literalRest {
                if o.prompt == nil { o.prompt = a }
                else { throw CLIOptionsError("多余的位置参数：\(a)") }
                i += 1
                continue
            }
            switch a {
            case "--":
                literalRest = true
            case "-p", "--print":
                o.printMode = true
                if i + 1 < args.count, !args[i + 1].hasPrefix("-") {
                    o.prompt = args[i + 1]
                    i += 1
                }
            case "-c", "--continue":
                o.continueLast = true
            case "--resume":
                o.resumeID = try requireValue(a)
            case "--yes", "--dangerously-skip-permissions":
                o.permissionMode = .autoApprove
            case "--ask":
                o.permissionMode = .ask
            case "--permission-mode":
                let mode = try requireValue(a)
                switch mode {
                case "dontAsk", "plan":
                    o.permissionMode = .dontAsk
                case "bypassPermissions", "acceptEdits", "auto", "default":
                    o.permissionMode = .autoApprove
                default:
                    throw CLIOptionsError("未知的 --permission-mode：\(mode)")
                }
            case "--model":
                let m = try requireValue(a).trimmingCharacters(in: .whitespacesAndNewlines)
                if !m.isEmpty { o.model = m }
            case "--system-prompt":
                o.systemPromptOverride = try requireValue(a)
            case "--append-system-prompt":
                o.appendedSystemPrompts.append(try requireValue(a))
            case "--append-system-prompt-file":
                o.appendedSystemPromptFiles.append(try requireValue(a))
            case "--tools":
                o.explicitTools = parseToolNames(try requireValue(a))
            case "--disallowedTools", "--disallowed-tools":
                o.disallowedTools.formUnion(parseToolNames(try requireValue(a)))
            case "--allowedTools", "--allowed-tools":
                o.allowedTools.append(contentsOf: AllowedToolRule.parseList(try requireValue(a)))
            case "--no-session-persistence":
                o.persistSession = false
            case "--output-format":
                o.outputFormat = try requireValue(a).lowercased()
            case "--settings":
                _ = try requireValue(a) // Accepted for Claude Code CLI flag compatibility.
            case "-h", "--help":
                o.showHelp = true
            case "-v", "--version":
                o.showVersion = true
            default:
                if !a.hasPrefix("-"), o.prompt == nil {
                    o.prompt = a
                } else {
                    throw CLIOptionsError("未知参数：\(a)")
                }
            }
            i += 1
        }
        return o
    }
}

enum ToolPolicy {
    /// Filters `tools` according to `--tools` / `--disallowedTools` and wraps mutating tools so
    /// `--permission-mode dontAsk` and `--allowedTools` rules (such as `Bash(tfa *)`) are enforced
    /// against the full `ToolInput` before execution.
    static func apply(to tools: [Tool] = Tools.all, options: CLIOptions) -> [Tool] {
        var filtered = tools
        if let explicit = options.explicitTools {
            filtered = filtered.filter { explicit.contains($0.name.lowercased()) }
        }
        if !options.disallowedTools.isEmpty {
            filtered = filtered.filter { !options.disallowedTools.contains($0.name.lowercased()) }
        }
        let enforceAllowlist = options.permissionMode == .dontAsk || !options.allowedTools.isEmpty
        guard enforceAllowlist else { return filtered }
        return filtered.map { tool in
            guard tool.mutating else { return tool }
            return Tool(
                name: tool.name,
                description: tool.description,
                properties: tool.properties,
                required: tool.required,
                mutating: tool.mutating,
                summaryKey: tool.summaryKey
            ) { input, cwd in
                if !isMutatingCallAllowed(tool: tool.name, input: input, rules: options.allowedTools) {
                    throw ToolError("权限策略拒绝执行 \(tool.summary(input))")
                }
                return try await tool.run(input, cwd)
            }
        }
    }

    static func isMutatingCallAllowed(tool: String, input: ToolInput, rules: [AllowedToolRule]) -> Bool {
        let lower = tool.lowercased()
        for rule in rules where rule.tool.lowercased() == lower {
            guard let prefix = rule.commandPrefix else { return true }
            if lower == "bash", let cmd = input.string("command"), matchesCommandPrefix(cmd, prefix: prefix) {
                return true
            }
        }
        return false
    }

    /// Validates that `command` runs a single command starting with `prefix` (e.g. `tfa`), without
    /// shell chaining (`;`, `|`, `&`), redirection (`>`, `<`), or command substitution (`` ` ``, `$(`),
    /// while permitting a trailing heredoc (`<<'EOF' ... EOF`) used by Superagent's router prompt.
    static func matchesCommandPrefix(_ command: String, prefix: String) -> Bool {
        let trimmedStart = command.drop(while: { $0 == " " || $0 == "\t" })
        guard !trimmedStart.isEmpty, !prefix.isEmpty else { return false }

        let newlineIndex = trimmedStart.firstIndex(of: "\n")
        let firstLineSub = newlineIndex.map { trimmedStart[..<$0] } ?? trimmedStart[...]
        var firstLine = String(firstLineSub)
        if firstLine.hasSuffix("\r") { firstLine.removeLast() }
        let rest: String? = newlineIndex.map { String(trimmedStart[trimmedStart.index(after: $0)...]) }

        // Must equal `prefix` or be followed immediately by space/tab.
        let trimmedFirst = firstLine.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
        guard trimmedFirst == prefix || trimmedFirst.hasPrefix(prefix + " ") || trimmedFirst.hasPrefix(prefix + "\t") else {
            return false
        }

        let chars = Array(firstLine)
        var idx = 0
        var inSingle = false
        var inDouble = false
        var heredocDelimiter: String?
        var heredocQuoted = false
        var heredocStripTabs = false

        while idx < chars.count {
            let c = chars[idx]
            if inSingle {
                if c == "'" { inSingle = false }
                idx += 1
                continue
            }
            if inDouble {
                if c == "\\" {
                    idx += 2
                    continue
                }
                if c == "\"" {
                    inDouble = false
                    idx += 1
                    continue
                }
                if c == "`" { return false }
                if c == "$", idx + 1 < chars.count, chars[idx + 1] == "(" { return false }
                idx += 1
                continue
            }
            switch c {
            case "'":
                inSingle = true
                idx += 1
            case "\"":
                inDouble = true
                idx += 1
            case ";", "|", "&", ">", "`":
                return false
            case "$":
                if idx + 1 < chars.count, chars[idx + 1] == "(" { return false }
                idx += 1
            case "<":
                guard heredocDelimiter == nil, idx + 1 < chars.count, chars[idx + 1] == "<" else { return false }
                idx += 2
                if idx < chars.count, chars[idx] == "-" {
                    heredocStripTabs = true
                    idx += 1
                }
                while idx < chars.count, chars[idx] == " " || chars[idx] == "\t" { idx += 1 }
                guard idx < chars.count else { return false }
                if chars[idx] == "'" || chars[idx] == "\"" {
                    let quote = chars[idx]
                    heredocQuoted = true
                    idx += 1
                    var delim = ""
                    while idx < chars.count, chars[idx] != quote {
                        delim.append(chars[idx])
                        idx += 1
                    }
                    guard idx < chars.count, !delim.isEmpty else { return false }
                    heredocDelimiter = delim
                    idx += 1
                } else {
                    heredocQuoted = false
                    var delim = ""
                    while idx < chars.count {
                        let dc = chars[idx]
                        if dc == " " || dc == "\t" || ";|&><`$'\"\\".contains(dc) { break }
                        delim.append(dc)
                        idx += 1
                    }
                    guard !delim.isEmpty else { return false }
                    heredocDelimiter = delim
                }
            case "\\":
                idx += 2
            default:
                idx += 1
            }
        }

        if inSingle || inDouble { return false }

        guard let rest else {
            return heredocDelimiter == nil
        }
        if rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return heredocDelimiter == nil
        }
        guard let delim = heredocDelimiter else { return false }

        let lines = rest.components(separatedBy: "\n").map { line -> String in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        var closedAt: Int?
        for (lineIdx, line) in lines.enumerated() {
            let candidate = heredocStripTabs ? String(line.drop(while: { $0 == "\t" })) : line
            if candidate == delim {
                closedAt = lineIdx
                break
            }
            if !heredocQuoted {
                if line.contains("`") || line.contains("$(") { return false }
            }
        }
        guard let endIdx = closedAt else { return false }
        for trailing in lines[(endIdx + 1)...] {
            if !trailing.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        }
        return true
    }
}
