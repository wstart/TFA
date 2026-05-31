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

/// The Lab detail pane. Owns a `SystemMonitor`, polling only while visible.
struct LabView: View {
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
        .background(Color(nsColor: .textBackgroundColor))
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
                    RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(.quaternary)
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
