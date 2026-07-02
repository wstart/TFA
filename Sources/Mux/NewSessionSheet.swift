import AppKit
import SwiftUI

/// New-session dialog: the user NAMES the session (required) and picks the FOLDER it starts in — the
/// session binds to that directory via tmux `new-session -c`. Replaces the old "instantly create
/// mux-N", so every local terminal gets an intentional name and a home folder.
struct NewSessionSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var folder = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var taken: Set<String> = []
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
    private var canCreate: Bool { !trimmed.isEmpty && nameError == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("新建会话").font(Theme.Font.headerTitle)

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
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(displayFolder)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(folder)
                    Button("选择…") { pickFolder() }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, Theme.Space.sm).padding(.vertical, Theme.Space.xs)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("创建") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 420)
        .onAppear {
            if name.isEmpty { name = appModel.suggestedLocalSessionName() }
            taken = appModel.takenLocalSessionNames()
            nameFocused = true
        }
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
        appModel.createLocalSession(name: trimmed, startDirectory: folder)
        dismiss()
    }
}
