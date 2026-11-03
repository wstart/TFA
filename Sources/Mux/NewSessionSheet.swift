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
    @State private var folder = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var taken: Set<String> = []
    @State private var axis = AxisModelService.shared
    @FocusState private var nameFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Only surfaced once the user has typed something invalid — an empty field just disables 创建.
    private var nameError: String? {
        guard !trimmed.isEmpty else { return nil }
        // tmux uses ':' and '.' to target windows/panes, so they can't appear in a session name.
        if trimmed.contains(":") || trimmed.contains(".") { return "名字不能包含 : 或 ." }
        if taken.contains(trimmed) { return "已有同名会话" }
        return nil
    }
    private var launchesAxisClaude: Bool { appModel.newSessionLaunchesAxisClaude }
    private var canCreate: Bool { !trimmed.isEmpty && nameError == nil && (!launchesAxisClaude || AxisClaude.executablePath != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                KindBadge(kind: launchesAxisClaude ? .axisClaude : .shell)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(launchesAxisClaude ? "启动 axis-claude" : "启动终端").font(Theme.Font.headerTitle)
                    Text(launchesAxisClaude ? "用本机 axis-model 读写代码、执行命令的编程助手。"
                                            : "一个真实的 tmux 会话——关掉 TFA 也不会丢。")
                        .font(Theme.Font.headerMeta)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            if launchesAxisClaude { axisStatus }

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("名字").font(.caption).foregroundStyle(.secondary)
                TextField("会话名字", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($nameFocused)
                if let err = nameError {
                    Text(err).font(.caption).foregroundStyle(Theme.Status.error)
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
            if let project = WorkspaceStore.shared.selected { folder = project.path }
            if name.isEmpty { name = appModel.suggestedLocalSessionName() }
            taken = appModel.takenLocalSessionNames()
            nameFocused = true
        }
        .task { if launchesAxisClaude { await axis.refresh() } }
    }

    /// axis-model state as a small status capsule (dot + text) — creatable either way: axis-claude
    /// itself reports a missing backend, and the user may start the service right after.
    @ViewBuilder private var axisStatus: some View {
        let (tint, text): (Color, String) = {
            if AxisClaude.executablePath == nil { return (Theme.Status.error, "未找到内置的 axis-claude，请重新安装 TFA") }
            if axis.status == .running { return (Theme.Status.positive, "axis-model 运行中 · \(axis.currentModelName)") }
            return (Theme.Status.attention, "axis-model \(axis.status.label) · 可在侧栏「模型」面板启动")
        }()
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
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func create() {
        guard canCreate else { return }
        appModel.createLocalSession(name: trimmed, startDirectory: folder,
                                    command: launchesAxisClaude ? AxisClaude.command(resume: false) : nil)
        dismiss()
    }
}
