import Foundation
import SQLite3

/// A bound SQL value.
public enum SQLValue {
    case null
    case int(Int64)
    case real(Double)
    case text(String)

    static func opt(_ s: String?) -> SQLValue { s.map(SQLValue.text) ?? .null }
    static func opt(_ d: Double?) -> SQLValue { d.map(SQLValue.real) ?? .null }
    static func bool(_ b: Bool) -> SQLValue { .int(b ? 1 : 0) }
}

/// One result row, read by column index.
struct SQLRow {
    fileprivate let values: [SQLValue]
    func text(_ i: Int) -> String { if case .text(let s) = values[i] { return s }; return "" }
    func optText(_ i: Int) -> String? { if case .text(let s) = values[i] { return s }; return nil }
    func int(_ i: Int) -> Int64 {
        switch values[i] { case .int(let v): return v; case .real(let d): return Int64(d); default: return 0 }
    }
    func optInt(_ i: Int) -> Int64? {
        switch values[i] { case .int(let v): return v; case .real(let d): return Int64(d); default: return nil }
    }
    func double(_ i: Int) -> Double {
        switch values[i] { case .real(let d): return d; case .int(let v): return Double(v); default: return 0 }
    }
    func optDouble(_ i: Int) -> Double? {
        switch values[i] { case .real(let d): return d; case .int(let v): return Double(v); default: return nil }
    }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// Minimal SQLite connection: WAL, a busy timeout shared by the app and the `tfa` CLI, and
/// `BEGIN IMMEDIATE` transactions so two writers never interleave a read-modify-write.
final class SQLiteDB {
    private let handle: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            throw SQLiteError(message: "无法打开数据库 \(path)：\(msg)")
        }
        handle = db
        sqlite3_busy_timeout(handle, 5000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA foreign_keys=ON")
    }

    deinit { sqlite3_close(handle) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(message: msg)
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: [SQLValue] = []) throws -> Int {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError() }
        return Int(sqlite3_changes(handle))
    }

    func query(_ sql: String, _ args: [SQLValue] = []) throws -> [SQLRow] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError() }
            let n = sqlite3_column_count(stmt)
            var values: [SQLValue] = []
            values.reserveCapacity(Int(n))
            for i in 0..<n {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: values.append(.int(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT: values.append(.real(sqlite3_column_double(stmt, i)))
                case SQLITE_TEXT: values.append(.text(String(cString: sqlite3_column_text(stmt, i))))
                default: values.append(.null)
                }
            }
            rows.append(SQLRow(values: values))
        }
        return rows
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Changes whenever ANOTHER connection commits — the app polls it to notice CLI writes.
    var dataVersion: Int64 { (try? query("PRAGMA data_version").first?.int(0)) ?? 0 }

    private var depth = 0

    /// Runs `body` in one `BEGIN IMMEDIATE` transaction (nested calls join the outer one).
    func transaction<T>(_ body: () throws -> T) throws -> T {
        if depth > 0 { return try body() }
        try exec("BEGIN IMMEDIATE")
        depth = 1
        do {
            let value = try body()
            depth = 0
            try exec("COMMIT")
            return value
        } catch {
            depth = 0
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            }
        }
        return stmt
    }

    private func lastError() -> SQLiteError { SQLiteError(message: String(cString: sqlite3_errmsg(handle))) }
}
