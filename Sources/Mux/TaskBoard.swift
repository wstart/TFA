import Foundation
import Observation
import SQLite3

// MARK: - Board model
//
// The task board is a SHARED SQLite DB at ~/.tfa/board.db so the TFA app, the `tfa-task` CLI, and the
// agents running inside terminals can all read/write it concurrently (WAL mode + row-level UPDATEs —
// no whole-file races). TFA polls `PRAGMA data_version` to notice another process's commits and
// reloads its in-memory snapshot live.

/// A task's lifecycle column on the Kanban board.
enum TaskStatus: String, CaseIterable, Identifiable {
    case todo, doing, done, blocked
    var id: String { rawValue }
    var label: String {
        switch self {
        case .todo: return "待办"
        case .doing: return "进行中"
        case .done: return "已完成"
        case .blocked: return "受阻"
        }
    }
    var symbol: String {
        switch self {
        case .todo: return "circle"
        case .doing: return "play.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.octagon.fill"
        }
    }
}

/// One entry in a task's execution log (posted by a human or an agent). `kind` lets the timeline
/// render steps, blockers, and questions distinctly.
struct TaskComment: Identifiable, Hashable {
    var id = UUID()
    var by: String
    var text: String
    var at: Double
    var kind: String = "note"   // note | step | blocked | question

    var symbol: String {
        switch kind {
        case "step": return "arrow.turn.down.right"
        case "blocked": return "exclamationmark.octagon.fill"
        case "question": return "questionmark.bubble.fill"
        default: return "text.bubble"
        }
    }
}

/// A board task. `assignee` is an agent id (see BoardAgent). `order` keeps manual ordering within a
/// column (smaller = higher).
struct BoardTask: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var body: String = ""
    var status: TaskStatus = .todo
    var assignee: String? = nil
    var createdAt: Double = 0
    var updatedAt: Double = 0
    var order: Double = 0
    var comments: [TaskComment] = []
}

/// An agent that can be assigned work. TFA auto-registers each of its terminals (id `tfa:<groupKey>`,
/// `session` ties back to the tmux session so TFA can dispatch into it). External processes self-
/// The board's agents ARE TFA's open terminals (one per `tfa:<groupKey>`). `session` ties it back to
/// the tmux session so TFA can dispatch into it. (There is no separate external-registration concept.)
struct BoardAgent: Identifiable, Hashable {
    var id: String
    var name: String
    var kind: String = ""
    var session: String? = nil
    var cwd: String = ""
    var lastSeen: Double = 0
}

/// In-memory snapshot of the whole board (rebuilt from SQLite on every change). Observed by the view.
/// Equatable so `reload()` can skip publishing when nothing actually changed (no spurious re-render).
struct Board: Equatable {
    var agents: [BoardAgent] = []
    var tasks: [BoardTask] = []
}

// MARK: - Store (SQLite-backed)

@MainActor
@Observable
final class TaskBoardStore {
    private(set) var board = Board()

    /// `~/.tfa/board.db` — a stable, agent-reachable path the `tfa-task` CLI also opens.
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tfa", isDirectory: true)
    static let dbURL = dir.appendingPathComponent("board.db")

    @ObservationIgnored private var db: OpaquePointer?
    @ObservationIgnored private var lastDataVersion: Int64 = -1

    init() {
        // The store is constructed during AppModel() on the MAIN thread before the window appears, so
        // keep init light: open the (tiny) DB synchronously, but push the agent-tooling file writes
        // (CLI + skill, ~9KB + chmod) OFF the main thread — they're only needed by agents in terminals.
        Task.detached(priority: .utility) { AgentTooling.install() }
        openDB(); reload()
    }
    deinit { if let db { sqlite3_close(db) } }

    /// When true (board on screen) the app heartbeat checks every tick for a live feel; when false
    /// it checks every few ticks — agent ask/block still surfaces attention while the board is CLOSED.
    @ObservationIgnored var watchFast = false

    /// ONE change-check, called from the app's single scheduler heartbeat. Polls PRAGMA data_version —
    /// it bumps when ANOTHER connection (the CLI / an agent) commits, so we reload only when
    /// something actually changed. Cheap; our own writes don't bump it.
    func tickIfChanged() {
        let v = dataVersion()
        if v != lastDataVersion { lastDataVersion = v; reload() }
    }

    // MARK: queries

    func tasks(in status: TaskStatus) -> [BoardTask] {
        board.tasks.filter { $0.status == status }.sorted { $0.order < $1.order }
    }
    func agent(_ id: String?) -> BoardAgent? { id.flatMap { aid in board.agents.first { $0.id == aid } } }
    func task(_ id: UUID) -> BoardTask? { board.tasks.first { $0.id == id } } // live read (for the open editor)

    // MARK: mutations

    func addTask(title: String, body: String = "") {
        let t = Self.now()
        let minOrder = scalarDouble("SELECT MIN(ord) FROM tasks WHERE status='todo'") ?? 0
        run("INSERT INTO tasks (id,title,body,status,assignee,createdAt,updatedAt,ord) VALUES (?,?,?,?,NULL,?,?,?)",
            [.t(UUID().uuidString.lowercased()), .t(title), .t(body), .t("todo"), .d(t), .d(t), .d(minOrder - 1)])
        reloadAndStamp()
    }
    /// Update only title/body (so a human editing the card never clobbers status/comments the agent
    /// changed concurrently).
    func updateTitleBody(_ id: UUID, title: String, body: String) {
        run("UPDATE tasks SET title=?,body=?,updatedAt=? WHERE id=?", [.t(title), .t(body), .d(Self.now()), .t(idStr(id))])
        reloadAndStamp()
    }
    func update(_ task: BoardTask) {
        run("UPDATE tasks SET title=?,body=?,status=?,assignee=?,updatedAt=?,ord=? WHERE id=?",
            [.t(task.title), .t(task.body), .t(task.status.rawValue), .tOpt(task.assignee), .d(Self.now()), .d(task.order), .t(idStr(task.id))])
        reloadAndStamp()
    }
    func delete(_ id: UUID) {
        run("DELETE FROM comments WHERE taskId=?", [.t(idStr(id))])
        run("DELETE FROM tasks WHERE id=?", [.t(idStr(id))])
        reloadAndStamp()
    }
    func move(_ id: UUID, to status: TaskStatus) {
        let top = (scalarDouble("SELECT MIN(ord) FROM tasks WHERE status=?", [.t(status.rawValue)]) ?? 0) - 1
        run("UPDATE tasks SET status=?,ord=?,updatedAt=? WHERE id=?", [.t(status.rawValue), .d(top), .d(Self.now()), .t(idStr(id))])
        reloadAndStamp()
    }
    func setAssignee(_ id: UUID, to agentID: String?) {
        run("UPDATE tasks SET assignee=?,updatedAt=? WHERE id=?", [.tOpt(agentID), .d(Self.now()), .t(idStr(id))])
        reloadAndStamp()
    }
    /// Re-point every task from one agent id to another (terminal rename: "tfa:<old>" → "tfa:<new>"),
    /// so a rename never strands its tasks under a dead id.
    func migrateAssignee(from old: String, to new: String) {
        guard old != new else { return }
        run("UPDATE tasks SET assignee=? WHERE assignee=?", [.t(new), .t(old)])
        reloadAndStamp()
    }
    func addComment(_ id: UUID, by: String, text: String, kind: String = "note") {
        let t = Self.now()
        run("INSERT INTO comments (id,taskId,by,text,at,kind) VALUES (?,?,?,?,?,?)",
            [.t(UUID().uuidString.lowercased()), .t(idStr(id)), .t(by), .t(text), .d(t), .t(kind)])
        run("UPDATE tasks SET updatedAt=? WHERE id=?", [.d(t), .t(idStr(id))])
        reloadAndStamp()
    }

    /// Replace the agent list with TFA's current terminals — the board's agents simply ARE the open
    /// terminals (no external-registration to preserve).
    func syncManagedAgents(_ managed: [BoardAgent]) {
        let now = Self.now()
        exec("BEGIN")
        run("DELETE FROM agents")
        for a in managed {
            run("INSERT OR REPLACE INTO agents (id,name,kind,session,cwd,lastSeen) VALUES (?,?,?,?,?,?)",
                [.t(a.id), .t(a.name), .t(a.kind), .tOpt(a.session), .t(a.cwd), .d(now)])
        }
        exec("COMMIT")
        reloadAndStamp()
    }

    // MARK: schema + IO

    private func openDB() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        guard sqlite3_open_v2(Self.dbURL.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { db = nil; return }
        sqlite3_busy_timeout(db, 3000)
        exec("PRAGMA journal_mode=WAL")   // concurrent readers + one writer across processes
        exec("PRAGMA synchronous=NORMAL")
        exec("""
            CREATE TABLE IF NOT EXISTS tasks (
              id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL DEFAULT '',
              status TEXT NOT NULL DEFAULT 'todo', assignee TEXT,
              createdAt REAL NOT NULL DEFAULT 0, updatedAt REAL NOT NULL DEFAULT 0, ord REAL NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS comments (
              id TEXT PRIMARY KEY, taskId TEXT NOT NULL, by TEXT NOT NULL DEFAULT 'agent',
              text TEXT NOT NULL DEFAULT '', at REAL NOT NULL DEFAULT 0, kind TEXT NOT NULL DEFAULT 'note');
            CREATE TABLE IF NOT EXISTS agents (
              id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL DEFAULT '',
              session TEXT, cwd TEXT NOT NULL DEFAULT '', external INTEGER NOT NULL DEFAULT 0, lastSeen REAL NOT NULL DEFAULT 0);
            """)
        // Migrate older DBs that predate the comment-kind column (errors harmlessly if it exists).
        exec("ALTER TABLE comments ADD COLUMN kind TEXT NOT NULL DEFAULT 'note'")
    }

    private func reload() {
        guard db != nil else { return }
        var tasks: [BoardTask] = []
        var commentsByTask: [String: [TaskComment]] = [:]
        query("SELECT id,taskId,by,text,at,kind FROM comments ORDER BY at ASC") { s in
            let tid = colText(s, 1)
            commentsByTask[tid, default: []].append(TaskComment(
                id: UUID(uuidString: colText(s, 0)) ?? UUID(), by: colText(s, 2), text: colText(s, 3),
                at: colDouble(s, 4), kind: colText(s, 5)))
        }
        query("SELECT id,title,body,status,assignee,createdAt,updatedAt,ord FROM tasks") { s in
            let idText = colText(s, 0)
            tasks.append(BoardTask(
                id: UUID(uuidString: idText) ?? UUID(), title: colText(s, 1), body: colText(s, 2),
                status: TaskStatus(rawValue: colText(s, 3)) ?? .todo, assignee: colTextOpt(s, 4),
                createdAt: colDouble(s, 5), updatedAt: colDouble(s, 6), order: colDouble(s, 7),
                comments: commentsByTask[idText] ?? []))
        }
        var agents: [BoardAgent] = []
        query("SELECT id,name,kind,session,cwd,lastSeen FROM agents") { s in
            agents.append(BoardAgent(
                id: colText(s, 0), name: colText(s, 1), kind: colText(s, 2), session: colTextOpt(s, 3),
                cwd: colText(s, 4), lastSeen: colDouble(s, 5)))
        }
        let next = Board(agents: agents, tasks: tasks)
        if next != board { board = next } // only invalidate observers on a real change
    }
    private func reloadAndStamp() { reload(); lastDataVersion = dataVersion() } // ignore our own write on next poll

    // MARK: tiny SQLite helpers

    private enum Bind { case t(String), tOpt(String?), d(Double) }

    @discardableResult private func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    private func run(_ sql: String, _ binds: [Bind] = []) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        sqlite3_step(stmt)
    }
    private func query(_ sql: String, _ binds: [Bind] = [], _ row: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }
    private func scalarDouble(_ sql: String, _ binds: [Bind] = []) -> Double? {
        var out: Double?
        query(sql, binds) { s in if sqlite3_column_type(s, 0) != SQLITE_NULL { out = sqlite3_column_double(s, 0) } }
        return out
    }
    private func bind(_ stmt: OpaquePointer?, _ binds: [Bind]) {
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .t(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .tOpt(let s): if let s { sqlite3_bind_text(stmt, idx, s, -1, Self.transient) } else { sqlite3_bind_null(stmt, idx) }
            case .d(let d): sqlite3_bind_double(stmt, idx, d)
            }
        }
    }
    private func dataVersion() -> Int64 {
        var v: Int64 = -1
        query("PRAGMA data_version") { s in v = sqlite3_column_int64(s, 0) }
        return v
    }

    private func colText(_ s: OpaquePointer?, _ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
    private func colTextOpt(_ s: OpaquePointer?, _ i: Int32) -> String? { sqlite3_column_type(s, i) == SQLITE_NULL ? nil : colText(s, i) }
    private func colDouble(_ s: OpaquePointer?, _ i: Int32) -> Double { sqlite3_column_double(s, i) }

    private func idStr(_ id: UUID) -> String { id.uuidString.lowercased() }
    static func now() -> Double { Date().timeIntervalSince1970 }
    /// SQLITE_TRANSIENT — tells SQLite to COPY the bound text (so our transient Swift String is safe).
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
