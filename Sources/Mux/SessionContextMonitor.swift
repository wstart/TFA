import Foundation
import Observation

/// Polls lightweight dev context for each connected LOCAL terminal — the git branch of its working
/// directory and the TCP ports its process tree is listening on — for display in the sidebar row.
/// One `lsof` + one `ps` per tick are shared across all sessions (O(processes), not O(sessions)).
/// Remote (ssh) sessions are skipped (their git/ports live on the remote host).
@MainActor
@Observable
final class SessionContextMonitor {
    struct Context: Equatable { var branch: String?; var ports: [Int] }
    private(set) var byID: [UUID: Context] = [:]

    /// Supplies the current connected-local terminals to inspect (id + cwd + shell pid). Set by AppModel.
    @ObservationIgnored var snapshot: (() -> [(id: UUID, path: String, pid: Int)])?
    @ObservationIgnored private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor in
            while !Task.isCancelled {
                let snap = snapshot?() ?? []
                if snap.isEmpty {
                    if !byID.isEmpty { byID = [:] }
                } else {
                    let result = await Task.detached(priority: .utility) { Self.compute(snap) }.value
                    if result != byID { byID = result }
                }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }
    func stop() { task?.cancel(); task = nil }

    func context(_ id: UUID) -> Context? { byID[id] }

    // MARK: - off-main computation

    nonisolated private static func compute(_ snap: [(id: UUID, path: String, pid: Int)]) -> [UUID: Context] {
        let rootPIDs = Set(snap.map(\.pid).filter { $0 > 0 })
        let portsByRoot = rootPIDs.isEmpty ? [:] : listeningPorts(rootPIDs: rootPIDs)
        var out: [UUID: Context] = [:]
        for s in snap {
            out[s.id] = Context(branch: gitBranch(s.path), ports: portsByRoot[s.pid] ?? [])
        }
        return out
    }

    /// `git -C <path> symbolic-ref --short HEAD` — the current branch, or nil (detached / not a repo).
    nonisolated private static func gitBranch(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let out = run("/usr/bin/git", ["-C", path, "symbolic-ref", "--short", "-q", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    /// Map each root (pane shell) pid → the sorted TCP ports its descendant processes listen on.
    /// Builds a pid→ppid map once (`ps`) and a listener pid→ports map once (`lsof`), then attributes
    /// each listener to whichever root pid is its ancestor.
    nonisolated private static func listeningPorts(rootPIDs: Set<Int>) -> [Int: [Int]] {
        // Parent map: "pid ppid" per line.
        var parent: [Int: Int] = [:]
        for line in run("/bin/ps", ["-axo", "pid=,ppid="]).split(separator: "\n") {
            let p = line.split(whereSeparator: { $0 == " " }).compactMap { Int($0) }
            if p.count == 2 { parent[p[0]] = p[1] }
        }
        // Listener pid → ports, from lsof field output (`p<pid>` then `n<host:port>` records).
        var portsByPid: [Int: Set<Int>] = [:]
        var cur = 0
        for line in run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"]).split(separator: "\n") {
            guard let tag = line.first else { continue }
            if tag == "p" { cur = Int(line.dropFirst()) ?? 0 }
            else if tag == "n", cur > 0, let portStr = line.split(separator: ":").last, let port = Int(portStr) {
                portsByPid[cur, default: []].insert(port)
            }
        }
        // Attribute each listener to its ancestor root pid (walk ppid chain, bounded).
        var portsByRoot: [Int: Set<Int>] = [:]
        for (pid, ports) in portsByPid {
            if let root = ancestorRoot(pid, in: rootPIDs, parent: parent) {
                portsByRoot[root, default: []].formUnion(ports)
            }
        }
        return portsByRoot.mapValues { $0.sorted() }
    }

    /// Walk `pid`'s ancestry (including itself) up to a depth cap; return the first ancestor that is a
    /// root pid, or nil.
    nonisolated private static func ancestorRoot(_ pid: Int, in roots: Set<Int>, parent: [Int: Int]) -> Int? {
        var cur = pid
        var depth = 0
        while depth < 40 {
            if roots.contains(cur) { return cur }
            guard let p = parent[cur], p > 1, p != cur else { return nil }
            cur = p; depth += 1
        }
        return nil
    }

    /// Run a command, returning stdout as a String ("" on any failure). stderr is discarded.
    nonisolated private static func run(_ path: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
