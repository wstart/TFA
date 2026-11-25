import AppKit
import SwiftUI
import SuperagentCore

// 组织（工作清单第 3 期，需求文档 §10）在界面上的三块：清单设置里的「组织」卡（注册 / 断开 / 状态）、任务卡元信息里的
// 「组织 · T-128」chip、任务卡底部的同步行。只用 `Theme` 的三种状态色；琥珀只给需要你（注意事项 A-04）。

// MARK: - 设置里的「组织」卡

struct OrgCard: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phrase = ""
    @State private var showManual = false
    @State private var server = ""
    @State private var email = ""
    @State private var invite = ""
    @State private var error: String?
    @State private var joinedBanner: String?
    @State private var joinedClearTask: Task<Void, Never>?
    @State private var registering = false
    @State private var syncingNow = false
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
                    Button(syncingNow || org.busy ? "同步中…" : "立即同步") {
                        syncingNow = true
                        Task {
                            await org.syncNow()
                            syncingNow = false
                        }
                    }
                    .controlSize(.small)
                    .disabled(org.busy || syncingNow)
                    Button("断开…") { confirmDisconnect = true }
                        .controlSize(.small)
                        .help("清除本机接入凭证，停止与组织同步（本地已有任务保留）")
                }
            }
            if let notice = joinedBanner {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Status.positive)
                    Text(notice)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.Status.positive)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, Theme.Space.sm)
                .background(Theme.Status.positive.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .transition(Theme.Motion.reveal(edge: .top, reduceMotion: reduceMotion))
            }
            if org.settings.isRegistered {
                details(org)
            }
            if !org.registered {
                form(org)
            }
            Text(org.registered
                 ? "派给你的组织任务会出现在清单里；只上传阶段、勾选、结果摘要和需要人的事，终端、命令全文和环境变量留在本机。"
                 : "在组织侧复制「一句话接入」链接粘贴到上方即可（也可直接发给主管终端说一句话接入）。不注册照常单机用。")
                .font(.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .animation(Theme.Motion.value(Theme.Motion.panel, reduceMotion: reduceMotion), value: joinedBanner)
        .saCard()
        .onAppear {
            server = org.settings.serverURL
            email = org.settings.email
        }
        .onDisappear {
            joinedClearTask?.cancel()
            joinedClearTask = nil
        }
        .alert("断开组织？", isPresented: $confirmDisconnect) {
            Button("断开", role: .destructive) { org.disconnect() }
            Button("保留", role: .cancel) {}
        } message: {
            Text("清除本机接入凭证，停止与组织同步（本地已有任务保留）。服务端的节点吊销由管理员处理。")
        }
    }

    private func showJoinedBanner() {
        joinedClearTask?.cancel()
        Theme.Motion.run(Theme.Motion.panel, reduceMotion: reduceMotion) {
            joinedBanner = "已接入组织，正在同步任务…"
        }
        joinedClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            Theme.Motion.run(Theme.Motion.echo, reduceMotion: reduceMotion) {
                joinedBanner = nil
            }
            joinedClearTask = nil
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

    private func joinByPhrase(_ org: OrgSync) {
        let input = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !registering, !input.isEmpty else { return }
        registering = true
        error = nil
        Task {
            error = await org.register(phrase: input)
            registering = false
            if error == nil {
                phrase = ""
                server = org.settings.serverURL
                email = org.settings.email
                showJoinedBanner()
            }
        }
    }

    private func form(_ org: OrgSync) -> some View {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let emailInvalid = !trimmedEmail.isEmpty && !trimmedEmail.contains("@")
        let missingFields = server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let manualInvalid = registering || missingFields || emailInvalid

        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            Field(title: "一句话快速接入") {
                HStack(spacing: Theme.Space.sm) {
                    TextField("粘贴一句话指令或接入链接（如 http://127.0.0.1:5180/join/...）", text: $phrase)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { joinByPhrase(org) }
                    Button(registering ? "接入中…" : "一键接入") {
                        joinByPhrase(org)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(registering || phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Button {
                Theme.Motion.run(Theme.Motion.panel, reduceMotion: reduceMotion) { showManual.toggle() }
            } label: {
                Text(showManual ? "手动填写服务器 / 邮箱 / 邀请码 ▴" : "手动填写服务器 / 邮箱 / 邀请码 ▾")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showManual {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    HStack(alignment: .top, spacing: Theme.Space.lg) {
                        Field(title: "服务器地址") {
                            TextField("http://127.0.0.1:5180", text: $server).textFieldStyle(.roundedBorder)
                        }
                        Field(title: "我的邮箱（可选）") {
                            TextField("留空将按邀请码自动识别", text: $email).textFieldStyle(.roundedBorder)
                        }
                    }
                    HStack(alignment: .bottom, spacing: Theme.Space.md) {
                        Field(title: "邀请码") {
                            TextField("管理员给的一次性邀请码", text: $invite).textFieldStyle(.roundedBorder)
                        }
                        if manualInvalid && !registering {
                            Text(emailInvalid ? "邮箱格式不正确" : "请填写服务器地址和邀请码")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .padding(.bottom, 5)
                        }
                        Button(registering ? "注册中…" : "注册") {
                            registering = true
                            error = nil
                            Task {
                                error = await org.register(server: server, email: email, invite: invite)
                                registering = false
                                if error == nil {
                                    invite = ""
                                    email = org.settings.email
                                    showJoinedBanner()
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manualInvalid)
                    }
                }
                .padding(.top, Theme.Space.xs)
                .transition(Theme.Motion.reveal(edge: .top, reduceMotion: reduceMotion))
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(Theme.Status.error).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 任务来源归属徽标（本地项目 vs 线上组织）

struct TaskOriginBadge: View {
    @Environment(AppModel.self) private var appModel
    let task: WorkTask
    var showProject: Bool = false
    var hasOnlineContext: Bool = true
    var multipleLocalProjects: Bool = true

    enum DisplayMode: Equatable {
        case hidden
        case online(label: String, help: String)
        case localWithOrigin(label: String, help: String)
        case localProjectOnly(name: String, help: String)
    }

    static func resolve(
        task: WorkTask,
        orgName: String,
        showProject: Bool = false,
        hasOnlineContext: Bool = true,
        multipleLocalProjects: Bool = true
    ) -> DisplayMode {
        if let origin = task.origin, !origin.isEmpty {
            let suffix = (task.originID ?? "").isEmpty ? "" : " · T-\(task.originID!)"
            let label = "线上 · " + (orgName.isEmpty ? "组织" : orgName) + suffix
            return .online(label: label, help: "线上组织任务：\(orgName.isEmpty ? origin : orgName)\(suffix)")
        }
        let trimmedScope = task.scope.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawProj = trimmedScope.isEmpty ? "" : (trimmedScope as NSString).lastPathComponent
        let proj = rawProj == "/" ? "" : rawProj
        if !hasOnlineContext {
            if showProject && multipleLocalProjects && !proj.isEmpty {
                return .localProjectOnly(name: proj, help: "项目目录：\(trimmedScope)")
            }
            return .hidden
        }
        let label = showProject && !proj.isEmpty ? "本地 · \(proj)" : "本地项目"
        return .localWithOrigin(label: label, help: trimmedScope.isEmpty ? "本地项目任务" : "本地项目：\(trimmedScope)")
    }

    var body: some View {
        let orgName = (task.origin.flatMap { $0.isEmpty ? nil : appModel.superagent.org.organizationName(for: $0) }) ?? ""
        switch Self.resolve(
            task: task,
            orgName: orgName,
            showProject: showProject,
            hasOnlineContext: hasOnlineContext,
            multipleLocalProjects: multipleLocalProjects
        ) {
        case .hidden:
            EmptyView()
        case .online(let label, let help):
            HStack(spacing: 3.5) {
                Image(systemName: "globe")
                    .font(.system(size: 9.5))
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2.5)
            .background(Theme.accent.opacity(0.28), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.borderStrong.opacity(0.65), lineWidth: 1))
            .help(help)
            .accessibilityLabel(label)
        case .localWithOrigin(let label, let help):
            HStack(spacing: 3.5) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 9.5))
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2.5)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 5))
            .help(help)
            .accessibilityLabel(label)
        case .localProjectOnly(let name, let help):
            HStack(spacing: 3.5) {
                Image(systemName: "folder")
                    .font(.system(size: 9.5))
                Text(name)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2.5)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 5))
            .help(help)
            .accessibilityLabel("项目 \(name)")
        }
    }
}

// MARK: - 任务卡：「线上 · 组织名 · T-128」chip（可点开服务端任务页） / 「本地项目」辨识 chip

struct OrgTaskChip: View {
    @Environment(AppModel.self) private var appModel
    let task: WorkTask

    var body: some View {
        if let origin = task.origin, !origin.isEmpty {
            let orgName = appModel.superagent.org.organizationName(for: origin)
            let displayOrg = orgName.isEmpty ? "组织" : orgName
            if let id = task.originID, !id.isEmpty {
                let label = "线上 · \(displayOrg) · T-\(id)"
                Button {
                    if let url = URL(string: "\(origin)/tasks/\(id)") { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "globe").font(.system(size: 10.5))
                        Text(label).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.accent.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.borderStrong.opacity(0.65), lineWidth: 1))
                }
                .buttonStyle(PaperPressButtonStyle())
                .help("在组织「\(displayOrg)」的工作清单里打开 T-\(id)")
                .accessibilityLabel("\(label)，在浏览器里打开")
            } else {
                let label = "线上 · \(displayOrg)"
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "globe").font(.system(size: 10.5))
                    Text(label).font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Theme.accent.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.borderStrong.opacity(0.65), lineWidth: 1))
                .accessibilityLabel(label)
            }
        } else {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "laptopcomputer").font(.system(size: 10))
                Text("本地项目").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            .help(task.scope.isEmpty ? "本地项目任务" : "本地项目任务：\(task.scope)")
            .accessibilityLabel("本地项目")
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
