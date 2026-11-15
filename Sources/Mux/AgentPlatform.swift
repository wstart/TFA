import Foundation

/// Agent-specific filesystem conventions used by the rules and Skills panels.
/// Keep the choice explicit: many users run Claude Code, Codex, and Antigravity side by side.
enum AgentPlatform: String, CaseIterable, Identifiable {
    case claude
    case codex
    case antigravity

    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }
    var shortTitle: String {
        switch self {
        case .claude: return "CLAUDE"
        case .codex: return "CODEX"
        case .antigravity: return "AGY"
        }
    }
    var rulesFileName: String {
        switch self {
        case .claude: return "CLAUDE.md"
        case .codex: return "AGENTS.md"
        case .antigravity: return "GEMINI.md"
        }
    }
    var binaryName: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .antigravity: return "agy"
        }
    }

    var homeDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude:
            if let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
                .split(separator: ",").first.map(String.init), !configured.isEmpty {
                return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath).standardizedFileURL
            }
            return home.appendingPathComponent(".claude", isDirectory: true)
        case .codex:
            if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
                return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath).standardizedFileURL
            }
            return home.appendingPathComponent(".codex", isDirectory: true)
        case .antigravity:
            if let configured = ProcessInfo.processInfo.environment["AGY_CONFIG_DIR"], !configured.isEmpty {
                return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath).standardizedFileURL
            }
            return home.appendingPathComponent(".gemini/config", isDirectory: true)
        }
    }

    var rulesURL: URL { homeDirectory.appendingPathComponent(rulesFileName) }
    var skillsDirectory: URL { homeDirectory.appendingPathComponent("skills", isDirectory: true) }
    var pluginsDirectory: URL { homeDirectory.appendingPathComponent("plugins", isDirectory: true) }

    var executablePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.npm-global/bin"]
        var candidates = paths.map { $0 + "/" + binaryName }
        if self == .codex {
            // Finder-launched apps do not inherit the CLI's terminal PATH.
            for applications in ["/Applications", home + "/Applications"] {
                for app in ["Codex.app", "ChatGPT.app"] {
                    candidates.append(applications + "/" + app + "/Contents/Resources/codex")
                }
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Launch or resume command for Antigravity CLI (`agy` / `agy --continue`).
    static func agyCommand(resume: Bool = false) -> String? {
        AgentPlatform.antigravity.executablePath.map { shellQuote($0) + (resume ? " --continue" : "") }
    }

    /// Matches `agy` as an executable token or path segment without false-matching unrelated substrings.
    static func isAgyCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        if lower == "agy" || lower.contains("antigravity") { return true }
        return lower.range(of: #"(?:^|[\s/'"])agy(?:$|[\s'"])"#, options: .regularExpression) != nil
    }

    static func recoveryCommand(command: String, stableID: String) -> String {
        if command.lowercased().contains("axis-claude"), let axis = AxisClaude.command(resume: true) { return axis }
        if isAgyCommand(command) {
            return agyCommand(resume: true) ?? "agy --continue"
        }
        if command.lowercased().contains("codex") {
            let executable = AgentPlatform.codex.executablePath.map(shellQuote) ?? "codex"
            let id = UserDefaults.standard.string(forKey: "codexSession." + stableID) ?? ""
            if UUID(uuidString: id) != nil { return executable + " resume " + shellQuote(id) }
            return executable + " resume" // No known identity: explicitly let the user choose, never guess --last.
        }
        return "claude --continue"
    }
}
