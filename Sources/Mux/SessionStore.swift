import Foundation
import SQLite3

// MARK: - 会话持久化(决议:重启 / tmux 关闭后恢复对话)
//
// tmux 把会话 / 窗格 / scrollback / 正在跑的程序只放在服务器进程的内存里——重启电脑或
// `tmux kill-server` 杀掉该进程后,磁盘上什么都不剩,全部丢失。要恢复,只能在重启发生**之前**
// 把状态定期写盘。本 store 就是那份磁盘快照:一个 TFA 自有的轻量 SQLite(`~/.tfa/sessions.db`,
// 与 agent 共享的 `board.db` 分开),每个**本地**终端一行——按永久 `@tfa_id` 关联,所以恢复出来的
// 终端会自动接回它原来的环境变量 / 分组 / 看板指派(见 AppModel 的身份系统)。
//
// 启动时:roster 里有、但活着的 tmux 服务器没有的会话 = 重启丢的 → 以休眠占位重建。

/// 一个会话的磁盘快照行。
struct SessionRecord {
    var tfaID: String
    var name: String
    var cwd: String
    var command: String   // 抓快照时该窗格在跑的命令(`pane_current_command`),用于 AI 检测
    var isAI: Bool        // 是否 AI agent 会话(claude / codex)——决定恢复时是续接对话还是回放文本
    var scrollback: String
    var updatedAt: Double
}

@MainActor
final class SessionStore {
    nonisolated static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tfa", isDirectory: true)
    nonisolated static let dbURL = dir.appendingPathComponent("sessions.db")

    private var db: OpaquePointer?
    private let url: URL

    /// Defaults to the real `~/.tfa/sessions.db`; tests pass a temp URL to avoid touching it.
    init(dbURL: URL = SessionStore.dbURL) { self.url = dbURL; openDB() }
    deinit { if let db { sqlite3_close(db) } }

    private func openDB() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { db = nil; return }
        sqlite3_busy_timeout(db, 3000)
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("""
            CREATE TABLE IF NOT EXISTS sessions (
              tfa_id TEXT PRIMARY KEY, name TEXT NOT NULL, cwd TEXT NOT NULL DEFAULT '',
              command TEXT NOT NULL DEFAULT '', is_ai INTEGER NOT NULL DEFAULT 0,
              scrollback TEXT NOT NULL DEFAULT '', updated_at REAL NOT NULL DEFAULT 0);
            """)
    }

    // MARK: 读

    /// 所有持久化的会话行(恢复时按它重建)。
    func roster() -> [SessionRecord] {
        var out: [SessionRecord] = []
        query("SELECT tfa_id,name,cwd,command,is_ai,scrollback,updated_at FROM sessions ORDER BY updated_at DESC") { s in
            out.append(SessionRecord(
                tfaID: colText(s, 0), name: colText(s, 1), cwd: colText(s, 2), command: colText(s, 3),
                isAI: sqlite3_column_int64(s, 4) != 0, scrollback: colText(s, 5), updatedAt: colDouble(s, 6)))
        }
        return out
    }

    // MARK: 写

    /// 完整快照(含 scrollback)——周期性写盘时用。
    func upsert(_ r: SessionRecord) {
        run("""
            INSERT INTO sessions (tfa_id,name,cwd,command,is_ai,scrollback,updated_at)
            VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(tfa_id) DO UPDATE SET
              name=excluded.name, cwd=excluded.cwd, command=excluded.command,
              is_ai=excluded.is_ai, scrollback=excluded.scrollback, updated_at=excluded.updated_at;
            """,
            [.t(r.tfaID), .t(r.name), .t(r.cwd), .t(r.command), .i(r.isAI ? 1 : 0), .t(r.scrollback), .d(Date().timeIntervalSince1970)])
    }

    /// 只更新元数据(名字 / cwd / 命令),**保留已存的 scrollback**——干净退出时同步调用,
    /// 不做 async 的 `capture-pane`(退出路径来不及 await)。
    func upsertMeta(tfaID: String, name: String, cwd: String, command: String, isAI: Bool) {
        run("""
            INSERT INTO sessions (tfa_id,name,cwd,command,is_ai,scrollback,updated_at)
            VALUES (?,?,?,?,?,'',?)
            ON CONFLICT(tfa_id) DO UPDATE SET
              name=excluded.name, cwd=excluded.cwd, command=excluded.command,
              is_ai=excluded.is_ai, updated_at=excluded.updated_at;
            """,
            [.t(tfaID), .t(name), .t(cwd), .t(command), .i(isAI ? 1 : 0), .d(Date().timeIntervalSince1970)])
    }

    /// 用户显式 Kill 一个终端 → 不再恢复它。(detach 不删:detach 是为了下次恢复。)
    func remove(tfaID: String) {
        run("DELETE FROM sessions WHERE tfa_id=?", [.t(tfaID)])
    }

    // MARK: tiny SQLite helpers(同 TaskBoardStore 风格)

    private enum Bind { case t(String), i(Int64), d(Double) }

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
    private func bind(_ stmt: OpaquePointer?, _ binds: [Bind]) {
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .t(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .i(let v): sqlite3_bind_int64(stmt, idx, v)
            case .d(let d): sqlite3_bind_double(stmt, idx, d)
            }
        }
    }
    private func colText(_ s: OpaquePointer?, _ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
    private func colDouble(_ s: OpaquePointer?, _ i: Int32) -> Double { sqlite3_column_double(s, i) }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
