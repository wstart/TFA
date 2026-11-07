import Foundation

/// TFA 已知的项目目录：各 tmux 会话（终端）所在的目录 + TFA 工作区里登记的项目。
/// 人只说「改一下 TFA」没给路径时，主管用它按名字找到目录，而不是把工单开在家目录里。
enum KnownProjects {
    struct Entry: Equatable {
        var path: String
        /// 终端名 / 项目名（按出现顺序，去重）。
        var names: [String]
        var git: Bool
    }

    /// 收集（会跑一次 `tmux list-panes`，读 TFA 的偏好设置）。
    static func list(env: [String: String]) -> [Entry] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tfaHome = (env["TFA_HOME"]?.isEmpty == false ? env["TFA_HOME"]! : home + "/.tfa")
        let workspace = UserDefaults(suiteName: "com.tfa.app")?.data(forKey: "workspace.projects")
        return build(paneLines: tmuxPanes(env: env), workspaceJSON: workspace, home: home, exclude: [tfaHome],
                     isGit: { gitRoot($0) })
    }

    /// 纯函数（可测）：`paneLines` 每行 `会话名\u{1f}目录`。家目录、根目录、TFA 自己的目录（worktree 等）不算项目。
    static func build(paneLines: [String], workspaceJSON: Data?, home: String, exclude: [String],
                      isGit: (String) -> Bool) -> [Entry] {
        var order: [String] = []
        var names: [String: [String]] = [:]
        func add(_ path: String, _ name: String) {
            let p = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
            guard !p.isEmpty, p != home, p != "/", !exclude.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) else { return }
            if names[p] == nil { order.append(p); names[p] = [] }
            if !name.isEmpty, !names[p]!.contains(name) { names[p]!.append(name) }
        }
        struct Project: Decodable { var name: String; var path: String }
        if let data = workspaceJSON, let projects = try? JSONDecoder().decode([Project].self, from: data) {
            for p in projects { add(p.path, p.name) }
        }
        for line in paneLines {
            let f = line.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            guard f.count == 2 else { continue }
            add(String(f[1]), String(f[0]))
        }
        return order.map { Entry(path: $0, names: names[$0] ?? [], git: isGit($0)) }
    }

    static func render(_ list: [Entry]) -> String {
        guard !list.isEmpty else { return "TFA 里没有已知的项目目录（终端都在家目录）。请问人要改哪个目录。\n" }
        var out = "TFA 已知的项目目录（人没说目录时，按人提到的名字选唯一明显匹配的一个，用 --dir 指定；拿不准就问人）：\n"
        for e in list {
            var line = e.path
            if e.git { line += " · git" }
            if !e.names.isEmpty { line += " · " + e.names.joined(separator: "、") }
            out += line + "\n"
        }
        return out
    }

    /// 目录自己或上级有 `.git`（不 fork git）。
    static func gitRoot(_ path: String) -> Bool {
        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return true }
            url.deleteLastPathComponent()
        }
        return false
    }

    /// 每个会话活动窗格的目录。找不到 tmux 或服务器没在跑 → 空。
    private static func tmuxPanes(env: [String: String]) -> [String] {
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        guard let tmux = dirs.map({ $0 + "/tmux" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmux)
        p.arguments = ["-u", "list-panes", "-a", "-F", "#{window_active}#{pane_active}\u{1f}#{session_name}\u{1f}#{pane_current_path}"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false)
            guard f.count == 3, f[0] == "11" else { return nil }
            return f[1] + "\u{1f}" + f[2]
        }
    }
}
