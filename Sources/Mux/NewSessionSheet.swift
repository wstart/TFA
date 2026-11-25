import AppKit
import SwiftUI

/// New-session dialog: the user NAMES the session (required) and picks the FOLDER it starts in — the
/// session binds to that directory via tmux `new-session -c`. Replaces the old "instantly create
/// mux-N", so every local terminal gets an intentional name and a home folder. Launches either a
/// plain shell or axis-claude (chosen from the sidebar「+」menu).
struct NewSessionSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var lastAutoName = ""
    @State private var nameEditedByUser = false
    @State private var folder = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var taken: Set<String> = []
    @State private var axis = AxisModelService.shared
    @FocusState private var nameFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// tmux uses ':' and '.' to target windows/panes; automatically normalize them instead of blocking the user.
    private var normalizedName: String { Self.normalizeSessionName(trimmed) }

    private static func normalizeSessionName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "：")
            .replacingOccurrences(of: ".", with: "·")
    }

    /// Only surfaced when the normalized name collides with an existing local session.
    private var nameError: String? {
        guard !normalizedName.isEmpty else { return nil }
        if taken.contains(normalizedName) { return "已有同名会话「\(normalizedName)」" }
        return nil
    }
    private var launchKind: AppModel.NewSessionLaunchKind { appModel.newSessionLaunchKind }
    private var launchAvailable: Bool {
        switch launchKind {
        case .shell: return true
        case .axisClaude: return AxisClaude.executablePath != nil
        case .antigravity: return AgentPlatform.antigravity.executablePath != nil
        }
    }
    private var canCreate: Bool { !normalizedName.isEmpty && nameError == nil && launchAvailable }

    private var badgeKind: TerminalKind {
        switch launchKind {
        case .shell: return .shell
        case .axisClaude: return .axisClaude
        case .antigravity: return .antigravity
        }
    }
    private var headerTitle: String {
        switch launchKind {
        case .shell: return "启动终端"
        case .axisClaude: return "启动 axis-claude"
        case .antigravity: return "启动 Antigravity"
        }
    }
    private var headerSubtitle: String {
        switch launchKind {
        case .shell: return "一个真实的 tmux 会话——关掉 TFA 也不会丢。"
        case .axisClaude: return "用本机 axis-model 读写代码、执行命令的编程助手。"
        case .antigravity: return "用 Google Antigravity (agy) 读写代码、执行命令的编程助手。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                KindBadge(kind: badgeKind)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(headerTitle).font(Theme.Font.headerTitle)
                    Text(headerSubtitle)
                        .font(Theme.Font.headerMeta)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            if launchKind == .axisClaude { axisStatus }
            if launchKind == .antigravity { agyStatus }

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("名字").font(.caption).foregroundStyle(.secondary)
                TextField("会话名字", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($nameFocused)
                    .onChange(of: name) { _, new in
                        if new != lastAutoName {
                            nameEditedByUser = true
                        }
                    }
                if let err = nameError {
                    Text(err).font(.caption).foregroundStyle(Theme.Status.error)
                } else if !trimmed.isEmpty && normalizedName != trimmed {
                    Text("将自动保存为会话名「\(normalizedName)」")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("起始文件夹").font(.caption).foregroundStyle(.secondary)
                // The whole row picks a folder (not just the small button).
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.textTertiary)
                    Text(displayFolder)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(folder)
                    Text("选择…").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, Theme.Space.md).padding(.vertical, 7)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture { pickFolder() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("起始文件夹 \(displayFolder)，点击选择")
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("创建") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 420)
        .onAppear {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if let project = WorkspaceStore.shared.selected, Self.directoryExists(project.path) {
                folder = project.path
            } else if let cwd = appModel.selectedConnection?.currentPath,
                      !cwd.isEmpty, cwd != home, Self.directoryExists(cwd) {
                folder = cwd
            }
            taken = appModel.takenLocalSessionNames()
            if name.isEmpty {
                let suggested = suggestedName(forFolder: folder)
                lastAutoName = suggested
                name = suggested
                nameEditedByUser = false
            }
            nameFocused = true
        }
        .task { if launchKind == .axisClaude { await axis.refresh() } }
    }

    /// axis-model state as a small status capsule (dot + text) — creatable either way: axis-claude
    /// itself reports a missing backend, and the user may start the service right after.
    @ViewBuilder private var axisStatus: some View {
        let (tint, text): (Color, String) = {
            if AxisClaude.executablePath == nil { return (Theme.Status.error, "未找到内置的 axis-claude，请重新安装 TFA") }
            if axis.status == .running { return (Theme.Status.positive, "axis-model 运行中 · \(axis.currentModelName)") }
            return (Theme.Status.attention, "axis-model \(axis.status.label) · 可在侧栏「模型」面板启动")
        }()
        statusCapsule(tint: tint, text: text)
    }

    @ViewBuilder private var agyStatus: some View {
        let (tint, text): (Color, String) = {
            if let path = AgentPlatform.antigravity.executablePath {
                return (Theme.Status.positive, "agy 已就绪 · \((path as NSString).abbreviatingWithTildeInPath)")
            }
            return (Theme.Status.error, "未找到 agy 命令 · 请先安装 Antigravity CLI")
        }()
        statusCapsule(tint: tint, text: text)
    }

    private func statusCapsule(tint: Color, text: String) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 5)
        .background(tint.opacity(0.10), in: Capsule())
    }

    private var displayFolder: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if folder == home { return "~" }
        if folder.hasPrefix(home + "/") { return "~" + folder.dropFirst(home.count) }
        return folder
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择新会话的起始文件夹"
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let url = panel.url {
            folder = url.path
            if !nameEditedByUser || trimmed.isEmpty {
                let suggested = suggestedName(forFolder: url.path)
                lastAutoName = suggested
                name = suggested
                nameEditedByUser = false
            }
        }
    }

    private func suggestedName(forFolder path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let rawBase = (path == home || path.isEmpty) ? "" : URL(fileURLWithPath: path).lastPathComponent
        let base = Self.normalizeSessionName(rawBase)
        guard !base.isEmpty, base != "/" else {
            return appModel.suggestedLocalSessionName()
        }
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    private static func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func create() {
        guard canCreate else { return }
        let cmd: String? = {
            switch launchKind {
            case .shell: return nil
            case .axisClaude: return AxisClaude.command(resume: false)
            case .antigravity: return AgentPlatform.agyCommand(resume: false)
            }
        }()
        appModel.createLocalSession(name: normalizedName, startDirectory: folder, command: cmd)
        dismiss()
    }
}
