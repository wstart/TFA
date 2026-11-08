import AppKit
import SwiftUI
import SuperagentCore

// 组织（工作清单第 3 期，需求文档 §10）在界面上的三块：清单设置里的「组织」卡（注册 / 断开 / 状态）、任务卡元信息里的
// 「组织 · T-128」chip、任务卡底部的同步行。只用 `Theme` 的三种状态色；琥珀只给需要你（注意事项 A-04）。

// MARK: - 设置里的「组织」卡

struct OrgCard: View {
    @Environment(AppModel.self) private var appModel
    @State private var server = ""
    @State private var email = ""
    @State private var invite = ""
    @State private var error: String?
    @State private var registering = false
    @State private var confirmDisconnect = false

    var body: some View {
        let org = appModel.superagent.org
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: org.registered ? (org.online ? "checkmark.circle.fill" : "wifi.slash") : "building.2")
                    .foregroundStyle(org.registered && org.online ? Theme.Status.positive : Theme.Status.neutral)
                VStack(alignment: .leading, spacing: 2) {
                    Text("组织").font(Theme.Font.rowTitle)
                    Text(org.statusText).font(Theme.Font.rowSubtitle).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer()
                if org.registered {
                    Button("立即同步") { Task { await org.syncNow() } }
                        .controlSize(.small).disabled(org.busy)
                    Button("断开…") { confirmDisconnect = true }
                        .controlSize(.small)
                        .help("本机删掉节点 token，不再同步")
                }
            }
            if org.settings.isRegistered {
                details(org)
            }
            if !org.registered {
                form(org)
            }
            Text(org.registered
                 ? "派给你的组织任务会出现在清单里；只上传阶段、勾选、结果摘要和需要人的事，终端、命令全文和环境变量留在本机。"
                 : "管理员在组织的「节点」页按成员生成邀请码（一次性，24 小时内有效）。不注册照常单机用。")
                .font(.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .saCard()
        .onAppear {
            server = org.settings.serverURL
            email = org.settings.email
        }
        .alert("断开组织？", isPresented: $confirmDisconnect) {
            Button("断开", role: .destructive) { org.disconnect() }
            Button("保留", role: .cancel) {}
        } message: {
            Text("本机删掉节点 token，不再同步；已经在清单里的组织任务留着，之后的改动留在本机。服务端的吊销由管理员做。")
        }
    }

    private func details(_ org: OrgSync) -> some View {
        let s = org.settings
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            detail("服务器", s.serverURL + (s.workspace.isEmpty ? "" : " · \(s.workspace)"))
            detail("邮箱", s.email)
            detail("节点", s.nodeID ?? "—", mono: true)
            detail("最近同步", s.lastSync.map { OrgSyncText.ago($0, now: Date()) } ?? "还没同步")
            detail("待上传", org.pendingTotal == 0 ? "没有" : "\(org.pendingTotal) 条" + (org.online ? "" : "（连上后补发）"))
        }
    }

    private func detail(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text(title).font(.caption).foregroundStyle(Theme.textTertiary).frame(width: 56, alignment: .leading)
            Text(value).font(mono ? .caption.monospaced() : .caption).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func form(_ org: OrgSync) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .top, spacing: Theme.Space.lg) {
                Field(title: "服务器地址") {
                    TextField("http://127.0.0.1:5180", text: $server).textFieldStyle(.roundedBorder)
                }
                Field(title: "我的邮箱") {
                    TextField("name@example.com", text: $email).textFieldStyle(.roundedBorder)
                }
            }
            HStack(alignment: .bottom, spacing: Theme.Space.lg) {
                Field(title: "邀请码") {
                    TextField("管理员给的一次性邀请码", text: $invite).textFieldStyle(.roundedBorder)
                }
                Button(registering ? "注册中…" : "注册") {
                    registering = true
                    error = nil
                    Task {
                        error = await org.register(server: server, email: email, invite: invite)
                        registering = false
                        if error == nil { invite = "" }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(registering || server.trimmingCharacters(in: .whitespaces).isEmpty || !email.contains("@")
                          || invite.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Theme.Status.error).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 任务卡：「组织 · T-128」chip（可点开服务端任务页）

struct OrgTaskChip: View {
    let task: WorkTask

    var body: some View {
        if let origin = task.origin, let id = task.originID {
            Button {
                if let url = URL(string: "\(origin)/tasks/\(id)") { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "building.2").font(.system(size: 10))
                    Text("组织 · T-\(id)").font(.system(size: 12, design: .monospaced))
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Theme.chrome, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("在组织的工作清单里打开 T-\(id)")
            .accessibilityLabel("组织任务 T-\(id)，在浏览器里打开")
        }
    }
}

// MARK: - 任务卡：同步行（§9.2）

/// 「已同步到组织 · 2 分钟前 / 待上传 N 条 / 离线 / 冲突 / 待领取」。待领取带「领取」；冲突带「本地为准 / 服务端为准」。
struct OrgSyncRow: View {
    @Environment(AppModel.self) private var appModel
    let view: TaskView

    var body: some View {
        if view.task.origin != nil {
            let org = appModel.superagent.org
            let line = OrgSyncText.line(view, pending: org.pending[view.id] ?? 0, registered: org.registered, online: org.online, now: Date())
            HStack(spacing: Theme.Space.md) {
                Image(systemName: line.symbol).foregroundStyle(Theme.textTertiary).frame(width: 16)
                    .accessibilityHidden(true)
                Text(line.text).font(.callout).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.md)
                if view.task.syncState == "claimable" {
                    Button("领取") { Task { await org.claim(view.id) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(org.busy || !org.registered)
                        .help("向组织领取这个任务；别人先领走了就从这里消失")
                } else if let c = view.syncConflicts.first {
                    OrgConflictButtons(taskID: view.id, conflict: c)
                }
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.md)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.border, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("同步：\(line.text)")
        }
    }
}

/// 同步冲突的两个按钮（需要你条和同步行共用）：一次定一项（第一处），定完下一处顶上来。
struct OrgConflictButtons: View {
    @Environment(AppModel.self) private var appModel
    let taskID: Int64
    let conflict: SyncConflict

    var body: some View {
        let org = appModel.superagent.org
        Button("本地为准（\(conflict.local.label)）") { org.resolveConflict(taskID, ord: conflict.ord, useServer: false) }
            .help("第 \(conflict.ord) 项按本机的状态，并上传")
        Button("服务端为准（\(conflict.server.label)）") { org.resolveConflict(taskID, ord: conflict.ord, useServer: true) }
            .buttonStyle(.borderedProminent)
            .help("第 \(conflict.ord) 项按组织那边的状态")
    }
}

/// 同步行的文案（纯函数，可测）。
enum OrgSyncText {
    static func line(_ v: TaskView, pending: Int, registered: Bool, online: Bool, now: Date) -> (symbol: String, text: String) {
        let t = v.task
        if t.syncState == "claimable" { return ("tray.and.arrow.down", "组织的待领取任务 · 领取后才在这里推进") }
        if let c = v.syncConflicts.first {
            return ("exclamationmark.arrow.triangle.2.circlepath",
                    "同步冲突" + (v.syncConflicts.count > 1 ? "（\(v.syncConflicts.count) 处）" : "") + "：" + c.line)
        }
        if !registered { return ("bolt.slash", "已断开组织 · 改动留在本机") }
        if pending > 0 { return online ? ("arrow.up.circle", "待上传 \(pending) 条") : ("wifi.slash", "离线 · 待上传 \(pending) 条，连上后补发") }
        let synced = t.syncedAt.map { "已同步到组织 · " + ago($0, now: now) } ?? "还没同步"
        if t.isOpen, t.stageKind == .review { return ("checkmark.icloud", synced + " · 等组织负责人通过") }
        return (t.syncedAt == nil ? "icloud" : "checkmark.icloud", synced + (online ? "" : " · 现在离线"))
    }

    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"; return f }()

    /// 「刚刚」「3 分钟前」「2 小时前」，更早显示日期。
    static func ago(_ t: Double, now: Date) -> String {
        let d = now.timeIntervalSince1970 - t
        if d < 60 { return "刚刚" }
        if d < 3600 { return "\(Int(d / 60)) 分钟前" }
        if d < 86400 { return "\(Int(d / 3600)) 小时前" }
        return day.string(from: Date(timeIntervalSince1970: t))
    }
}
