import Foundation
import SuperagentCore

/// `tfa read …` 的文本视图。请求原文和每条消息都完整给出（执行者从这里推导需求）；
/// 概览和时间线才截断成一行。
enum Views {
    // MARK: - 概览

    static func overview(_ engine: SuperagentEngine) throws -> String {
        let views = try engine.views(endedLimit: 0)
        let needs = views.compactMap { v in v.stage.needsPerson.map { (v, $0) } }
            .sorted { ($0.1, $0.0.id) < ($1.1, $1.0.id) }.map(\.0)
        let others = views.filter { $0.stage.needsPerson == nil }.sorted { $0.id < $1.id }
        let pending = try engine.store.pendingTriggers()
        var s = ""
        if needs.isEmpty, others.isEmpty { s += "没有打开的工单。\n" }
        if !needs.isEmpty { s += "需要你（\(needs.count)）：\n" + needs.map { line($0) + "\n" }.joined() }
        if !others.isEmpty { s += "其他打开的工单（\(others.count)）：\n" + others.map { line($0) + "\n" }.joined() }
        if !pending.isEmpty {
            s += "待决定的候选（\(pending.count)，详情 tfa read candidates）：\n"
            s += pending.map { "\($0.id) [\(strength($0.strength))] 来源 \($0.source) · \($0.repo) · \(clip($0.text, 80))\n" }.joined()
        }
        return s
    }

    /// `#12 [待评审] 标题 · 目录 · 最后回报摘要`；不是「开发」的单在标题后写角色：`#13 [工作中] 标题 · 助理`。
    static func line(_ v: TicketView) -> String {
        let t = v.ticket
        var s = "#\(t.id) [\(v.stage.label)] \(t.title)"
        if t.role != Role.developer { s += " · \(t.role)" }
        if !t.repo.isEmpty { s += " · \(t.repo)" }
        if let e = t.deliveryError { s += " · \(clip(e, 80))" }
        if !t.reportSummary.isEmpty { s += " · \(clip(t.reportSummary, 80))" }
        if let q = t.attention { s += " · 问：\(clip(q, 80))" }
        return s
    }

    // MARK: - 工单详情

    static func ticket(_ engine: SuperagentEngine, _ id: Int64) throws -> String {
        let v = try engine.view(id)
        let t = v.ticket
        var s = "#\(t.id)「\(t.title)」 \(v.stage.label)\(t.endedBy.map { "（由\($0)结束）" } ?? "")\n"
        let role = try engine.store.role(t.role)
        s += "角色：\(t.role)\(role.map { "（\($0.traits)）" } ?? "")\n"
        s += "目录：\(t.repo.isEmpty ? "没有（不针对某个项目）" : t.repo)\n"
        if !t.dir.isEmpty { s += "工作目录：\(t.dir)\(t.branch.isEmpty ? "" : "（分支 \(t.branch)）")\n" }
        if !t.session.isEmpty { s += "终端：\(t.session)\n" }
        if let m = mandate(t.mandate) { s += m + "\n" }

        s += "\n【原始请求】\n\(t.request)\n"
        if !t.note.isEmpty { s += "\n【路由备注】\(t.note)\n" }
        s += "\n【确认】\(t.ack.isEmpty ? "还没有" : t.ack)\n"

        if let state = t.reportState {
            s += "\n【最新回报】\(state.rawValue)\(t.reportAt.map { " · " + time($0) } ?? "")\n\(t.reportSummary)\n"
        } else if !t.reportSummary.isEmpty {
            s += "\n【最新回报】本轮还没有；上一轮：\n\(t.reportSummary)\n"
        } else {
            s += "\n【最新回报】还没有\n"
        }
        if let path = t.reportPath { s += "报告文件：\(path)\n" }
        if let q = t.attention { s += "\n【等人回答的问题】\n\(q)\n" }
        if let e = t.deliveryError { s += "\n【送达问题】\(e)\n" }

        let inputs = try engine.store.inputs(id)
        if inputs.isEmpty {
            s += "\n【消息】没有\n"
        } else {
            s += "\n【消息】\(inputs.count) 条，按时间顺序：\n"
            for (i, m) in inputs.enumerated() {
                let who = m.kind == .human ? "人" : "TFA"
                let delivered = m.deliveredAt == nil ? "待送达" : "已送达"
                s += "[\(i + 1)] \(who) · \(delivered) · \(time(m.createdAt))\n\(m.text)\n"
            }
        }

        let events = try engine.store.events(ticketID: id, limit: 20)
        if !events.isEmpty {
            s += "\n【时间线】最近 \(events.count) 条：\n"
            s += events.map { "\(time($0.at)) \($0.kind) \(clip($0.text, 200))\n" }.joined()
        }
        return s
    }

    /// `授权：inferred · 规则 lint=match,r2=no_match · 版本 V · 来源 t3`（明确请求没有规则段）。mandate 读不出来 → nil。
    static func mandate(_ json: String) -> String? {
        guard let m = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let strength = m["strength"] as? String else { return nil }
        var s = "授权：\(strength)"
        let rules = (m["rules"] as? [String: String]) ?? [:]
        if !rules.isEmpty { s += " · 规则 " + rules.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") }
        if let v = m["policy_version"] as? String, !v.isEmpty { s += " · 版本 \(v)" }
        if let t = m["trigger"] as? String, !t.isEmpty { s += " · 来源 \(t)" }
        return s
    }

    // MARK: - 候选

    static func candidates(_ engine: SuperagentEngine) throws -> String {
        let pending = try engine.store.pendingTriggers()
        guard !pending.isEmpty else { return "没有待决定的候选。\n" }
        var s = "待决定的候选（\(pending.count)）：\n"
        let inferred = pending.contains { $0.strength == .inferred }
        let version = try inferred ? engine.store.policyVersion() : ""
        let rules = try inferred ? engine.store.rules().filter(\.enabled) : []
        for t in pending {
            s += "\n\(t.id) [\(strength(t.strength))] 来源 \(t.source) · 目录 \(t.repo) · \(time(t.createdAt))\n\(t.text)\n"
            switch t.strength {
            case .explicit:
                s += "→ 接单：tfa route accept --trigger \(t.id) --role … --title …；不接：tfa route ignore --trigger \(t.id) --reason …\n"
            case .inferred:
                let verdicts = rules.map { " --rule \($0.id)=match|no_match|requires_design_decision" }.joined()
                s += "→ 研判：tfa eval decide --trigger \(t.id) --version \(version)\(verdicts) --decision accept|ignore [--title …] --reason …\n"
            }
        }
        return s
    }

    // MARK: - 规则

    static func rules(_ engine: SuperagentEngine) throws -> String {
        let mode = try engine.store.acceptMode()
        let enabled = try engine.store.rules().filter(\.enabled)
        var s = "接单模式：\(mode.rawValue)（\(mode.label)）\n规则版本：\(try engine.store.policyVersion())\n"
        guard !enabled.isEmpty else { return s + "启用的规则：没有\n" }
        s += "启用的规则（\(enabled.count)）：\n"
        for r in enabled { s += "\n\(r.id)「\(r.name)」\n\(r.instruction)\n" }
        return s
    }

    // MARK: - 角色

    static func roles(_ engine: SuperagentEngine) throws -> String {
        let roles = try engine.store.roles()
        var s = "现有角色（\(roles.count)，接单时按「接什么」选一个，写 --role 名称；都不合适就先和人对焦，再 tfa role set 新建）：\n"
        for r in roles {
            s += "\n\(r.name)（\(r.traits)）\n接什么：\(r.scope)\n主要行为：\n\(r.behavior)\n"
        }
        return s
    }

    // MARK: - 工具

    static func strength(_ s: Strength) -> String { s == .explicit ? "明确" : "推断" }

    /// 压成一行，超过 n 字截断加「…」。
    static func clip(_ s: String, _ n: Int) -> String {
        let one = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return one.count > n ? String(one.prefix(n)) + "…" : one
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    static func time(_ t: Double) -> String { clock.string(from: Date(timeIntervalSince1970: t)) }
}
