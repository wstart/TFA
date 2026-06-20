import Foundation
import Observation

/// 任务调度中心 — 派发队列 + attention 调和,从 AppModel 拆出的纯领域逻辑。
///
/// ```
/// 看板(SQLite) ←─ DispatchBoard ──┐
///                                  │   tick(): ① flush 排队派发(终端转闲/连上后补发)
///   终端们    ←─ DispatchTerminal ─┼──        ② flush 排队的回复/补充行
///   (仅本地)                       │          ③ 看板 ask/blocked → 终端 attention(入态一次)
/// ```
///
/// 两个协议把它与 UI / tmux / SQLite 解耦:测试用假终端+假看板覆盖全部边界
/// (忙→排队→闲→派发、连接中→补发、任务删除→清队、远程拒绝、attention 复位)。
@MainActor
protocol DispatchTerminal: AnyObject {
    /// 永久身份(@tfa_id)。看板 agent id = "tfa:<agentKey>"。
    var agentKey: String { get }
    var displayName: String { get }
    /// 远程(ssh)终端禁止派发 — 它们摸不到本机 board.db,回报通道不存在。
    var isLocal: Bool { get }
    var isConnected: Bool { get }
    /// 正在产出输出(此刻输入会被吞)— 派发只在空闲时落键。
    var isBusy: Bool { get }
    func ensureConnected()
    func sendLine(_ line: String)
    func raiseAttention(message: String)
}

@MainActor
protocol DispatchBoard: AnyObject {
    var allTasks: [BoardTask] { get }
    func agentName(_ id: String) -> String?
    func addComment(_ id: UUID, by: String, text: String, kind: String)
    func setAssignee(_ id: UUID, to agentID: String?)
    func move(_ id: UUID, to status: TaskStatus)
}

@MainActor
final class DispatchCenter {
    private let board: DispatchBoard
    /// 当前终端快照(由 AppModel 注入;测试注入假终端)。
    var terminals: () -> [any DispatchTerminal] = { [] }

    /// taskID → agentID:目标终端忙/连接中时排队,转闲后由 tick 补发。
    private(set) var pendingDispatch: [UUID: String] = [:]
    /// 排队的回复/补充行(目标终端忙时缓存),key = agentKey。
    private(set) var pendingLines: [(key: String, line: String)] = []
    /// 已经为「等待人」状态亮过铃铛的任务 — 入态只触发一次,离态复位。
    private(set) var surfacedAttention: Set<UUID> = []

    init(board: DispatchBoard) {
        self.board = board
    }

    private func terminal(forKey key: String) -> (any DispatchTerminal)? {
        terminals().first { $0.agentKey == key }
    }

    // MARK: - 入口(UI 调用)

    /// 指派并派发:状态 → 进行中,向终端打一行认领指令(忙则排队)。
    func dispatchTask(_ taskID: UUID, to agentID: String) {
        guard board.allTasks.contains(where: { $0.id == taskID }) else { return }
        board.setAssignee(taskID, to: agentID)
        board.move(taskID, to: .doing)
        attemptDispatch(taskID, to: agentID, queueIfBusy: true)
    }

    /// 人的回复/补充:记到看板,并推进被指派的终端(忙则排队)。
    func pushReply(_ taskID: UUID, text: String) {
        board.addComment(taskID, by: "你", text: text, kind: "note")
        guard let task = board.allTasks.first(where: { $0.id == taskID }),
              let a = task.assignee, a.hasPrefix("tfa:") else { return }
        let key = String(a.dropFirst("tfa:".count))
        let short = String(taskID.uuidString.lowercased().prefix(8))
        sendOrQueueLine(key, "【任务 #\(short) 补充】\(text)（`~/.tfa/bin/tfa-task show \(short)` 看全部）")
    }

    // MARK: - 心跳(主循环每 tick 调一次)

    /// ① 终端转闲 → 补发排队任务;② flush 排队行;③ 看板等待状态 → attention。
    func tick() {
        for (taskID, agentID) in Array(pendingDispatch) {
            guard board.allTasks.contains(where: { $0.id == taskID }) else {
                pendingDispatch[taskID] = nil // 任务已删除 → 出队
                continue
            }
            let key = String(agentID.dropFirst("tfa:".count))
            guard let t = terminal(forKey: key) else { continue } // 终端暂时不在(关了/未发现)→ 留队
            if t.isConnected, !t.isBusy { attemptDispatch(taskID, to: agentID, queueIfBusy: false) }
        }
        for i in pendingLines.indices.reversed() {
            let p = pendingLines[i]
            if let t = terminal(forKey: p.key), t.isConnected, !t.isBusy {
                t.sendLine(p.line)
                pendingLines.remove(at: i)
            }
        }
        reconcileAttention()
    }

    // MARK: - internals

    /// 只在终端空闲时落键 — 命令运行中打进去会被吞掉却报「已派发」(历史 bug)。
    private func attemptDispatch(_ taskID: UUID, to agentID: String, queueIfBusy: Bool) {
        let name = board.agentName(agentID) ?? agentID
        guard agentID.hasPrefix("tfa:") else {
            board.addComment(taskID, by: "TFA", text: "「\(name)」不是 TFA 终端,无法派发", kind: "note")
            return
        }
        let key = String(agentID.dropFirst("tfa:".count))
        guard let t = terminal(forKey: key) else {
            board.addComment(taskID, by: "TFA", text: "未找到终端 \(name),未派发", kind: "note")
            return
        }
        guard t.isLocal else {
            // 远程终端摸不到本机看板,agent 永远无法回报 — 拒绝并说明,绝不静默假装成功。
            board.addComment(taskID, by: "TFA", text: "「\(name)」是远程终端,不支持任务派发(无法回报)", kind: "note")
            return
        }
        t.ensureConnected() // 幂等 — dormant 占位则现在开始连
        if !t.isConnected || t.isBusy {
            if queueIfBusy, pendingDispatch[taskID] == nil {
                pendingDispatch[taskID] = agentID
                let why = t.isConnected ? "终端忙" : "终端连接中"
                board.addComment(taskID, by: "TFA", text: "\(why),已排队 — 就绪后自动派发给 \(name)", kind: "note")
            }
            return
        }
        pendingDispatch[taskID] = nil
        guard let task = board.allTasks.first(where: { $0.id == taskID }) else { return }
        t.sendLine(Self.dispatchLine(task))
        board.addComment(taskID, by: "TFA", text: "已派发给 \(name)", kind: "note")
    }

    private func sendOrQueueLine(_ key: String, _ line: String) {
        guard let t = terminal(forKey: key) else { return }
        guard t.isLocal else { return } // 远程终端不推送(同派发硬门)
        if !t.isConnected || t.isBusy {
            pendingLines.append((key, line))
            t.ensureConnected()
        } else {
            t.sendLine(line)
        }
    }

    /// 统一「等你接管」信号:任务进入 question/blocked → 点亮其终端的 attention。
    /// 入态触发一次(surfacedAttention),用户查看即清;离开等待态后可再次触发。
    private func reconcileAttention() {
        for t in board.allTasks {
            let waiting = t.status == .blocked || t.comments.last?.kind == "question"
            if waiting, !surfacedAttention.contains(t.id) {
                surfacedAttention.insert(t.id)
                if let a = t.assignee, a.hasPrefix("tfa:"),
                   let term = terminal(forKey: String(a.dropFirst("tfa:".count))) {
                    let msg = t.comments.last?.text ?? t.title
                    term.raiseAttention(message: "任务「\(t.title)」: \(msg)")
                }
            } else if !waiting {
                surfacedAttention.remove(t.id)
            }
        }
    }

    /// 单行派发指令(不能含换行 — 换行会让交互式 agent CLI 提前提交)。全文经 `tfa-task show` 读。
    static func dispatchLine(_ t: BoardTask) -> String {
        let short = String(t.id.uuidString.lowercased().prefix(8)) // matches the CLI's lowercased ids
        let b = "~/.tfa/bin/tfa-task"
        // 正文在看板上(show 可读)— 打进终端的行要有界,超长标题截断。
        let title = t.title.count > 60 ? t.title.prefix(60) + "…" : Substring(t.title)
        return "请认领并处理 TFA 任务 #\(short)「\(title)」。"
            + "步骤:① `\(b) show \(short)` 看完整需求;② `\(b) claim \(short)` 认领;"
            + "③ 每完成一步用 `\(b) step \(short) \"做了什么/下一步\"` 实时回报;"
            + "④ 需要我确认/补信息用 `\(b) ask \(short) \"问题\"`,卡住用 `\(b) block \(short) \"原因\"`;"
            + "⑤ 全部做完后先 `\(b) step \(short) \"最终结果:…(改了哪些文件/验证情况)\"` 回报结果,再 `\(b) done \(short)`。"
            + "务必边做边回报,让我在看板上看到完整过程和最终结果。"
    }
}

// MARK: - 生产适配

/// TaskBoardStore 直接充当 DispatchBoard(它本就是 UI 无关的 SQLite 门面)。
extension TaskBoardStore: DispatchBoard {
    var allTasks: [BoardTask] { board.tasks }
    func agentName(_ id: String) -> String? { agent(id)?.name }
}

/// 把一个 ConnectionSession(+AppModel 的忙闲判断)包成 DispatchTerminal。
@MainActor
final class TerminalAgentAdapter: DispatchTerminal {
    private let conn: ConnectionSession
    private unowned let model: AppModel

    init(_ conn: ConnectionSession, model: AppModel) {
        self.conn = conn
        self.model = model
    }

    var agentKey: String { conn.stableID }
    var displayName: String { conn.title }
    var isLocal: Bool { conn.host == nil }
    var isConnected: Bool { conn.state.connected }
    var isBusy: Bool { model.isWorking(conn) }
    func ensureConnected() { model.ensureConnected(conn.id) }
    func sendLine(_ line: String) { conn.sendLine(line) }
    func raiseAttention(message: String) { conn.raiseAttention(message: message) }
}
