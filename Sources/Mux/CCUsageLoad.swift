import Foundation

/// Phase 1b — ccusage data pipeline: a unified LoadedEntry, the Claude source loader (paths /
/// line-prefilter / parse / dedup), generic aggregation (daily / session / weekly / monthly),
/// and 5-hour billing blocks. Codex source lands next (CCUsageCodex.swift). Per spec
/// ~/.gstack/projects/tty/ccusage-spec/{core.md, claude-codex.md}.
extension CCUsage {

    /// One usage record after parsing + costing (the unit fed to aggregation/blocks).
    struct LoadedEntry: Sendable {
        var timestamp: TimestampMs
        var date: String                 // YYYY-MM-DD in the chosen tz
        var sessionId: String
        var projectPath: String
        var model: String?               // display name (nil for <synthetic>); may carry "-fast"
        var cost: Double
        var usage: TokenUsageRaw
        var messageId: String?
        var requestId: String?
        var isSidechain: Bool
        var version: String?
        var agent: String                // "claude" | "codex"
    }

    struct ModelBreakdown: Sendable { var model: String; var counts = TokenCounts(); var cost = 0.0 }

    /// One aggregated bucket (a day / week / month / session).
    struct Summary: Sendable, Identifiable {
        var id: String { key }
        var key: String                  // the group key (date / week / month / sessionId)
        var counts = TokenCounts()
        var cost = 0.0
        var modelsUsed: [String] = []
        var breakdowns: [ModelBreakdown] = []
        var lastActivity: TimestampMs?
        var projectPath: String?
    }

    // MARK: - Claude source

    enum ClaudeSource {
        /// Discover Claude data roots (spec §9.1). CLAUDE_CONFIG_DIR (comma list) overrides; else
        /// XDG config + ~/.claude. Only roots whose `projects/` exists are kept.
        static func dataRoots(env: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            func hasProjects(_ u: URL) -> Bool {
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: u.appendingPathComponent("projects").path, isDirectory: &isDir) && isDir.boolValue
            }
            func expand(_ raw: String) -> URL {
                var p = raw
                if p == "~" { return home }
                if p.hasPrefix("~/") { p = String(p.dropFirst(2)); return home.appendingPathComponent(p) }
                return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            }
            func normalize(_ u: URL) -> URL { u.lastPathComponent == "projects" ? u.deletingLastPathComponent() : u }

            var roots: [URL] = []
            var seen = Set<String>()
            func add(_ u: URL) { let s = u.standardizedFileURL.path; if !seen.contains(s) { seen.insert(s); roots.append(u) } }

            if let cfg = env["CLAUDE_CONFIG_DIR"], !cfg.isEmpty {
                for seg in cfg.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !seg.isEmpty {
                    let u = normalize(expand(seg))
                    if hasProjects(u) { add(u) }
                }
                return roots // set → don't fall through to defaults
            }
            let xdg = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
            for cand in [xdg.appendingPathComponent("claude"), home.appendingPathComponent(".claude")] where hasProjects(cand) {
                add(cand)
            }
            return roots
        }

        /// All `projects/**/*.jsonl` under the roots, sorted by path string (stable for dedup).
        static func files(roots: [URL]) -> [URL] {
            let fm = FileManager.default
            var out: [URL] = []
            for root in roots {
                let proj = root.appendingPathComponent("projects")
                guard let en = fm.enumerator(at: proj, includingPropertiesForKeys: nil) else { continue }
                for case let u as URL in en where u.pathExtension == "jsonl" { out.append(u) }
            }
            return out.sorted { $0.path < $1.path }
        }

        /// `(session_id, project_path)` from a file path (spec §9.1 extract_session_parts).
        static func sessionParts(_ url: URL) -> (String, String) {
            let comps = url.pathComponents
            let rel: [String]
            if let i = comps.firstIndex(of: "projects") { rel = Array(comps[(i + 1)...]) } else { rel = comps }
            let fileId = url.deletingPathExtension().lastPathComponent
            if rel.count == 2, !fileId.isEmpty { return (fileId, rel[0]) }
            if rel.count >= 4, rel[rel.count - 2] == "subagents" {
                let proj = rel[0..<(rel.count - 3)].joined(separator: "/")
                return (rel[rel.count - 3], proj.isEmpty ? "Unknown Project" : proj)
            }
            let session = rel.count >= 2 ? rel[rel.count - 2] : "unknown"
            let proj = rel.count > 2 ? rel[0..<(rel.count - 2)].joined(separator: "/") : "Unknown Project"
            return (session, proj)
        }

        private static let bannedNullFields = ["id", "cwd", "model", "speed", "costUSD", "version",
            "sessionId", "requestId", "isApiErrorMessage", "cache_read_input_tokens", "cache_creation_input_tokens"]

        /// Load + cost + dedup all Claude entries.
        static func load(mode: CostMode, pricing: PricingMap, timeZone: TimeZone? = nil,
                         env: [String: String] = ProcessInfo.processInfo.environment) -> [LoadedEntry] {
            var deduper = ClaudeDeduper()
            for file in files(roots: dataRoots(env: env)) {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let (sid, proj) = sessionParts(file)
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let e = parseLine(String(line), sessionId: sid, projectPath: proj,
                                            mode: mode, pricing: pricing, tz: timeZone) else { continue }
                    deduper.push(e)
                }
            }
            return deduper.result
        }

        /// Parse one JSONL line into a LoadedEntry (nil if filtered/invalid). Spec §7 + §2 + §6 note.
        static func parseLine(_ line: String, sessionId: String, projectPath: String,
                              mode: CostMode, pricing: PricingMap, tz: TimeZone?) -> LoadedEntry? {
            guard line.contains("\"usage\":{") else { return nil }
            for f in bannedNullFields where line.contains("\"\(f)\":null") { return nil }
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            // AgentProgress nesting: data.message holds the real record.
            let rootMsg: [String: Any]
            let tsString: String?
            let costUSD: Double?
            let requestId: String?
            let isSidechain: Bool
            let version: String?
            let sessIdField: String?
            if let dataObj = obj["data"] as? [String: Any], let inner = dataObj["message"] as? [String: Any] {
                rootMsg = (inner["message"] as? [String: Any]) ?? inner
                tsString = inner["timestamp"] as? String
                costUSD = (inner["costUSD"] as? NSNumber)?.doubleValue
                requestId = inner["requestId"] as? String
                isSidechain = (inner["isSidechain"] as? Bool) ?? false
                version = nil; sessIdField = nil
            } else {
                rootMsg = (obj["message"] as? [String: Any]) ?? [:]
                tsString = obj["timestamp"] as? String
                costUSD = (obj["costUSD"] as? NSNumber)?.doubleValue
                requestId = obj["requestId"] as? String
                isSidechain = (obj["isSidechain"] as? Bool) ?? false
                version = obj["version"] as? String
                sessIdField = obj["sessionId"] as? String
            }
            guard let tsString, let ts = parseTimestampMs(tsString) else { return nil }
            // validity (§7)
            if let v = version, !isSemverPrefix(v) { return nil }
            if let s = sessIdField, s.isEmpty { return nil }
            if let r = requestId, r.isEmpty { return nil }
            guard let usageObj = rootMsg["usage"] as? [String: Any] else { return nil }
            let mid = rootMsg["id"] as? String
            if let m = mid, m.isEmpty { return nil }
            let rawModel = rootMsg["model"] as? String
            if let m = rawModel, m.isEmpty { return nil }

            func u64(_ k: String) -> UInt64 { (usageObj[k] as? NSNumber)?.uint64Value ?? 0 }
            var usage = TokenUsageRaw()
            usage.inputTokens = u64("input_tokens")
            usage.outputTokens = u64("output_tokens")
            usage.cacheCreationInputTokens = u64("cache_creation_input_tokens")
            usage.cacheReadInputTokens = u64("cache_read_input_tokens")
            if let sp = usageObj["speed"] as? String { usage.speed = Speed(rawValue: sp) }

            // model display normalization (§6 note): <synthetic> → nil; fast → "-fast"
            var displayModel: String?
            if let rm = rawModel, rm != "<synthetic>" {
                displayModel = (usage.speed == .fast) ? rm + "-fast" : rm
            }
            let pricingModel = (rawModel == "<synthetic>") ? nil : rawModel
            let cost = CCUsage.cost(model: pricingModel, usage: usage, costUSD: costUSD, mode: mode, pricing: pricing)

            return LoadedEntry(
                timestamp: ts, date: formatDate(ts, timeZone: tz),
                sessionId: sessIdField ?? sessionId, projectPath: projectPath,
                model: displayModel, cost: cost, usage: usage,
                messageId: mid, requestId: requestId, isSidechain: isSidechain,
                version: version, agent: "claude")
        }

        static func isSemverPrefix(_ s: String) -> Bool {
            // [0-9]+.[0-9]+.[0-9]+ prefix
            let parts = s.split(separator: ".")
            guard parts.count >= 3 else { return false }
            for p in parts.prefix(3) where !p.allSatisfy({ $0.isNumber }) || p.isEmpty { return false }
            return true
        }
    }

    /// Claude dedup engine (spec §6): key (message.id, requestId) + sidechain fallback + winner rule.
    struct ClaudeDeduper {
        private(set) var result: [LoadedEntry] = []
        private var exact: [String: [Int]] = [:]      // "mid\u{0}req" → indexes
        private var byMsg: [String: [Int]] = [:]       // mid → indexes (sidechain bucket)

        mutating func push(_ e: LoadedEntry) {
            guard let mid = e.messageId else { result.append(e); return }
            let exactKey = mid + "\u{0}" + (e.requestId ?? "")
            // 1. exact
            if let idxs = exact[exactKey] {
                for i in idxs where result[i].messageId == mid && result[i].requestId == e.requestId {
                    if shouldReplace(candidate: e, existing: result[i]) { replace(i, e, mid, exactKey) }
                    return
                }
            }
            // 2. sidechain fallback (same mid, either side sidechain)
            if let idxs = byMsg[mid] {
                for i in idxs where result[i].messageId == mid && (e.isSidechain || result[i].isSidechain) {
                    if shouldReplace(candidate: e, existing: result[i]) {
                        let oldExact = result[i].messageId! + "\u{0}" + (result[i].requestId ?? "")
                        replace(i, e, mid, oldExact)
                    }
                    return
                }
            }
            // 3. new
            let i = result.count
            result.append(e)
            exact[exactKey, default: []].append(i)
            byMsg[mid, default: []].append(i)
        }

        private mutating func replace(_ i: Int, _ e: LoadedEntry, _ mid: String, _ oldExactKey: String) {
            result[i] = e
            let newExact = mid + "\u{0}" + (e.requestId ?? "")
            if newExact != oldExactKey { exact[newExact, default: []].append(i) }
        }

        private func shouldReplace(candidate c: LoadedEntry, existing x: LoadedEntry) -> Bool {
            if c.isSidechain != x.isSidechain { return x.isSidechain } // keep non-sidechain
            let ct = c.usage.total, xt = x.usage.total
            if ct != xt { return ct > xt }                              // keep larger
            return c.usage.speed != nil && x.usage.speed == nil         // tiebreak: has speed
        }
    }

    // MARK: - Aggregation (spec §5)

    /// Group entries by a key fn, accumulating counts/cost/per-model breakdown (sorted by cost desc).
    static func summarize(_ entries: [LoadedEntry], by keyFn: (LoadedEntry) -> String) -> [Summary] {
        var map: [String: Summary] = [:]
        for e in entries {
            var s = map[e.key(keyFn)] ?? Summary(key: keyFn(e))
            s.counts.add(e.usage); s.cost += e.cost
            if let lastTs = s.lastActivity { if e.timestamp > lastTs { s.lastActivity = e.timestamp; s.projectPath = e.projectPath } }
            else { s.lastActivity = e.timestamp; s.projectPath = e.projectPath }
            if let m = e.model {
                if let bi = s.breakdowns.firstIndex(where: { $0.model == m }) {
                    s.breakdowns[bi].counts.add(e.usage); s.breakdowns[bi].cost += e.cost
                } else {
                    s.modelsUsed.append(m)
                    var b = ModelBreakdown(model: m); b.counts.add(e.usage); b.cost = e.cost
                    s.breakdowns.append(b)
                }
            }
            map[keyFn(e)] = s
        }
        return map.values
            .map { var s = $0; s.breakdowns.sort { $0.cost > $1.cost }; return s }
            .sorted { $0.key < $1.key }
    }

    static func daily(_ e: [LoadedEntry]) -> [Summary] { summarize(e) { $0.date } }
    static func session(_ e: [LoadedEntry]) -> [Summary] { summarize(e) { $0.sessionId } }

    /// Weekly/monthly bucket from daily rows. Monthly = "YYYY-MM"; weekly = Monday-based week start.
    static func bucketByMonth(_ daily: [Summary]) -> [Summary] { rebucket(daily) { String($0.key.prefix(7)) } }
    static func bucketByWeek(_ daily: [Summary]) -> [Summary] { rebucket(daily) { weekStartMonday($0.key) } }

    private static func rebucket(_ rows: [Summary], _ keyFn: (Summary) -> String) -> [Summary] {
        var map: [String: Summary] = [:]
        for r in rows {
            let k = keyFn(r)
            var s = map[k] ?? Summary(key: k)
            s.counts.input += r.counts.input; s.counts.output += r.counts.output
            s.counts.cacheCreation += r.counts.cacheCreation; s.counts.cacheRead += r.counts.cacheRead
            s.counts.extraTotal += r.counts.extraTotal; s.cost += r.cost
            for b in r.breakdowns {
                if let bi = s.breakdowns.firstIndex(where: { $0.model == b.model }) {
                    s.breakdowns[bi].counts.input += b.counts.input; s.breakdowns[bi].counts.output += b.counts.output
                    s.breakdowns[bi].counts.cacheCreation += b.counts.cacheCreation; s.breakdowns[bi].counts.cacheRead += b.counts.cacheRead
                    s.breakdowns[bi].cost += b.cost
                } else { s.modelsUsed.append(b.model); s.breakdowns.append(b) }
            }
            map[k] = s
        }
        return map.values.map { var s = $0; s.breakdowns.sort { $0.cost > $1.cost }; return s }.sorted { $0.key < $1.key }
    }

    /// Monday-based week start for "YYYY-MM-DD" (spec §5.3, all-agent weekly uses Monday).
    static func weekStartMonday(_ date: String) -> String {
        let p = date.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return date }
        let days = daysFromCivil(year: p[0], month: p[1], day: p[2])
        let dow = ((days % 7) + 7 + 4) % 7   // 0=Sun..6=Sat (epoch 1970-01-01 was Thursday)
        let shift = (dow - 1 + 7) % 7        // back to Monday
        let start = days - shift
        // civil_from_days
        var z = start + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        z -= era * 146_097
        let doe = z
        let yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365*yoe + yoe/4 - yoe/100)
        let mp = (5*doy + 2)/153
        let d = doy - (153*mp+2)/5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let year = m <= 2 ? y + 1 : y
        return String(format: "%04d-%02d-%02d", year, m, d)
    }

    // MARK: - Blocks (5-hour billing windows, spec §8)

    struct Block {
        var id: String
        var start: TimestampMs
        var end: TimestampMs
        var isGap: Bool
        var counts = TokenCounts()
        var cost = 0.0
        var models: [String] = []
        var isActive = false
        var entryCount = 0
    }

    static func identifyBlocks(_ entries: [LoadedEntry], hours: Double = 5, now: TimestampMs) -> [Block] {
        guard !entries.isEmpty else { return [] }
        let dur = Int64(hours * 3_600_000)
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }
        var blocks: [Block] = []
        var curStart = sorted[0].timestamp.flooredToHour()
        var cur: [LoadedEntry] = []
        func close() { if !cur.isEmpty { blocks.append(makeBlock(curStart, cur, now, dur)) } }
        for e in sorted {
            let lastTime = cur.last?.timestamp ?? curStart
            let sinceStart = e.timestamp.ms - curStart.ms
            let sinceLast = e.timestamp.ms - lastTime.ms
            if sinceStart > dur || sinceLast > dur {
                close()
                if sinceLast > dur {
                    blocks.append(Block(id: "gap-" + formatRFC3339(TimestampMs(ms: lastTime.ms + dur)),
                                        start: TimestampMs(ms: lastTime.ms + dur), end: e.timestamp, isGap: true))
                }
                curStart = e.timestamp.flooredToHour()
                cur = []
            }
            cur.append(e)
        }
        close()
        return blocks
    }

    private static func makeBlock(_ start: TimestampMs, _ entries: [LoadedEntry], _ now: TimestampMs, _ dur: Int64) -> Block {
        let end = TimestampMs(ms: start.ms + dur)
        var b = Block(id: formatRFC3339(start), start: start, end: end, isGap: false)
        b.entryCount = entries.count
        for e in entries {
            b.counts.add(e.usage); b.cost += e.cost
            if let m = e.model, !b.models.contains(m) { b.models.append(m) }
        }
        if let lastTs = entries.last?.timestamp {
            b.isActive = (now.ms - lastTs.ms) < dur && now.ms < end.ms
        }
        return b
    }

    private static func formatRFC3339(_ ts: TimestampMs) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date(timeIntervalSince1970: Double(ts.ms) / 1000))
    }
}

private extension CCUsage.LoadedEntry {
    func key(_ fn: (CCUsage.LoadedEntry) -> String) -> String { fn(self) }
}
