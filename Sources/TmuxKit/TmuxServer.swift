import Foundation

/// One-shot, non-`-CC` queries against a local tmux server.
///
/// Used at launch to DISCOVER existing sessions so the app can resume them. These run a short
/// `tmux` subprocess and exit; they never hold a control-mode connection open.
public enum TmuxServer {
    /// Environment for spawned tmux processes with a UTF-8 ctype forced on.
    ///
    /// GUI apps launched from Finder/`open` inherit a minimal, often C/POSIX-locale environment.
    /// Under a C locale tmux mangles multibyte (e.g. CJK) text — `#{session_name}` for a session
    /// named `tfa主程` comes back as `tfa____`, so discovery then tries to attach a name that
    /// matches nothing. Forcing `LC_CTYPE=UTF-8` (dropping a C-valued `LC_ALL` that would otherwise
    /// override it) makes tmux and the shells it spawns handle UTF-8 regardless of how we launched.
    public static func utf8Environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let all = env["LC_ALL"], all == "C" || all == "POSIX" || all.isEmpty {
            env.removeValue(forKey: "LC_ALL")
        }
        env["LC_CTYPE"] = "UTF-8"
        return env
    }

    /// List existing local tmux session names on the given socket (default socket when nil).
    ///
    /// Returns `[]` if tmux is missing, no server is running, or the command fails — an empty
    /// result always means "nothing to resume", never an error to surface.
    /// Per-session last OUTPUT-activity time (epoch seconds), as `[sessionName: epoch]`, taken from
    /// `#{window_activity}` (max across a session's windows). Unlike `session_activity`,
    /// `window_activity` updates on pane output even for DETACHED sessions — so this reflects "is
    /// this session producing output" for EVERY session, not just the ones TFA has attached.
    /// Best-effort: returns `[:]` on any failure.
    public static func localWindowActivity(tmuxPath: String? = nil, socketName: String? = nil) -> [String: Int] {
        guard let tmux = tmuxPath ?? TmuxLocator.find() else { return [:] }
        var args: [String] = []
        if let socket = socketName { args += ["-L", socket] }
        args += ["-u", "list-windows", "-a", "-F", "#{session_name}\u{1f}#{window_activity}"] // US separator

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = args
        process.environment = utf8Environment()
        let stdout = Pipe(); process.standardOutput = stdout; process.standardError = Pipe()
        do { try process.run() } catch { return [:] }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [:] }

        var out: [String: Int] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let t = Int(parts[1]) else { continue }
            let name = String(parts[0])
            out[name] = max(out[name] ?? 0, t)
        }
        return out
    }

    /// The latest non-empty visible line of a session's active pane (`capture-pane -p`), cleaned of
    /// control chars and clamped. Works for ANY session (no attach needed). nil on failure / blank.
    public static func lastOutputLine(session: String, tmuxPath: String? = nil, socketName: String? = nil) -> String? {
        guard let tmux = tmuxPath ?? TmuxLocator.find() else { return nil }
        var args: [String] = []
        if let socket = socketName { args += ["-L", socket] }
        args += ["-u", "capture-pane", "-p", "-t", session]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = args
        process.environment = utf8Environment()
        let stdout = Pipe(); process.standardOutput = stdout; process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let cleaned = String(line.unicodeScalars.filter { $0.value >= 0x20 }).trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty { return cleaned.count > 60 ? String(cleaned.prefix(60)) + "…" : cleaned }
        }
        return nil
    }

    public static func listLocalSessions(tmuxPath: String? = nil,
                                         socketName: String? = nil) -> [String] {
        guard let tmux = tmuxPath ?? TmuxLocator.find() else { return [] }

        var args: [String] = []
        if let socket = socketName { args += ["-L", socket] }
        // `-u` forces UTF-8 so multibyte session names aren't mangled under a C-locale launch.
        args += ["-u", "list-sessions", "-F", "#{session_name}"]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = args
        process.environment = utf8Environment()

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe() // swallow "error connecting ..." when no server exists

        do {
            try process.run()
        } catch {
            return []
        }

        // Read BEFORE waitUntilExit to avoid a full-pipe-buffer deadlock.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return [] }

        return parseSessionNames(data)
    }

    /// List existing tmux session names on a REMOTE host over ssh, as a ONE-SHOT (NOT `-CC`) query.
    ///
    /// Used when the user switches the active host so the app can discover and load that host's
    /// sessions. It runs `ssh <ControlMaster opts> <args> <host> tmux list-sessions …`, sharing the
    /// EXACT ControlMaster options every interactive terminal uses — so if a connection to the host
    /// is already up, this reuses its authenticated master and never re-prompts. When no master is up
    /// yet, a supplied `password` is fed via SSH_ASKPASS (same mechanism as `TmuxConnection`).
    ///
    /// Returns `[]` on ANY failure (ssh refused, auth failed, no tmux server, timeout) — discovery is
    /// best-effort and must never throw to the UI. `ConnectTimeout=8` guards against hanging.
    public static func listRemoteSessions(host: String,
                                          args: [String] = [],
                                          password: String? = nil) async -> [String] {
        // Hop off the main actor: Process spawning + blocking pipe reads must not block the UI.
        await Task.detached(priority: .utility) { () -> [String] in
            var argv: [String] = []
            // Same ControlMaster options as interactive terminals → reuse the authenticated master.
            argv += TmuxConnection.sshControlMasterArgs()
            // Bound the attempt so a dead/filtered host can't hang discovery. BatchMode is NOT used:
            // we need ssh to invoke SSH_ASKPASS to authenticate when the master isn't up.
            argv += ["-o", "ConnectTimeout=8"]
            // With an auto-supplied password, keep the host-key + prompt handling non-interactive so
            // the askpass-provided password is what answers (mirrors resolvedArgv()).
            if let pw = password, !pw.isEmpty {
                argv += ["-o", "StrictHostKeyChecking=accept-new", "-o", "NumberOfPasswordPrompts=1"]
            }
            argv += args
            // The remote command must be ONE pre-quoted token: ssh joins everything after the host
            // with spaces and hands it to the remote LOGIN shell, which re-parses it. An unquoted
            // `#{session_name}` would be read as a shell comment (a `#` starting a word), eating the
            // `-F` argument. Single-quoting the format keeps it intact through that re-parse. The
            // `env PATH=…` prefix makes `tmux` resolvable on macOS (Homebrew) remotes — see remotePATH.
            argv += [host, "env PATH=\(TmuxConnection.remotePATH) tmux -u list-sessions -F '#{session_name}'"]

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = argv
            var env = utf8Environment()
            if let askpass = TmuxConnection.askpassEnv(password: password) {
                for (k, v) in askpass { env[k] = v }
            }
            process.environment = env

            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe() // swallow ssh/tmux diagnostics

            do {
                try process.run()
            } catch {
                return []
            }

            // Read BEFORE waitUntilExit to avoid a full-pipe-buffer deadlock.
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return [] }
            return parseSessionNames(data)
        }.value
    }

    /// Split a `#{session_name}`-per-line tmux output blob into trimmed, non-empty names.
    private static func parseSessionNames(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true) // names may contain spaces
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
