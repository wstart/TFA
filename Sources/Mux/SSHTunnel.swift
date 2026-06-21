import Foundation
import Observation
import TmuxKit

// MARK: - SSH 反向端口转发(reverse tunnel)
//
// 把本机的一个端口通过 ssh 反向暴露到远程服务器上:
//   ssh -N -R <remotePort>:localhost:<localPort> -p <loginPort> <account>@<serverIP>
// 服务器上访问 localhost:remotePort 即打到本机的 localPort。密码复用 TFA 现成的 SSH_ASKPASS
// 注入(见 TmuxConnection.askpassEnv),无需 PTY 交互。进程退出即按指数退避自动重连。

/// 一条隧道配置。密码不存这里——存 Keychain(AppModel 用 `tunnel:<id>` 作 key)。
struct SSHTunnel: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var serverIP: String
    var account: String
    var loginPort: Int = 22
    var remotePort: Int        // 服务器上映射出的端口
    var localPort: Int         // 本机被转发的端口
    var enabled: Bool = false  // 记住的开关:为 true 则开机自动拉起
    /// 远程端口绑定到所有网卡(`-R 0.0.0.0:…`),让外网可访问;否则只绑服务器 loopback。
    /// 注意:还需服务器 sshd_config 设 `GatewayPorts yes`(或 clientspecified)才真正生效。
    var gatewayPorts: Bool = false

    init(id: UUID = UUID(), name: String, serverIP: String, account: String,
         loginPort: Int = 22, remotePort: Int, localPort: Int, enabled: Bool = false, gatewayPorts: Bool = false) {
        self.id = id; self.name = name; self.serverIP = serverIP; self.account = account
        self.loginPort = loginPort; self.remotePort = remotePort; self.localPort = localPort
        self.enabled = enabled; self.gatewayPorts = gatewayPorts
    }
    // 容错解码(后续加字段也能读旧数据)。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        serverIP = try c.decode(String.self, forKey: .serverIP)
        account = try c.decode(String.self, forKey: .account)
        loginPort = try c.decodeIfPresent(Int.self, forKey: .loginPort) ?? 22
        remotePort = try c.decode(Int.self, forKey: .remotePort)
        localPort = try c.decode(Int.self, forKey: .localPort)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        gatewayPorts = try c.decodeIfPresent(Bool.self, forKey: .gatewayPorts) ?? false
    }

    /// `账号@IP:登录端口` — 副标题展示用。
    var endpointLabel: String { "\(account)@\(serverIP):\(loginPort)" }
    /// `远程:remotePort ← 本地:localPort` — 一眼看清转发方向。
    var forwardLabel: String { "远程 :\(remotePort)  ←  本地 :\(localPort)" }
}

/// 一条隧道的运行态(驱动 UI 的状态点)。
enum TunnelState: Equatable {
    case stopped
    case connecting
    case running
    case retrying(String)   // 断开了,正按退避重连;附最近一次错误

    var isLive: Bool { if case .stopped = self { return false }; return true }
}

/// 进程生命周期管理器:每条隧道一个 `ssh -N -R` 子进程,断开自动重连。与持久化 / 密码解耦
/// (密码经 `passwordFor` 闭包从 AppModel 的 Keychain 镜像取)。
@MainActor
@Observable
final class TunnelRunner {
    /// id → 运行态(UI 观察)。
    private(set) var states: [UUID: TunnelState] = [:]
    /// id → 连接日志(最近若干行,UI 观察)。捕获 ssh 的 stdout/stderr + 生命周期事件。
    private(set) var logs: [UUID: [String]] = [:]
    /// 取某条隧道的密码(由 AppModel 注入:读 Keychain 镜像)。
    @ObservationIgnored var passwordFor: (UUID) -> String? = { _ in nil }

    @ObservationIgnored private var procs: [UUID: Process] = [:]
    @ObservationIgnored private var intentionalStop: Set<UUID> = []   // 用户主动停 → 不重连
    @ObservationIgnored private var attempts: [UUID: Int] = [:]
    @ObservationIgnored private var graceTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastError: [UUID: String] = [:]
    private static let maxLogLines = 400

    func state(_ id: UUID) -> TunnelState { states[id] ?? .stopped }
    func log(_ id: UUID) -> [String] { logs[id] ?? [] }
    func clearLog(_ id: UUID) { logs[id] = [] }

    /// 时间戳前缀的日志格式化器(仅主线程用)。
    @ObservationIgnored private static let logClock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private func appendLog(_ id: UUID, _ line: String) {
        var arr = logs[id] ?? []
        arr.append("\(Self.logClock.string(from: Date()))  \(line)")
        if arr.count > Self.maxLogLines { arr.removeFirst(arr.count - Self.maxLogLines) }
        logs[id] = arr
    }
    /// 把 ssh 流式输出切成行写入日志,并记住最近一条非空(用于断开提示)。
    private func ingest(_ id: UUID, _ chunk: String) {
        for raw in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            appendLog(id, line)
            lastError[id] = line
        }
    }

    /// 启动(幂等:已在跑则忽略)。
    func start(_ t: SSHTunnel) {
        guard procs[t.id] == nil else { return }
        intentionalStop.remove(t.id)
        attempts[t.id] = 0
        states[t.id] = .connecting
        spawn(t)
    }

    /// 用户主动停止 → 终止进程且不再重连。
    func stop(_ id: UUID) {
        intentionalStop.insert(id)
        graceTasks[id]?.cancel(); graceTasks[id] = nil
        procs[id]?.terminate()
        procs[id] = nil
        states[id] = .stopped
    }

    /// 应用配置改动:重启该隧道,让新参数生效。
    func restart(_ t: SSHTunnel) {
        if procs[t.id] != nil {
            intentionalStop.insert(t.id)
            procs[t.id]?.terminate()
            procs[t.id] = nil
        }
        start(t)
    }

    /// 退出 app 时终止所有隧道,避免 ssh 子进程变孤儿。
    func stopAll() {
        for (id, p) in procs { intentionalStop.insert(id); p.terminate() }
        procs.removeAll()
        for (_, t) in graceTasks { t.cancel() }
        graceTasks.removeAll()
    }

    // MARK: - internals

    private func spawn(_ t: SSHTunnel) {
        // GatewayPorts on → bind 远程端口到所有网卡(外网可达,需服务器也允许);否则只绑 loopback。
        let forward = t.gatewayPorts
            ? "0.0.0.0:\(t.remotePort):localhost:\(t.localPort)"
            : "\(t.remotePort):localhost:\(t.localPort)"
        let args = [
            "-N",                                              // 不执行远程命令,只做转发
            "-R", forward,                                     // 反向转发
            "-p", "\(t.loginPort)",
            "-o", "ExitOnForwardFailure=yes",                  // 远程端口占用/绑定失败 → 立即退出(好报错+重连)
            "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3", // 链路死了能察觉 → 退出 → 重连
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "NumberOfPasswordPrompts=1",
            "\(t.account)@\(t.serverIP)",
        ]
        appendLog(t.id, "▶ 启动:ssh \(args.joined(separator: " "))")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        if let pw = passwordFor(t.id), let ask = TmuxConnection.askpassEnv(password: pw) {
            for (k, v) in ask { env[k] = v } // SSH_ASKPASS + TFA_SSH_PASSWORD,无 tty 也能喂密码
        }
        p.environment = env
        // 流式捕获 ssh 的 stderr/stdout 到日志(EOF 时摘掉 handler 避免空读风暴)。
        let onData: @Sendable (FileHandle) -> Void = { [weak self] fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; return }
            guard let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in self?.ingest(t.id, s) }
        }
        let errPipe = Pipe(); p.standardError = errPipe
        let outPipe = Pipe(); p.standardOutput = outPipe
        errPipe.fileHandleForReading.readabilityHandler = onData
        outPipe.fileHandleForReading.readabilityHandler = onData
        p.terminationHandler = { [weak self] proc in
            errPipe.fileHandleForReading.readabilityHandler = nil
            outPipe.fileHandleForReading.readabilityHandler = nil
            let code = proc.terminationStatus
            Task { @MainActor in self?.handleExit(t, status: code) }
        }
        do {
            try p.run()
            procs[t.id] = p
            // ssh -N 没有明确的"已连上"信号:存活 3 秒未退出就当作已建立。
            graceTasks[t.id]?.cancel()
            graceTasks[t.id] = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let cur = self.procs[t.id], cur.isRunning else { return }
                self.states[t.id] = .running
                self.attempts[t.id] = 0
                self.appendLog(t.id, "✓ 已连接")
            }
        } catch {
            appendLog(t.id, "✕ 启动失败:\(error.localizedDescription)")
            states[t.id] = .retrying(error.localizedDescription)
            scheduleReconnect(t)
        }
    }

    private func handleExit(_ t: SSHTunnel, status: Int32) {
        procs[t.id] = nil
        graceTasks[t.id]?.cancel(); graceTasks[t.id] = nil
        guard !intentionalStop.contains(t.id) else {
            states[t.id] = .stopped
            appendLog(t.id, "■ 已停止")
            return
        }
        let msg = lastError[t.id] ?? "连接断开 (exit \(status))"
        appendLog(t.id, "✕ 断开 (exit \(status))")
        states[t.id] = .retrying(msg)
        scheduleReconnect(t)
    }

    private func scheduleReconnect(_ t: SSHTunnel) {
        let n = (attempts[t.id] ?? 0) + 1
        attempts[t.id] = n
        let delay = min(pow(2.0, Double(n - 1)), 30.0) // 1,2,4,8,16,30,30… 封顶 30s,长存活
        appendLog(t.id, "↻ \(Int(delay))s 后重连(第 \(n) 次)")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !self.intentionalStop.contains(t.id), self.procs[t.id] == nil else { return }
            self.spawn(t)
        }
    }
}
