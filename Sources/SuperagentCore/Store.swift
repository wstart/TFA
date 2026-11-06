import CryptoKit
import Foundation

/// `~/.tfa/superagent.db` —— 唯一的事实来源。App 与 `tfa` 命令行各开一个连接；所有写入都经
/// `SuperagentEngine`（同一份逻辑），在 `BEGIN IMMEDIATE` 事务里完成，副作用与状态变更同事务入队。
public final class SuperagentStore {
    let db: SQLiteDB
    public let url: URL

    public init(url: URL = SuperagentPaths.database) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDB(path: url.path)
        try migrate()
    }

    /// 另一个连接（App ↔ CLI）提交后会变化。
    public var dataVersion: Int64 { db.dataVersion }

    public func transaction<T>(_ body: () throws -> T) throws -> T { try db.transaction(body) }

    private func migrate() throws {
        try db.exec("""
            CREATE TABLE IF NOT EXISTS ticket (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              title TEXT NOT NULL, request TEXT NOT NULL, note TEXT NOT NULL DEFAULT '',
              repo TEXT NOT NULL DEFAULT '', dir TEXT NOT NULL DEFAULT '', branch TEXT NOT NULL DEFAULT '',
              worktree INTEGER NOT NULL DEFAULT 1,
              status TEXT NOT NULL DEFAULT 'open', ended_by TEXT, ended_at REAL,
              ack TEXT NOT NULL DEFAULT '', attention TEXT,
              report_state TEXT, report_summary TEXT NOT NULL DEFAULT '', report_path TEXT, report_at REAL,
              delivery_error TEXT, nudged INTEGER NOT NULL DEFAULT 0, notified_stage TEXT,
              mandate TEXT NOT NULL DEFAULT '{}', trigger_id TEXT, session TEXT NOT NULL DEFAULT '',
              turn_at REAL, created_at REAL NOT NULL, updated_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS assignment (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ticket_id INTEGER NOT NULL REFERENCES ticket(id),
              state TEXT NOT NULL DEFAULT 'pending', reason TEXT NOT NULL DEFAULT '',
              created_at REAL NOT NULL, started_at REAL, ended_at REAL);
            CREATE INDEX IF NOT EXISTS assignment_ticket ON assignment(ticket_id, id);
            CREATE TABLE IF NOT EXISTS input (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ticket_id INTEGER NOT NULL REFERENCES ticket(id),
              kind TEXT NOT NULL, text TEXT NOT NULL, created_at REAL NOT NULL, delivered_at REAL);
            CREATE INDEX IF NOT EXISTS input_ticket ON input(ticket_id, id);
            CREATE TABLE IF NOT EXISTS trigger (
              id TEXT PRIMARY KEY, source TEXT NOT NULL, strength TEXT NOT NULL, text TEXT NOT NULL,
              repo TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'pending', ticket_id INTEGER,
              created_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS decision (
              id INTEGER PRIMARY KEY AUTOINCREMENT, trigger_id TEXT, ticket_id INTEGER,
              kind TEXT NOT NULL, reason TEXT NOT NULL DEFAULT '', policy_version TEXT NOT NULL DEFAULT '',
              rules TEXT NOT NULL DEFAULT '{}', created_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS effect (
              kind TEXT NOT NULL, key TEXT NOT NULL, seq INTEGER NOT NULL DEFAULT 1,
              attempts INTEGER NOT NULL DEFAULT 0, next_at REAL NOT NULL, last_error TEXT,
              created_at REAL NOT NULL, PRIMARY KEY(kind, key));
            CREATE TABLE IF NOT EXISTS relay (
              id INTEGER PRIMARY KEY AUTOINCREMENT, ticket_id INTEGER, text TEXT NOT NULL,
              created_at REAL NOT NULL, delivered_at REAL);
            CREATE TABLE IF NOT EXISTS event (
              id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, ticket_id INTEGER,
              kind TEXT NOT NULL, text TEXT NOT NULL DEFAULT '');
            CREATE INDEX IF NOT EXISTS event_ticket ON event(ticket_id, id);
            CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
    }

    // MARK: - Tickets

    private static let ticketColumns = """
        id,title,request,note,repo,dir,branch,worktree,status,ended_by,ended_at,ack,attention,
        report_state,report_summary,report_path,report_at,delivery_error,nudged,notified_stage,
        mandate,trigger_id,session,turn_at,created_at,updated_at
        """

    private static func ticket(_ r: SQLRow) -> Ticket {
        Ticket(id: r.int(0), title: r.text(1), request: r.text(2), note: r.text(3), repo: r.text(4),
               dir: r.text(5), branch: r.text(6), worktree: r.int(7) != 0,
               status: TicketStatus(rawValue: r.text(8)) ?? .open, endedBy: r.optText(9), endedAt: r.optDouble(10),
               ack: r.text(11), attention: r.optText(12), reportState: r.optText(13).flatMap(ReportState.init),
               reportSummary: r.text(14), reportPath: r.optText(15), reportAt: r.optDouble(16),
               deliveryError: r.optText(17), nudged: r.int(18) != 0, notifiedStage: r.optText(19),
               mandate: r.text(20), triggerID: r.optText(21), session: r.text(22), turnAt: r.optDouble(23),
               createdAt: r.double(24), updatedAt: r.double(25))
    }

    public func ticket(_ id: Int64) throws -> Ticket? {
        try db.query("SELECT \(Self.ticketColumns) FROM ticket WHERE id=?", [.int(id)]).first.map(Self.ticket)
    }

    /// 打开的工单在前（新的在前），然后是最近结束的 `endedLimit` 个。
    public func tickets(endedLimit: Int = 30) throws -> [Ticket] {
        let open = try db.query("SELECT \(Self.ticketColumns) FROM ticket WHERE status='open' ORDER BY id DESC").map(Self.ticket)
        let ended = try db.query("SELECT \(Self.ticketColumns) FROM ticket WHERE status!='open' ORDER BY updated_at DESC LIMIT ?",
                                 [.int(Int64(endedLimit))]).map(Self.ticket)
        return open + ended
    }

    func insertTicket(_ t: Ticket) throws -> Int64 {
        try db.run("""
            INSERT INTO ticket (title,request,note,repo,dir,branch,worktree,status,mandate,trigger_id,created_at,updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [.text(t.title), .text(t.request), .text(t.note), .text(t.repo), .text(t.dir), .text(t.branch),
             .bool(t.worktree), .text(t.status.rawValue), .text(t.mandate), .opt(t.triggerID),
             .real(t.createdAt), .real(t.updatedAt)])
        return db.lastInsertID
    }

    func saveTicket(_ t: Ticket) throws {
        try db.run("""
            UPDATE ticket SET title=?,request=?,note=?,repo=?,dir=?,branch=?,worktree=?,status=?,ended_by=?,ended_at=?,
              ack=?,attention=?,report_state=?,report_summary=?,report_path=?,report_at=?,delivery_error=?,nudged=?,
              notified_stage=?,session=?,turn_at=?,updated_at=? WHERE id=?
            """,
            [.text(t.title), .text(t.request), .text(t.note), .text(t.repo), .text(t.dir), .text(t.branch),
             .bool(t.worktree), .text(t.status.rawValue), .opt(t.endedBy), .opt(t.endedAt),
             .text(t.ack), .opt(t.attention), .opt(t.reportState?.rawValue), .text(t.reportSummary),
             .opt(t.reportPath), .opt(t.reportAt), .opt(t.deliveryError), .bool(t.nudged),
             .opt(t.notifiedStage), .text(t.session), .opt(t.turnAt), .real(t.updatedAt), .int(t.id)])
    }

    // MARK: - Assignments

    private static func assignment(_ r: SQLRow) -> Assignment {
        Assignment(id: r.int(0), ticketID: r.int(1), state: AssignmentState(rawValue: r.text(2)) ?? .pending,
                   reason: r.text(3), createdAt: r.double(4), startedAt: r.optDouble(5), endedAt: r.optDouble(6))
    }

    public func latestAssignment(_ ticketID: Int64) throws -> Assignment? {
        try db.query("SELECT id,ticket_id,state,reason,created_at,started_at,ended_at FROM assignment WHERE ticket_id=? ORDER BY id DESC LIMIT 1",
                     [.int(ticketID)]).first.map(Self.assignment)
    }

    public func assignments(_ ticketID: Int64) throws -> [Assignment] {
        try db.query("SELECT id,ticket_id,state,reason,created_at,started_at,ended_at FROM assignment WHERE ticket_id=? ORDER BY id",
                     [.int(ticketID)]).map(Self.assignment)
    }

    func insertAssignment(ticketID: Int64, reason: String, at: Double) throws -> Int64 {
        try db.run("INSERT INTO assignment (ticket_id,state,reason,created_at) VALUES (?,'pending',?,?)",
                   [.int(ticketID), .text(reason), .real(at)])
        return db.lastInsertID
    }

    func setAssignment(_ id: Int64, state: AssignmentState, at: Double, reason: String? = nil) throws {
        switch state {
        case .running:
            try db.run("UPDATE assignment SET state='running', started_at=COALESCE(started_at, ?) WHERE id=?", [.real(at), .int(id)])
        case .ended:
            try db.run("UPDATE assignment SET state='ended', ended_at=?, reason=COALESCE(?, reason) WHERE id=?",
                       [.real(at), .opt(reason), .int(id)])
        case .pending:
            try db.run("UPDATE assignment SET state='pending' WHERE id=?", [.int(id)])
        }
    }

    // MARK: - Inputs

    private static func input(_ r: SQLRow) -> TicketInput {
        TicketInput(id: r.int(0), ticketID: r.int(1), kind: InputKind(rawValue: r.text(2)) ?? .human,
                    text: r.text(3), createdAt: r.double(4), deliveredAt: r.optDouble(5))
    }

    public func inputs(_ ticketID: Int64) throws -> [TicketInput] {
        try db.query("SELECT id,ticket_id,kind,text,created_at,delivered_at FROM input WHERE ticket_id=? ORDER BY id",
                     [.int(ticketID)]).map(Self.input)
    }

    public func undelivered(_ ticketID: Int64) throws -> [TicketInput] {
        try db.query("SELECT id,ticket_id,kind,text,created_at,delivered_at FROM input WHERE ticket_id=? AND delivered_at IS NULL ORDER BY id",
                     [.int(ticketID)]).map(Self.input)
    }

    func insertInput(ticketID: Int64, kind: InputKind, text: String, at: Double) throws -> Int64 {
        try db.run("INSERT INTO input (ticket_id,kind,text,created_at) VALUES (?,?,?,?)",
                   [.int(ticketID), .text(kind.rawValue), .text(text), .real(at)])
        return db.lastInsertID
    }

    func markDelivered(_ ids: [Int64], at: Double) throws {
        for id in ids { try db.run("UPDATE input SET delivered_at=? WHERE id=? AND delivered_at IS NULL", [.real(at), .int(id)]) }
    }

    func dropUndelivered(_ ticketID: Int64) throws {
        try db.run("DELETE FROM input WHERE ticket_id=? AND delivered_at IS NULL", [.int(ticketID)])
    }

    // MARK: - Triggers & decisions

    private static func trigger(_ r: SQLRow) -> Trigger {
        Trigger(id: r.text(0), source: r.text(1), strength: Strength(rawValue: r.text(2)) ?? .explicit, text: r.text(3),
                repo: r.text(4), status: TriggerStatus(rawValue: r.text(5)) ?? .pending,
                ticketID: r.optInt(6), createdAt: r.double(7))
    }

    public func trigger(_ id: String) throws -> Trigger? {
        try db.query("SELECT id,source,strength,text,repo,status,ticket_id,created_at FROM trigger WHERE id=?", [.text(id)])
            .first.map(Self.trigger)
    }

    public func pendingTriggers() throws -> [Trigger] {
        try db.query("SELECT id,source,strength,text,repo,status,ticket_id,created_at FROM trigger WHERE status='pending' ORDER BY created_at")
            .map(Self.trigger)
    }

    func insertTrigger(_ t: Trigger) throws {
        try db.run("INSERT INTO trigger (id,source,strength,text,repo,status,ticket_id,created_at) VALUES (?,?,?,?,?,?,?,?)",
                   [.text(t.id), .text(t.source), .text(t.strength.rawValue), .text(t.text), .text(t.repo),
                    .text(t.status.rawValue), t.ticketID.map(SQLValue.int) ?? .null, .real(t.createdAt)])
    }

    func decideTrigger(_ id: String, ticketID: Int64?) throws {
        try db.run("UPDATE trigger SET status='decided', ticket_id=COALESCE(?, ticket_id) WHERE id=?",
                   [ticketID.map(SQLValue.int) ?? .null, .text(id)])
    }

    /// 新的 trigger id：t + 自增序号（短，便于主管在命令里引用）。
    func nextTriggerID() throws -> String {
        let n = (try kvInt("seq.trigger") ?? 0) + 1
        try setKV("seq.trigger", String(n))
        return "t\(n)"
    }

    private static func decision(_ r: SQLRow) -> Decision {
        Decision(id: r.int(0), triggerID: r.optText(1), ticketID: r.optInt(2),
                 kind: DecisionKind(rawValue: r.text(3)) ?? .ignore, reason: r.text(4), policyVersion: r.text(5),
                 rules: r.text(6), createdAt: r.double(7))
    }

    public func decisions(limit: Int = 50) throws -> [Decision] {
        try db.query("SELECT id,trigger_id,ticket_id,kind,reason,policy_version,rules,created_at FROM decision ORDER BY id DESC LIMIT ?",
                     [.int(Int64(limit))]).map(Self.decision)
    }

    func insertDecision(triggerID: String?, ticketID: Int64?, kind: DecisionKind, reason: String,
                        policyVersion: String, rules: String, at: Double) throws {
        try db.run("INSERT INTO decision (trigger_id,ticket_id,kind,reason,policy_version,rules,created_at) VALUES (?,?,?,?,?,?,?)",
                   [.opt(triggerID), ticketID.map(SQLValue.int) ?? .null, .text(kind.rawValue), .text(reason),
                    .text(policyVersion), .text(rules), .real(at)])
    }

    // MARK: - Effects

    private static func effect(_ r: SQLRow) -> Effect? {
        guard let kind = EffectKind(rawValue: r.text(0)) else { return nil }
        return Effect(kind: kind, key: r.text(1), seq: r.int(2), attempts: Int(r.int(3)), nextAt: r.double(4),
                      lastError: r.optText(5), createdAt: r.double(6))
    }

    /// 入队（或重新入队：seq+1、立即到期；失败计数保留，直到成功一次）。
    func enqueue(_ kind: EffectKind, _ key: String, at: Double) throws {
        try db.run("""
            INSERT INTO effect (kind,key,seq,attempts,next_at,created_at) VALUES (?,?,1,0,?,?)
            ON CONFLICT(kind,key) DO UPDATE SET seq=seq+1, next_at=MIN(next_at, excluded.next_at)
            """, [.text(kind.rawValue), .text(key), .real(at), .real(at)])
    }

    /// 到期的副作用，按入队顺序。
    public func dueEffects(now: Double) throws -> [Effect] {
        try db.query("SELECT kind,key,seq,attempts,next_at,last_error,created_at FROM effect WHERE next_at<=? ORDER BY created_at, key",
                     [.real(now)]).compactMap(Self.effect)
    }

    public func effects() throws -> [Effect] {
        try db.query("SELECT kind,key,seq,attempts,next_at,last_error,created_at FROM effect ORDER BY created_at")
            .compactMap(Self.effect)
    }

    public func effect(_ kind: EffectKind, _ key: String) throws -> Effect? {
        try db.query("SELECT kind,key,seq,attempts,next_at,last_error,created_at FROM effect WHERE kind=? AND key=?",
                     [.text(kind.rawValue), .text(key)]).first.flatMap(Self.effect)
    }

    /// 完成：只有 seq 没变才删除（执行期间又入队的工作保留并立即到期）。
    public func completeEffect(_ e: Effect) throws {
        try db.transaction {
            let n = try db.run("DELETE FROM effect WHERE kind=? AND key=? AND seq=?", [.text(e.kind.rawValue), .text(e.key), .int(e.seq)])
            if n == 0 {
                try db.run("UPDATE effect SET attempts=0, last_error=NULL WHERE kind=? AND key=?", [.text(e.kind.rawValue), .text(e.key)])
            }
        }
    }

    /// 失败：指数退避（2s→60s，launch 5s→300s），返回新的失败次数。
    @discardableResult
    public func failEffect(_ e: Effect, error: String, now: Double) throws -> Int {
        let attempts = e.attempts + 1
        let (base, cap) = e.kind.backoff
        // 连续 3 次失败：暂停（不再每分钟往终端里重打一遍），等重试 / 人的操作 / 新消息重新入队。
        let delay = attempts >= 3 ? Self.pausedDelay : min(cap, base * pow(2, Double(attempts - 1)))
        try db.run("UPDATE effect SET attempts=?, next_at=?, last_error=? WHERE kind=? AND key=?",
                   [.int(Int64(attempts)), .real(now + delay), .text(String(error.prefix(300))), .text(e.kind.rawValue), .text(e.key)])
        return attempts
    }

    static let pausedDelay: Double = 1800

    /// 稍后再试（槽位满 / 终端忙）——不计失败。
    public func deferEffect(_ e: Effect, until: Double) throws {
        try db.run("UPDATE effect SET next_at=MAX(next_at, ?) WHERE kind=? AND key=? AND seq=?",
                   [.real(until), .text(e.kind.rawValue), .text(e.key), .int(e.seq)])
    }

    func dropEffect(_ kind: EffectKind, _ key: String) throws {
        try db.run("DELETE FROM effect WHERE kind=? AND key=?", [.text(kind.rawValue), .text(key)])
    }

    // MARK: - Relay（主管收件箱）

    private static func relay(_ r: SQLRow) -> Relay {
        Relay(id: r.int(0), ticketID: r.optInt(1), text: r.text(2), createdAt: r.double(3), deliveredAt: r.optDouble(4))
    }

    public func pendingRelays() throws -> [Relay] {
        try db.query("SELECT id,ticket_id,text,created_at,delivered_at FROM relay WHERE delivered_at IS NULL ORDER BY id").map(Self.relay)
    }

    func insertRelay(ticketID: Int64?, text: String, at: Double) throws {
        try db.run("INSERT INTO relay (ticket_id,text,created_at) VALUES (?,?,?)",
                   [ticketID.map(SQLValue.int) ?? .null, .text(text), .real(at)])
    }

    func markRelayed(_ ids: [Int64], at: Double) throws {
        for id in ids { try db.run("UPDATE relay SET delivered_at=? WHERE id=?", [.real(at), .int(id)]) }
    }

    // MARK: - Timeline

    func log(_ ticketID: Int64?, _ kind: String, _ text: String, at: Double) throws {
        try db.run("INSERT INTO event (at,ticket_id,kind,text) VALUES (?,?,?,?)",
                   [.real(at), ticketID.map(SQLValue.int) ?? .null, .text(kind), .text(text)])
    }

    public func events(ticketID: Int64? = nil, limit: Int = 200) throws -> [TimelineEvent] {
        let rows: [SQLRow]
        if let ticketID {
            rows = try db.query("SELECT id,at,ticket_id,kind,text FROM event WHERE ticket_id=? ORDER BY id DESC LIMIT ?",
                                [.int(ticketID), .int(Int64(limit))])
        } else {
            rows = try db.query("SELECT id,at,ticket_id,kind,text FROM event ORDER BY id DESC LIMIT ?", [.int(Int64(limit))])
        }
        return rows.reversed().map { TimelineEvent(id: $0.int(0), at: $0.double(1), ticketID: $0.optInt(2),
                                                   kind: $0.text(3), text: $0.text(4)) }
    }

    // MARK: - KV（设置、规则、定时任务、规则历史）

    public func kv(_ key: String) throws -> String? {
        try db.query("SELECT value FROM kv WHERE key=?", [.text(key)]).first?.text(0)
    }

    func kvInt(_ key: String) throws -> Int? { try kv(key).flatMap { Int($0) } }

    func setKV(_ key: String, _ value: String?) throws {
        if let value {
            try db.run("INSERT INTO kv (key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
        } else {
            try db.run("DELETE FROM kv WHERE key=?", [.text(key)])
        }
    }

    public func settings() throws -> Settings {
        var s = Settings()
        if let v = try kvInt("settings.slots") { s.slots = max(1, min(8, v)) }
        if let v = try kv("settings.worktree") { s.worktree = v == "1" }
        if let v = try kv("settings.acceptance") { s.acceptance = v == "1" }
        if let v = try kv("settings.idleSeconds").flatMap(Double.init) { s.idleSeconds = max(20, v) }
        return s
    }

    public func saveSettings(_ s: Settings) throws {
        try db.transaction {
            try setKV("settings.slots", String(s.slots))
            try setKV("settings.worktree", s.worktree ? "1" : "0")
            try setKV("settings.acceptance", s.acceptance ? "1" : "0")
            try setKV("settings.idleSeconds", String(Int(s.idleSeconds)))
        }
    }

    public func rules() throws -> [Rule] {
        guard let json = try kv("policy.rules"), let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Rule].self, from: data)) ?? []
    }

    public func acceptMode() throws -> AcceptMode {
        try kv("policy.mode").flatMap(AcceptMode.init) ?? .observe
    }

    public func schedules() throws -> [Schedule] {
        guard let json = try kv("schedules"), let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Schedule].self, from: data)) ?? []
    }

    func saveSchedules(_ list: [Schedule]) throws {
        let data = try JSONEncoder().encode(list)
        try setKV("schedules", String(decoding: data, as: UTF8.self))
    }

    /// Policy 版本 = 启用的规则 + 接单模式的哈希（前 12 位）。每个 Mandate 记下它依据的版本。
    public func policyVersion() throws -> String {
        Self.policyVersion(rules: try rules(), mode: try acceptMode())
    }

    static func policyVersion(rules: [Rule], mode: AcceptMode) -> String {
        var canon = "mode=\(mode.rawValue)\n"
        for r in rules where r.enabled { canon += "\(r.id)\u{1f}\(r.name)\u{1f}\(r.instruction)\n" }
        let digest = SHA256.hash(data: Data(canon.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// 规则的历史版本（最新在前）。
    public func policyHistory() throws -> [(version: String, at: Double, summary: String)] {
        guard let json = try kv("policy.history"), let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let v = row["version"] as? String, let at = row["at"] as? Double else { return nil }
            return (v, at, row["summary"] as? String ?? "")
        }
    }

    func appendPolicyHistory(version: String, at: Double, summary: String) throws {
        var rows: [[String: Any]] = []
        if let json = try kv("policy.history"), let data = json.data(using: .utf8),
           let old = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { rows = old }
        rows.insert(["version": version, "at": at, "summary": summary], at: 0)
        let data = try JSONSerialization.data(withJSONObject: Array(rows.prefix(50)))
        try setKV("policy.history", String(decoding: data, as: UTF8.self))
    }
}
