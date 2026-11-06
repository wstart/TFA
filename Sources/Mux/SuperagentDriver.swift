import Foundation
import TmuxKit

/// 一个工单 / 主管会话里跑 agent 的那个窗格此刻的状态（Superagent 的 Pass 每轮取一次快照）。
struct SuperagentPane: Equatable, Sendable {
    var session: String
    /// tmux 窗格 id（`%N`）：所有打字 / 截屏都对准它——人在同一会话里另开的窗口或分屏不受影响。
    var pane: String
    /// `@tfa_ticket` 会话选项：这个会话是哪个工单的执行终端。
    var ticket: Int64?
    /// `@tfa_role` = router：「主管」终端。
    var isRouter: Bool
    /// 最近一次输出的时间（epoch 秒，`window_activity`）。
    var activity: Int
    /// 前台命令（`pane_current_command`）。
    var command: String

    /// 前台是裸 shell = 没在跑 agent（打字进去会被 shell 当命令执行）。
    var isPlainShell: Bool { Self.isShell(command) }
    static func isShell(_ command: String) -> Bool { plainShells.contains(command.lowercased()) }
    static let plainShells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "tcsh", "csh", "ksh", "-zsh", "-bash", "login"]
}

/// Superagent 用到的 tmux / git 操作。全部是一次性子进程（不需要 `-CC` 连接，对没 attach 的会话也有效），
/// 阻塞调用——运行时在后台线程上调它们。
struct SuperagentTmux: Sendable {
    var tmuxPath: String? = TmuxLocator.find()
    /// 测试用私有 socket；nil = 默认服务器。
    var socketName: String?

    struct Failure: Error, CustomStringConvertible { let description: String }

    @discardableResult
    func run(_ args: [String]) -> (status: Int32, out: String, err: String) {
        guard let tmux = tmuxPath else { return (127, "", "找不到 tmux") }
        var full: [String] = []
        if let socketName { full += ["-L", socketName] }
        return Self.exec(tmux, full + ["-u"] + args)
    }

    static func exec(_ path: String, _ args: [String], cwd: String? = nil) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = TmuxServer.utf8Environment()
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (127, "", "\(error)") }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    /// 每个会话一个窗格：标记过的 agent 窗格（`@tfa_pane`），没标记就取活动窗格。
    /// nil = 查询失败（不能据此判断会话没了）；[] = 服务器没在跑（会话确实都没了）。
    func snapshot() -> [SuperagentPane]? {
        let r = run(["list-panes", "-a", "-F",
                     "#{pane_id}\u{1f}#{@tfa_pane}\u{1f}#{window_active}#{pane_active}\u{1f}#{@tfa_ticket}\u{1f}#{@tfa_role}\u{1f}#{window_activity}\u{1f}#{pane_current_command}\u{1f}#{session_name}"])
        guard r.status == 0 else {
            let e = r.err.lowercased()
            return e.contains("no server running") || e.contains("error connecting") ? [] : nil
        }
        var tagged: [String: SuperagentPane] = [:], active: [String: SuperagentPane] = [:]
        var marked: Set<String> = [], order: [String] = []
        for line in r.out.split(separator: "\n") {
            let f = line.split(separator: "\u{1f}", maxSplits: 7, omittingEmptySubsequences: false)
            guard f.count == 8 else { continue }
            let session = String(f[7])
            let pane = SuperagentPane(session: session, pane: String(f[0]), ticket: Int64(f[3]), isRouter: f[4] == "router",
                                      activity: Int(f[5]) ?? 0, command: String(f[6]))
            if !order.contains(session) { order.append(session) }
            if !f[1].isEmpty { marked.insert(session) }
            if f[0] == f[1] { tagged[session] = pane }
            if f[2] == "11" { active[session] = pane }
        }
        // 标记过 agent 窗格的会话只认那个窗格（它被关了 = 会话里没有 agent 了）；没标记的取活动窗格。
        return order.compactMap { marked.contains($0) ? tagged[$0] : active[$0] }
    }

    /// 建一个后台会话（不抢焦点），打上工单 / 主管标记，并记下 agent 窗格。返回窗格 id。
    @discardableResult
    func newSession(name: String, dir: String, ticket: Int64? = nil, router: Bool = false) throws -> String {
        let r = run(["new-session", "-d", "-P", "-F", "#{pane_id}", "-s", name, "-c", dir, "-x", "160", "-y", "48"])
        guard r.status == 0 else { throw Failure(description: "建终端失败：\(r.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
        let pane = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        // `=name:` — set-option resolves a pane-style target; a bare `=name` reports "no such session".
        // An untagged terminal would be invisible to the next pass and get created again — fail loudly.
        var tags = [("@tfa_pane", pane)]
        if let ticket { tags.append(("@tfa_ticket", String(ticket))) }
        if router { tags.append(("@tfa_role", "router")) }
        for (option, value) in tags {
            let r = run(["set-option", "-t", "=\(name):", option, value])
            guard r.status == 0 else {
                run(["kill-session", "-t", "=\(name)"])
                throw Failure(description: "标记终端失败：\(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        return pane
    }

    /// 打一行字并提交：文本和回车分开发（agent TUI 会把「文本+回车」整块当成多行粘贴）。
    /// `target`：窗格 id（`%N`）或 `=会话:`。
    func type(_ target: String, _ text: String) {
        let line = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        run(["send-keys", "-t", target, "-l", "--", line])
        Thread.sleep(forTimeInterval: 0.25)
        run(["send-keys", "-t", target, "Enter"])
    }

    func sendKey(_ target: String, _ key: String) {
        run(["send-keys", "-t", target, key])
    }

    /// 窗格最近 `lines` 行（折行拼回一行，便于找送达标记）。
    func capture(_ target: String, lines: Int = 200) -> String {
        run(["capture-pane", "-p", "-J", "-S", "-\(lines)", "-t", target]).out
    }

    /// 末尾几行非空输出（停下未回报时附给人看）。
    func tail(_ target: String, lines: Int = 6) -> String {
        capture(target, lines: 60).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.suffix(lines).joined(separator: "\n")
    }

    /// 打字前的最后确认：此刻前台命令和最近输出时间（快照可能已是十几秒前的）。nil = 窗格没了。
    func paneState(_ target: String) -> (command: String, activity: Int)? {
        let r = run(["display-message", "-p", "-t", target, "#{pane_current_command}\u{1f}#{window_activity}"])
        guard r.status == 0 else { return nil }
        let f = r.out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\u{1f}", omittingEmptySubsequences: false)
        guard f.count == 2 else { return nil }
        return (String(f[0]), Int(f[1]) ?? 0)
    }

    /// Claude Code 对新目录弹出的「信任此文件夹」对话框，且说的正是 `dir`（TFA 自己建的工单目录）。
    static func showsTrustDialog(_ screen: String, for dir: String) -> Bool {
        guard screen.contains("trust this folder") || screen.contains("Do you trust") else { return false }
        let real = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        return screen.contains(dir) || screen.contains(real) || screen.contains("/private" + dir)
    }

    /// The agent is showing a dialog (folder trust, permission prompt, a picker): typed text + Enter
    /// would answer it on the person's behalf — e.g. Claude Code's trust dialog defaults to "No, exit".
    static func showsDialog(_ screen: String) -> Bool {
        let tail = screen.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.suffix(15).joined(separator: "\n")
        return dialogMarkers.contains { tail.contains($0) }
    }
    static let dialogMarkers = ["Enter to confirm", "Esc to cancel", "Do you want to proceed", "Do you want to make this edit",
                                "Do you trust", "trust this folder"]

    /// 在已有名字之外取一个可用的会话名（tmux 会话名不能含 `.` 和 `:`）。
    static func sessionName(_ base: String, taken: Set<String>) -> String {
        var clean = base.replacingOccurrences(of: ".", with: "·").replacingOccurrences(of: ":", with: "：")
        clean = clean.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: "-")
        if clean.isEmpty { clean = "工单" }
        var name = clean, i = 2
        while taken.contains(name) { name = "\(clean)-\(i)"; i += 1 }
        return name
    }

    // MARK: - git worktree

    /// 工单目录：git 仓库 → `~/.tfa/worktrees/<仓库名>-<工单号>`（分支 `tfa/<工单号>`），已存在就沿用；
    /// 非 git 目录或关了 worktree → 直接用原目录。返回 (目录, 分支)。
    /// `fresh` = 工单从没准备过目录：这时已存在的同名分支不是它的（库被重建过），换一个分支名。
    static func prepareDirectory(repo: String, ticket: Int64, worktree: Bool, root: URL, fresh: Bool = false) throws -> (dir: String, branch: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repo, isDirectory: &isDir), isDir.boolValue else {
            throw Failure(description: "目录不存在：\(repo)")
        }
        guard worktree else { return (repo, "") }
        let git = "/usr/bin/git"
        let top = exec(git, ["-C", repo, "rev-parse", "--show-toplevel"])
        guard top.status == 0 else { return (repo, "") } // 不是 git 仓库
        let toplevel = top.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let sub = repo.hasPrefix(toplevel) ? String(repo.dropFirst(toplevel.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : ""
        let name = URL(fileURLWithPath: toplevel).lastPathComponent
        let path = root.appendingPathComponent("\(name)-\(ticket)").path
        var branch = "tfa/\(ticket)"
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // 目录被人手动删掉时 git 还记着它（"missing but already registered worktree"）：先清理。
            _ = exec(git, ["-C", toplevel, "worktree", "prune"])
            func exists(_ b: String) -> Bool { exec(git, ["-C", toplevel, "rev-parse", "--verify", "--quiet", "refs/heads/\(b)"]).status == 0 }
            if fresh, exists(branch) {
                var n = 2
                while exists("tfa/\(ticket)-\(n)") { n += 1 }
                branch = "tfa/\(ticket)-\(n)"
            }
            let hasBranch = exists(branch)
            let r = hasBranch ? exec(git, ["-C", toplevel, "worktree", "add", path, branch])
                              : exec(git, ["-C", toplevel, "worktree", "add", "-b", branch, path])
            guard r.status == 0 else {
                throw Failure(description: "git worktree 失败：\(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        let dir = sub.isEmpty ? path : (path as NSString).appendingPathComponent(sub)
        return (FileManager.default.fileExists(atPath: dir) ? dir : path, branch)
    }

    /// 单引号转义，给打进 shell 的命令行用。
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
