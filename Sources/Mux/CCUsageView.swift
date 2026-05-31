import SwiftUI

/// Lab「Token 用量」experiment: reads Claude + Codex usage in the background, aggregates, and shows
/// daily/weekly/monthly/session views with per-model breakdown and a grand total. (ccusage port,
/// claude+codex sources.)
struct TokenUsageView: View {
    enum ViewKind: String, CaseIterable, Identifiable, Sendable {
        case daily = "日", weekly = "周", monthly = "月", session = "会话"
        var id: String { rawValue }
    }

    @State private var kind: ViewKind = .daily
    @State private var rows: [CCUsage.Summary] = []
    @State private var loading = true
    @State private var loadTask: Task<Void, Never>?

    private var totalCost: Double { rows.reduce(0) { $0 + $1.cost } }
    private var totalTokens: UInt64 { rows.reduce(0) { $0 + $1.counts.total } }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $kind) {
                ForEach(ViewKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.vertical, Theme.Space.md)

            // Grand total
            HStack(spacing: Theme.Space.lg) {
                Text("总计").font(Theme.Font.rowTitle)
                Spacer()
                Text("\(Self.fmtTokens(totalTokens)) tokens")
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                Text(Self.fmtCost(totalCost))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.brand)
            }
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.bottom, Theme.Space.sm)
            Divider()

            if loading {
                VStack(spacing: Theme.Space.md) {
                    ProgressView().controlSize(.large)
                    Text("正在读取 Claude / Codex 使用记录…").font(Theme.Font.emptyBody).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView("暂无用量数据", systemImage: "chart.bar",
                    description: Text("在 ~/.claude 或 ~/.codex 没找到可统计的会话记录。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows) { row in
                    DisclosureGroup {
                        ForEach(Array(row.breakdowns.enumerated()), id: \.offset) { _, b in
                            line(b.model, b.counts.total, b.cost, indent: true)
                        }
                    } label: {
                        line(row.key, row.counts.total, row.cost, indent: false)
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { reload() }
        .onChange(of: kind) { reload() }
        .onDisappear { loadTask?.cancel() }
    }

    @ViewBuilder
    private func line(_ title: String, _ tokens: UInt64, _ cost: Double, indent: Bool) -> some View {
        HStack(spacing: Theme.Space.md) {
            Text(title)
                .font(indent ? Theme.Font.rowSubtitle : Theme.Font.rowTitle)
                .foregroundStyle(indent ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Theme.Space.md)
            Text("\(Self.fmtTokens(tokens))")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).monospacedDigit()
            Text(Self.fmtCost(cost))
                .font(.system(.callout, design: .monospaced).weight(indent ? .regular : .medium))
                .foregroundStyle(indent ? .secondary : Theme.brand)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.leading, indent ? Theme.Space.lg : 0)
    }

    private func reload() {
        loading = true
        loadTask?.cancel()
        let kind = self.kind
        loadTask = Task { @MainActor in
            let result = await Task.detached(priority: .utility) { () -> [CCUsage.Summary] in
                let pricing = CCUsage.PricingMap.builtin()
                let entries = CCUsage.ClaudeSource.load(mode: .auto, pricing: pricing)
                    + CCUsage.CodexSource.load(pricing: pricing)
                switch kind {
                case .daily:   return CCUsage.daily(entries)
                case .weekly:  return CCUsage.bucketByWeek(CCUsage.daily(entries))
                case .monthly: return CCUsage.bucketByMonth(CCUsage.daily(entries))
                case .session: return CCUsage.session(entries)
                }
            }.value
            guard !Task.isCancelled else { return }
            self.rows = result.sorted { $0.key > $1.key } // newest first
            self.loading = false
        }
    }

    // MARK: formatting

    static func fmtTokens(_ n: UInt64) -> String {
        let d = Double(n)
        if d >= 1_000_000 { return String(format: "%.2fM", d / 1_000_000) }
        if d >= 1_000 { return String(format: "%.1fK", d / 1_000) }
        return "\(n)"
    }

    static func fmtCost(_ c: Double) -> String {
        if c == 0 { return "$0" }
        if c < 0.01 { return String(format: "$%.4f", c) }
        return String(format: "$%.2f", c)
    }
}
