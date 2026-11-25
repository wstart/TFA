import Foundation

/// 从自然语言句子、单链接或 `tfa://` 唤起链接中解析组织接入信息（服务器根地址 + 一次性邀请码 + 可选邮箱）。
public struct OrgJoinSpec: Equatable, Sendable {
    public var serverURL: String
    public var inviteCode: String
    public var email: String?

    public init(serverURL: String, inviteCode: String, email: String? = nil) {
        self.serverURL = serverURL
        self.inviteCode = inviteCode
        self.email = email
    }

    /// 解析任意自然语言或接入链接。
    /// 支持：
    /// - `tfa://join?url=http://127.0.0.1:5180/join/Ab3x9Kp2`
    /// - `tfa://join?s=http://127.0.0.1:5180&c=Ab3x9Kp2&e=a@b.com`
    /// - `http://127.0.0.1:5180/join/Ab3x9Kp2`（带或不带 `?email=...`）
    /// - `把这台 TFA 接入公司：http://127.0.0.1:5180/join/Ab3x9Kp2。`
    /// - `接入 http://127.0.0.1:5180 邀请码 Ab3x9Kp2 邮箱 a@b.com`
    /// - `http://127.0.0.1:5180 Ab3x9Kp2`
    public static func parse(_ input: String) -> OrgJoinSpec? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. 优先识别 `tfa://` 唤起链接
        for raw in matches(of: #"(?i)tfa://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+"#, in: trimmed) {
            let cleaned = stripTrailingPunctuation(raw)
            if let spec = parseTFAScheme(cleaned, fallbackContext: trimmed) {
                return spec
            }
        }

        // 2. 识别 `http://` 或 `https://` 链接
        let httpMatches = matches(of: #"(?i)https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+"#, in: trimmed)
        for raw in httpMatches {
            let cleaned = stripTrailingPunctuation(raw)
            if let spec = parseHTTPURL(cleaned, fullText: trimmed, rawMatch: raw) {
                return spec
            }
        }

        // 3. 兜底识别省略协议头的 `host[:port]/join/<code>` 形式（如 `127.0.0.1:5180/join/Ab3x9Kp2`）
        let bareMatches = matches(
            of: #"(?i)(?:localhost|(?:\d{1,3}\.){3}\d{1,3}|[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+)(?::\d+)?/join/[A-Za-z0-9\-._~%]+(?:\?[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]*)?"#,
            in: trimmed
        )
        for raw in bareMatches {
            let cleaned = stripTrailingPunctuation(raw)
            if let spec = parseHTTPURL("http://" + cleaned, fullText: trimmed, rawMatch: raw) {
                return spec
            }
        }

        return nil
    }

    /// 规范化服务器根地址为 `http(s)://host[:port]`（去掉末尾斜杠与路径）。
    public static func normalizeServerURL(_ s: String) -> URL? {
        var text = stripTrailingPunctuation(s.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard let u = URL(string: text),
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty else { return nil }
        let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return URL(string: "\(scheme)://\(formattedHost)" + (u.port.map { ":\($0)" } ?? ""))
    }

    /// 节点 token 走 `Authorization: Bearer` 明文：公网地址必须 https（协议 §6）。本机和局域网可以 http：
    /// loopback、localhost、*.local、10/8、172.16/12、192.168/16、169.254/16，以及 IPv6 的 ::1、fe80::/10、fc00::/7。
    public static func needsTLS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") { return false }
        if host.contains(":") { return !(host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")) }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return true }
        if parts[0] == 127 || parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254)
            || (parts[0] == 172 && (16...31).contains(parts[1])) { return false }
        return true
    }

    // MARK: - 内部解析

    private static func parseTFAScheme(_ raw: String, fallbackContext: String) -> OrgJoinSpec? {
        guard let comps = URLComponents(string: raw),
              comps.scheme?.lowercased() == "tfa" else { return nil }
        let host = comps.host?.lowercased() ?? ""
        guard host == "join" || host == "org-join" || host.isEmpty else { return nil }

        let items = comps.queryItems ?? []
        func q(_ names: String...) -> String? {
            for name in names {
                if let val = items.first(where: { $0.name.lowercased() == name })?.value {
                    let clean = stripTrailingPunctuation(val.trimmingCharacters(in: .whitespacesAndNewlines))
                    if !clean.isEmpty { return clean }
                }
            }
            return nil
        }

        let explicitEmail = normalizeEmail(q("e", "email"))

        // 形式 A：tfa://join?url=http://127.0.0.1:5180/join/Ab3x9Kp2
        if let innerURL = q("url", "u", "link") {
            if var spec = parseHTTPURL(innerURL, fullText: innerURL, rawMatch: innerURL) {
                if spec.email == nil { spec.email = explicitEmail ?? extractEmail(in: fallbackContext) }
                return spec
            }
            // 若 innerURL 只是服务器根地址且 query 里另有 code
            if let base = normalizeServerURL(innerURL),
               let code = cleanCode(q("c", "code", "invite", "invite_code")) {
                return OrgJoinSpec(serverURL: base.absoluteString, inviteCode: code,
                                   email: explicitEmail ?? extractEmail(in: fallbackContext))
            }
        }

        // 形式 B：tfa://join?s=http://127.0.0.1:5180&c=Ab3x9Kp2&e=a@b.com
        if let serverRaw = q("s", "server", "server_url", "host"),
           let base = normalizeServerURL(serverRaw),
           let code = cleanCode(q("c", "code", "invite", "invite_code")) {
            return OrgJoinSpec(serverURL: base.absoluteString, inviteCode: code, email: explicitEmail)
        }

        // 形式 C：tfa://join/http://127.0.0.1:5180/join/Ab3x9Kp2
        let pathTrimmed = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !pathTrimmed.isEmpty, var spec = parseHTTPURL(pathTrimmed, fullText: pathTrimmed, rawMatch: pathTrimmed) {
            if spec.email == nil { spec.email = explicitEmail }
            return spec
        }

        return nil
    }

    private static func parseHTTPURL(_ cleanedURL: String, fullText: String, rawMatch: String) -> OrgJoinSpec? {
        guard let base = normalizeServerURL(cleanedURL),
              let comps = URLComponents(string: cleanedURL) else { return nil }

        let items = comps.queryItems ?? []
        func q(_ names: String...) -> String? {
            for name in names {
                if let val = items.first(where: { $0.name.lowercased() == name })?.value {
                    let clean = stripTrailingPunctuation(val.trimmingCharacters(in: .whitespacesAndNewlines))
                    if !clean.isEmpty { return clean }
                }
            }
            return nil
        }

        let remainder = fullText.replacingOccurrences(of: rawMatch, with: " ")
        let email = normalizeEmail(q("email", "e")) ?? extractEmail(in: remainder)

        // 1. 路径包含 `/join/<invite_code>`
        let segments = comps.path.split(separator: "/").map(String.init)
        if let joinIdx = segments.firstIndex(where: { $0.lowercased() == "join" }),
           joinIdx + 1 < segments.count,
           let code = cleanCode(segments[joinIdx + 1]) {
            return OrgJoinSpec(serverURL: base.absoluteString, inviteCode: code, email: email)
        }

        // 2. query 中直接携带邀请码
        if let code = cleanCode(q("invite_code", "invite", "code", "c")) {
            return OrgJoinSpec(serverURL: base.absoluteString, inviteCode: code, email: email)
        }

        // 3. 自然语言分段形式：从 URL 之外的剩余文本提取邀请码
        if let code = extractInviteCode(from: remainder, email: email) {
            return OrgJoinSpec(serverURL: base.absoluteString, inviteCode: code, email: email)
        }

        return nil
    }

    private static func extractInviteCode(from text: String, email: String?) -> String? {
        var cleaned = text
        if let email {
            cleaned = cleaned.replacingOccurrences(of: email, with: " ", options: [.caseInsensitive])
        }

        // 优先找显式标签后的邀请码（如 `邀请码 Ab3x9Kp2`、`邀请码：Ab3x9Kp2`、`invite=Ab3x9Kp2`）
        let labeledPattern = #"(?i)(?:邀请码|邀请口令|口令|invite[_\-]?code|invite|code)\s*[:：=]?\s*([A-Za-z0-9_\-]{2,})"#
        if let first = firstCapture(of: labeledPattern, in: cleaned), let code = cleanCode(first) {
            return code
        }

        // 否则按空白/标点提取剩余 ASCII token（排除明显非邀请码的英文词）
        let ignored: Set<String> = [
            "tfa", "org", "join", "http", "https", "server", "url",
            "email", "mail", "code", "invite", "invite_code", "app", "mac", "cli"
        ]
        let tokens = matches(of: #"[A-Za-z0-9_\-]{2,}"#, in: cleaned)
        for token in tokens {
            let lower = token.lowercased()
            if ignored.contains(lower) { continue }
            if let code = cleanCode(token) {
                return code
            }
        }
        return nil
    }

    private static func extractEmail(in text: String) -> String? {
        for candidate in matches(of: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, in: text) {
            if let email = normalizeEmail(candidate) {
                return email
            }
        }
        return nil
    }

    private static func normalizeEmail(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = stripTrailingPunctuation(raw.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased()
        guard cleaned.contains("@"), !cleaned.hasPrefix("@"), !cleaned.hasSuffix("@") else { return nil }
        return cleaned
    }

    private static func cleanCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let decoded = raw.removingPercentEncoding ?? raw
        let cleaned = stripSurroundingPunctuation(decoded.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleaned.isEmpty else { return nil }
        return cleaned
    }

    /// 去除 URL 或值末尾常黏连的中英文标点。
    private static func stripTrailingPunctuation(_ s: String) -> String {
        let trailing = CharacterSet(charactersIn: "。！？，；：、）》」』】〉”’\"'.,;!?)>]`")
        var result = s
        while let last = result.unicodeScalars.last, trailing.contains(last) {
            result.unicodeScalars.removeLast()
        }
        return result
    }

    private static func stripSurroundingPunctuation(_ s: String) -> String {
        let edges = CharacterSet(charactersIn: "。！？，；：、（）《》「」『』【】〈〉“”‘’\"'.,;!?()[]<>`")
        return s.trimmingCharacters(in: edges)
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: range).map { ns.substring(with: $0.range) }
    }

    private static func firstCapture(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}
