import Foundation
import SuperagentCore

// 看门狗研判用的模型调用（工作清单第 4 期）。两种后端共用一个协议，按设置选：`cli` = 本机的 `claude -p`（走用户的订阅），
// `api` = Anthropic Messages API（key 在钥匙串）。都在后台跑，不碰主线程；测试注入假后端。

/// 一问一答：system + user → 模型的文字回复。实现自己负责线程和超时。
protocol ModelBackend: Sendable {
    func complete(system: String, user: String) async throws -> String
}

struct ModelBackendError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum ModelBackends {
    /// 按设置选后端（API 的 key 此刻从钥匙串读；没有 key 调用时才报错，面板上另有提示）。
    static func make(_ s: Settings) -> ModelBackend {
        switch s.modelBackend {
        case .cli: return ClaudeCLIBackend(model: s.modelName)
        case .api: return AnthropicAPIBackend(model: s.modelName, apiKey: ModelAPIKeyStore.load())
        case .axisModel: return AxisModelBackend(model: s.modelName)
        }
    }
}

// MARK: - 本机 claude

/// `claude -p --output-format json --model <m> --system-prompt <s> --tools "" <user>`：不开工具、不存会话；
/// 解析 JSON 结果里的 `result`。走用户自己的 Claude Code 登录（订阅或它配置的 key）。
struct ClaudeCLIBackend: ModelBackend {
    var model: String
    /// 可执行文件；nil = 在 PATH 和常见位置里找。
    var executable: String?
    var timeout: Double = 180

    func complete(system: String, user: String) async throws -> String {
        guard let exe = executable ?? Self.locate() else {
            throw ModelBackendError("找不到 claude 命令：装好 Claude Code，或在设置里把模型调用方式改成 Anthropic API")
        }
        let args = ["-p", "--output-format", "json", "--model", model, "--system-prompt", system,
                    "--tools", "", "--no-session-persistence", user]
        let r = try await Self.run(exe, args, timeout: timeout)
        if r.status != 0 {
            let err = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ModelBackendError("claude 退出码 \(r.status)：\(String(err.prefix(300)))")
        }
        return try Self.parseOutput(r.out)
    }

    /// `--output-format json` 的输出是一个对象（`result` 是回复，`is_error` 为真时 `result` 是错误）；老版本或别的格式就原样返回。
    static func parseOutput(_ out: String) throws -> String {
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else { return trimmed }
        if let dict = obj as? [String: Any] { return try result(dict) }
        if let list = obj as? [[String: Any]], let last = list.last(where: { $0["type"] as? String == "result" }) ?? list.last {
            return try result(last)
        }
        return trimmed
    }

    private static func result(_ d: [String: Any]) throws -> String {
        let text = d["result"] as? String ?? ""
        if d["is_error"] as? Bool == true {
            throw ModelBackendError("claude 报错：\(text.isEmpty ? (d["subtype"] as? String ?? "未知") : String(text.prefix(300)))")
        }
        guard !text.isEmpty else { throw ModelBackendError("claude 没有返回内容（\(d["subtype"] as? String ?? "?")）") }
        return text
    }

    /// PATH 上的 claude 优先（用户自己的），再看常见安装位置（App 从 Finder 启动时 PATH 很短）。
    static func locate() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        candidates += [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 跑一个子进程到结束（超时就结束它），在后台队列上等。环境里去掉 TFA_* 和 CLAUDECODE：别让 claude 以为自己是某张工单的执行者。
    static func run(_ exe: String, _ args: [String], timeout: Double) async throws -> (status: Int32, out: String, err: String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                for k in env.keys where k.hasPrefix("TFA_") || k == "CLAUDECODE" { env[k] = nil }
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { return cont.resume(throwing: ModelBackendError("启动 \(exe) 失败：\(error)")) }
                running.add(p)
                let timedOut = Flag()
                let timer = DispatchWorkItem { if p.isRunning { timedOut.set(); p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                // 两个管道分开读：stderr 积满 64K 时 claude 会卡在写上，这边就永远读不完 stdout。
                let errBox = Box()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                group.wait()
                timer.cancel()
                running.remove(p)
                if timedOut.isSet { return cont.resume(throwing: ModelBackendError("claude 超过 \(Int(timeout)) 秒没有回复，已结束它")) }
                cont.resume(returning: (p.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errBox.data, as: UTF8.self)))
            }
        }
    }

    /// 结束所有还在跑的 claude 子进程：App 退出 / 停循环时调（AGENTS.md：子进程要在正常退出和信号退出时回收，不留孤儿）。
    /// 被结束的那次研判报「退出码 15」，看门狗只记时间线。
    static func terminateAll() { running.terminateAll() }

    private static let running = Running()

    /// 正在跑的子进程名单（后台队列上增删，退出路径上读）。
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var procs: [Process] = []
        func add(_ p: Process) { lock.lock(); procs.append(p); lock.unlock() }
        func remove(_ p: Process) { lock.lock(); procs.removeAll { $0 === p }; lock.unlock() }
        func terminateAll() {
            lock.lock(); let list = procs; lock.unlock()
            for p in list where p.isRunning { p.terminate() }
        }
    }

    private final class Box: @unchecked Sendable { var data = Data() }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}

// MARK: - Anthropic API

/// `POST /v1/messages`（anthropic-version 2026-10-21）：system + 一条 user 消息，取回复里的文本块。
/// 不带 thinking / effort 参数：按模型默认，兼容用户填的任何模型名。
struct AnthropicAPIBackend: ModelBackend {
    var model: String
    var apiKey: String?
    var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    var session: URLSession = .shared
    var timeout: Double = 120
    var maxTokens = 1024

    func complete(system: String, user: String) async throws -> String {
        guard let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw ModelBackendError("没有 Anthropic API key：在设置里填入并保存到钥匙串，或把模型调用方式改回本机 claude")
        }
        var req = URLRequest(url: endpoint, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = ["model": model, "max_tokens": maxTokens, "system": system,
                                   "messages": [["role": "user", "content": user]]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = (obj?["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw ModelBackendError("Anthropic API \(status)：\(message)")
        }
        guard let obj else { throw ModelBackendError("Anthropic API 返回的不是 JSON") }
        if obj["stop_reason"] as? String == "refusal" { throw ModelBackendError("模型拒绝了这次研判（refusal）") }
        let text = ((obj["content"] as? [[String: Any]]) ?? [])
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        guard !text.isEmpty else { throw ModelBackendError("Anthropic API 没有返回文本（stop_reason \(obj["stop_reason"] as? String ?? "?")）") }
        return text
    }
}

// MARK: - 本机 axis-model

/// `POST /v1/messages`（默认 `http://127.0.0.1:1234`）：复用本机 axis-model 服务做看门狗研判。
/// 兼容 SSE 流式响应（`axis-model` 默认 `stream: true`）与普通 JSON 响应。
struct AxisModelBackend: ModelBackend {
    var model: String
    var baseURL: URL?
    var authToken: String?
    var session: URLSession = .shared
    var timeout: Double = 120
    var maxTokens = 1024

    func complete(system: String, user: String) async throws -> String {
        let env = ProcessInfo.processInfo.environment
        let resolvedBase: URL = {
            if let baseURL { return baseURL }
            let raw = [env["AXIS_BASE_URL"], env["ANTHROPIC_BASE_URL"]]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "http://127.0.0.1:1234"
            return URL(string: raw) ?? URL(string: "http://127.0.0.1:1234")!
        }()
        let token = authToken
            ?? [env["AXIS_AUTH_TOKEN"], env["ANTHROPIC_AUTH_TOKEN"]]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            ?? "dummy"
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveModel: String = {
            if trimmedModel.isEmpty || trimmedModel == Settings.defaultModel {
                if let envModel = env["AXIS_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines), !envModel.isEmpty {
                    return envModel
                }
                return "axis_model"
            }
            return trimmedModel
        }()

        let endpoint = resolvedBase.path.hasSuffix("/v1/messages")
            ? resolvedBase
            : resolvedBase.appendingPathComponent("v1/messages")
        var req = URLRequest(url: endpoint, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        req.setValue(token, forHTTPHeaderField: "x-api-key")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": effectiveModel,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "stream": true,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let u as URLError {
            switch u.code {
            case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet,
                 .networkConnectionLost, .dnsLookupFailed, .timedOut:
                throw ModelBackendError("无法连接 axis-model（\(resolvedBase.absoluteString)）— 请在「模型」面板启动服务并加载模型")
            default:
                throw ModelBackendError("连接 axis-model 失败：\(u.localizedDescription)")
            }
        } catch {
            throw ModelBackendError("连接 axis-model 失败：\(error.localizedDescription)")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let msg = (obj?["error"] as? [String: Any])?["message"] as? String
                ?? String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ModelBackendError("axis-model HTTP \(status)：\(msg)")
        }

        return try Self.parseResponse(data)
    }

    static func parseResponse(_ data: Data) throws -> String {
        let raw = String(decoding: data, as: UTF8.self)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let obj = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] {
            if let err = (obj["error"] as? [String: Any])?["message"] as? String {
                throw ModelBackendError("axis-model 推理出错：\(err)")
            }
            let text = ((obj["content"] as? [[String: Any]]) ?? [])
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            guard !text.isEmpty else { throw ModelBackendError("axis-model 没有返回文本") }
            return text
        }

        var text = ""
        var sawEvent = false
        for line in raw.components(separatedBy: "\n") {
            let clean = line.hasSuffix("\r") ? String(line.dropLast()) : line
            guard clean.hasPrefix("data:") else { continue }
            let payload = clean.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let event = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            sawEvent = true
            switch type {
            case "error":
                let msg = (event["error"] as? [String: Any])?["message"] as? String ?? payload
                throw ModelBackendError("axis-model 推理出错：\(msg)")
            case "content_block_start":
                if let block = event["content_block"] as? [String: Any],
                   block["type"] as? String == "text",
                   let t = block["text"] as? String {
                    text += t
                }
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let t = delta["text"] as? String {
                    text += t
                }
            default:
                break
            }
        }
        guard sawEvent else { throw ModelBackendError("无法解析 axis-model 响应") }
        guard !text.isEmpty else { throw ModelBackendError("axis-model 没有返回文本") }
        return text
    }
}
