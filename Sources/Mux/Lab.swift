import SwiftUI
import Darwin
import Metal

/// The "Lab" (实验室) — a home for experimental, non-terminal features. First experiment: a live
/// system monitor. Selected from the sidebar's bottom Lab entry; shown in the detail area.
///
/// Metrics use PUBLIC macOS APIs only:
/// - CPU: `host_statistics(HOST_CPU_LOAD_INFO)` tick deltas between samples.
/// - Memory: `host_statistics64(HOST_VM_INFO64)` + `ProcessInfo.physicalMemory`.
/// - Load / uptime: `getloadavg` / `sysctl kern.boottime`.
/// - GPU: Metal device names only — macOS exposes NO public GPU-utilisation API (Activity Monitor
///   uses private IOReport), so we show the model, not a usage percentage.
@MainActor
@Observable
final class SystemMonitor {
    private(set) var cpuUsage: Double = 0           // 0…1 (busy fraction since last sample)
    private(set) var memUsedGB: Double = 0
    private(set) var memTotalGB: Double = 0
    private(set) var load1: Double = 0
    private(set) var load5: Double = 0
    private(set) var load15: Double = 0
    private(set) var uptime: TimeInterval = 0
    private(set) var gpuNames: [String] = []
    private(set) var coreCount: Int = ProcessInfo.processInfo.activeProcessorCount

    private var prevTicks: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Begin polling once per second. Idempotent. Call `stop()` when the Lab view disappears.
    func start() {
        guard pollTask == nil else { return }
        gpuNames = MTLCopyAllDevices().map { $0.name }
        memTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 // /1024³
        _ = sampleCPU() // prime the tick baseline so the first visible reading is real
        sampleAll()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                sampleAll()
            }
        }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    private func sampleAll() {
        cpuUsage = sampleCPU()
        sampleMemory()
        var l = [Double](repeating: 0, count: 3)
        if getloadavg(&l, 3) == 3 { load1 = l[0]; load5 = l[1]; load15 = l[2] }
        uptime = sampleUptime()
    }

    /// Busy fraction since the previous call, from cumulative CPU ticks (user+sys+nice vs idle).
    private func sampleCPU() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return cpuUsage }
        // cpu_ticks is a C array imported as a tuple: (USER, SYSTEM, IDLE, NICE).
        let user = info.cpu_ticks.0, sys = info.cpu_ticks.1, idle = info.cpu_ticks.2, nice = info.cpu_ticks.3
        defer { prevTicks = (user, sys, idle, nice) }
        guard let p = prevTicks else { return 0 }
        let dBusy = Double(user &- p.user) + Double(sys &- p.sys) + Double(nice &- p.nice)
        let dIdle = Double(idle &- p.idle)
        let total = dBusy + dIdle
        return total > 0 ? min(max(dBusy / total, 0), 1) : cpuUsage
    }

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let page = Double(vm_kernel_page_size)
        // "Used" ≈ active + wired + compressed (matches Activity Monitor's rough memory-used).
        let usedBytes = (Double(stats.active_count) + Double(stats.wire_count)
                         + Double(stats.compressor_page_count)) * page
        memUsedGB = usedBytes / 1_073_741_824
    }

    private func sampleUptime() -> TimeInterval {
        var bt = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &bt, &size, nil, 0) == 0, bt.tv_sec != 0 else { return uptime }
        return max(0, Date().timeIntervalSince1970 - Double(bt.tv_sec))
    }
}

// MARK: - Lab view (detail area)

/// The Lab detail pane: a tab switcher between experiments (system monitor · token usage).
struct LabView: View {
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("系统监控").tag(0)
                Text("Token 用量").tag(1)
                Text("PTY / 进程").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.top, Theme.Space.md)
            Divider().padding(.top, Theme.Space.sm)
            switch tab {
            case 0: SystemMonitorPane()
            case 1: TokenUsageView()
            default: PtyMonitorPane()
            }
        }
        .background(Theme.canvas)
    }
}

/// System-monitor experiment. Owns a `SystemMonitor`, polling only while visible.
private struct SystemMonitorPane: View {
    @State private var monitor = SystemMonitor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                Text("系统监控")
                    .font(Theme.Font.emptyTitle)

                MetricBar(title: "CPU", value: monitor.cpuUsage,
                          detail: "\(Int(monitor.cpuUsage * 100))%  ·  \(monitor.coreCount) cores")

                MetricBar(title: "内存 / Memory",
                          value: monitor.memTotalGB > 0 ? monitor.memUsedGB / monitor.memTotalGB : 0,
                          detail: String(format: "%.1f / %.1f GB", monitor.memUsedGB, monitor.memTotalGB))

                statRow("负载 / Load",
                        String(format: "%.2f · %.2f · %.2f", monitor.load1, monitor.load5, monitor.load15))
                statRow("运行时间 / Uptime", Self.formatUptime(monitor.uptime))
                statRow("GPU", monitor.gpuNames.isEmpty ? "—" : monitor.gpuNames.joined(separator: ", "))

                Text("GPU 利用率 macOS 无公开 API，此处仅显示型号。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(Theme.Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(Theme.Font.rowTitle)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private static func formatUptime(_ t: TimeInterval) -> String {
        let s = Int(t), d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h \(m)m" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

// MARK: - PTY / process monitor

/// Watches pseudo-terminal pressure and TFA's own `tmux -CC` control clients. Each terminal TFA
/// shows is backed by a spawned `tmux -CC` child holding ONE pty. If TFA dies by signal/crash
/// (not a clean Quit), those setsid children orphan to launchd (PPID 1) and keep their ptys,
/// piling up across restarts until the system pty limit is hit and no new terminal can open.
@MainActor @Observable
final class PtyMonitor {
    private(set) var ptyCount = 0
    private(set) var ptyMax = 0
    private(set) var ccTotal = 0       // live `tmux -CC` clients (TFA's terminals)
    private(set) var ccOrphans = 0     // of those, PPID==1 (leaked)
    private(set) var probeSockets = 0  // leftover `mux*-<pid>-<rand>` probe sockets (other tools)
    private(set) var loading = false
    @ObservationIgnored private var orphanPids: [pid_t] = []

    struct Snapshot { var ptyCount = 0; var ptyMax = 0; var ccTotal = 0; var ccOrphans = 0; var probeSockets = 0; var orphanPids: [pid_t] = [] }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .utility) {
            let s = PtyMonitor.sample()
            await MainActor.run {
                self.ptyCount = s.ptyCount; self.ptyMax = s.ptyMax
                self.ccTotal = s.ccTotal; self.ccOrphans = s.ccOrphans
                self.probeSockets = s.probeSockets; self.orphanPids = s.orphanPids
                self.loading = false
            }
        }
    }

    /// SIGTERM every orphaned (PPID 1) `tmux -CC` client. This only DETACHES them — the tmux
    /// sessions survive on the server and can be reopened — but frees the ptys they were holding.
    func cleanupOrphans() {
        for pid in orphanPids { _ = Darwin.kill(pid, SIGTERM) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }

    nonisolated static func sample() -> Snapshot {
        var s = Snapshot()
        let devs = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        s.ptyCount = devs.filter { $0.hasPrefix("ttys") }.count
        var maxv: Int32 = 0; var sz = MemoryLayout<Int32>.size
        if sysctlbyname("kern.tty.ptmx_max", &maxv, &sz, nil, 0) == 0 { s.ptyMax = Int(maxv) }
        for line in runPS().split(separator: "\n") {
            guard line.contains("tmux -u -CC "),
                  line.contains("attach-session") || line.contains("new-session") else { continue }
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 2, let pid = pid_t(f[0]), let ppid = pid_t(f[1]) else { continue }
            s.ccTotal += 1
            if ppid == 1 { s.ccOrphans += 1; s.orphanPids.append(pid) }
        }
        let dir = "/private/tmp/tmux-\(getuid())"
        let socks = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        s.probeSockets = socks.filter { $0.hasPrefix("mux") && $0.contains("-") }.count
        return s
    }

    nonisolated private static func runPS() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,command="]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// PTY / process monitor experiment. Surfaces pty pressure + leaked `tmux -CC` clients, with a
/// one-click cleanup for orphans.
private struct PtyMonitorPane: View {
    @State private var monitor = PtyMonitor()
    @State private var confirmCleanup = false

    private var ptyFraction: Double {
        monitor.ptyMax > 0 ? Double(monitor.ptyCount) / Double(monitor.ptyMax) : 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                HStack {
                    Text("PTY / 进程监控").font(Theme.Font.emptyTitle)
                    Spacer()
                    Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).disabled(monitor.loading).help("刷新")
                }

                MetricBar(title: "PTY 使用 / pseudo-terminals", value: ptyFraction,
                          detail: "\(monitor.ptyCount) / \(monitor.ptyMax)")
                if ptyFraction > 0.8 {
                    Text("⚠️ pty 使用率接近上限，新终端可能打不开。")
                        .font(.caption).foregroundStyle(.orange)
                }

                statRow("TFA 的 tmux -CC 客户端", "\(monitor.ccTotal)")
                statRow("其中孤儿 (PPID=1·未回收)", "\(monitor.ccOrphans)")
                statRow("残留 tmux 探针 socket (其它工具)", "\(monitor.probeSockets)")

                if monitor.ccOrphans > 0 {
                    Button(role: .destructive) { confirmCleanup = true } label: {
                        Label("清理 \(monitor.ccOrphans) 个孤儿客户端", systemImage: "trash")
                    }
                    Text("孤儿 = TFA 被强杀后没回收的 tmux -CC 进程，各占一个 pty。清理只是分离它们，tmux 会话本身保留、可重新打开。")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    Text("没有孤儿客户端 👍").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(Theme.Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
        .onAppear { monitor.refresh() }
        .alert("清理孤儿 tmux -CC 客户端?", isPresented: $confirmCleanup) {
            Button("清理", role: .destructive) { monitor.cleanupOrphans() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("向 \(monitor.ccOrphans) 个无父进程的 tmux -CC 客户端发送 SIGTERM，释放其占用的 pty。tmux 会话只是被分离，不会结束。")
        }
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(Theme.Font.rowTitle)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}

/// A labelled progress bar for a 0…1 metric, brand-tinted, with a right-aligned detail string.
private struct MetricBar: View {
    let title: String
    let value: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text(title).font(Theme.Font.rowTitle)
                Spacer()
                Text(detail).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.surface2)
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.brand)
                        .frame(width: max(0, min(1, value)) * geo.size.width)
                        .animation(.easeOut(duration: 0.3), value: value)
                }
            }
            .frame(height: 10)
        }
    }
}
