import SwiftUI

/// Caches loaded usage entries across Lab tab switches so the panel only reads ~/.claude / ~/.codex
/// ONCE per app run (loading is the expensive part). Aggregation is cheap and done per view.
@MainActor @Observable
final class UsageStore {
    static let shared = UsageStore()
    private(set) var entries: [CCUsage.LoadedEntry]?
    private(set) var loading = false
    @ObservationIgnored private var task: Task<Void, Never>?

    func loadIfNeeded() {
        guard entries == nil, task == nil else { return }
        loading = true
        task = Task { @MainActor in
            let loaded = await Task.detached(priority: .userInitiated) { () -> [CCUsage.LoadedEntry] in
                let p = CCUsage.PricingMap.builtin()
                return CCUsage.ClaudeSource.load(mode: .auto, pricing: p) + CCUsage.CodexSource.load(pricing: p)
            }.value
            self.entries = loaded
            self.loading = false
            self.task = nil
        }
    }

    func reload() { entries = nil; task?.cancel(); task = nil; loadIfNeeded() }
}

/// Lab「Token 用量」: ccusage-style aligned multi-column table over cached Claude + Codex usage.
struct TokenUsageView: View {
    enum ViewKind: String, CaseIterable, Identifiable, Sendable {
        case daily = "日", weekly = "周", monthly = "月", session = "会话"
        var id: String { rawValue }
        var periodTitle: String {
            switch self {
            case .daily: return "日期"
            case .weekly: return "周起始"
            case .monthly: return "月份"
            case .session: return "会话"
            }
        }
    }

    @State private var store = UsageStore.shared
    @State private var kind: ViewKind = .daily

    /// Aggregate the cached entries for the current view (cheap, in-memory).
    private var rows: [CCUsage.Summary] {
        guard let entries = store.entries else { return [] }
        let r: [CCUsage.Summary]
        switch kind {
        case .daily:   r = CCUsage.daily(entries)
        case .weekly:  r = CCUsage.bucketByWeek(CCUsage.daily(entries))
        case .monthly: r = CCUsage.bucketByMonth(CCUsage.daily(entries))
        case .session: r = CCUsage.session(entries)
        }
        return r.sorted { $0.key > $1.key }
    }

    var body: some View {
        let rows = self.rows
        let totalCost = rows.reduce(0) { $0 + $1.cost }
        let totalTokens = rows.reduce(0) { $0 + $1.counts.total }
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.lg) {
                Picker("", selection: $kind) { ForEach(ViewKind.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button { store.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("重新读取使用记录").disabled(store.loading)
                Spacer()
                if !store.loading && store.entries != nil {
                    Text("\(rows.count) 条 · \(Self.grouped(totalTokens)) tokens")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Text(Self.fmtCost(totalCost))
                        .font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(Theme.brand)
                }
            }
            .padding(Theme.Space.lg)
            Divider()
            content(rows)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { store.loadIfNeeded() }
    }

    @ViewBuilder private func content(_ rows: [CCUsage.Summary]) -> some View {
        if store.loading {
            VStack(spacing: Theme.Space.md) {
                ProgressView().controlSize(.large)
                Text("正在读取 Claude / Codex 使用记录…").font(Theme.Font.emptyBody).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            ContentUnavailableView("暂无用量数据", systemImage: "chart.bar",
                description: Text("在 ~/.claude 或 ~/.codex 没找到可统计的会话记录。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(rows) {
                TableColumn(kind.periodTitle) { r in
                    Text(r.key).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }.width(min: 110, ideal: 150)
                TableColumn("模型") { r in
                    Text(r.modelsUsed.joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }.width(min: 90, ideal: 160)
                TableColumn("Input") { num($0.counts.input) }.width(min: 64, ideal: 84)
                TableColumn("Output") { num($0.counts.output) }.width(min: 64, ideal: 84)
                TableColumn("Cache") { num($0.counts.cacheCreation + $0.counts.cacheRead) }.width(min: 64, ideal: 90)
                TableColumn("Total") { num($0.counts.total) }.width(min: 70, ideal: 96)
                TableColumn("Cost") { r in
                    Text(Self.fmtCost(r.cost)).font(.system(.body, design: .monospaced).weight(.medium))
                        .monospacedDigit().foregroundStyle(Theme.brand).frame(maxWidth: .infinity, alignment: .trailing)
                }.width(min: 70, ideal: 90)
            }
        }
    }

    private func num(_ n: UInt64) -> some View {
        Text(Self.grouped(n)).font(.system(.body, design: .monospaced)).monospacedDigit()
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
    }

    static func grouped(_ n: UInt64) -> String { nf.string(from: NSNumber(value: n)) ?? "\(n)" }
    private static let nf: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; return f }()
    static func fmtCost(_ c: Double) -> String {
        if c == 0 { return "$0" }
        return c < 0.01 ? String(format: "$%.4f", c) : String(format: "$%.2f", c)
    }
}
