import Foundation

struct ToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct ToolResult: Equatable {
    var content: String
    var isError: Bool
}

/// Typed accessors over a tool_use `input` object. The server coerces XML parameters, so numbers
/// and booleans may arrive either as JSON scalars or as strings — accept both.
struct ToolInput {
    let raw: JSONValue

    func string(_ key: String) -> String? {
        switch raw[key] {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int64(n)) : String(n)
        case .bool(let b): return String(b)
        default: return nil
        }
    }

    func required(_ key: String) throws -> String {
        guard let v = string(key) else { throw ToolError("缺少参数 \(key)") }
        return v
    }

    func int(_ key: String) -> Int? {
        switch raw[key] {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    func bool(_ key: String) -> Bool {
        switch raw[key] {
        case .bool(let b): return b
        case .string(let s): return ["true", "1", "yes"].contains(s.lowercased())
        case .number(let n): return n != 0
        default: return false
        }
    }
}

struct Tool {
    let name: String
    let description: String
    let properties: [(String, String, String)]   // (name, JSON type, description)
    let required: [String]
    /// Mutating tools need user permission.
    let mutating: Bool
    /// Input key shown in the one-line call summary, e.g. `Bash(ls -la)`.
    let summaryKey: String
    let run: (ToolInput, URL) async throws -> ToolResult

    var schema: JSONValue {
        var props: [String: JSONValue] = [:]
        for (key, type, desc) in properties {
            props[key] = .object(["type": .string(type), "description": .string(desc)])
        }
        return .object([
            "name": .string(name),
            "description": .string(description),
            "input_schema": .object([
                "type": .string("object"),
                "properties": .object(props),
                "required": .array(required.map { .string($0) }),
            ]),
        ])
    }

    func summary(_ input: ToolInput) -> String {
        let arg = (input.string(summaryKey) ?? "").replacingOccurrences(of: "\n", with: " ")
        return "\(name)(\(arg.count > 80 ? String(arg.prefix(80)) + "…" : arg))"
    }
}

// MARK: - Helpers

func resolvePath(_ path: String, cwd: URL) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
    return cwd.appendingPathComponent(expanded).standardizedFileURL
}

/// Keeps the head and tail of long output so both the start and the final error remain visible.
func truncateMiddle(_ s: String, limit: Int) -> String {
    guard s.count > limit else { return s }
    let half = limit / 2
    return String(s.prefix(half)) + "\n…（省略 \(s.count - limit) 字符）…\n" + String(s.suffix(half))
}

private let skippedDirs: Set<String> = [".git", ".build", "node_modules"]

/// Recursively lists regular files under `root`, skipping VCS/build directories.
private func walkFiles(_ root: URL) -> [URL] {
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) else { return [] }
    var out: [URL] = []
    for case let url as URL in e {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values?.isDirectory == true {
            if skippedDirs.contains(url.lastPathComponent) { e.skipDescendants() }
        } else if values?.isRegularFile == true {
            out.append(url)
        }
    }
    return out
}

private func relativePath(_ url: URL, to root: URL) -> String {
    let r = root.standardizedFileURL.path
    let p = url.standardizedFileURL.path
    if p.hasPrefix(r + "/") { return String(p.dropFirst(r.count + 1)) }
    return p
}

/// Converts a shell glob (`*`, `?`, `**`, `{a,b}`) into an anchored regex over `/`-separated paths.
func globToRegex(_ glob: String) -> NSRegularExpression? {
    var re = "^"
    var chars = Array(glob)[...]
    var inBrace = false
    while let c = chars.popFirst() {
        switch c {
        case "*":
            if chars.first == "*" {
                chars.removeFirst()
                if chars.first == "/" { chars.removeFirst(); re += "(?:.*/)?" } else { re += ".*" }
            } else {
                re += "[^/]*"
            }
        case "?": re += "[^/]"
        case "{": inBrace = true; re += "(?:"
        case "}" where inBrace: inBrace = false; re += ")"
        case "," where inBrace: re += "|"
        default: re += NSRegularExpression.escapedPattern(for: String(c))
        }
    }
    return try? NSRegularExpression(pattern: re + "$")
}

private func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
    re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

private func isBinary(_ data: Data) -> Bool {
    data.prefix(8000).contains(0)
}

// MARK: - Tools

enum Tools {
    static let all: [Tool] = [read, write, edit, bash, glob, grep, ls]

    static func named(_ name: String) -> Tool? { all.first { $0.name == name } }

    static let read = Tool(
        name: "Read",
        description: "Read a text file. Returns lines prefixed with line numbers. Use offset/limit for large files.",
        properties: [
            ("path", "string", "File path (absolute or relative to the working directory)"),
            ("offset", "integer", "1-based line to start from"),
            ("limit", "integer", "Maximum number of lines (default 2000)"),
        ],
        required: ["path"], mutating: false, summaryKey: "path"
    ) { input, cwd in
        let url = resolvePath(try input.required("path"), cwd: cwd)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ToolError("文件不存在：\(url.path)")
        }
        if isDir.boolValue { throw ToolError("\(url.path) 是目录，请用 LS") }
        let data = try Data(contentsOf: url)
        if isBinary(data) { throw ToolError("\(url.path) 是二进制文件") }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let start = max(1, input.int("offset") ?? 1)
        let limit = max(1, input.int("limit") ?? 2000)
        guard start <= lines.count else { return ToolResult(content: "（文件共 \(lines.count) 行，offset 超出范围）", isError: false) }
        let end = min(lines.count, start - 1 + limit)
        var out = ""
        for i in (start - 1)..<end {
            var line = lines[i]
            if line.count > 2000 { line = String(line.prefix(2000)) + "…" }
            out += String(format: "%6d\t", i + 1) + line + "\n"
            if out.count > 100_000 {
                out += "…（输出过长，已在第 \(i + 1) 行截断，用 offset 继续读取）\n"
                break
            }
        }
        if out.isEmpty { out = "（空文件）" }
        return ToolResult(content: out, isError: false)
    }

    static let write = Tool(
        name: "Write",
        description: "Create or overwrite a file with the given content. Parent directories are created.",
        properties: [
            ("path", "string", "File path (absolute or relative to the working directory)"),
            ("content", "string", "Full file content"),
        ],
        required: ["path", "content"], mutating: true, summaryKey: "path"
    ) { input, cwd in
        let url = resolvePath(try input.required("path"), cwd: cwd)
        let content = try input.required("content")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return ToolResult(content: "已写入 \(content.utf8.count) 字节到 \(url.path)", isError: false)
    }

    static let edit = Tool(
        name: "Edit",
        description: "Replace an exact string in a file. old_string must match exactly and be unique unless replace_all is true. Read the file first.",
        properties: [
            ("path", "string", "File path (absolute or relative to the working directory)"),
            ("old_string", "string", "Exact text to replace"),
            ("new_string", "string", "Replacement text"),
            ("replace_all", "boolean", "Replace every occurrence (default false)"),
        ],
        required: ["path", "old_string", "new_string"], mutating: true, summaryKey: "path"
    ) { input, cwd in
        let url = resolvePath(try input.required("path"), cwd: cwd)
        let old = try input.required("old_string")
        let new = try input.required("new_string")
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("文件不存在：\(url.path)") }
        guard !old.isEmpty else { throw ToolError("old_string 不能为空") }
        guard old != new else { throw ToolError("old_string 与 new_string 相同") }
        let text = try String(contentsOf: url, encoding: .utf8)
        let count = text.components(separatedBy: old).count - 1
        if count == 0 { throw ToolError("未找到 old_string") }
        if count > 1 && !input.bool("replace_all") {
            throw ToolError("old_string 出现 \(count) 次，不唯一；请提供更多上下文或设置 replace_all")
        }
        let updated = input.bool("replace_all")
            ? text.replacingOccurrences(of: old, with: new)
            : text.replacingCharacters(in: text.range(of: old)!, with: new)
        try Data(updated.utf8).write(to: url)
        return ToolResult(content: "已替换 \(count) 处：\(url.path)", isError: false)
    }

    static let bash = Tool(
        name: "Bash",
        description: "Run a shell command with /bin/bash in the working directory. Returns combined stdout and stderr. Background processes are killed when the command ends.",
        properties: [
            ("command", "string", "The command to run"),
            ("timeout", "integer", "Timeout in seconds (default 120, max 600)"),
        ],
        required: ["command"], mutating: true, summaryKey: "command"
    ) { input, cwd in
        let command = try input.required("command")
        let timeout = min(600, max(1, input.int("timeout") ?? 120))
        let r = try await Shell.run(command, cwd: cwd, timeout: TimeInterval(timeout))
        var out = truncateMiddle(r.output, limit: 30_000)
        if r.timedOut { out += "\n[超时：\(timeout) 秒后已终止]" }
        else if r.status != 0 { out += "\n[exit code \(r.status)]" }
        if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out = "（无输出）" }
        return ToolResult(content: out, isError: r.timedOut || r.status != 0)
    }

    static let glob = Tool(
        name: "Glob",
        description: "Find files by glob pattern (e.g. **/*.swift, src/*.ts). Returns paths relative to the search directory.",
        properties: [
            ("pattern", "string", "Glob pattern; supports *, ?, ** and {a,b}"),
            ("path", "string", "Directory to search (default: working directory)"),
        ],
        required: ["pattern"], mutating: false, summaryKey: "pattern"
    ) { input, cwd in
        let pattern = try input.required("pattern")
        let root = resolvePath(input.string("path") ?? ".", cwd: cwd)
        guard let re = globToRegex(pattern) else { throw ToolError("无效的 glob：\(pattern)") }
        let hits = walkFiles(root).map { relativePath($0, to: root) }.filter { matches(re, $0) }.sorted()
        if hits.isEmpty { return ToolResult(content: "（无匹配文件）", isError: false) }
        var out = hits.prefix(200).joined(separator: "\n")
        if hits.count > 200 { out += "\n…（共 \(hits.count) 个，仅显示前 200 个）" }
        return ToolResult(content: out, isError: false)
    }

    static let grep = Tool(
        name: "Grep",
        description: "Search file contents with a regular expression. Returns path:line:text matches.",
        properties: [
            ("pattern", "string", "Regular expression (ICU syntax)"),
            ("path", "string", "File or directory to search (default: working directory)"),
            ("glob", "string", "Only search files matching this glob (e.g. *.swift)"),
            ("ignore_case", "boolean", "Case-insensitive search"),
        ],
        required: ["pattern"], mutating: false, summaryKey: "pattern"
    ) { input, cwd in
        let pattern = try input.required("pattern")
        let re: NSRegularExpression
        do {
            re = try NSRegularExpression(pattern: pattern, options: input.bool("ignore_case") ? [.caseInsensitive] : [])
        } catch { throw ToolError("无效的正则：\(pattern)") }
        let root = resolvePath(input.string("path") ?? ".", cwd: cwd)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) else {
            throw ToolError("路径不存在：\(root.path)")
        }
        var files = isDir.boolValue ? walkFiles(root) : [root]
        if let g = input.string("glob"), let gre = globToRegex(g) {
            files = files.filter { matches(gre, g.contains("/") ? relativePath($0, to: root) : $0.lastPathComponent) }
        }
        var out: [String] = []
        var total = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard let data = try? Data(contentsOf: file), data.count < 5_000_000, !isBinary(data) else { continue }
            let name = isDir.boolValue ? relativePath(file, to: root) : file.path
            for (i, line) in String(decoding: data, as: UTF8.self).components(separatedBy: "\n").enumerated() where matches(re, line) {
                total += 1
                if out.count < 200 {
                    out.append("\(name):\(i + 1):\(line.count > 300 ? String(line.prefix(300)) + "…" : line)")
                }
            }
        }
        if out.isEmpty { return ToolResult(content: "（无匹配）", isError: false) }
        var s = out.joined(separator: "\n")
        if total > out.count { s += "\n…（共 \(total) 处匹配，仅显示前 \(out.count) 处）" }
        return ToolResult(content: s, isError: false)
    }

    static let ls = Tool(
        name: "LS",
        description: "List a directory. Directories end with /.",
        properties: [("path", "string", "Directory (default: working directory)")],
        required: [], mutating: false, summaryKey: "path"
    ) { input, cwd in
        let url = resolvePath(input.string("path") ?? ".", cwd: cwd)
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() } catch {
            throw ToolError("无法列出目录：\(url.path)")
        }
        if names.isEmpty { return ToolResult(content: "（空目录）", isError: false) }
        let lines = names.prefix(500).map { name -> String in
            var d: ObjCBool = false
            FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &d)
            return d.boolValue ? name + "/" : name
        }
        var out = lines.joined(separator: "\n")
        if names.count > 500 { out += "\n…（共 \(names.count) 项，仅显示前 500 项）" }
        return ToolResult(content: out, isError: false)
    }
}

// MARK: - Shell

enum Shell {
    struct Result {
        var output: String
        var status: Int32
        var timedOut: Bool
    }

    /// Process group of the running command, so signal handlers can reclaim it on shutdown.
    private static let lock = NSLock()
    private static var activeGroups: Set<pid_t> = []

    static func killAll() {
        for g in lock.withLock({ activeGroups }) { _ = kill(-g, SIGKILL) }
    }

    /// Runs `command` via `/bin/bash -c` in its own process group (stdin = /dev/null, default
    /// signal dispositions). The whole group is SIGKILLed on timeout, task cancellation, or after
    /// the shell exits, so no descendants outlive the call.
    static func run(_ command: String, cwd: URL, timeout: TimeInterval) async throws -> Result {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw ToolError("pipe 失败") }
        let readFD = fds[0], writeFD = fds[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_addclose(&actions, writeFD)
        posix_spawn_file_actions_addchdir_np(&actions, cwd.path)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t()
        sigfillset(&defaults)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &empty)
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/bash"), strdup("-c"), strdup(command), nil]
        defer { argv.forEach { free($0) } }
        let rc = posix_spawn(&pid, "/bin/bash", &actions, &attr, argv, environ)
        close(writeFD)
        guard rc == 0 else {
            close(readFD)
            throw ToolError("无法启动 bash：\(String(cString: strerror(rc)))")
        }
        lock.withLock { _ = activeGroups.insert(pid) }

        let state = RunState()
        let killGroup = { _ = kill(-pid, SIGKILL) }

        return try await withTaskCancellationHandler {
            let output: Data = await withCheckedContinuation { cont in
                let group = DispatchGroup()
                var data = Data()
                // Reader: drains the pipe until every writer (incl. descendants) is gone.
                group.enter()
                DispatchQueue.global().async {
                    var buf = [UInt8](repeating: 0, count: 65536)
                    while true {
                        let n = read(readFD, &buf, buf.count)
                        if n <= 0 { break }
                        if data.count < 4_000_000 { data.append(buf, count: n) }
                    }
                    close(readFD)
                    group.leave()
                }
                // Waiter: reaps the shell, then kills leftover background descendants.
                group.enter()
                DispatchQueue.global().async {
                    var status: Int32 = 0
                    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                    state.setStatus(status)
                    killGroup()
                    group.leave()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if !state.finished { state.timedOut = true; killGroup() }
                }
                group.notify(queue: .global()) { cont.resume(returning: data) }
            }
            lock.withLock { _ = activeGroups.remove(pid) }
            if Task.isCancelled { throw CancellationError() }
            let raw = state.status
            let exit: Int32 = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
            return Result(output: String(decoding: output, as: UTF8.self), status: exit, timedOut: state.timedOut)
        } onCancel: {
            killGroup()
        }
    }

    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var _status: Int32 = 0
        private var _finished = false
        private var _timedOut = false
        var status: Int32 { lock.withLock { _status } }
        var finished: Bool { lock.withLock { _finished } }
        var timedOut: Bool {
            get { lock.withLock { _timedOut } }
            set { lock.withLock { _timedOut = newValue } }
        }
        func setStatus(_ s: Int32) { lock.withLock { _status = s; _finished = true } }
    }
}
