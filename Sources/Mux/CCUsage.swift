import Foundation

/// Swift port of ccusage's source-independent core — time, pricing, cost, token types.
/// (Phase 1a: pure logic, no data-source loaders or UI.) Ported from the ccusage Rust core per the
/// spec in ~/.gstack/projects/tty/ccusage-spec/core.md. All token rates are USD **per token**.
enum CCUsage {

    // MARK: - Time (spec §4)

    /// Epoch milliseconds wrapper.
    struct TimestampMs: Comparable, Hashable, Sendable {
        var ms: Int64
        static func < (a: TimestampMs, b: TimestampMs) -> Bool { a.ms < b.ms }
        /// Floor to the start of the hour.
        func flooredToHour() -> TimestampMs {
            TimestampMs(ms: Int64((Double(ms) / 3_600_000).rounded(.down)) * 3_600_000)
        }
        /// Saturating (never-negative) ms duration since an earlier timestamp.
        func durationSince(_ earlier: TimestampMs) -> Int64 { max(0, ms - earlier.ms) }
    }

    /// Strict RFC3339 → epoch ms (UTC). Accepts `YYYY-MM-DDTHH:MM:SS[.mmm](Z|±HH:MM)` only (byte
    /// lengths 20/24/25/29). Returns nil on any malformed shape (mirrors `parse_ts_timestamp`).
    static func parseTimestampMs(_ s: String) -> TimestampMs? {
        let b = Array(s.utf8)
        let n = b.count
        // length 20/25 → no fraction; 24/29 → 3-digit fraction at idx19.
        let hasFraction: Bool
        switch n {
        case 20, 25: hasFraction = false
        case 24, 29: hasFraction = true
        default: return nil
        }
        func digit(_ i: Int) -> Int? { let c = b[i]; return (c >= 48 && c <= 57) ? Int(c - 48) : nil }
        func num(_ i: Int, _ len: Int) -> Int? {
            var v = 0
            for k in 0..<len { guard let d = digit(i + k) else { return nil }; v = v * 10 + d }
            return v
        }
        guard b[4] == 45, b[7] == 45, b[10] == 84 || b[10] == 116, b[13] == 58, b[16] == 58 else { return nil } // - - T :
        guard let year = num(0, 4), let mon = num(5, 2), let day = num(8, 2),
              let hour = num(11, 2), let min = num(14, 2), let sec = num(17, 2),
              mon >= 1, mon <= 12, day >= 1, day <= 31, hour <= 23, min <= 59, sec <= 59 else { return nil }
        var millis = 0
        var tzIdx = 19
        if hasFraction {
            guard b[19] == 46, let f = num(20, 3) else { return nil } // .
            millis = f
            tzIdx = 23
        }
        // tz: Z or ±HH:MM
        var offsetSec = 0
        let tzc = b[tzIdx]
        if tzc == 90 || tzc == 122 { // Z/z
            guard tzIdx == n - 1 else { return nil }
        } else if tzc == 43 || tzc == 45 { // + / -
            guard n - tzIdx == 6, b[tzIdx + 3] == 58, let oh = num(tzIdx + 1, 2), let om = num(tzIdx + 4, 2) else { return nil }
            offsetSec = (oh * 3600 + om * 60) * (tzc == 45 ? -1 : 1)
        } else { return nil }
        // civil → days since epoch (Howard Hinnant)
        let days = Self.daysFromCivil(year: year, month: mon, day: day)
        let utcSec = Int64(days) * 86_400 + Int64(hour) * 3600 + Int64(min) * 60 + Int64(sec) - Int64(offsetSec)
        return TimestampMs(ms: utcSec * 1000 + Int64(millis))
    }

    /// Days from 1970-01-01 for a civil date (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// `YYYY-MM-DD` for a timestamp in the given IANA zone (default = system local).
    static func formatDate(_ ts: TimestampMs, timeZone: TimeZone? = nil) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone ?? .current
        let date = Date(timeIntervalSince1970: Double(ts.ms) / 1000)
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Token usage (spec §3)

    enum Speed: String, Codable { case standard, fast }

    struct TokenUsageRaw {
        var inputTokens: UInt64 = 0
        var outputTokens: UInt64 = 0
        var cacheCreationInputTokens: UInt64 = 0
        var cacheReadInputTokens: UInt64 = 0
        var speed: Speed?
        var total: UInt64 { inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens }
    }

    /// Aggregation token counts (spec §3.2). `extraTotal` is non-Claude (e.g. codex reasoning).
    struct TokenCounts: Sendable {
        var input: UInt64 = 0, output: UInt64 = 0, cacheCreation: UInt64 = 0, cacheRead: UInt64 = 0
        var extraTotal: UInt64 = 0
        var total: UInt64 { input + output + cacheCreation + cacheRead + extraTotal }
        mutating func add(_ u: TokenUsageRaw) {
            input += u.inputTokens; output += u.outputTokens
            cacheCreation += u.cacheCreationInputTokens; cacheRead += u.cacheReadInputTokens
        }
    }

    // MARK: - Pricing (spec §1)

    struct Pricing {
        var input: Double, output: Double, cacheCreate: Double, cacheRead: Double
        var cacheReadExplicit: Bool = true
        var inputAbove200k: Double?, outputAbove200k: Double?
        var cacheCreateAbove200k: Double?, cacheReadAbove200k: Double?
        var fastMultiplier: Double = 1.0
    }

    /// Fast-multiplier overrides (spec §1.6), shipped verbatim.
    private static let fastExact: [String: Double] = ["gpt-5.5": 2.5, "gpt-5.4": 2.0, "gpt-5.3-codex": 2.0]
    private static let fastNormalizedPrefix: [String: Double] = ["claude-opus-4-6": 6.0, "claude-opus-4-7": 6.0, "claude-opus-4-8": 2.0]

    static func fastMultiplier(for model: String) -> Double {
        if let m = fastExact[model] { return m }
        let norm = normalizedPricingKey(model)
        for part in norm.split(whereSeparator: { $0 == "/" || $0 == ":" }).map(String.init) {
            for (base, mult) in fastNormalizedPrefix where matchesModelSuffix(part, base) { return mult }
        }
        return 1.0
    }

    /// `matchesModelSuffix` (spec §1.6): last occurrence of base; suffix == base, or char after base is `-`.
    private static func matchesModelSuffix(_ part: String, _ base: String) -> Bool {
        let p = Array(part.utf8), bse = Array(base.utf8)
        guard let idx = lastIndexOf(bse, in: p) else { return false }
        let after = idx + bse.count
        return after == p.count || p[after] == 45 // '-'
    }

    struct PricingMap {
        var entries: [String: Pricing] = [:]
        var contextLimits: [String: UInt64] = [:]

        /// Built-in hardcoded pricing (spec §1.7) + fast multipliers + context limits. This is the
        /// offline/default table covering frontier Claude/GPT/etc. models.
        static func builtin() -> PricingMap {
            var m = PricingMap()
            func put(_ key: String, _ i: Double, _ o: Double, _ cc: Double, _ cr: Double,
                     explicit: Bool = true, tiers: (Double, Double, Double, Double)? = nil, ctx: UInt64? = nil) {
                var p = Pricing(input: i, output: o, cacheCreate: cc, cacheRead: cr, cacheReadExplicit: explicit)
                if let t = tiers { p.inputAbove200k = t.0; p.outputAbove200k = t.1; p.cacheCreateAbove200k = t.2; p.cacheReadAbove200k = t.3 }
                p.fastMultiplier = CCUsage.fastMultiplier(for: key)
                m.entries[key] = p
                if let c = ctx { m.contextLimits[key] = c }
            }
            let M = 1e-6
            put("claude-opus-4-5", 5*M, 25*M, 6.25*M, 0.5*M, ctx: 200_000)
            put("claude-opus-4-6", 5*M, 25*M, 6.25*M, 0.5*M, ctx: 1_000_000)
            put("claude-opus-4-7", 5*M, 25*M, 6.25*M, 0.5*M, ctx: 1_000_000)
            put("claude-opus-4-8", 5*M, 25*M, 6.25*M, 0.5*M, ctx: 1_000_000)
            put("claude-haiku-4-5", 1*M, 5*M, 1.25*M, 0.1*M, ctx: 200_000)
            put("claude-opus-4", 15*M, 75*M, 18.75*M, 1.5*M, ctx: 200_000)
            put("claude-sonnet-4-6", 3*M, 15*M, 3.75*M, 0.3*M, ctx: 1_000_000)
            put("claude-sonnet-4", 3*M, 15*M, 3.75*M, 0.3*M, tiers: (6*M, 22.5*M, 7.5*M, 0.6*M), ctx: 200_000)
            put("claude-3-5-haiku", 0.8*M, 4*M, 1.0*M, 0.08*M, ctx: 200_000)
            put("claude-3-5-haiku-20241022", 0.8*M, 4*M, 1.0*M, 0.08*M, ctx: 200_000)
            put("claude-3-opus", 15*M, 75*M, 18.75*M, 1.5*M, ctx: 200_000)
            put("claude-3-sonnet", 3*M, 15*M, 3.75*M, 0.3*M, ctx: 200_000)
            put("claude-3-haiku", 0.25*M, 1.25*M, 0.3*M, 0.03*M, ctx: 200_000)
            put("gpt-5", 1.25*M, 10*M, 1.25*M, 0.125*M)
            put("gpt-5.5", 5*M, 30*M, 5*M, 0.5*M, ctx: 1_050_000)
            put("grok-4.3", 1.25*M, 2.5*M, 1.25*M, 0.125*M, explicit: false, ctx: 1_000_000)
            put("moonshot/kimi-k2.5", 0.6*M, 3*M, 0.75*M, 0.1*M, ctx: 262_144)
            put("moonshot/kimi-k2.6", 0.95*M, 4*M, 1.1875*M, 0.16*M, ctx: 262_144)
            put("gpt-5.1", 1.25*M, 10*M, 1.25*M, 0.125*M)
            put("gpt-5.1-codex", 1.25*M, 10*M, 1.25*M, 0.125*M)
            put("gpt-5.2-codex", 1.75*M, 14*M, 1.75*M, 0.175*M)
            put("gpt-5.2", 1.75*M, 14*M, 1.75*M, 0.175*M)
            put("gpt-5.3-codex", 1.75*M, 14*M, 1.75*M, 0.175*M)
            put("gpt-5.4", 2.5*M, 15*M, 2.5*M, 0.25*M, ctx: 1_050_000)
            put("gpt-5.4-mini", 0.75*M, 4.5*M, 0.75*M, 0.075*M)
            put("gpt-5.4-nano", 0.2*M, 1.25*M, 0.2*M, 0.02*M)
            return m
        }

        /// Resolve pricing for a model name: exact, else fuzzy longest-key match (spec §1.5).
        func find(_ model: String) -> Pricing? {
            if let p = entries[model] { return p }
            let norm = CCUsage.normalizedPricingKey(model)
            var best: String?
            for key in entries.keys where CCUsage.pricingKeyMatches(candidate: key, model: model, normModel: norm) {
                if let b = best {
                    // maximize (key.count, key): longest; tie → lexicographically GREATER
                    if key.count > b.count || (key.count == b.count && key > b) { best = key }
                } else { best = key }
            }
            return best.flatMap { entries[$0] }
        }
    }

    // MARK: - Fuzzy model-key matching (spec §1.5)

    static func normalizedPricingKey(_ v: String) -> String {
        guard v.contains(".") || v.contains("@") else { return v }
        return String(v.map { ($0 == "." || $0 == "@") ? "-" : $0 })
    }

    private static func isAlnum(_ c: UInt8) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
    }

    static func pricingKeyMatches(candidate: String, model: String, normModel: String) -> Bool {
        containsPricingKey(model, candidate) || containsPricingKey(candidate, model)
        || containsPricingKey(normModel, normalizedPricingKey(candidate))
        || containsPricingKey(normalizedPricingKey(candidate), normModel)
    }

    /// True if `key` occurs in `value` at a left boundary with an allowed suffix.
    static func containsPricingKey(_ value: String, _ key: String) -> Bool {
        let v = Array(value.utf8), k = Array(key.utf8)
        guard !k.isEmpty, v.count >= k.count else { return false }
        var i = 0
        let last = v.count - k.count
        while i <= last {
            if Array(v[i..<i+k.count]) == k {
                let leftOK = (i == 0) || !isAlnum(v[i - 1])
                if leftOK {
                    let suffix = Array(v[(i + k.count)...])
                    if suffixAllows(key: k, suffix: suffix) { return true }
                }
            }
            i += 1
        }
        return false
    }

    private static func suffixAllows(key: [UInt8], suffix: [UInt8]) -> Bool {
        if suffix.isEmpty { return true }
        if isAlnum(suffix[0]) { return false }
        return !suffixStartsWithNumericModelVersion(key: key, suffix: suffix)
    }

    /// 8-digit run after a digit-ending key = date alias (allowed); other numeric runs = new version.
    private static func suffixStartsWithNumericModelVersion(key: [UInt8], suffix: [UInt8]) -> Bool {
        guard let lastK = key.last, lastK >= 48, lastK <= 57 else { return false }     // key ends in digit
        guard let first = suffix.first, first == 45 || first == 46 else { return false } // '-' or '.'
        var digitLen = 0
        var idx = 1
        while idx < suffix.count, suffix[idx] >= 48, suffix[idx] <= 57 { digitLen += 1; idx += 1 }
        if digitLen == 0 { return false }
        let afterIsBoundary = (idx >= suffix.count) || !isAlnum(suffix[idx])
        return !(digitLen == 8 && afterIsBoundary)
    }

    private static func lastIndexOf(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        var i = hay.count - needle.count
        while i >= 0 {
            if Array(hay[i..<i+needle.count]) == needle { return i }
            i -= 1
        }
        return nil
    }

    // MARK: - Cost (spec §2)

    enum CostMode: String { case auto, calculate, display }

    static func cost(model: String?, usage: TokenUsageRaw, costUSD: Double?, mode: CostMode, pricing: PricingMap) -> Double {
        switch mode {
        case .display: return costUSD ?? 0
        case .auto: return costUSD ?? calculateFromTokens(model: model, usage: usage, pricing: pricing)
        case .calculate: return calculateFromTokens(model: model, usage: usage, pricing: pricing)
        }
    }

    static func calculateFromTokens(model: String?, usage: TokenUsageRaw, pricing: PricingMap) -> Double {
        guard let model, let p = pricing.find(model) else { return 0 }
        let mult = (usage.speed == .fast) ? p.fastMultiplier : 1.0
        let c = tiered(usage.inputTokens, p.input, p.inputAbove200k)
            + tiered(usage.outputTokens, p.output, p.outputAbove200k)
            + tiered(usage.cacheCreationInputTokens, p.cacheCreate, p.cacheCreateAbove200k)
            + tiered(usage.cacheReadInputTokens, p.cacheRead, p.cacheReadAbove200k)
        return c * mult
    }

    /// Per-token-type tiered cost against the 200k threshold (spec §2.2).
    static func tiered(_ tokens: UInt64, _ base: Double, _ above: Double?) -> Double {
        if tokens == 0 { return 0 }
        let threshold: UInt64 = 200_000
        if let above, tokens > threshold {
            return Double(threshold) * base + Double(tokens - threshold) * above
        }
        return Double(tokens) * base
    }
}
