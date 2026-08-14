import SwiftUI

/// 隧道管理面板:SSH 反向转发 + Cloudflare 公网隧道两个分区(状态 + 启停开关 + 编辑/删除)。
struct TunnelsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var editing: SSHTunnel?              // 正在编辑的 SSH 隧道(sheet)
    @State private var showAdd = false                  // 新建 SSH sheet
    @State private var editingCF: CloudflaredTunnel?    // 正在编辑的公网隧道(sheet)
    @State private var showAddCF = false                // 新建公网 sheet

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("已配置的隧道").font(Theme.Font.rowTitle).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button { showAdd = true } label: { Label("SSH 反向隧道…", systemImage: "network") }
                    Button { showAddCF = true } label: { Label("Cloudflare 公网隧道…", systemImage: "globe") }
                } label: {
                    Label("新建隧道", systemImage: "plus")
                }
                .menuStyle(.borderedButton)
                .fixedSize()
            }
            .padding(Theme.Space.lg)

            if appModel.sshTunnels.isEmpty && appModel.cloudflaredTunnels.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        if !appModel.sshTunnels.isEmpty {
                            sectionHeader("SSH 反向转发")
                            ForEach(appModel.sshTunnels) { t in
                                TunnelRow(tunnel: t, onEdit: { editing = t })
                            }
                        }
                        if !appModel.cloudflaredTunnels.isEmpty {
                            sectionHeader("公网隧道(cloudflared)")
                                .padding(.top, appModel.sshTunnels.isEmpty ? 0 : Theme.Space.md)
                            if CloudflaredRunner.binaryPath() == nil {
                                CloudflaredMissingBanner()
                            }
                            ForEach(appModel.cloudflaredTunnels) { t in
                                CloudflaredRow(tunnel: t, onEdit: { editingCF = t })
                            }
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
        .sheet(isPresented: $showAddCF) {
            CloudflaredSheet(existing: nil)
        }
        .sheet(item: $editingCF) { t in
            CloudflaredSheet(existing: t)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.Font.sectionHeader)
            .foregroundStyle(Theme.textTertiary)
            .textCase(.uppercase)
            .padding(.horizontal, Theme.Space.xs)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 40)).foregroundStyle(Theme.brand.opacity(0.5))
            Text("还没有隧道").font(Theme.Font.emptyTitle)
            Text("SSH 反向隧道:把本机端口暴露到你的远程服务器(服务器访问「远程端口」即打到本机)。\nCloudflare 公网隧道:一键把本机端口打通成公网 HTTPS 地址(免账号,随机 trycloudflare.com 域名)。\n点右上角「新建隧道」选择类型;可保存多条、开机自动连、断线自动重连。")
                .font(Theme.Font.emptyBody).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 未安装 cloudflared 时的提示条(装好后开关即可用,无需重启 TFA)。
private struct CloudflaredMissingBanner: View {
    @State private var copied = false
    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.attention)
            Text("未检测到 cloudflared —— 公网隧道需要它。").lineLimit(1)
            Text("brew install cloudflared").font(.caption.monospaced())
                .padding(.horizontal, Theme.Space.sm).padding(.vertical, 2)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            Button(copied ? "已复制" : "复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install cloudflared", forType: .string)
                copied = true
            }
            .controlSize(.small)
            Spacer(minLength: 0)
        }
        .font(Theme.Font.headerMeta)
        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
        .background(Theme.Status.attention.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
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
            TunnelLogView(title: tunnel.name.isEmpty ? tunnel.endpointLabel : tunnel.name,
                          read: { appModel.tunnelRunner.log(tunnel.id) },
                          clear: { appModel.tunnelRunner.clearLog(tunnel.id) })
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
    @Environment(\.dismiss) private var dismiss
    let title: String
    let read: () -> [String]     // body 里读 → @Observable 依赖照常注册,SSH / cloudflared 共用
    let clear: () -> Void

    private var lines: [String] { read() }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack {
                Text("连接日志 · \(title)").font(Theme.Font.headerTitle)
                Spacer()
                Button("清空") { clear() }
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

/// 一行公网隧道:状态点 + 名称/端口 + 公网地址(点开 · 可复制)+ 启用开关 + 日志/编辑/删除。
private struct CloudflaredRow: View {
    @Environment(AppModel.self) private var appModel
    let tunnel: CloudflaredTunnel
    let onEdit: () -> Void
    @State private var confirmDelete = false
    @State private var showLog = false
    @State private var copied = false

    private var state: TunnelState { appModel.cloudflaredRunner.state(tunnel.id) }
    private var publicURL: String? { appModel.cloudflaredRunner.url(tunnel.id) }

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Circle().fill(statusColor).frame(width: 9, height: 9)
                .help(statusText)

            VStack(alignment: .leading, spacing: 3) {
                Text(tunnel.name.isEmpty ? "本地 :\(tunnel.localPort)" : tunnel.name)
                    .font(Theme.Font.rowTitle).lineLimit(1)
                Text("本地 :\(tunnel.localPort) → 公网 · \(statusText)")
                    .font(Theme.Font.rowSubtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 150, alignment: .leading)

            // 公网地址:running 时是可点开的链接 + 复制按钮;其余状态是安静的占位。
            if let url = publicURL {
                HStack(spacing: Theme.Space.xs) {
                    Button {
                        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                    } label: {
                        Text(url.replacingOccurrences(of: "https://", with: ""))
                            .font(.caption.monospaced())
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.borderless)
                    .help("在浏览器打开 \(url)")
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("复制公网地址")
                }
                .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.xs)
                .background(Theme.chrome, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).stroke(Theme.border, lineWidth: 1))
            } else {
                Text(state.isLive ? "分配地址中…" : "启动后分配公网地址")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Spacer(minLength: Theme.Space.sm)

            Toggle("", isOn: Binding(get: { tunnel.enabled },
                                     set: { appModel.setCloudflaredEnabled(tunnel, $0) }))
                .labelsHidden().toggleStyle(.switch)
                .help(tunnel.enabled ? "已启用(开机自动打通)" : "已停用")

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
        .alert("删除公网隧道?", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { appModel.removeCloudflaredTunnel(tunnel) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将停止并删除「\(tunnel.name.isEmpty ? "本地 :\(tunnel.localPort)" : tunnel.name)」。")
        }
        .sheet(isPresented: $showLog) {
            TunnelLogView(title: tunnel.name.isEmpty ? "本地 :\(tunnel.localPort)" : tunnel.name,
                          read: { appModel.cloudflaredRunner.log(tunnel.id) },
                          clear: { appModel.cloudflaredRunner.clearLog(tunnel.id) })
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
        case .running: return "已打通"
        case .connecting: return "连接中…"
        case .retrying(let e): return "重连中:\(e)"
        case .stopped: return "已停止"
        }
    }
}

/// 新建 / 编辑公网隧道:名称 + 本地端口。地址由 cloudflared 每次启动随机分配。
private struct CloudflaredSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let existing: CloudflaredTunnel?

    @State private var name = ""
    @State private var localPort = ""

    private var portValue: Int? {
        Int(localPort.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text(existing == nil ? "新建 Cloudflare 公网隧道" : "编辑公网隧道").font(Theme.Font.headerTitle)
            Text("把本机端口打通成公网 HTTPS 地址(TryCloudflare 免账号)。**拿到链接的任何人都能访问**,地址随机、每次重启会变。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("名称(如 dev-server)", text: $name)
                .textFieldStyle(.roundedBorder).autocorrectionDisabled()
            TextField("本地端口(如 3000)", text: $localPort)
                .textFieldStyle(.roundedBorder).autocorrectionDisabled()

            if CloudflaredRunner.binaryPath() == nil {
                Text("⚠️ 未检测到 cloudflared:先 `brew install cloudflared`(保存配置不受影响)")
                    .font(.caption).foregroundStyle(Theme.Status.attention)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button(existing == nil ? "创建并打通" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(portValue == nil)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 440)
        .onAppear {
            if let t = existing {
                name = t.name
                localPort = "\(t.localPort)"
            }
        }
    }

    private func save() {
        guard let port = portValue else { return }
        if var t = existing {
            t.name = name.trimmingCharacters(in: .whitespaces)
            t.localPort = port
            appModel.updateCloudflaredTunnel(t)
        } else {
            appModel.addCloudflaredTunnel(name: name.trimmingCharacters(in: .whitespaces), localPort: port)
        }
        dismiss()
    }
}
