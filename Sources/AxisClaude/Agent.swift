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

        for _ in 0..<Self.maxToolRounds {
            try Task.checkCancellation()
            ui.requestStarted()
            let request = MessagesRequest(model: config.model, max_tokens: config.maxTokens,
                                          system: systemPrompt, messages: messages, tools: toolSchemas)
            let reply = try await transport.send(request) { [ui] in ui.streamEvent($0) }
            ui.responseFinished(reply)
            messages.append(Message(role: "assistant", content: reply.content.isEmpty ? [.text("")] : reply.content))
            lastText = reply.text

            let uses = reply.content.compactMap { block -> (String, String, JSONValue)? in
                if case .toolUse(let id, let name, let input) = block { return (id, name, input) }
                return nil
            }
            if uses.isEmpty { return lastText }

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
