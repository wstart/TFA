import Foundation

// 角色（docs/superagent-roles.md）：主管接单时先选角色，TFA 按角色的定义生成（启动）它的 Agent，再交单。
// 常驻角色一个终端串行处理所有单；每单角色每张单一个终端 + 目录。

extension SuperagentEngine {
    // MARK: - 角色管理（主管和人对焦后 / 人在面板里）

    /// 新建或更新一个角色。内置角色只能改「接什么」和主要行为（运行方式固定），且只能由人改。
    /// 有打开的工单时不能改运行方式（常驻 / 每单），否则这些单找不到自己的终端。
    @discardableResult
    public func setRole(_ role: Role, by: String = "你") throws -> (role: Role, created: Bool) {
        var r = role
        r.name = r.name.trimmingCharacters(in: .whitespacesAndNewlines)
        r.scope = r.scope.trimmingCharacters(in: .whitespacesAndNewlines)
        r.behavior = r.behavior.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.name.isEmpty else { throw SuperagentError("缺少角色名称") }
        guard r.name.count <= Role.maxName else { throw SuperagentError("角色名称最多 \(Role.maxName) 字") }
        guard r.name.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".:#/\\'\""))) == nil else {
            throw SuperagentError("角色名称不能含空格和 . : # / \\ ' \"")
        }
        guard !r.scope.isEmpty else { throw SuperagentError("角色「\(r.name)」缺少「接什么」（主管据此选角色）") }
        guard r.scope.count <= Role.maxScope else { throw SuperagentError("「接什么」最多 \(Role.maxScope) 字") }
        guard !r.behavior.isEmpty else { throw SuperagentError("角色「\(r.name)」缺少主要行为") }
        guard r.behavior.count <= Role.maxBehavior else { throw SuperagentError("主要行为最多 \(Role.maxBehavior) 字") }
        return try store.transaction {
            var list = try store.roles()
            let old = list.firstIndex { $0.name == r.name }
            if let builtin = Role.builtins.first(where: { $0.name == r.name }) {
                guard by == "你" else { throw SuperagentError("「\(r.name)」是内置角色，只能由人在 TFA 主管面板里改") }
                r.standing = builtin.standing; r.edits = builtin.edits; r.review = builtin.review
            }
            if let i = old, list[i].standing != r.standing,
               try store.tickets(endedLimit: 0).contains(where: { $0.role == r.name }) {
                throw SuperagentError("角色「\(r.name)」还有打开的工单，不能改成\(r.standing ? "常驻" : "每单一个终端")")
            }
            if let i = old { list[i] = r } else { list.append(r) }
            try store.saveRoles(list)
            try store.log(nil, "role", "\(by)\(old == nil ? "新建" : "更新")了角色「\(r.name)」（\(r.traits)）", at: now())
            return (r, old == nil)
        }
    }

    /// 删除一个新建的角色（内置角色和还有打开工单的角色不能删）。
    public func deleteRole(_ name: String, by: String = "你") throws {
        guard !Role.builtins.contains(where: { $0.name == name }) else { throw SuperagentError("「\(name)」是内置角色，不能删除") }
        try store.transaction {
            var list = try store.roles()
            guard list.contains(where: { $0.name == name }) else { throw SuperagentError("没有角色「\(name)」") }
            guard try !store.tickets(endedLimit: 0).contains(where: { $0.role == name }) else {
                throw SuperagentError("角色「\(name)」还有打开的工单，结束后再删")
            }
            list.removeAll { $0.name == name }
            try store.saveRoles(list)
            try store.log(nil, "role", "\(by)删除了角色「\(name)」", at: now())
        }
    }

    func requireRole(_ name: String) throws -> Role {
        guard let r = try store.role(name) else {
            let names = try store.roles().map(\.name).joined(separator: "、")
            throw SuperagentError("没有角色「\(name)」。现有角色：\(names)（tfa read roles 查看各自接什么）；"
                                  + "都不合适就先和人对焦，再用 tfa role set 新建")
        }
        return r
    }

    // MARK: - 常驻 Agent 的排队

    /// 这张单的执行者此刻正在做它（本轮开始了、还没给出结论或问题）。
    func inTurn(_ v: TicketView) -> Bool {
        let t = v.ticket
        return t.isOpen && v.assignment?.state == .running && t.attention == nil && t.deliveryError == nil
            && (t.reportState == nil || t.reportState == .progress)
    }

    /// 常驻角色的 Agent 正在做别的单：新单和跟进先排队，一次只交给它一张。
    public func agentBusy(_ role: String, excluding id: Int64) throws -> Bool {
        try store.tickets(endedLimit: 0).filter { $0.id != id && $0.role == role }.map(view).contains(where: inTurn)
    }

    /// 常驻终端里没写 `--ticket` 时，它此刻在做的那张单（恰好一张才算）。
    public func currentTicket(agent role: String) throws -> Int64? {
        let current = try store.tickets(endedLimit: 0).filter { $0.role == role }.map(view).filter(inTurn)
        return current.count == 1 ? current[0].id : nil
    }
}
