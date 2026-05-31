import Foundation

/// Describes how to reach a tmux server and which session to open in control mode.
public struct TmuxConnection: Sendable {
    public enum Endpoint: Sendable {
        case local
        /// Remote tmux over ssh. `host` is any ssh target (user@host or a Host alias);
        /// `sshArgs` are extra ssh flags (e.g. ["-p", "2222"]).
        case ssh(host: String, sshArgs: [String])
    }

    public var endpoint: Endpoint
    /// Session to attach to / create.
    public var sessionName: String
    /// If true use `attach-session`; otherwise `new-session -A` (create-or-attach).
    public var attachOnly: Bool
    /// Optional dedicated tmux socket (`-L name`), local only.
    public var socketName: String?
    /// Override tmux path (local only); otherwise auto-located.
    public var tmuxPath: String?
    public var cols: Int
    public var rows: Int
    /// Optional ssh password, auto-supplied at the password prompt during login. Held only on this
    /// struct and never part of `displayName`/logs. NOTE: the app layer separately persists saved-host
    /// passwords to the macOS Keychain (see `AppModel.addHost` / `Keychain`), keyed by `user@host`.
    public var password: String?

    public init(endpoint: Endpoint = .local,
                sessionName: String = "GUI",
                attachOnly: Bool = false,
                socketName: String? = nil,
                tmuxPath: String? = nil,
                cols: Int = 80,
                rows: Int = 24,
                password: String? = nil) {
        self.endpoint = endpoint
        self.sessionName = sessionName
        self.attachOnly = attachOnly
        self.socketName = socketName
        self.tmuxPath = tmuxPath
        self.cols = cols
        self.rows = rows
        self.password = password
    }

    /// A short, human-readable label for this connection.
    public var displayName: String {
        switch endpoint {
        case .local: return socketName.map { "local:\($0)" } ?? "local"
        case .ssh(let host, _): return "ssh:\(host)"
        }
    }

    /// Remote connections go through an interactive ssh login (password / host-key / 2FA) before
    /// tmux control mode starts; local ones enter control mode immediately.
    public var isRemote: Bool {
        if case .ssh = endpoint { return true }
        return false
    }

    private var tmuxSubcommand: [String] {
        attachOnly
            ? ["attach-session", "-t", sessionName]
            : ["new-session", "-A", "-s", sessionName]
    }

    /// Resolve (executable, argv). argv[0] is the executable path by convention.
    public func resolvedArgv() throws -> (exec: String, argv: [String]) {
        switch endpoint {
        case .local:
            guard let tmux = tmuxPath ?? TmuxLocator.find() else { throw TmuxError.tmuxNotFound }
            var args = [tmux]
            if let socket = socketName { args += ["-L", socket] }
            args += ["-u", "-CC"]
            args += tmuxSubcommand
            return (tmux, args)
        case .ssh(let host, let sshArgs):
            let ssh = "/usr/bin/ssh"
            var args = [ssh, "-tt"]
            // Multiplex every terminal to a host over ONE shared master connection: authenticate
            // once, then new terminals AND reconnects reuse it (no repeated password prompts). The
            // master persists ~10 min after the last session (ControlPersist).
            args += Self.sshControlMasterArgs()
            // With an auto-supplied password we feed it via SSH_ASKPASS (see makeTransport), so make
            // ssh non-interactive about the host key (else that prompt would consume the password).
            if let pw = password, !pw.isEmpty {
                args += ["-o", "StrictHostKeyChecking=accept-new", "-o", "NumberOfPasswordPrompts=1"]
            }
            args += sshArgs
            args += [host, "--", "tmux", "-u", "-CC"]
            args += tmuxSubcommand
            return (ssh, args)
        }
    }

    /// Ensure `~/.ssh` exists (mode 700) so ssh can place the ControlMaster socket there.
    private static func ensureSSHControlDir() {
        let dir = ("~/.ssh" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    /// The ssh ControlMaster options shared by EVERY ssh invocation to a host (interactive `-CC`
    /// terminals AND one-shot queries like remote session listing). Sharing the exact same options
    /// is what lets a one-shot reuse the authenticated master a live terminal already brought up —
    /// so listing a remote host's sessions never re-prompts for a password. Also ensures `~/.ssh`.
    public static func sshControlMasterArgs() -> [String] {
        ensureSSHControlDir()
        return ["-o", "ControlMaster=auto",
                "-o", "ControlPath=~/.ssh/tfa-cm-%C",
                "-o", "ControlPersist=600"]
    }

    /// The environment that feeds `password` to ssh via SSH_ASKPASS (no controlling terminal needed),
    /// or nil if there's no password / the helper couldn't be written. Reused by one-shot queries so
    /// they can authenticate when no master is up yet, exactly like an interactive connection.
    public static func askpassEnv(password: String?) -> [String: String]? {
        guard let pw = password, !pw.isEmpty, let script = askpassScript() else { return nil }
        return [
            "SSH_ASKPASS": script,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ":0",
            "TFA_SSH_PASSWORD": pw,
        ]
    }

    public func makeTransport() throws -> PtyProcessTransport {
        let (exec, argv) = try resolvedArgv()
        let transport = PtyProcessTransport(execPath: exec, argv: argv, cols: cols, rows: rows)
        // ssh reads the password from /dev/tty, which a posix_spawn'd child lacks. Supply it via
        // SSH_ASKPASS instead (works without a controlling terminal). The helper just echoes the
        // password from the (in-memory, per-process) env var.
        if isRemote, let env = Self.askpassEnv(password: password) {
            transport.extraEnv = env
        }
        return transport
    }

    /// Write (once) a tiny askpass helper that echoes `$TFA_SSH_PASSWORD`, and return its path.
    private static func askpassScript() -> String? {
        let path = NSTemporaryDirectory() + "tfa-askpass.sh"
        let body = "#!/bin/sh\nprintf '%s\\n' \"$TFA_SSH_PASSWORD\"\n"
        if (try? String(contentsOfFile: path, encoding: .utf8)) != body {
            guard (try? body.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return nil }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }
}

/// Locates the tmux binary across common install locations (GUI apps inherit a minimal PATH).
public enum TmuxLocator {
    public static func find() -> String? {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
            "/run/current-system/sw/bin/tmux",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}
