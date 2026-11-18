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
        // 角色（docs/superagent-roles.md）之前的库没有 role 列：旧工单都是「开发」。
        try addColumn("ticket", "role", "TEXT NOT NULL DEFAULT '\(Role.developer)'")
        // 工作清单（TFA-工作清单-需求文档 §7）：任务 / 清单项 / 工作流；工单回指任务；时间线按任务聚合。
        try db.exec("""
            CREATE TABLE IF NOT EXISTS task (
              id INTEGER PRIMARY KEY AUTOINCREMENT, origin TEXT, origin_id TEXT,
              title TEXT NOT NULL, request TEXT NOT NULL, source TEXT NOT NULL, source_ref TEXT,
              scope TEXT NOT NULL DEFAULT '', owner TEXT NOT NULL DEFAULT '你', due REAL,
              priority TEXT NOT NULL DEFAULT 'medium', workflow TEXT NOT NULL DEFAULT 'default',
              workflow_snapshot TEXT NOT NULL DEFAULT '[]', stage TEXT NOT NULL,
              status TEXT NOT NULL DEFAULT 'open', result_summary TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '',
              notified_stage TEXT, sync_state TEXT NOT NULL DEFAULT 'local', synced_at REAL,
              created_at REAL NOT NULL, updated_at REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS task_status ON task(status, stage);
            CREATE TABLE IF NOT EXISTS task_dep (task_id INTEGER NOT NULL, depends_on INTEGER NOT NULL, PRIMARY KEY (task_id, depends_on));
            CREATE TABLE IF NOT EXISTS item (
              id INTEGER PRIMARY KEY AUTOINCREMENT, task_id INTEGER NOT NULL, ord INTEGER NOT NULL, text TEXT NOT NULL,
              assignee TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'todo', ticket_id INTEGER, done_at REAL, done_by TEXT);
            CREATE INDEX IF NOT EXISTS item_task ON item(task_id, ord);
            CREATE TABLE IF NOT EXISTS workflow (id TEXT PRIMARY KEY, name TEXT NOT NULL, scope TEXT NOT NULL DEFAULT '', stages TEXT NOT NULL);
            """)
        try addColumn("ticket", "task_id", "INTEGER")
        try addColumn("ticket", "item_ids", "TEXT NOT NULL DEFAULT '[]'")
        try addColumn("ticket", "review_of", "INTEGER")
        try addColumn("event", "task_id", "INTEGER")
        try addColumn("decision", "task_id", "INTEGER")
        try addColumn("decision", "verdict", "TEXT")
        try db.exec("""
            CREATE INDEX IF NOT EXISTS ticket_task ON ticket(task_id);
            CREATE INDEX IF NOT EXISTS event_task ON event(task_id, id);
            """)
        // 第 4 期：清单项开始做的时间（「今天」视图把你名下拖了 2 天的项提到前面）。
        try addColumn("item", "started_at", "REAL")
        // 第 6 版：每个清单项独立持久化完成摘要（任务完成后终端关闭仍可点开阅读）。
        try addColumn("item", "summary", "TEXT NOT NULL DEFAULT ''")
        // 组织同步（第 3 期，需求文档 §10.3；注意事项 I-01 / I-02）：上行 outbox、组织任务的服务端版本、清单项 ↔ 服务端清单项。
        try db.exec("""
            CREATE TABLE IF NOT EXISTS outbox (
              id INTEGER PRIMARY KEY AUTOINCREMENT, task_id INTEGER NOT NULL DEFAULT 0, kind TEXT NOT NULL,
              payload TEXT NOT NULL DEFAULT '', seq INTEGER NOT NULL DEFAULT 1, attempts INTEGER NOT NULL DEFAULT 0,
              next_at REAL NOT NULL, last_error TEXT, created_at REAL NOT NULL, UNIQUE (task_id, kind));
            CREATE TABLE IF NOT EXISTS org_task (
              task_id INTEGER PRIMARY KEY, version INTEGER NOT NULL DEFAULT 0, label TEXT NOT NULL DEFAULT '',
              scope_name TEXT NOT NULL DEFAULT '', edits INTEGER NOT NULL DEFAULT 1,
              needs_sent TEXT NOT NULL DEFAULT '', audit_after INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS org_item (
              item_id INTEGER PRIMARY KEY, task_id INTEGER NOT NULL, origin_item_id INTEGER NOT NULL,
              synced_status TEXT NOT NULL DEFAULT 'todo', conflict_local TEXT, conflict_server TEXT);
            CREATE INDEX IF NOT EXISTS org_item_task ON org_item(task_id);
            CREATE INDEX IF NOT EXISTS task_origin ON task(origin, origin_id);
            CREATE TABLE IF NOT EXISTS knowledge (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              task_id INTEGER UNIQUE REFERENCES task(id),
              scope TEXT NOT NULL DEFAULT '',
              title TEXT NOT NULL,
              tldr TEXT NOT NULL DEFAULT '',
              outcomes TEXT NOT NULL DEFAULT '[]',
              pitfalls TEXT NOT NULL DEFAULT '[]',
              files TEXT NOT NULL DEFAULT '[]',
              tags TEXT NOT NULL DEFAULT '[]',
              pinned INTEGER NOT NULL DEFAULT 0,
              archived INTEGER NOT NULL DEFAULT 0,
              user_edited INTEGER NOT NULL DEFAULT 0,
              ai_refined INTEGER NOT NULL DEFAULT 0,
              needs_refine INTEGER NOT NULL DEFAULT 0,
              md_path TEXT NOT NULL DEFAULT '',
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS knowledge_scope ON knowledge(archived, pinned, scope, updated_at);
            CREATE TABLE IF NOT EXISTS task_context_link (
              task_id INTEGER NOT NULL REFERENCES task(id),
              knowledge_id INTEGER NOT NULL REFERENCES knowledge(id),
              note TEXT NOT NULL DEFAULT '',
              created_at REAL NOT NULL,
              PRIMARY KEY (task_id, knowledge_id));
            CREATE INDEX IF NOT EXISTS task_context_link_kb ON task_context_link(knowledge_id, task_id);
            """)
        if try (db.query("PRAGMA user_version").first?.int(0) ?? 0) < Self.schemaVersion {
            try db.exec("PRAGMA user_version=\(Self.schemaVersion)")
        }
    }

    /// 表结构版本（注意事项 B-01）：1 = 工单 + 角色；2 = 工作清单；3 = 清单项的 started_at；4 = 组织同步；5 = 任务总结与项目知识库；6 = 清单项独立摘要。
    static let schemaVersion: Int64 = 6

    /// 加一列；已有就跳过。App 和 tfa 可能同时打开旧库：另一个连接先加上了也不算错。
    private func addColumn(_ table: String, _ name: String, _ decl: String) throws {
        func has() throws -> Bool { try db.query("PRAGMA table_info(\(table))").contains { $0.text(1) == name } }
        guard try !has() else { return }
        do { try db.exec("ALTER TABLE \(table) ADD COLUMN \(name) \(decl)") } catch {
            if try !has() { throw error }
        }
    }

    /// 迁移前的整库备份（注意事项 B-01）：先 checkpoint 把 -wal 合进主文件，再复制到 `superagent.db.bak-<时间>`。
    @discardableResult
    public func backup(suffix: String? = nil) throws -> URL {
        // busy ≠ 0：别的连接还在读，-wal 没能全部合进主文件——把它一起拷到 <备份名>-wal，备份才打得开、数据才齐。
        let busy = try db.query("PRAGMA wal_checkpoint(TRUNCATE)").first?.int(0) ?? 0
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
        let dest = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".bak-" + (suffix ?? f.string(from: Date())))
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: url, to: dest)
        let wal = URL(fileURLWithPath: url.path + "-wal"), destWal = URL(fileURLWithPath: dest.path + "-wal")
        if fm.fileExists(atPath: destWal.path) { try fm.removeItem(at: destWal) }
        if busy != 0, fm.fileExists(atPath: wal.path) { try fm.copyItem(at: wal, to: destWal) }
        return dest
    }

    // MARK: - Tickets

    private static let ticketColumns = """
        id,title,request,note,repo,dir,branch,worktree,status,ended_by,ended_at,ack,attention,
        report_state,report_summary,report_path,report_at,delivery_error,nudged,notified_stage,
        mandate,trigger_id,session,turn_at,created_at,updated_at,role,task_id,item_ids,review_of
        """

    private static func ticket(_ r: SQLRow) -> Ticket {
        Ticket(id: r.int(0), title: r.text(1), role: r.text(26), request: r.text(2), note: r.text(3), repo: r.text(4),
               dir: r.text(5), branch: r.text(6), worktree: r.int(7) != 0,
               status: TicketStatus(rawValue: r.text(8)) ?? .open, endedBy: r.optText(9), endedAt: r.optDouble(10),
               ack: r.text(11), attention: r.optText(12), reportState: r.optText(13).flatMap(ReportState.init),
               reportSummary: r.text(14), reportPath: r.optText(15), reportAt: r.optDouble(16),
               deliveryError: r.optText(17), nudged: r.int(18) != 0, notifiedStage: r.optText(19),
               mandate: r.text(20), triggerID: r.optText(21), session: r.text(22), turnAt: r.optDouble(23),
               createdAt: r.double(24), updatedAt: r.double(25),
               taskID: r.optInt(27), itemIDs: Self.ids(r.text(28)), reviewOf: r.optInt(29))
    }

    static func ids(_ json: String) -> [Int64] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Int64]) ?? []
    }
    static func json(_ ids: [Int64]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: ids)) ?? Data("[]".utf8), as: UTF8.self)
    }

    /// 一个任务名下的工单（打开的 + 已结束的），按 id。
    public func tickets(task id: Int64) throws -> [Ticket] {
        try db.query("SELECT \(Self.ticketColumns) FROM ticket WHERE task_id=? ORDER BY id", [.int(id)]).map(Self.ticket)
    }

    /// 一批任务名下的工单，按任务分组（清单页一次聚合，注意事项 B-11）。
    public func tickets(taskIDs: [Int64]) throws -> [Int64: [Ticket]] {
        var out: [Int64: [Ticket]] = [:]
        for chunk in Self.chunks(taskIDs) {
            let rows = try db.query("SELECT \(Self.ticketColumns) FROM ticket WHERE task_id IN (\(Self.marks(chunk.count))) ORDER BY id",
                                    chunk.map(SQLValue.int))
            for t in rows.map(Self.ticket) { out[t.taskID ?? 0, default: []].append(t) }
        }
        return out
    }

    /// 迁移用：只写回指列 `task_id / item_ids`，工单其余列原样不动（注意事项 B-02）。
    func linkTicket(_ id: Int64, task: Int64, itemIDs: [Int64]) throws {
        try db.run("UPDATE ticket SET task_id=?, item_ids=? WHERE id=?", [.int(task), .text(Self.json(itemIDs)), .int(id)])
    }

    /// `IN (?,?,…)` 的占位符；一次最多 500 个（SQLite 变量上限之内）。
    static func marks(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }
    static func chunks(_ ids: [Int64]) -> [[Int64]] {
        stride(from: 0, to: ids.count, by: 500).map { Array(ids[$0..<min($0 + 500, ids.count)]) }
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
            INSERT INTO ticket (title,request,note,repo,dir,branch,worktree,status,mandate,trigger_id,created_at,updated_at,role,
              task_id,item_ids,review_of)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [.text(t.title), .text(t.request), .text(t.note), .text(t.repo), .text(t.dir), .text(t.branch),
             .bool(t.worktree), .text(t.status.rawValue), .text(t.mandate), .opt(t.triggerID),
             .real(t.createdAt), .real(t.updatedAt), .text(t.role),
             t.taskID.map(SQLValue.int) ?? .null, .text(Self.json(t.itemIDs)), t.reviewOf.map(SQLValue.int) ?? .null])
        return db.lastInsertID
    }

    func saveTicket(_ t: Ticket) throws {
        try db.run("""
            UPDATE ticket SET title=?,request=?,note=?,repo=?,dir=?,branch=?,worktree=?,status=?,ended_by=?,ended_at=?,
              ack=?,attention=?,report_state=?,report_summary=?,report_path=?,report_at=?,delivery_error=?,nudged=?,
              notified_stage=?,session=?,turn_at=?,updated_at=?,task_id=?,item_ids=? WHERE id=?
            """,
            [.text(t.title), .text(t.request), .text(t.note), .text(t.repo), .text(t.dir), .text(t.branch),
             .bool(t.worktree), .text(t.status.rawValue), .opt(t.endedBy), .opt(t.endedAt),
             .text(t.ack), .opt(t.attention), .opt(t.reportState?.rawValue), .text(t.reportSummary),
             .opt(t.reportPath), .opt(t.reportAt), .opt(t.deliveryError), .bool(t.nudged),
             .opt(t.notifiedStage), .text(t.session), .opt(t.turnAt), .real(t.updatedAt),
             t.taskID.map(SQLValue.int) ?? .null, .text(Self.json(t.itemIDs)), .int(t.id)])
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

    private static let decisionColumns = "id,trigger_id,ticket_id,kind,reason,policy_version,rules,created_at,task_id,verdict"

    private static func decision(_ r: SQLRow) -> Decision {
        Decision(id: r.int(0), triggerID: r.optText(1), ticketID: r.optInt(2),
                 kind: DecisionKind(rawValue: r.text(3)) ?? .ignore, reason: r.text(4), policyVersion: r.text(5),
                 rules: r.text(6), createdAt: r.double(7), taskID: r.optInt(8), verdict: r.optText(9))
    }

    public func decisions(limit: Int = 50) throws -> [Decision] {
        try db.query("SELECT \(Self.decisionColumns) FROM decision ORDER BY id DESC LIMIT ?", [.int(Int64(limit))]).map(Self.decision)
    }

    public func decision(_ id: Int64) throws -> Decision? {
        try db.query("SELECT \(Self.decisionColumns) FROM decision WHERE id=?", [.int(id)]).first.map(Self.decision)
    }

    /// 研判过的决定（会接 / 本会接单 / 不接），给观察记录的标注和准确率用；最新在前。
    /// 只算**推断**候选（规则研判）的决定：人明确提的请求没有「判断对不对」可言。
    public func assessedDecisions(limit: Int = 200) throws -> [Decision] {
        try db.query("""
            SELECT \(Self.decisionColumns) FROM decision
            WHERE kind IN ('accept','would_accept','ignore')
              AND trigger_id IN (SELECT id FROM trigger WHERE strength='inferred')
            ORDER BY id DESC LIMIT ?
            """, [.int(Int64(limit))]).map(Self.decision)
    }

    @discardableResult
    func insertDecision(triggerID: String?, ticketID: Int64?, kind: DecisionKind, reason: String,
                        policyVersion: String, rules: String, at: Double, taskID: Int64? = nil) throws -> Int64 {
        try db.run("INSERT INTO decision (trigger_id,ticket_id,kind,reason,policy_version,rules,created_at,task_id) VALUES (?,?,?,?,?,?,?,?)",
                   [.opt(triggerID), ticketID.map(SQLValue.int) ?? .null, .text(kind.rawValue), .text(reason),
                    .text(policyVersion), .text(rules), .real(at), taskID.map(SQLValue.int) ?? .null])
        return db.lastInsertID
    }

    func setDecisionVerdict(_ id: Int64, _ verdict: String?) throws {
        try db.run("UPDATE decision SET verdict=? WHERE id=?", [.opt(verdict), .int(id)])
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

    /// 工单的一条记录；`task` 给了就同时按任务聚合（工单属于某个任务时调用方应传它的 taskID）。
    func log(_ ticketID: Int64?, _ kind: String, _ text: String, at: Double, task: Int64? = nil) throws {
        try db.run("INSERT INTO event (at,ticket_id,kind,text,task_id) VALUES (?,?,?,?,?)",
                   [.real(at), ticketID.map(SQLValue.int) ?? .null, .text(kind), .text(text), task.map(SQLValue.int) ?? .null])
    }

    /// 迁移用：工单原有的记录按任务聚合（任务卡的活动里能看到工单的历史）。
    func retagEvents(ticket: Int64, task: Int64) throws {
        try db.run("UPDATE event SET task_id=? WHERE ticket_id=? AND task_id IS NULL", [.int(task), .int(ticket)])
    }

    public func events(ticketID: Int64? = nil, taskID: Int64? = nil, limit: Int = 200) throws -> [TimelineEvent] {
        let rows: [SQLRow]
        if let taskID {
            rows = try db.query("SELECT id,at,ticket_id,kind,text,task_id FROM event WHERE task_id=? ORDER BY id DESC LIMIT ?",
                                [.int(taskID), .int(Int64(limit))])
        } else if let ticketID {
            rows = try db.query("SELECT id,at,ticket_id,kind,text,task_id FROM event WHERE ticket_id=? ORDER BY id DESC LIMIT ?",
                                [.int(ticketID), .int(Int64(limit))])
        } else {
            rows = try db.query("SELECT id,at,ticket_id,kind,text,task_id FROM event ORDER BY id DESC LIMIT ?", [.int(Int64(limit))])
        }
        return rows.reversed().map { TimelineEvent(id: $0.int(0), at: $0.double(1), ticketID: $0.optInt(2),
                                                   kind: $0.text(3), text: $0.text(4), taskID: $0.optInt(5)) }
    }

    // MARK: - 任务 / 清单项 / 工作流（工作清单）

    private static let taskColumns = """
        id,origin,origin_id,title,request,source,source_ref,scope,owner,due,priority,workflow,workflow_snapshot,stage,
        status,result_summary,note,notified_stage,sync_state,synced_at,created_at,updated_at
        """

    private static func task(_ r: SQLRow, deps: [Int64]) -> WorkTask {
        let stages = (try? JSONDecoder().decode([WorkflowStage].self, from: Data(r.text(12).utf8))) ?? Workflow.builtins[0].stages
        return WorkTask(id: r.int(0), origin: r.optText(1), originID: r.optText(2), title: r.text(3), request: r.text(4),
                    source: TaskSource(rawValue: r.text(5)) ?? .manual, sourceRef: r.optText(6), scope: r.text(7), owner: r.text(8),
                    due: r.optDouble(9), priority: TaskPriority(rawValue: r.text(10)) ?? .medium, deps: deps, workflow: r.text(11),
                    stages: stages, stage: r.text(13), status: TaskStatus(rawValue: r.text(14)) ?? .open, resultSummary: r.text(15),
                    note: r.text(16), notifiedStage: r.optText(17), syncState: r.text(18), syncedAt: r.optDouble(19),
                    createdAt: r.double(20), updatedAt: r.double(21))
    }

    /// 一批任务行 + 它们的前置（一次查询，不逐个任务查）。
    private func tasks(rows: [SQLRow]) throws -> [WorkTask] {
        var deps: [Int64: [Int64]] = [:]
        for chunk in Self.chunks(rows.map { $0.int(0) }) {
            for d in try db.query("SELECT task_id,depends_on FROM task_dep WHERE task_id IN (\(Self.marks(chunk.count))) ORDER BY depends_on",
                                  chunk.map(SQLValue.int)) {
                deps[d.int(0), default: []].append(d.int(1))
            }
        }
        return rows.map { Self.task($0, deps: deps[$0.int(0)] ?? []) }
    }

    public func task(_ id: Int64) throws -> WorkTask? {
        try tasks(rows: try db.query("SELECT \(Self.taskColumns) FROM task WHERE id=?", [.int(id)])).first
    }

    /// 按指定 ID 集合批量读取任务（不局限于最近 30 条，供跨历史关联脉络树一次加载）。
    public func tasks(ids: [Int64]) throws -> [Int64: WorkTask] {
        var out: [Int64: WorkTask] = [:]
        let unique = Array(Set(ids))
        for chunk in Self.chunks(unique) {
            let rows = try db.query("SELECT \(Self.taskColumns) FROM task WHERE id IN (\(Self.marks(chunk.count)))",
                                    chunk.map(SQLValue.int))
            for t in try tasks(rows: rows) { out[t.id] = t }
        }
        return out
    }

    /// 库中全部现存任务的 ID 集合（轻量整数查询）。
    public func allTaskIDs() throws -> Set<Int64> {
        Set(try db.query("SELECT id FROM task").map { $0.int(0) })
    }

    /// 全部前置任务依赖边 `(taskID, dependsOn)`（即 `dependsOn -> taskID`）。
    public func allTaskDeps() throws -> [(taskID: Int64, dependsOn: Int64)] {
        try db.query("SELECT task_id, depends_on FROM task_dep ORDER BY depends_on, task_id")
            .map { ($0.int(0), $0.int(1)) }
    }

    /// 打开的任务（新的在前），然后是最近结束的 `endedLimit` 个。
    public func tasks(endedLimit: Int = 30) throws -> [WorkTask] {
        let open = try db.query("SELECT \(Self.taskColumns) FROM task WHERE status='open' ORDER BY id DESC")
        let ended = try db.query("SELECT \(Self.taskColumns) FROM task WHERE status!='open' ORDER BY updated_at DESC LIMIT ?",
                                 [.int(Int64(endedLimit))])
        return try tasks(rows: open + ended)
    }

    func insertTask(_ t: WorkTask) throws -> Int64 {
        let snapshot = String(decoding: try JSONEncoder().encode(t.stages), as: UTF8.self)
        try db.run("""
            INSERT INTO task (origin,origin_id,title,request,source,source_ref,scope,owner,due,priority,workflow,workflow_snapshot,stage,
              status,result_summary,note,notified_stage,sync_state,synced_at,created_at,updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [.opt(t.origin), .opt(t.originID), .text(t.title), .text(t.request), .text(t.source.rawValue), .opt(t.sourceRef),
             .text(t.scope), .text(t.owner), .opt(t.due), .text(t.priority.rawValue), .text(t.workflow), .text(snapshot), .text(t.stage),
             .text(t.status.rawValue), .text(t.resultSummary), .text(t.note), .opt(t.notifiedStage), .text(t.syncState), .opt(t.syncedAt),
             .real(t.createdAt), .real(t.updatedAt)])
        let id = db.lastInsertID
        try saveDeps(id, t.deps)
        return id
    }

    /// 快照（stages）建好后不再改；deps 整体替换。
    func saveTask(_ t: WorkTask) throws {
        try db.run("""
            UPDATE task SET origin=?,origin_id=?,title=?,request=?,source=?,source_ref=?,scope=?,owner=?,due=?,priority=?,workflow=?,
              stage=?,status=?,result_summary=?,note=?,notified_stage=?,sync_state=?,synced_at=?,updated_at=? WHERE id=?
            """,
            [.opt(t.origin), .opt(t.originID), .text(t.title), .text(t.request), .text(t.source.rawValue), .opt(t.sourceRef),
             .text(t.scope), .text(t.owner), .opt(t.due), .text(t.priority.rawValue), .text(t.workflow),
             .text(t.stage), .text(t.status.rawValue), .text(t.resultSummary), .text(t.note), .opt(t.notifiedStage),
             .text(t.syncState), .opt(t.syncedAt), .real(t.updatedAt), .int(t.id)])
        try saveDeps(t.id, t.deps)
    }

    private func saveDeps(_ id: Int64, _ deps: [Int64]) throws {
        try db.run("DELETE FROM task_dep WHERE task_id=?", [.int(id)])
        for d in Set(deps) where d != id { try db.run("INSERT INTO task_dep (task_id,depends_on) VALUES (?,?)", [.int(id), .int(d)]) }
    }

    /// 依赖它的任务（前置被取消时要标受阻）。
    public func dependents(of id: Int64) throws -> [Int64] {
        try db.query("SELECT task_id FROM task_dep WHERE depends_on=?", [.int(id)]).map { $0.int(0) }
    }

    private static func item(_ r: SQLRow) -> Item {
        Item(id: r.int(0), taskID: r.int(1), ord: Int(r.int(2)), text: r.text(3), assignee: Assignee(raw: r.text(4)),
             status: ItemStatus(rawValue: r.text(5)) ?? .todo, ticketID: r.optInt(6), doneAt: r.optDouble(7), doneBy: r.optText(8),
             startedAt: r.optDouble(9), summary: r.text(10))
    }

    private static let itemColumns = "id,task_id,ord,text,assignee,status,ticket_id,done_at,done_by,started_at,summary"

    public func items(_ taskID: Int64) throws -> [Item] {
        try db.query("SELECT \(Self.itemColumns) FROM item WHERE task_id=? ORDER BY ord", [.int(taskID)]).map(Self.item)
    }

    /// 一批任务的清单项，按任务分组、各自按 `ord`（清单页一次聚合，注意事项 B-11）。
    public func items(taskIDs: [Int64]) throws -> [Int64: [Item]] {
        var out: [Int64: [Item]] = [:]
        for chunk in Self.chunks(taskIDs) {
            let rows = try db.query("SELECT \(Self.itemColumns) FROM item WHERE task_id IN (\(Self.marks(chunk.count))) ORDER BY task_id, ord",
                                    chunk.map(SQLValue.int))
            for i in rows.map(Self.item) { out[i.taskID, default: []].append(i) }
        }
        return out
    }

    /// 主管建任务时对每项「谁来做」的建议（`ord` → 角色名或「你」）；只是分配界面的默认值，不是分配（注意事项 E-02）。
    public func suggestions(task id: Int64) throws -> [Int: String] {
        guard let json = try kv("task.suggest.\(id)"), let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return Dictionary(uniqueKeysWithValues: dict.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    func saveSuggestions(task id: Int64, _ s: [Int: String]) throws {
        let dict = Dictionary(uniqueKeysWithValues: s.map { (String($0.key), $0.value) })
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try setKV("task.suggest.\(id)", String(decoding: data, as: UTF8.self))
    }

    public func item(_ id: Int64) throws -> Item? {
        try db.query("SELECT \(Self.itemColumns) FROM item WHERE id=?", [.int(id)]).first.map(Self.item)
    }

    func insertItem(_ i: Item) throws -> Int64 {
        try db.run("INSERT INTO item (task_id,ord,text,assignee,status,ticket_id,done_at,done_by,started_at,summary) VALUES (?,?,?,?,?,?,?,?,?,?)",
                   [.int(i.taskID), .int(Int64(i.ord)), .text(i.text), .text(i.assignee.raw), .text(i.status.rawValue),
                    i.ticketID.map(SQLValue.int) ?? .null, .opt(i.doneAt), .opt(i.doneBy), .opt(i.startedAt), .text(i.summary)])
        return db.lastInsertID
    }

    func saveItem(_ i: Item) throws {
        try db.run("UPDATE item SET ord=?,text=?,assignee=?,status=?,ticket_id=?,done_at=?,done_by=?,started_at=?,summary=? WHERE id=?",
                   [.int(Int64(i.ord)), .text(i.text), .text(i.assignee.raw), .text(i.status.rawValue),
                    i.ticketID.map(SQLValue.int) ?? .null, .opt(i.doneAt), .opt(i.doneBy), .opt(i.startedAt), .text(i.summary), .int(i.id)])
    }

    func deleteItem(_ id: Int64) throws {
        try db.run("DELETE FROM item WHERE id=?", [.int(id)])
    }

    /// 自定义工作流模板（内置的不存库）。
    public func workflows() throws -> [Workflow] {
        let custom = try db.query("SELECT id,name,scope,stages FROM workflow ORDER BY name").compactMap { r -> Workflow? in
            guard let stages = try? JSONDecoder().decode([WorkflowStage].self, from: Data(r.text(3).utf8)) else { return nil }
            return Workflow(id: r.text(0), name: r.text(1), scope: r.text(2), stages: stages)
        }
        return Workflow.builtins + custom.filter { !$0.isBuiltin }
    }

    public func workflow(_ id: String) throws -> Workflow? { try workflows().first { $0.id == id } }

    func saveWorkflow(_ w: Workflow) throws {
        let stages = String(decoding: try JSONEncoder().encode(w.stages), as: UTF8.self)
        try db.run("""
            INSERT INTO workflow (id,name,scope,stages) VALUES (?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, scope=excluded.scope, stages=excluded.stages
            """, [.text(w.id), .text(w.name), .text(w.scope), .text(stages)])
    }

    func deleteWorkflow(_ id: String) throws {
        try db.run("DELETE FROM workflow WHERE id=?", [.text(id)])
    }

    /// 某天的打扰次数（本地日历日 yyyy-MM-dd；注意事项 B-10 / G-02）。
    public func interruptions(day: String) throws -> Int { try kvInt("interruption.\(day)") ?? 0 }

    func bumpInterruptions(day: String) throws {
        try setKV("interruption.\(day)", String(try interruptions(day: day) + 1))
    }

    public static func day(_ at: Double, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: at))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
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

    /// 退回链接（设计评审 2026-11-08，4A）：不加列，存 kv `task.handback.<新任务>` = `"<原任务>:<序号>:<工单>"`。
    /// 全部读出、按新任务号升序（同一项退回过两次时，后一条是现行的）。
    public func handbackLinks() throws -> [HandbackLink] {
        try db.query("SELECT key,value FROM kv WHERE key LIKE 'task.handback.%' ORDER BY key").compactMap { r in
            let parts = r.text(1).split(separator: ":").map(String.init)
            guard let to = Int64(r.text(0).dropFirst("task.handback.".count)), parts.count == 3,
                  let from = Int64(parts[0]), let ord = Int(parts[1]), let ticket = Int64(parts[2]) else { return nil }
            return HandbackLink(fromTaskID: from, itemOrd: ord, ticketID: ticket, toTaskID: to)
        }.sorted { $0.toTaskID < $1.toTaskID }
    }

    func saveHandbackLink(_ l: HandbackLink) throws {
        try setKV("task.handback.\(l.toTaskID)", "\(l.fromTaskID):\(l.itemOrd):\(l.ticketID)")
    }

    /// 被人改派走的退回链接（链接项 4C）：那一项不再跟随新任务，新任务结束时也不回填。存 kv `task.handbackDetached.<新任务>`，
    /// 链接本身留作历史（`handbackLinks` 的 LIKE 'task.handback.%' 不会匹配这个键）。
    public func detachedHandbacks() throws -> Set<Int64> {
        Set(try db.query("SELECT key FROM kv WHERE key LIKE 'task.handbackDetached.%'").compactMap {
            Int64($0.text(0).dropFirst("task.handbackDetached.".count))
        })
    }

    func detachHandback(toTaskID: Int64) throws {
        try setKV("task.handbackDetached.\(toTaskID)", "1")
    }

    public func settings() throws -> Settings {
        var s = Settings()
        if let v = try kvInt("settings.slots") { s.slots = max(1, min(8, v)) }
        if let v = try kv("settings.worktree") { s.worktree = v == "1" }
        if let v = try kv("settings.acceptance") { s.acceptance = v == "1" }
        if let v = try kv("settings.idleSeconds").flatMap(Double.init) { s.idleSeconds = max(20, v) }
        if let v = try kvInt("settings.interruptionBudget") { s.interruptionBudget = max(1, min(99, v)) }
        if let v = try kv("settings.watchdogEnabled") { s.watchdogEnabled = v == "1" }
        if let v = try kvInt("settings.watchdogIntervalMinutes") { s.watchdogIntervalMinutes = max(1, min(120, v)) }
        if let v = try kv("settings.modelBackend").flatMap(ModelBackendKind.init) { s.modelBackend = v }
        if let v = try kv("settings.modelName")?.trimmingCharacters(in: .whitespaces), !v.isEmpty { s.modelName = v }
        if let v = try kv("settings.codingAgent").flatMap(CodingAgentKind.init) { s.codingAgent = v }
        if let v = try kv("settings.knowledgeSyncDir")?.trimmingCharacters(in: .whitespaces) { s.knowledgeSyncDir = v }
        return s
    }

    public func saveSettings(_ s: Settings) throws {
        try db.transaction {
            try setKV("settings.slots", String(s.slots))
            try setKV("settings.worktree", s.worktree ? "1" : "0")
            try setKV("settings.acceptance", s.acceptance ? "1" : "0")
            try setKV("settings.idleSeconds", String(Int(s.idleSeconds)))
            try setKV("settings.interruptionBudget", String(s.interruptionBudget))
            try setKV("settings.watchdogEnabled", s.watchdogEnabled ? "1" : "0")
            try setKV("settings.watchdogIntervalMinutes", String(s.watchdogIntervalMinutes))
            try setKV("settings.modelBackend", s.modelBackend.rawValue)
            try setKV("settings.modelName", s.modelName)
            try setKV("settings.codingAgent", s.codingAgent.rawValue)
            try setKV("settings.knowledgeSyncDir", s.knowledgeSyncDir.trimmingCharacters(in: .whitespaces).nilIfEmpty)
        }
    }

    /// 内置角色（人改过的用改过的版本）在前，然后是新建的角色。
    public func roles() throws -> [Role] {
        var saved: [Role] = []
        if let json = try kv("roles"), let data = json.data(using: .utf8) {
            saved = (try? JSONDecoder().decode([Role].self, from: data)) ?? []
        }
        let builtins = Role.builtins.map { b in saved.first { $0.name == b.name } ?? b }
        return builtins + saved.filter { !$0.isBuiltin }
    }

    public func role(_ name: String) throws -> Role? {
        try roles().first { $0.name == name }
    }

    /// 只存人改过的内置角色和新建的角色：内置角色的默认值随版本更新。
    func saveRoles(_ list: [Role]) throws {
        let changed = list.filter { r in !Role.builtins.contains(r) }
        let data = try JSONEncoder().encode(changed)
        try setKV("roles", String(decoding: data, as: UTF8.self))
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

    // MARK: - 组织同步（第 3 期：outbox、组织任务的服务端状态、节点设置；注意事项 I-01 / I-02）

    private static let outboxColumns = "id,task_id,kind,payload,seq,attempts,next_at,last_error,created_at"

    private static func outbox(_ r: SQLRow) -> OutboxEntry {
        OutboxEntry(id: r.int(0), taskID: r.int(1), kind: r.text(2), payload: r.text(3), seq: r.int(4), attempts: Int(r.int(5)),
                    nextAt: r.double(6), lastError: r.optText(7), createdAt: r.double(8))
    }

    /// 入队。同一任务同类未发送的合并成一条：seq+1、payload 换成新的、立即到期（位置不变，仍按最早入队的顺序重放）；
    /// 失败计数保留，直到成功一次。`taskID = 0` 是节点级（当天打扰次数）。
    func enqueueOutbox(_ taskID: Int64, kind: String, payload: String = "", at: Double) throws {
        try db.run("""
            INSERT INTO outbox (task_id,kind,payload,seq,attempts,next_at,created_at) VALUES (?,?,?,1,0,?,?)
            ON CONFLICT(task_id,kind) DO UPDATE SET seq=seq+1, payload=excluded.payload, next_at=MIN(next_at, excluded.next_at)
            """, [.int(taskID), .text(kind), .text(payload), .real(at), .real(at)])
    }

    /// 到期的上行，按入队顺序（按序重放）。
    public func pendingOutbox(now: Double) throws -> [OutboxEntry] {
        try db.query("SELECT \(Self.outboxColumns) FROM outbox WHERE next_at<=? ORDER BY id", [.real(now)]).map(Self.outbox)
    }

    /// 全部未发送的上行，按入队顺序。
    public func outbox() throws -> [OutboxEntry] {
        try db.query("SELECT \(Self.outboxColumns) FROM outbox ORDER BY id").map(Self.outbox)
    }

    public func outbox(task id: Int64) throws -> [OutboxEntry] {
        try db.query("SELECT \(Self.outboxColumns) FROM outbox WHERE task_id=? ORDER BY id", [.int(id)]).map(Self.outbox)
    }

    /// 发送成功：只有 seq 没变才删除（发送期间又入队的改动保留并立即到期）。
    public func completeOutbox(_ e: OutboxEntry) throws {
        try db.transaction {
            let n = try db.run("DELETE FROM outbox WHERE id=? AND seq=?", [.int(e.id), .int(e.seq)])
            if n == 0 { try db.run("UPDATE outbox SET attempts=0, last_error=NULL WHERE id=?", [.int(e.id)]) }
        }
    }

    /// 发送失败（连不上 / 5xx）：指数退避 2s→60s，不停摆——断网恢复后要尽快重放。返回新的失败次数。
    @discardableResult
    public func failOutbox(_ e: OutboxEntry, error: String, now: Double) throws -> Int {
        let attempts = e.attempts + 1
        let delay = min(60, 2 * pow(2, Double(attempts - 1)))
        try db.run("UPDATE outbox SET attempts=?, next_at=?, last_error=? WHERE id=?",
                   [.int(Int64(attempts)), .real(now + delay), .text(String(error.prefix(300))), .int(e.id)])
        return attempts
    }

    func dropOutbox(task id: Int64) throws {
        try db.run("DELETE FROM outbox WHERE task_id=?", [.int(id)])
    }

    /// 组织任务按 `(origin, origin_id)` 唯一（I-01）。
    public func task(origin: String, originID: String) throws -> WorkTask? {
        try tasks(rows: try db.query("SELECT \(Self.taskColumns) FROM task WHERE origin=? AND origin_id=?", [.text(origin), .text(originID)])).first
    }

    /// 某个服务器的、处于某个同步状态的任务（「待领取」的对账用）。
    public func tasks(origin: String, syncState: String) throws -> [WorkTask] {
        try tasks(rows: try db.query("SELECT \(Self.taskColumns) FROM task WHERE origin=? AND sync_state=? ORDER BY id",
                                     [.text(origin), .text(syncState)]))
    }

    /// 只给「待领取」的占位行用（它从没被做过）：连同清单项、同步状态、时间线、上行一起删。普通任务不硬删（注意事项 B-08）。
    func deleteTask(_ id: Int64) throws {
        for sql in ["DELETE FROM item WHERE task_id=?", "DELETE FROM org_item WHERE task_id=?", "DELETE FROM org_task WHERE task_id=?",
                    "DELETE FROM task_context_link WHERE task_id=?",
                    "DELETE FROM task_dep WHERE task_id=? OR depends_on=?", "DELETE FROM event WHERE task_id=?",
                    "DELETE FROM outbox WHERE task_id=?", "DELETE FROM task WHERE id=?"] {
            try db.run(sql, Array(repeating: SQLValue.int(id), count: sql.components(separatedBy: "?").count - 1))
        }
    }

    func orgState(_ taskID: Int64) throws -> OrgTaskState? {
        try db.query("SELECT task_id,version,label,scope_name,edits,needs_sent,audit_after FROM org_task WHERE task_id=?", [.int(taskID)]).first.map {
            OrgTaskState(taskID: $0.int(0), version: Int($0.int(1)), label: $0.text(2), scopeName: $0.text(3), edits: $0.int(4) != 0,
                         needsSent: $0.text(5), auditAfter: $0.int(6))
        }
    }

    func saveOrgState(_ s: OrgTaskState) throws {
        try db.run("""
            INSERT INTO org_task (task_id,version,label,scope_name,edits,needs_sent,audit_after) VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(task_id) DO UPDATE SET version=excluded.version, label=excluded.label, scope_name=excluded.scope_name,
              edits=excluded.edits, needs_sent=excluded.needs_sent, audit_after=excluded.audit_after
            """, [.int(s.taskID), .int(Int64(s.version)), .text(s.label), .text(s.scopeName), .bool(s.edits), .text(s.needsSent), .int(s.auditAfter)])
    }

    private static func orgItem(_ r: SQLRow) -> OrgItemState {
        OrgItemState(itemID: r.int(0), taskID: r.int(1), originItemID: r.int(2), syncedStatus: ItemStatus(rawValue: r.text(3)) ?? .todo,
                     conflictLocal: r.optText(4).flatMap(ItemStatus.init), conflictServer: r.optText(5).flatMap(ItemStatus.init))
    }

    func orgItems(_ taskID: Int64) throws -> [OrgItemState] {
        try db.query("SELECT item_id,task_id,origin_item_id,synced_status,conflict_local,conflict_server FROM org_item WHERE task_id=? ORDER BY item_id",
                     [.int(taskID)]).map(Self.orgItem)
    }

    func saveOrgItem(_ s: OrgItemState) throws {
        try db.run("""
            INSERT INTO org_item (item_id,task_id,origin_item_id,synced_status,conflict_local,conflict_server) VALUES (?,?,?,?,?,?)
            ON CONFLICT(item_id) DO UPDATE SET origin_item_id=excluded.origin_item_id, synced_status=excluded.synced_status,
              conflict_local=excluded.conflict_local, conflict_server=excluded.conflict_server
            """, [.int(s.itemID), .int(s.taskID), .int(s.originItemID), .text(s.syncedStatus.rawValue),
                  .opt(s.conflictLocal?.rawValue), .opt(s.conflictServer?.rawValue)])
    }

    func deleteOrgItem(_ itemID: Int64) throws {
        try db.run("DELETE FROM org_item WHERE item_id=?", [.int(itemID)])
    }

    /// 一批任务里没裁决的同步冲突，按任务分组、各自按 `ord`（清单页一次聚合，注意事项 B-11）。
    public func orgConflicts(taskIDs: [Int64]) throws -> [Int64: [SyncConflict]] {
        var out: [Int64: [SyncConflict]] = [:]
        for chunk in Self.chunks(taskIDs) {
            let rows = try db.query("""
                SELECT o.task_id, i.ord, i.text, o.conflict_local, o.conflict_server FROM org_item o JOIN item i ON i.id=o.item_id
                WHERE o.conflict_server IS NOT NULL AND o.task_id IN (\(Self.marks(chunk.count))) ORDER BY o.task_id, i.ord
                """, chunk.map(SQLValue.int))
            for r in rows {
                out[r.int(0), default: []].append(SyncConflict(ord: Int(r.int(1)), text: r.text(2), local: ItemStatus(rawValue: r.text(3)) ?? .todo,
                                                               server: ItemStatus(rawValue: r.text(4)) ?? .todo))
            }
        }
        return out
    }

    /// 任务的活动，`after` 之后的 `limit` 条（审计摘要上行用），按 id 升序。
    public func events(taskID: Int64, after: Int64, limit: Int = 50) throws -> [TimelineEvent] {
        try db.query("SELECT id,at,ticket_id,kind,text,task_id FROM event WHERE task_id=? AND id>? ORDER BY id LIMIT ?",
                     [.int(taskID), .int(after), .int(Int64(limit))]).map {
            TimelineEvent(id: $0.int(0), at: $0.double(1), ticketID: $0.optInt(2), kind: $0.text(3), text: $0.text(4), taskID: $0.optInt(5))
        }
    }

    public func orgSettings() throws -> OrgSettings {
        var s = OrgSettings()
        s.serverURL = try kv("org.serverURL") ?? ""
        s.email = try kv("org.email") ?? ""
        s.nodeID = try kv("org.nodeID")
        s.lastSync = try kv("org.lastSync").flatMap(Double.init)
        s.taskCursor = try kv("org.taskCursor")
        s.eventCursor = try kv("org.eventCursor")
        s.workspace = try kv("org.workspace") ?? ""
        return s
    }

    public func saveOrgSettings(_ s: OrgSettings) throws {
        try db.transaction {
            try setKV("org.serverURL", s.serverURL.nilIfEmpty)
            try setKV("org.email", s.email.nilIfEmpty)
            try setKV("org.nodeID", s.nodeID)
            try setKV("org.lastSync", s.lastSync.map { String($0) })
            try setKV("org.taskCursor", s.taskCursor)
            try setKV("org.eventCursor", s.eventCursor)
            try setKV("org.workspace", s.workspace.nilIfEmpty)
        }
    }
}
