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
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.lg) {
                Picker("", selection: $kind) { ForEach(ViewKind.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button { store.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("重新读取使用记录").disabled(store.loading)
                Spacer()
                Text("Claude Code · Codex").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Space.lg)
            Divider()
            if !store.loading, store.entries != nil, !rows.isEmpty {
                summary(rows, totalCost: totalCost)
                if kind == .daily {
                    UsageHeatmap(rows: rows)   // 日历热力图取代表格,一眼看每日波动
                    Spacer(minLength: 0)
                } else {
                    content(rows)
                }
            } else {
                content(rows)                  // loading / empty states
            }
        }
        .background(Theme.canvas)
        .onAppear { store.loadIfNeeded() }
    }

    // MARK: - Usage overview (v2)

    /// A cost/tokens headline plus a monochrome Token-composition bar. Stays inside DESIGN.md's
    /// near-monochrome palette — the four token classes are an ink→pewter ramp, not four hues.
    @ViewBuilder private func summary(_ rows: [CCUsage.Summary], totalCost: Double) -> some View {
        let input      = rows.reduce(UInt64(0)) { $0 + $1.counts.input }
        let output     = rows.reduce(UInt64(0)) { $0 + $1.counts.output }
        let cacheMake  = rows.reduce(UInt64(0)) { $0 + $1.counts.cacheCreation }
        let cacheRead  = rows.reduce(UInt64(0)) { $0 + $1.counts.cacheRead }
        let total = input + output + cacheMake + cacheRead
        let segs: [(label: String, value: UInt64, color: Color)] = [
            ("Input", input, Theme.Colors.charcoal),
            ("Output", output, Theme.Colors.slate),
            ("Cache 创建", cacheMake, Theme.Colors.stone),
            ("Cache 读取", cacheRead, Theme.Colors.pewter),
        ]
        VStack(spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.md) {
                statCard(title: "总花费", value: Self.fmtCost(totalCost), sub: "\(rows.count) 条记录", emphasis: true)
                statCard(title: "总 Tokens", value: Self.grouped(total), sub: "\(kind.rawValue)视图合计", emphasis: false)
            }
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("Token 构成").font(.caption).foregroundStyle(Theme.textTertiary)
                GeometryReader { geo in
                    let gap: CGFloat = 1.5
                    let avail = max(0, geo.size.width - gap * CGFloat(segs.count - 1))
                    HStack(spacing: gap) {
                        ForEach(segs, id: \.label) { seg in
                            Rectangle().fill(seg.color)
                                .frame(width: avail * frac(seg.value, total))
                        }
                    }
                }
                .frame(height: 12)
                .clipShape(Capsule())
                HStack(spacing: Theme.Space.lg) {
                    ForEach(segs, id: \.label) { seg in
                        HStack(spacing: Theme.Space.xs) {
                            RoundedRectangle(cornerRadius: 2).fill(seg.color).frame(width: 9, height: 9)
                            Text(seg.label).font(.caption2).foregroundStyle(Theme.textSecondary)
                            Text(pct(seg.value, total)).font(.caption2.weight(.medium).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                        }
                        .help("\(seg.label): \(Self.grouped(seg.value)) tokens")
                    }
                    Spacer()
                }
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.border, lineWidth: 1))
        }
        .padding(Theme.Space.lg)
    }

    private func statCard(title: String, value: String, sub: String, emphasis: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(.caption).foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(emphasis ? Theme.brand : Theme.textPrimary)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            Text(sub).font(.caption2).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.lg)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.border, lineWidth: 1))
    }

    private func frac(_ n: UInt64, _ total: UInt64) -> CGFloat { total == 0 ? 0 : CGFloat(Double(n) / Double(total)) }
    private func pct(_ n: UInt64, _ total: UInt64) -> String { total == 0 ? "0%" : String(format: "%.0f%%", Double(n) / Double(total) * 100) }

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

/// GitHub-contributions-style daily usage heatmap: one cell per day, laid out in week columns and
/// shaded by that day's cost relative to the busiest day — so usage variation reads at a glance.
/// Monochrome ink ramp (DESIGN.md: color only as deliberate annotation). Hover a cell for the exact
/// date / cost / tokens.
private struct UsageHeatmap: View {
    let rows: [CCUsage.Summary]        // daily summaries, key = "yyyy-MM-dd"

    private let gap: CGFloat = 3
    private let monthRow: CGFloat = 12
    @State private var containerW: CGFloat = 0

    private static let parser: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    var body: some View {
        let cal = Calendar.current
        let byDay = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let dates = rows.compactMap { Self.parser.date(from: $0.key) }
        if let minD = dates.min(), let maxD = dates.max() {
            let maxCost = max(rows.map(\.cost).max() ?? 0, 0.0001)
            let weeks = Self.weeks(from: minD, to: maxD, cal: cal)
            let labels = Self.monthLabels(weeks, cal: cal)
            // Cell height: track the (auto) column width so cells are square when weeks are dense, and
            // cap at 30 so a sparse (few-week) grid stays short instead of ballooning tall. Columns
            // always fill the width via `.frame(maxWidth: .infinity)`, so the grid spans 100% regardless.
            let colW = containerW > 0 ? (containerW - gap * CGFloat(max(weeks.count - 1, 0))) / CGFloat(weeks.count) : 20
            let cellH = min(max(colW, 12), 30)
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("每日用量 · 颜色越深花费越多").font(.caption).foregroundStyle(Theme.textTertiary)
                // Month axis: each label sits above the week where its month begins, overflowing right.
                HStack(spacing: gap) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                        Color.clear.frame(maxWidth: .infinity).frame(height: monthRow)
                            .overlay(alignment: .leading) {
                                if !label.isEmpty {
                                    Text(label).font(.system(size: 8)).foregroundStyle(Theme.textTertiary).fixedSize()
                                }
                            }
                    }
                }
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { i in
                                if i < week.count {
                                    let key = Self.parser.string(from: week[i])
                                    let s = byDay[key]
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(color(level(s?.cost ?? 0, max: maxCost)))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: cellH)
                                        .help(tooltip(key, s))
                                } else {
                                    Color.clear.frame(maxWidth: .infinity).frame(height: cellH)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { containerW = geo.size.width }
                        .onChange(of: geo.size.width) { containerW = geo.size.width }
                })
                legend
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var legend: some View {
        HStack(spacing: Theme.Space.xs) {
            Text("少").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
            ForEach(0..<5, id: \.self) { l in
                RoundedRectangle(cornerRadius: 2).fill(color(l)).frame(width: 11, height: 11)
            }
            Text("多").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
            Spacer()
        }
    }

    private func level(_ cost: Double, max: Double) -> Int {
        guard cost > 0 else { return 0 }
        let r = cost / max
        if r <= 0.25 { return 1 }
        if r <= 0.5 { return 2 }
        if r <= 0.75 { return 3 }
        return 4
    }

    /// Empty = faint linen; then an ink ramp light→dark (mist → pewter → stone → charcoal).
    private func color(_ level: Int) -> Color {
        switch level {
        case 0:  return Theme.Colors.linen.opacity(0.5)
        case 1:  return Theme.Colors.mist
        case 2:  return Theme.Colors.pewter
        case 3:  return Theme.Colors.stone
        default: return Theme.Colors.charcoal
        }
    }

    private func tooltip(_ key: String, _ s: CCUsage.Summary?) -> String {
        guard let s else { return "\(key) · 无用量" }
        return "\(key) · \(TokenUsageView.fmtCost(s.cost)) · \(TokenUsageView.grouped(s.counts.total)) tokens"
    }

    /// Week columns from the start-of-week containing `minD` through `maxD` (last column may be partial).
    private static func weeks(from minD: Date, to maxD: Date, cal: Calendar) -> [[Date]] {
        let start = cal.dateInterval(of: .weekOfYear, for: minD)?.start ?? cal.startOfDay(for: minD)
        var out: [[Date]] = []
        var col: [Date] = []
        var d = cal.startOfDay(for: start)
        let end = cal.startOfDay(for: maxD)
        while d <= end {
            col.append(d)
            if col.count == 7 { out.append(col); col = [] }
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        if !col.isEmpty { out.append(col) }
        return out
    }

    /// One label per week column: the month abbreviation when this column's first day opens a new month.
    private static func monthLabels(_ weeks: [[Date]], cal: Calendar) -> [String] {
        let fmt = DateFormatter(); fmt.setLocalizedDateFormatFromTemplate("MMM")
        var out: [String] = []; var last = -1
        for week in weeks {
            guard let first = week.first else { out.append(""); continue }
            let m = cal.component(.month, from: first)
            if m != last { out.append(fmt.string(from: first)); last = m } else { out.append("") }
        }
        return out
    }
}
