import Foundation
import Security
import SuperagentCore

/// 组织节点 token 的 Keychain 存取（与 `Mux/Keychain.swift` 中的 `OrgTokenStore` 100% 一致：
/// `kSecClassGenericPassword`, `kSecAttrService = "com.tfa.org"`, `kSecAttrAccount = nodeID`,
/// `kSecAttrAccessibleAfterFirstUnlock`）。测试可替换闭包以避免触碰本机真实 Keychain。
enum OrgCLITokenStore {
    private static let service = "com.tfa.org"

    static var load: (_ nodeID: String) -> String? = keychainLoad
    static var save: (_ token: String, _ nodeID: String) -> Void = keychainSave
    static var delete: (_ nodeID: String) -> Void = keychainDelete

    static func resetToKeychain() {
        load = keychainLoad
        save = keychainSave
        delete = keychainDelete
    }

    static func keychainLoad(nodeID: String) -> String? {
        var query = baseQuery(nodeID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    static func keychainSave(_ token: String, nodeID: String) {
        SecItemDelete(baseQuery(nodeID) as CFDictionary)
        guard !token.isEmpty else { return }
        var add = baseQuery(nodeID)
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func keychainDelete(nodeID: String) {
        SecItemDelete(baseQuery(nodeID) as CFDictionary)
    }

    private static func baseQuery(_ nodeID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: nodeID]
    }
}

/// `tfa org …`：接入、查看或断开公司组织协同。
/// 允许人及主管终端（`TFA_ROLE=router`）执行，只拒绝执行终端（`requireNotWorker`）。
extension TFACommand {
    static func org(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        guard let sub = args.first else {
            throw CLIError.usage("缺少子命令（join / status / leave）", command: "org")
        }
        let rest = args.dropFirst()
        switch sub {
        case "join": return try orgJoin(rest, c)
        case "status": return try orgStatus(rest, c)
        case "leave": return try orgLeave(rest, c)
        case "-h", "--help": throw CLIError.help("org")
        default: throw CLIError.usage("未知的子命令 org \(sub)", command: "org")
        }
    }

    private static func orgJoin(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "org join"
        if args.count == 1, args.first == "-h" || args.first == "--help" {
            throw CLIError.help(cmd)
        }
        try c.requireNotWorker("org")

        let raw: String
        if args.isEmpty || (args.count == 1 && args.first == "-") {
            raw = c.piped() ?? ""
        } else {
            raw = args.joined(separator: " ")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError.usage("缺少组织接入链接或一句话指令（也可从 stdin 传入）", command: cmd)
        }
        guard let spec = OrgJoinSpec.parse(trimmed) else {
            throw CLIError.usage("没在输入里找到组织接入链接或「服务器地址 + 邀请码」", command: cmd)
        }
        guard let base = OrgJoinSpec.normalizeServerURL(spec.serverURL) else {
            throw SuperagentError("服务器地址格式不对：\(spec.serverURL)")
        }
        if OrgJoinSpec.needsTLS(base) {
            throw SuperagentError("公网地址要用 https://（节点 token 不能明文传）；本机或局域网才可以用 http://")
        }

        let engine = try c.engine()
        let store = engine.store
        let existing = try store.orgSettings()
        let nodeID = existing.nodeID ?? String(UUID().uuidString.lowercased().prefix(8))
        let roles = ((try? store.roles()) ?? Role.builtins).map(\.name)
        let machine = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

        let body = OrgRegisterBody(
            inviteCode: spec.inviteCode,
            nodeId: nodeID,
            personEmail: spec.email ?? "",
            roles: roles,
            version: "0.25.0",
            machine: machine
        )
        let response = try registerOrgNode(base: base, body: body)
        guard !response.token.isEmpty else {
            throw SuperagentError("服务端没有返回节点 token")
        }

        OrgCLITokenStore.save(response.token, nodeID)

        let resolvedEmail = [response.person?.email, spec.email]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first { !$0.isEmpty } ?? ""
        let wsName = (response.workspace?.name?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 } ?? ""

        var s = OrgSettings()
        s.serverURL = base.absoluteString
        s.email = resolvedEmail
        s.nodeID = nodeID
        s.workspace = wsName
        if s.serverURL == existing.serverURL {
            s.taskCursor = existing.taskCursor
            s.eventCursor = existing.eventCursor
        }
        try store.saveOrgSettings(s)

        let displayWS = wsName.isEmpty ? (base.host ?? base.absoluteString) : wsName
        let displayEmail = resolvedEmail.isEmpty ? "未设置" : resolvedEmail
        return Outcome(out: "已接入组织「\(displayWS)」（节点 \(nodeID)，账号 \(displayEmail)），正在后台同步任务。\n", changed: true)
    }

    private static func orgStatus(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "org status"
        let a = try parse(args, cmd)
        try noPositional(a, cmd)
        try c.requireNotWorker("org")

        let s = try c.engine().store.orgSettings()
        guard s.isRegistered, let nodeID = s.nodeID else {
            return Outcome(out: "未接入组织。\n")
        }
        let connected = OrgCLITokenStore.load(nodeID) != nil
        var lines = [
            "组织状态：\(connected ? "已接入" : "已断开（本地凭据已清除）")",
            "组织：\(s.workspace.isEmpty ? "（未命名）" : s.workspace)",
            "服务器：\(s.serverURL)",
            "邮箱：\(s.email.isEmpty ? "（未设置）" : s.email)",
            "节点：\(nodeID)",
        ]
        if let lastSync = s.lastSync {
            lines.append("最近同步：\(OrgTime.string(lastSync))")
        }
        return Outcome(out: lines.joined(separator: "\n") + "\n")
    }

    private static func orgLeave(_ args: ArraySlice<String>, _ c: Context) throws -> Outcome {
        let cmd = "org leave"
        let a = try parse(args, cmd)
        try noPositional(a, cmd)
        try c.requireNotWorker("org")

        let s = try c.engine().store.orgSettings()
        guard s.isRegistered, let nodeID = s.nodeID else {
            return Outcome(out: "当前未接入组织。\n")
        }
        let hadToken = OrgCLITokenStore.load(nodeID) != nil
        OrgCLITokenStore.delete(nodeID)
        guard hadToken else {
            return Outcome(out: "当前已断开组织连接（节点 \(nodeID)）。\n")
        }
        return Outcome(out: "已断开组织连接（节点 \(nodeID)，本地历史任务已保留）。\n", changed: true)
    }

    // MARK: - HTTP 注册

    private struct OrgRegisterBody: Encodable {
        var inviteCode: String
        var nodeId: String
        var personEmail: String
        var roles: [String]
        var version: String
        var machine: String
    }

    private struct OrgRegisterWorkspace: Decodable {
        var id: LenientString?
        var name: String?
    }

    private struct OrgRegisterPerson: Decodable {
        var email: String?
        var name: String?
    }

    private struct OrgRegisterResponse: Decodable {
        var token: String
        var workspace: OrgRegisterWorkspace?
        var person: OrgRegisterPerson?
    }

    private struct OrgAPIErrorBody: Decodable {
        var error: String?
        var message: String?
    }

    private static func registerOrgNode(base: URL, body: OrgRegisterBody) throws -> OrgRegisterResponse {
        guard let url = URL(string: base.absoluteString + "/api/v1/nodes/register") else {
            throw SuperagentError("服务器地址不对：\(base.absoluteString)")
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(body.nodeId, forHTTPHeaderField: "X-TFA-Node")
        req.httpBody = try OrgTaskDTO.encoder.encode(body)

        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let sem = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?

        session.dataTask(with: req) { data, resp, err in
            resultData = data
            resultResponse = resp
            resultError = err
            sem.signal()
        }.resume()

        let waitResult = sem.wait(timeout: .now() + 20)
        if waitResult == .timedOut {
            throw SuperagentError("连接组织服务器超时：\(base.absoluteString)")
        }
        if let err = resultError {
            throw SuperagentError("连不上组织服务器：\(err.localizedDescription)")
        }
        guard let http = resultResponse as? HTTPURLResponse else {
            throw SuperagentError("组织服务器没有返回 HTTP 响应")
        }
        let data = resultData ?? Data()
        guard (200..<300).contains(http.statusCode) else {
            let apiErr = try? JSONDecoder().decode(OrgAPIErrorBody.self, from: data)
            let code = apiErr?.error ?? "http_\(http.statusCode)"
            let msg = apiErr?.message ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw SuperagentError("接入失败（\(http.statusCode) \(code)）：\(msg)")
        }
        do {
            return try OrgTaskDTO.decoder.decode(OrgRegisterResponse.self, from: data)
        } catch {
            throw SuperagentError("组织服务器响应解析失败：\(error)")
        }
    }
}
