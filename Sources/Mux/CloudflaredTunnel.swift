import Foundation
import Observation

// MARK: - Cloudflare 公网隧道(cloudflared quick tunnel)
//
// 把本机的一个端口直接暴露成公网 HTTPS 地址:
//   cloudflared tunnel --url http://127.0.0.1:<port> --no-autoupdate
// 走 TryCloudflare 免费快速隧道:无需账号/登录,每次启动分配一个随机的
// `https://<random>.trycloudflare.com` 地址(从 cloudflared 的日志里解析)。
// 注意:地址是公网可达的 —— 随机到不可猜,但**拿到链接的任何人都能访问**,UI 里要说清。

/// 一条公网隧道配置(无凭据,持久化整条进 UserDefaults)。
struct CloudflaredTunnel: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var localPort: Int
    var enabled: Bool = false  // 记住的开关:为 true 则开机自动拉起

    init(id: UUID = UUID(), name: String, localPort: Int, enabled: Bool = false) {
        self.id = id; self.name = name; self.localPort = localPort; self.enabled = enabled
    }
    // 容错解码(后续加字段也能读旧数据)。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        localPort = try c.decode(Int.self, forKey: .localPort)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }
}

/// cloudflared 子进程管理器:每条隧道一个 `cloudflared tunnel --url`,从日志解析分配到的公网
/// 地址,断开按指数退避自动重连。与 `TunnelRunner`(ssh -R)同构 —— 有意保持两份小而直白的
/// 实现,而不是为两个后端抽一层(重复优于错误的抽象)。
@MainActor
@Observable
final class CloudflaredRunner {
    /// id → 运行态(UI 观察;复用 SSH 隧道的 TunnelState 词汇)。
    private(set) var states: [UUID: TunnelState] = [:]
    /// id → 本次分配到的公网地址(running 时有值;每次重启都会变)。
    private(set) var urls: [UUID: String] = [:]
    /// id → 连接日志(最近若干行,UI 观察)。
    private(set) var logs: [UUID: [String]] = [:]

    @ObservationIgnored private var procs: [UUID: Process] = [:]
    @ObservationIgnored private var intentionalStop: Set<UUID> = []
    @ObservationIgnored private var attempts: [UUID: Int] = [:]
    @ObservationIgnored private var lastError: [UUID: String] = [:]
    private static let maxLogLines = 400

    func state(_ id: UUID) -> TunnelState { states[id] ?? .stopped }
    func url(_ id: UUID) -> String? { urls[id] }
    func log(_ id: UUID) -> [String] { logs[id] ?? [] }
    func clearLog(_ id: UUID) { logs[id] = [] }

    /// 本机的 cloudflared 可执行文件(Homebrew ARM/Intel、系统路径);nil = 未安装 → UI 给安装提示。
    nonisolated static func binaryPath() -> String? {
        for p in ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared", "/usr/bin/cloudflared"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    @ObservationIgnored private static let logClock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private func appendLog(_ id: UUID, _ line: String) {
        var arr = logs[id] ?? []
        arr.append("\(Self.logClock.string(from: Date()))  \(line)")
        if arr.count > Self.maxLogLines { arr.removeFirst(arr.count - Self.maxLogLines) }
        logs[id] = arr
    }

    /// 公网地址的解析:cloudflared 把分配结果打在日志里(一个框住的
    /// `https://xxx.trycloudflare.com`)。看到即视为「已连通」。
    private static let urlRegex = try! NSRegularExpression(pattern: #"https://[a-zA-Z0-9-]+\.trycloudflare\.com"#)

    private func ingest(_ id: UUID, _ chunk: String) {
        for raw in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            appendLog(id, line)
            lastError[id] = line
            let range = NSRange(line.startIndex..., in: line)
            if let m = Self.urlRegex.firstMatch(in: line, range: range), let r = Range(m.range, in: line) {
                let url = String(line[r])
                if urls[id] != url {
                    urls[id] = url
                    states[id] = .running
                    attempts[id] = 0
                    appendLog(id, "✓ 公网地址:\(url)")
                }
            }
        }
    }

    /// 启动(幂等:已在跑则忽略)。
    func start(_ t: CloudflaredTunnel) {
        guard procs[t.id] == nil else { return }
        intentionalStop.remove(t.id)
        attempts[t.id] = 0
        states[t.id] = .connecting
        spawn(t)
    }

    /// 用户主动停止 → 终止进程且不再重连。
    func stop(_ id: UUID) {
        intentionalStop.insert(id)
        procs[id]?.terminate()
        procs[id] = nil
        urls[id] = nil
        states[id] = .stopped
    }

    /// 应用配置改动:重启该隧道,让新端口生效(公网地址会变)。
    func restart(_ t: CloudflaredTunnel) {
        if procs[t.id] != nil {
            intentionalStop.insert(t.id)
            procs[t.id]?.terminate()
            procs[t.id] = nil
        }
        start(t)
    }

    /// 退出 app 时终止所有隧道,避免 cloudflared 子进程变孤儿。
    func stopAll() {
        for (id, p) in procs { intentionalStop.insert(id); p.terminate() }
        procs.removeAll()
    }

    // MARK: - internals

    private func spawn(_ t: CloudflaredTunnel) {
        guard let bin = Self.binaryPath() else {
            appendLog(t.id, "✕ 未找到 cloudflared(brew install cloudflared)")
            states[t.id] = .retrying("未安装 cloudflared")
            return // 不进重连循环 — 装好后用开关重新启动
        }
        let args = ["tunnel", "--url", "http://127.0.0.1:\(t.localPort)", "--no-autoupdate"]
        appendLog(t.id, "▶ 启动:cloudflared \(args.joined(separator: " "))")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let onData: @Sendable (FileHandle) -> Void = { [weak self] fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; return }
            guard let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in self?.ingest(t.id, s) }
        }
        let errPipe = Pipe(); p.standardError = errPipe   // cloudflared 的日志(含公网地址)走 stderr
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
        } catch {
            appendLog(t.id, "✕ 启动失败:\(error.localizedDescription)")
            states[t.id] = .retrying(error.localizedDescription)
            scheduleReconnect(t)
        }
    }

    private func handleExit(_ t: CloudflaredTunnel, status: Int32) {
        procs[t.id] = nil
        urls[t.id] = nil
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

    private func scheduleReconnect(_ t: CloudflaredTunnel) {
        let n = (attempts[t.id] ?? 0) + 1
        attempts[t.id] = n
        let delay = min(pow(2.0, Double(n - 1)), 30.0)
        appendLog(t.id, "↻ \(Int(delay))s 后重连(第 \(n) 次)")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !self.intentionalStop.contains(t.id), self.procs[t.id] == nil else { return }
            self.spawn(t)
        }
    }
}
