import Foundation

/// Phase 1b' — Codex source loader. Reads `~/.codex/sessions/**/*.jsonl` (or CODEX_HOME), handling
/// both session logs (turn_context sets the model; event_msg/token_count carries CUMULATIVE usage →
/// differenced) and headless `codex exec --json` lines (single-shot usage, many field-name variants).
/// Codex cost differs from Claude: no cache-creation, no 200k tiering, reasoning not billed, cached
/// input billed at cache-read rate (input rate if not explicit), fast = ≥2×. Per spec §二.
/// Simplifications (documented): reasoning tokens omitted from display totals; speed assumed standard.
extension CCUsage {

    enum CodexSource {
        /// Codex homes (spec §二.1): CODEX_HOME (comma list) else ~/.codex.
        static func homes(env: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
            let home = FileManager.default.homeDirectoryForCurrentUser
            if let c = env["CODEX_HOME"], !c.isEmpty {
                return c.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            }
            return [home.appendingPathComponent(".codex")]
        }

        /// For each home: `home/sessions` if it's a dir, else the home itself.
        static func sessionDirs(_ homes: [URL]) -> [URL] {
            let fm = FileManager.default
            var out: [URL] = []
            var seen = Set<String>()
            for h in homes {
                let s = h.appendingPathComponent("sessions")
                var isDir: ObjCBool = false
                let chosen = (fm.fileExists(atPath: s.path, isDirectory: &isDir) && isDir.boolValue) ? s : h
                let key = chosen.standardizedFileURL.path
                if !seen.contains(key) { seen.insert(key); out.append(chosen) }
            }
            return out
        }

        static func files(_ dirs: [URL]) -> [URL] {
            let fm = FileManager.default
            var out: [URL] = []
            for d in dirs {
                guard let en = fm.enumerator(at: d, includingPropertiesForKeys: nil) else { continue }
                for case let u as URL in en where u.pathExtension == "jsonl" { out.append(u) }
            }
            return out.sorted { $0.path < $1.path }
        }

        /// `session_id` = path relative to the sessions dir, minus `.jsonl`, components joined by `/`.
        static func sessionId(_ url: URL, under dir: URL) -> String {
            let rel = url.deletingPathExtension().path.replacingOccurrences(of: dir.path + "/", with: "")
            return rel.isEmpty ? "unknown" : rel
        }

        // MARK: load

        private struct Event {
            var ts: TimestampMs; var tsString: String; var model: String
            var input: UInt64; var cached: UInt64; var output: UInt64; var reasoning: UInt64; var total: UInt64
        }

        static func load(pricing: PricingMap, timeZone: TimeZone? = nil,
                         env: [String: String] = ProcessInfo.processInfo.environment) -> [LoadedEntry] {
            var result: [LoadedEntry] = []
            var seen = Set<String>() // aggregate dedup key (incl. session)
            for dir in sessionDirs(homes(env: env)) {
                for file in files([dir]) {
                    guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                    let sid = sessionId(file, under: dir)
                    var currentModel: String?
                    var previousTotals = (i: UInt64(0), c: UInt64(0), o: UInt64(0), r: UInt64(0))
                    for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                        let line = String(raw)
                        guard let obj = jsonObject(line) else { continue }
                        guard let ev = parse(line: line, obj: obj, file: file,
                                             currentModel: &currentModel, previousTotals: &previousTotals) else { continue }
                        guard !ev.model.isEmpty else { continue } // aggregate requires non-empty model
                        let key = "\(sid)\u{0}\(ev.tsString)\u{0}\(ev.model)\u{0}\(ev.input)\u{0}\(ev.cached)\u{0}\(ev.output)\u{0}\(ev.reasoning)\u{0}\(ev.total)"
                        if seen.contains(key) { continue }
                        seen.insert(key)
                        let nonCached = ev.input >= ev.cached ? ev.input - ev.cached : 0
                        var usage = TokenUsageRaw()
                        usage.inputTokens = nonCached          // display/cost input is NON-cached
                        usage.cacheReadInputTokens = ev.cached  // cached billed at cache-read rate
                        usage.outputTokens = ev.output
                        let cost = codexCost(model: ev.model, nonCachedInput: nonCached, cached: ev.cached,
                                             output: ev.output, speed: .standard, pricing: pricing)
                        result.append(LoadedEntry(timestamp: ev.ts, date: formatDate(ev.ts, timeZone: timeZone),
                            sessionId: sid, projectPath: file.deletingLastPathComponent().lastPathComponent,
                            model: ev.model, cost: cost, usage: usage, messageId: nil, requestId: nil,
                            isSidechain: false, version: nil, agent: "codex"))
                    }
                }
            }
            return result
        }

        /// Parse one Codex line → Event. Mutates session model/totals state.
        private static func parse(line: String, obj: [String: Any], file: URL,
                                  currentModel: inout String?,
                                  previousTotals: inout (i: UInt64, c: UInt64, o: UInt64, r: UInt64)) -> Event? {
            let isSession = line.contains("\"type\":\"turn_context\"")
                || (line.contains("\"type\":\"event_msg\"") && line.contains("\"type\":\"token_count\""))
            if isSession {
                let type = obj["type"] as? String
                if type == "turn_context" {
                    if let m = modelFrom(obj["payload"] as? [String: Any]) { currentModel = m }
                    return nil
                }
                guard type == "event_msg", let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let tsString = codexTimestamp(obj["timestamp"]), let ts = parseTimestampMs(tsString) ?? numericTs(obj["timestamp"]) else { return nil }
                let info = payload["info"] as? [String: Any] ?? [:]
                let total = usageTuple(info["total_token_usage"] as? [String: Any])
                let last = info["last_token_usage"] as? [String: Any]
                let raw: (i: UInt64, c: UInt64, o: UInt64, r: UInt64)
                if let last { raw = usageTuple(last) }
                else { raw = (total.i &- min(total.i, previousTotals.i), total.c &- min(total.c, previousTotals.c),
                              total.o &- min(total.o, previousTotals.o), total.r &- min(total.r, previousTotals.r)) }
                if info["total_token_usage"] != nil { previousTotals = total }
                if raw.i == 0 && raw.c == 0 && raw.o == 0 && raw.r == 0 { return nil }
                let model = modelFrom(payload) ?? modelFrom(info) ?? currentModel ?? "gpt-5"
                if modelFrom(payload) != nil || modelFrom(info) != nil { currentModel = model }
                let cached = min(raw.c, raw.i)
                return Event(ts: ts, tsString: tsString, model: model, input: raw.i, cached: cached,
                             output: raw.o, reasoning: raw.r, total: raw.i + raw.o + raw.r)
            } else {
                // Headless: usage from top/data/result/response
                guard let usageObj = firstDict(obj, ["usage"]) ?? firstDict(obj["data"] as? [String: Any], ["usage"])
                        ?? firstDict(obj["result"] as? [String: Any], ["usage"]) ?? firstDict(obj["response"] as? [String: Any], ["usage"]) else { return nil }
                let u = usageTuple(usageObj)
                let total = (looseU64(usageObj["total_tokens"]) ?? 0)
                let tot = (total > 0 || u.i + u.o + u.r == 0) ? total : (u.i + u.o + u.r)
                if u.i == 0 && u.c == 0 && u.o == 0 && u.r == 0 && tot == 0 { return nil }
                let tsString = codexTimestamp(obj["timestamp"]) ?? codexTimestamp(obj["created_at"]) ?? fileMtime(file)
                guard let ts = parseTimestampMs(tsString) ?? numericTs(obj["timestamp"]) else { return nil }
                let model = modelFrom(obj) ?? modelFrom(obj["data"] as? [String: Any]) ?? currentModel ?? "gpt-5"
                currentModel = model
                let cached = min(u.c, u.i)
                return Event(ts: ts, tsString: tsString, model: model, input: u.i, cached: cached,
                             output: u.o, reasoning: u.r, total: tot)
            }
        }

        // MARK: codex cost (spec §二.4)

        static func codexCost(model: String, nonCachedInput: UInt64, cached: UInt64, output: UInt64,
                              speed: Speed, pricing: PricingMap) -> Double {
            guard let p = pricing.find(model) else { return 0 }
            let mult = (speed == .fast) ? (p.fastMultiplier == 1.0 ? 2.0 : p.fastMultiplier) : 1.0
            let cacheReadRate = p.cacheReadExplicit ? p.cacheRead : p.input
            return (Double(nonCachedInput) * p.input + Double(cached) * cacheReadRate + Double(output) * p.output) * mult
        }

        // MARK: field-variant helpers

        /// Loose u64: number, or a numeric string (trimmed). nil otherwise.
        static func looseU64(_ v: Any?) -> UInt64? {
            if let n = v as? NSNumber { return n.uint64Value }
            if let s = v as? String, let n = UInt64(s.trimmingCharacters(in: .whitespaces)) { return n }
            return nil
        }

        /// Extract (input, cached, output, reasoning) from a usage dict with all field-name variants.
        private static func usageTuple(_ d: [String: Any]?) -> (i: UInt64, c: UInt64, o: UInt64, r: UInt64) {
            guard let d else { return (0, 0, 0, 0) }
            func pick(_ keys: [String]) -> UInt64 { for k in keys { if let v = looseU64(d[k]) { return v } }; return 0 }
            return (pick(["input_tokens", "prompt_tokens", "input"]),
                    pick(["cached_input_tokens", "cache_read_input_tokens", "cached_tokens"]),
                    pick(["output_tokens", "completion_tokens", "output"]),
                    pick(["reasoning_output_tokens", "reasoning_tokens"]))
        }

        private static func modelFrom(_ d: [String: Any]?) -> String? {
            guard let d else { return nil }
            for k in ["model", "model_name"] {
                if let s = d[k] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
            }
            if let meta = d["metadata"] as? [String: Any], let s = meta["model"] as? String,
               !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
            return nil
        }

        private static func firstDict(_ d: [String: Any]?, _ keys: [String]) -> [String: Any]? {
            guard let d else { return nil }
            for k in keys { if let v = d[k] as? [String: Any] { return v } }
            return nil
        }

        /// Codex timestamp → string. String trimmed; Number >1e10 = ms else seconds → RFC3339.
        private static func codexTimestamp(_ v: Any?) -> String? {
            if let s = v as? String { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
            return nil
        }
        private static func numericTs(_ v: Any?) -> TimestampMs? {
            guard let n = (v as? NSNumber)?.int64Value else { return nil }
            return TimestampMs(ms: n > 10_000_000_000 ? n : n * 1000)
        }
        private static func fileMtime(_ url: URL) -> String {
            let d = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date ?? Date(timeIntervalSince1970: 0)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
            f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: d)
        }

        private static func jsonObject(_ line: String) -> [String: Any]? {
            guard let data = line.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }
}
