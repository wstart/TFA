import Foundation

/// Agent-specific filesystem conventions used by the rules and Skills panels.
/// Keep the choice explicit: many users run Claude Code and Codex side by side.
enum AgentPlatform: String, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }
    var title: String { self == .claude ? "Claude Code" : "Codex" }
    var shortTitle: String { self == .claude ? "CLAUDE" : "CODEX" }
    var rulesFileName: String { self == .claude ? "CLAUDE.md" : "AGENTS.md" }

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
        }
    }

    var rulesURL: URL { homeDirectory.appendingPathComponent(rulesFileName) }
    var skillsDirectory: URL { homeDirectory.appendingPathComponent("skills", isDirectory: true) }

    var executablePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.npm-global/bin"]
        var candidates = paths.map { $0 + "/" + rawValue }
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

    static func recoveryCommand(command: String, stableID: String) -> String {
        if command.lowercased().contains("codex") {
            let executable = AgentPlatform.codex.executablePath.map(shellQuote) ?? "codex"
            let id = UserDefaults.standard.string(forKey: "codexSession." + stableID) ?? ""
            if UUID(uuidString: id) != nil { return executable + " resume " + shellQuote(id) }
            return executable + " resume" // No known identity: explicitly let the user choose, never guess --last.
        }
        return "claude --continue"
    }
}
