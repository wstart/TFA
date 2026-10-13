import Foundation

// MARK: - JSON value

/// Minimal dynamic JSON value used for tool schemas, tool inputs and SSE payloads.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // Integral values encode as integers so schemas/inputs round-trip cleanly.
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    static func parse(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// Compact, key-sorted serialization (stable bytes).
    var compactString: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}

// MARK: - Messages

enum ContentBlock: Codable, Equatable {
    case text(String)
    case thinking(String, signature: String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String, isError: Bool)

    private enum Keys: String, CodingKey {
        case type, text, thinking, signature, id, name, input, tool_use_id, content, is_error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "thinking":
            self = .thinking(try c.decode(String.self, forKey: .thinking),
                             signature: try c.decodeIfPresent(String.self, forKey: .signature) ?? "")
        case "tool_use":
            self = .toolUse(id: try c.decode(String.self, forKey: .id),
                            name: try c.decode(String.self, forKey: .name),
                            input: try c.decodeIfPresent(JSONValue.self, forKey: .input) ?? .object([:]))
        case "tool_result":
            self = .toolResult(toolUseID: try c.decode(String.self, forKey: .tool_use_id),
                               content: try c.decodeIfPresent(String.self, forKey: .content) ?? "",
                               isError: try c.decodeIfPresent(Bool.self, forKey: .is_error) ?? false)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                   debugDescription: "unsupported block type \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t, forKey: .text)
        case .thinking(let t, let sig):
            try c.encode("thinking", forKey: .type)
            try c.encode(t, forKey: .thinking)
            try c.encode(sig, forKey: .signature)
        case .toolUse(let id, let name, let input):
            try c.encode("tool_use", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case .toolResult(let id, let content, let isError):
            try c.encode("tool_result", forKey: .type)
            try c.encode(id, forKey: .tool_use_id)
            try c.encode(content, forKey: .content)
            if isError { try c.encode(true, forKey: .is_error) }
        }
    }
}

struct Message: Codable, Equatable {
    var role: String
    var content: [ContentBlock]
}

struct MessagesRequest: Encodable {
    var model: String
    var max_tokens: Int
    var system: String
    var messages: [Message]
    var tools: [JSONValue]
    var stream: Bool = true
}

struct AssistantMessage: Equatable {
    var content: [ContentBlock]
    var stopReason: String?

    var text: String {
        content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
    }
}

/// Incremental UI notifications produced while a response streams in.
enum StreamEvent: Equatable {
    case text(String)
    case thinking(String)
    case toolUseStart(name: String)
}

// MARK: - Config

struct APIConfig {
    var baseURL: URL
    var model: String
    var authToken: String
    var maxTokens: Int

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> APIConfig {
        func pick(_ keys: String...) -> String? {
            keys.lazy.compactMap { env[$0] }.first { !$0.isEmpty }
        }
        let base = pick("AXIS_BASE_URL", "ANTHROPIC_BASE_URL") ?? "http://127.0.0.1:1234"
        return APIConfig(
            baseURL: URL(string: base) ?? URL(string: "http://127.0.0.1:1234")!,
            model: pick("AXIS_MODEL") ?? "axis_model",
            authToken: pick("AXIS_AUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN") ?? "dummy",
            maxTokens: pick("AXIS_MAX_TOKENS").flatMap(Int.init) ?? 8192
        )
    }
}

// MARK: - Errors

enum APIError: Error, Equatable, CustomStringConvertible {
    case unreachable(String)
    case http(status: Int, body: String)
    case server(String)
    case badResponse(String)

    var description: String {
        switch self {
        case .unreachable(let base):
            return "无法连接 axis-model（\(base)）— 请在 TFA「模型」面板启动服务"
        case .http(let status, let body):
            return "axis-model 返回 HTTP \(status)：\(body)"
        case .server(let msg):
            return "axis-model 推理出错：\(msg)"
        case .badResponse(let msg):
            return "无法解析 axis-model 响应：\(msg)"
        }
    }
}

// MARK: - SSE parsing

enum SSE {
    /// Parses one SSE line. Only `data:` lines carry payloads; each Anthropic event JSON names its
    /// own `type`, so `event:` lines and blank separators can be ignored (robust to line iterators
    /// that drop empty lines).
    static func payload(fromLine line: String) -> JSONValue? {
        guard line.hasPrefix("data:") else { return nil }
        let body = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if body.isEmpty || body == "[DONE]" { return nil }
        return try? JSONValue.parse(body)
    }
}

/// Folds Anthropic stream events into the final assistant message.
struct StreamAssembler {
    private enum Kind { case text, thinking, toolUse(id: String, name: String) }
    private struct Builder {
        var kind: Kind
        var text = ""
        var json = ""
        var signature = ""
    }

    private var builders: [Int: Builder] = [:]
    private(set) var stopReason: String?

    mutating func handle(_ event: JSONValue) throws -> [StreamEvent] {
        switch event["type"]?.stringValue {
        case "content_block_start":
            guard let index = event["index"].flatMap(Self.int), let block = event["content_block"] else { return [] }
            switch block["type"]?.stringValue {
            case "tool_use":
                let name = block["name"]?.stringValue ?? ""
                builders[index] = Builder(kind: .toolUse(id: block["id"]?.stringValue ?? "", name: name))
                return [.toolUseStart(name: name)]
            case "thinking":
                var b = Builder(kind: .thinking)
                b.text = block["thinking"]?.stringValue ?? ""
                builders[index] = b
                return b.text.isEmpty ? [] : [.thinking(b.text)]
            default:
                var b = Builder(kind: .text)
                b.text = block["text"]?.stringValue ?? ""
                builders[index] = b
                return b.text.isEmpty ? [] : [.text(b.text)]
            }
        case "content_block_delta":
            guard let index = event["index"].flatMap(Self.int), let delta = event["delta"],
                  builders[index] != nil else { return [] }
            switch delta["type"]?.stringValue {
            case "text_delta":
                let t = delta["text"]?.stringValue ?? ""
                builders[index]!.text += t
                return [.text(t)]
            case "thinking_delta":
                let t = delta["thinking"]?.stringValue ?? ""
                builders[index]!.text += t
                return [.thinking(t)]
            case "input_json_delta":
                builders[index]!.json += delta["partial_json"]?.stringValue ?? ""
            case "signature_delta":
                builders[index]!.signature += delta["signature"]?.stringValue ?? ""
            default:
                break
            }
            return []
        case "message_delta":
            if let r = event["delta"]?["stop_reason"]?.stringValue { stopReason = r }
            return []
        case "error":
            throw APIError.server(event["error"]?["message"]?.stringValue ?? event.compactString)
        default:
            return []   // message_start, content_block_stop, ping, message_stop
        }
    }

    func finish() throws -> AssistantMessage {
        var blocks: [ContentBlock] = []
        for index in builders.keys.sorted() {
            let b = builders[index]!
            switch b.kind {
            case .text:
                blocks.append(.text(b.text))
            case .thinking:
                blocks.append(.thinking(b.text, signature: b.signature))
            case .toolUse(let id, let name):
                let raw = b.json.trimmingCharacters(in: .whitespacesAndNewlines)
                let input: JSONValue
                do { input = raw.isEmpty ? .object([:]) : try JSONValue.parse(raw) } catch {
                    throw APIError.badResponse("工具 \(name) 的参数不是合法 JSON：\(raw.prefix(200))")
                }
                blocks.append(.toolUse(id: id, name: name, input: input))
            }
        }
        return AssistantMessage(content: blocks, stopReason: stopReason)
    }

    private static func int(_ v: JSONValue) -> Int? {
        if case .number(let n) = v { return Int(n) }
        return nil
    }
}

// MARK: - Transport

protocol Transport {
    func send(_ request: MessagesRequest, onEvent: @escaping (StreamEvent) -> Void) async throws -> AssistantMessage
}

/// Streams `POST /v1/messages` from the axis-model server (Anthropic Messages API).
struct HTTPTransport: Transport {
    let config: APIConfig
    /// Sent as `x-session-id` so the server keeps one prefix-cache slot per conversation.
    let sessionID: String

    private static let urlSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        // The server pings every 5s during long prefills; this is the idle timeout between bytes.
        c.timeoutIntervalForRequest = 600
        c.timeoutIntervalForResource = 3600
        return URLSession(configuration: c)
    }()

    func send(_ request: MessagesRequest, onEvent: @escaping (StreamEvent) -> Void) async throws -> AssistantMessage {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(config.authToken, forHTTPHeaderField: "x-api-key")
        req.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue(sessionID, forHTTPHeaderField: "x-session-id")
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        req.httpBody = try enc.encode(request)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await Self.urlSession.bytes(for: req)
        } catch {
            throw mapTransportError(error)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var data = Data()
            do {
                for try await b in bytes {
                    data.append(b)
                    if data.count >= 4000 { break }
                }
            } catch {}
            throw APIError.http(status: http.statusCode, body: Self.errorSnippet(data))
        }

        var assembler = StreamAssembler()
        do {
            for try await line in bytes.lines {
                guard let payload = SSE.payload(fromLine: line) else { continue }
                for e in try assembler.handle(payload) { onEvent(e) }
            }
        } catch let e as APIError {
            throw e
        } catch {
            throw mapTransportError(error)
        }
        try Task.checkCancellation()
        return try assembler.finish()
    }

    private func mapTransportError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let u = error as? URLError {
            switch u.code {
            case .cancelled:
                return CancellationError()
            case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet,
                 .networkConnectionLost, .dnsLookupFailed, .timedOut:
                return APIError.unreachable(config.baseURL.absoluteString)
            default:
                break
            }
        }
        return APIError.badResponse(error.localizedDescription)
    }

    /// Prefers the `error.message` of an Anthropic-style error body; falls back to raw text.
    static func errorSnippet(_ data: Data) -> String {
        if let v = try? JSONDecoder().decode(JSONValue.self, from: data) {
            if let m = v["error"]?["message"]?.stringValue { return m }
            if let m = v["error"]?.stringValue { return m }
        }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > 300 ? String(s.prefix(300)) + "…" : s
    }
}
