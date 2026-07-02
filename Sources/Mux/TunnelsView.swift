import SwiftUI

/// SSH 反向端口转发管理面板:隧道列表(状态 + 启停开关 + 编辑/删除)+ 新建/编辑表单。
struct TunnelsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var editing: SSHTunnel?      // 正在编辑的隧道(sheet)
    @State private var showAdd = false          // 新建 sheet

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("已配置的隧道").font(Theme.Font.rowTitle).foregroundStyle(.secondary)
                Spacer()
                Button { showAdd = true } label: { Label("新建隧道", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            .padding(Theme.Space.lg)

            if appModel.sshTunnels.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: Theme.Space.sm) {
                        ForEach(appModel.sshTunnels) { t in
                            TunnelRow(tunnel: t, onEdit: { editing = t })
                        }
                    }
                    .padding(.horizontal, Theme.Space.lg)
                    .padding(.bottom, Theme.Space.lg)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .sheet(isPresented: $showAdd) {
            TunnelSheet(existing: nil)
        }
        .sheet(item: $editing) { t in
            TunnelSheet(existing: t)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 40)).foregroundStyle(Theme.brand.opacity(0.5))
            Text("还没有隧道").font(Theme.Font.emptyTitle)
            Text("把本机端口通过 SSH 反向暴露到远程服务器:\n服务器访问「远程端口」即打到本机「本地端口」。\n点右上角「新建隧道」添加,可保存多条、开机自动连、断线自动重连。")
                .font(Theme.Font.emptyBody).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 一行隧道:状态点 + 名称/端点/转发方向 + 启用开关 + 编辑/删除。
private struct TunnelRow: View {
    @Environment(AppModel.self) private var appModel
    let tunnel: SSHTunnel
    let onEdit: () -> Void
    @State private var confirmDelete = false
    @State private var showLog = false

    private var state: TunnelState { appModel.tunnelRunner.state(tunnel.id) }

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Circle().fill(statusColor).frame(width: 9, height: 9)
                .help(statusText)

            VStack(alignment: .leading, spacing: 3) {
                Text(tunnel.name.isEmpty ? tunnel.endpointLabel : tunnel.name)
                    .font(Theme.Font.rowTitle).lineLimit(1)
                Text("\(tunnel.endpointLabel) · \(statusText)")
                    .font(Theme.Font.rowSubtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 180, alignment: .leading)

            // v2 port-mapping chip: the forward on a quiet cream capsule so it reads as a discrete fact.
            Text(tunnel.forwardLabel)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.xs)
                .background(Theme.chrome, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).stroke(Theme.border, lineWidth: 1))

            Spacer(minLength: Theme.Space.sm)

            Toggle("", isOn: Binding(get: { tunnel.enabled },
                                     set: { appModel.setTunnelEnabled(tunnel, $0) }))
                .labelsHidden().toggleStyle(.switch)
                .help(tunnel.enabled ? "已启用(开机自动连)" : "已停用")

            Button { showLog = true } label: { Image(systemName: "doc.text.magnifyingglass") }
                .buttonStyle(.borderless).help("连接日志")
            Button { onEdit() } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help("编辑")
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("删除")
        }
        .padding(Theme.Space.xl)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))
        .alert("删除隧道?", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { appModel.removeTunnel(tunnel) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将停止并删除「\(tunnel.name.isEmpty ? tunnel.endpointLabel : tunnel.name)」,其保存的密码也会清除。")
        }
        .sheet(isPresented: $showLog) {
            TunnelLogView(tunnel: tunnel)
        }
    }

    private var statusColor: Color {
        switch state {
        case .running: return Theme.Status.positive
        case .connecting: return Theme.brand
        case .retrying: return Theme.Status.attention
        case .stopped: return .secondary
        }
    }
    private var statusText: String {
        switch state {
        case .running: return "已连接"
        case .connecting: return "连接中…"
        case .retrying(let e): return "重连中:\(e)"
        case .stopped: return "已停止"
        }
    }
}

/// 新建 / 编辑隧道表单。`existing == nil` 为新建。
private struct TunnelSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let existing: SSHTunnel?

    @State private var name = ""
    @State private var serverIP = ""
    @State private var account = ""
    @State private var password = ""
    @State private var loginPort = "22"
    @State private var remotePort = ""
    @State private var localPort = ""
    @State private var gatewayPorts = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text(existing == nil ? "新建反向隧道" : "编辑隧道").font(Theme.Font.headerTitle)

            VStack(alignment: .leading, spacing: Theme.Space.md) {
                field("名称(可选)", "给这条隧道起个名", text: $name)
                field("服务器 IP / 域名", "例如 203.0.113.10", text: $serverIP)
                field("账号", "服务器 SSH 用户名", text: $account)
                SecureField(existing == nil ? "密码" : "密码(留空=不改)", text: $password)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: Theme.Space.md) {
                    field("登录端口", "22", text: $loginPort).frame(width: 110)
                    field("远程端口", "服务器上映射出的端口", text: $remotePort)
                    field("本地端口", "本机被转发的端口", text: $localPort)
                }
                Toggle(isOn: $gatewayPorts) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("允许外网访问(GatewayPorts)")
                        Text("远程端口绑定到所有网卡而非仅 loopback;需服务器 sshd 配置 GatewayPorts yes 才生效")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 460)

            Text("ssh -N -R 远程端口:localhost:本地端口 -p 登录端口 账号@IP —— 服务器访问 localhost:远程端口 即打到本机的本地端口。密码保存到 macOS 钥匙串。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button(existing == nil ? "保存并启动" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
        .padding(Theme.Space.xl)
        .onAppear(perform: seed)
    }

    private func field(_ title: String, _ placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private var valid: Bool {
        !serverIP.trimmingCharacters(in: .whitespaces).isEmpty
            && !account.trimmingCharacters(in: .whitespaces).isEmpty
            && port(loginPort) != nil && port(remotePort) != nil && port(localPort) != nil
            && (existing != nil || !password.isEmpty) // 新建必须有密码
    }
    private func port(_ s: String) -> Int? {
        guard let n = Int(s.trimmingCharacters(in: .whitespaces)), (1...65535).contains(n) else { return nil }
        return n
    }

    private func seed() {
        guard let t = existing else { return }
        name = t.name; serverIP = t.serverIP; account = t.account
        loginPort = "\(t.loginPort)"; remotePort = "\(t.remotePort)"; localPort = "\(t.localPort)"
        gatewayPorts = t.gatewayPorts
        // 密码不回填(留空=不改);用户想改时直接输入新值。
    }

    private func save() {
        guard let lp = port(loginPort), let rp = port(remotePort), let llp = port(localPort) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let ip = serverIP.trimmingCharacters(in: .whitespaces)
        let acc = account.trimmingCharacters(in: .whitespaces)
        if var t = existing {
            t.name = trimmedName; t.serverIP = ip; t.account = acc
            t.loginPort = lp; t.remotePort = rp; t.localPort = llp; t.gatewayPorts = gatewayPorts
            appModel.updateTunnel(t, password: password.isEmpty ? nil : password)
        } else {
            appModel.addTunnel(name: trimmedName, serverIP: ip, account: acc, password: password,
                               loginPort: lp, remotePort: rp, localPort: llp, gatewayPorts: gatewayPorts)
        }
        dismiss()
    }
}

/// 连接日志查看:实时显示该隧道的 ssh 输出 + 生命周期事件(最新在下,自动滚到底)。
private struct TunnelLogView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let tunnel: SSHTunnel

    private var lines: [String] { appModel.tunnelRunner.log(tunnel.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack {
                Text("连接日志 · \(tunnel.name.isEmpty ? tunnel.endpointLabel : tunnel.name)").font(Theme.Font.headerTitle)
                Spacer()
                Button("清空") { appModel.tunnelRunner.clearLog(tunnel.id) }
                    .buttonStyle(.borderless).disabled(lines.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if lines.isEmpty {
                            Text("暂无日志。启用隧道后,这里会实时显示连接过程与错误。")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                    }
                    .padding(Theme.Space.sm)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.canvas))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                .onChange(of: lines.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(Theme.Space.xl)
        .frame(width: 640, height: 460)
    }
}
