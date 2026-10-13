import AppKit
import Observation
import SwiftUI

/// The bundled `axis-claude` CLI (a small Claude-Code-style agent that talks to axis-model). It ships
/// next to the app executable — `TFA.app/Contents/MacOS/axis-claude`, or `.build/<config>/` in dev.
enum AxisClaude {
    static var executablePath: String? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = dir.appendingPathComponent("axis-claude").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Shell command that starts (or, with `resume`, continues the last conversation of) axis-claude.
    static func command(resume: Bool) -> String? {
        executablePath.map { AgentPlatform.shellQuote($0) + (resume ? " --continue" : "") }
    }
}

/// Local axis-model (MLX inference server, github.com/wstart/axis-model): install detection, status,
/// stats and control. The server is launchd-managed (KeepAlive), so start/stop go through launchctl —
/// killing the process would just get it relaunched. Talks to the server's own HTTP API.
@MainActor
@Observable
final class AxisModelService {
    static let shared = AxisModelService()

    enum Status: Equatable {
        case notInstalled, stopped, starting, standby, running, stopping
        var label: String {
            switch self {
            case .notInstalled: "未安装"
            case .stopped: "已停止"
            case .starting: "启动中…"
            case .standby: "待命 · 未加载模型"
            case .running: "运行中"
            case .stopping: "停止中…"
            }
        }
    }

    struct Model: Identifiable, Equatable { let id: String; let path: String; let sizeGB: Double }

    struct Stats: Equatable {
        var rpm = 0.0, tpm = 0, cacheHitRate = 0.0, totalRequests = 0
        var cacheSlots = 0, cacheMaxSlots = 0, memoryGB = 0.0, systemGB = 0.0, uptime = 0.0
    }

    nonisolated static let repoURL = "https://github.com/wstart/axis-model"
    nonisolated static let repoDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("axis-model").path
    nonisolated static let appPath = "/Applications/Axis Model.app"
    nonisolated static let plistPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.local.mlxserver.plist").path
    nonisolated private static let base = URL(string: "http://127.0.0.1:1234")!

    private(set) var status: Status = .stopped
    private(set) var currentModelPath = ""
    private(set) var models: [Model] = []
    private(set) var stats = Stats()
    private(set) var loadError = ""
    private(set) var commitsBehind = 0
    private(set) var switchingTo: String?
    var lastMessage: String?

    /// A requested start/stop is in flight until the server answers (or stops answering) — or this
    /// deadline passes (the server saves its cache before exiting, which can take a while).
    @ObservationIgnored private var transitionDeadline: Date?

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.plistPath)
            || FileManager.default.fileExists(atPath: Self.repoDir + "/mlx_server/server.py")
    }
    var isReachable: Bool { status == .running || status == .standby }
    var currentModelName: String { (currentModelPath as NSString).lastPathComponent }

    func refresh() async {
        let health = await Self.getJSON("/health", timeout: 2)
        if let health {
            let ready = health["status"] as? String == "ok"
            if status == .stopping, let d = transitionDeadline, Date() < d {
                // still saving its cache on the way down — keep showing 停止中
            } else {
                status = ready ? .running : .standby
                transitionDeadline = nil
            }
            loadError = health["error"] as? String ?? ""
            if let s = await Self.getJSON("/stats", timeout: 3) {
                stats = Stats(rpm: s["rpm"] as? Double ?? 0, tpm: s["tpm_total"] as? Int ?? 0,
                              cacheHitRate: s["cache_hit_rate"] as? Double ?? 0,
                              totalRequests: s["total_requests"] as? Int ?? 0,
                              cacheSlots: s["cache_slots"] as? Int ?? 0, cacheMaxSlots: s["cache_max_slots"] as? Int ?? 0,
                              memoryGB: s["process_rss_gb"] as? Double ?? 0, systemGB: s["system_total_gb"] as? Double ?? 0,
                              uptime: s["uptime"] as? Double ?? 0)
            }
            if let m = await Self.getJSON("/models/available", timeout: 5) {
                currentModelPath = m["current_path"] as? String ?? ""
                models = (m["models"] as? [[String: Any]] ?? []).compactMap { d in
                    guard let id = d["id"] as? String, let path = d["path"] as? String else { return nil }
                    return Model(id: id, path: path, sizeGB: d["size_gb"] as? Double ?? 0)
                }
            }
        } else if status == .starting, let d = transitionDeadline, Date() < d {
            // launchd is still bringing it up
        } else {
            transitionDeadline = nil
            status = isInstalled ? .stopped : .notInstalled
        }
    }

    func start() {
        guard isInstalled, status == .stopped else { return }
        status = .starting; transitionDeadline = Date().addingTimeInterval(180)
        Task.detached {
            if !Self.launchctl(["load", Self.plistPath]) {
                _ = Self.launchctl(["kickstart", "-k", "gui/\(getuid())/com.local.mlxserver"]) // already loaded
            }
        }
    }

    func stop() {
        guard isReachable else { return }
        status = .stopping; transitionDeadline = Date().addingTimeInterval(120)
        Task.detached {
            if !Self.launchctl(["unload", Self.plistPath]) {
                await MainActor.run { self.lastMessage = "停止失败：launchctl unload 未成功" }
            }
        }
    }

    func restart() {
        guard isReachable else { return }
        status = .starting; transitionDeadline = Date().addingTimeInterval(180)
        Task.detached { _ = Self.launchctl(["kickstart", "-k", "gui/\(getuid())/com.local.mlxserver"]) }
    }

    /// Loading a model takes tens of seconds; the server answers when it's done.
    func switchModel(_ m: Model) {
        guard switchingTo == nil else { return }
        switchingTo = m.id
        Task {
            let r = await Self.postJSON("/model/switch", ["path": m.path, "model_id": m.id], timeout: 900)
            switchingTo = nil
            lastMessage = r?["message"] as? String ?? "切换失败（服务无响应）"
            await refresh()
        }
    }

    /// `git fetch` the local checkout and count commits behind origin/main (0 when unknown).
    func checkForUpdate() async {
        guard FileManager.default.fileExists(atPath: Self.repoDir + "/.git") else { commitsBehind = 0; return }
        commitsBehind = await Task.detached(priority: .utility) { () -> Int in
            _ = Self.run("/usr/bin/git", ["-C", Self.repoDir, "fetch", "-q"])
            let out = Self.run("/usr/bin/git", ["-C", Self.repoDir, "rev-list", "--count", "HEAD..origin/main"])
            return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }.value
    }

    /// Shell line that clones (if needed) and installs axis-model; run in a visible TFA terminal.
    static var installCommand: String {
        let dir = AgentPlatform.shellQuote(repoDir)
        return "{ [ -d \(dir)/.git ] || git clone \(repoURL) \(dir); } && cd \(dir) && ./install.sh"
    }
    static var updateCommand: String { "cd \(AgentPlatform.shellQuote(repoDir)) && ./update.sh" }

    // MARK: - plumbing

    nonisolated private static func launchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process(); let out = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func getJSON(_ path: String, timeout: TimeInterval) async -> [String: Any]? {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.timeoutInterval = timeout
        return await send(req)
    }

    nonisolated private static func postJSON(_ path: String, _ body: [String: Any], timeout: TimeInterval) async -> [String: Any]? {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await send(req)
    }

    nonisolated private static func send(_ req: URLRequest) async -> [String: Any]? {
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - Panel

/// The「模型」detail pane: install axis-model if missing, otherwise status + control + stats + models.
/// Polls only while visible.
struct AxisModelView: View {
    @Environment(AppModel.self) private var appModel
    @State private var service = AxisModelService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header
                if service.status == .notInstalled {
                    installCard
                } else {
                    controls
                    if service.isReachable { statsCard; modelsCard }
                    axisClaudeCard
                }
                if let msg = service.lastMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Space.xxl)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
        .task {
            await service.checkForUpdate()
            while !Task.isCancelled {
                await service.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var statusTint: Color {
        switch service.status {
        case .running: Theme.Status.positive
        case .standby: Theme.Status.attention
        case .starting, .stopping: Theme.Status.pending
        case .stopped, .notInstalled: Theme.Status.neutral
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            Circle().fill(statusTint).frame(width: 9, height: 9)
            Text(service.status.label).font(Theme.Font.emptyTitle)
            if service.status == .starting || service.status == .stopping { ProgressView().controlSize(.small) }
            Spacer()
        }
    }

    private var installCard: some View {
        card {
            Text("本机还没有安装 axis-model").font(Theme.Font.rowTitle)
            Text("axis-model 在本机 Apple Silicon 上跑大模型（MLX），给 axis-claude 当后端，不联网、不需要账号。安装会下载仓库到 ~/axis-model 并运行 install.sh：装 mlx-lm / aria2、菜单栏应用和开机自启服务。需要 Python 3.10+；安装过程不下载模型。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("一键安装") { appModel.runSetupCommand(name: "axis-model-install", AxisModelService.installCommand) }
                .buttonStyle(.borderedProminent)
            Text("安装在新终端里进行，过程和报错都能直接看到。").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var controls: some View {
        card {
            HStack(spacing: Theme.Space.md) {
                switch service.status {
                case .stopped:
                    Button("启动服务") { service.start() }.buttonStyle(.borderedProminent)
                case .running, .standby:
                    Button("停止服务") { service.stop() }
                    Button("重启服务") { service.restart() }
                default:
                    EmptyView()
                }
                Spacer()
                if FileManager.default.fileExists(atPath: AxisModelService.appPath) {
                    Button("打开 Axis Model") { NSWorkspace.shared.open(URL(fileURLWithPath: AxisModelService.appPath)) }
                }
            }
            if service.status == .standby {
                Text(service.loadError.isEmpty ? "服务在运行，但还没有加载模型。在下方选择一个模型，或在 Axis Model 应用的「模型库」里下载。" : "模型加载失败：\(service.loadError)")
                    .font(.caption).foregroundStyle(Theme.Status.attention)
            }
            if service.commitsBehind > 0 {
                HStack {
                    Text("有新版本 · 落后 \(service.commitsBehind) 个提交").font(.caption).foregroundStyle(Theme.Status.attention)
                    Button("更新") { appModel.runSetupCommand(name: "axis-model-update", AxisModelService.updateCommand) }
                        .controlSize(.small)
                }
            }
        }
    }

    private var statsCard: some View {
        let s = service.stats
        return card {
            Text("运行数据").font(Theme.Font.rowTitle)
            statRow("当前模型", service.currentModelName.isEmpty ? "—" : service.currentModelName)
            statRow("每分钟", String(format: "%.1f 请求 · %d tokens", s.rpm, s.tpm))
            statRow("缓存命中率", String(format: "%.1f%%", s.cacheHitRate * 100))
            statRow("缓存槽位", "\(s.cacheSlots) / \(s.cacheMaxSlots)")
            statRow("内存", String(format: "%.1f / %.0f GB", s.memoryGB, s.systemGB))
            statRow("累计请求", "\(s.totalRequests)")
            statRow("已运行", Self.formatUptime(s.uptime))
        }
    }

    private var modelsCard: some View {
        card {
            Text("模型").font(Theme.Font.rowTitle)
            if service.models.isEmpty {
                Text("没有扫描到本地模型。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(service.models) { m in
                HStack {
                    Image(systemName: m.path == service.currentModelPath ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(m.path == service.currentModelPath ? Theme.Status.positive : Theme.textTertiary)
                    Text(m.id).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(String(format: "%.1f GB", m.sizeGB)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if service.switchingTo == m.id {
                        ProgressView().controlSize(.small)
                    } else if m.path != service.currentModelPath {
                        Button("切换") { service.switchModel(m) }
                            .controlSize(.small)
                            .disabled(service.switchingTo != nil)
                    }
                }
            }
            if service.switchingTo != nil {
                Text("正在加载模型，可能需要几十秒…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var axisClaudeCard: some View {
        card {
            Text("axis-claude").font(Theme.Font.rowTitle)
            Text("内置的命令行编程助手，用本机 axis-model 读写代码、执行命令。点侧栏「+」→「启动 axis-claude」新建。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let path = AxisClaude.executablePath {
                Text(path).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
            } else {
                Text("未找到 axis-claude 可执行文件").font(.caption).foregroundStyle(Theme.Status.error)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) { content() }
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.border, lineWidth: 1))
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Text(value).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private static func formatUptime(_ t: TimeInterval) -> String {
        let s = Int(t), d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h \(m)m" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
