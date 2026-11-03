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
}
