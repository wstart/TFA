import SwiftUI

/// Detail pane for a group's Markdown note — "what this group is for / what each session does".
/// Opened by clicking a group's NAME in the sidebar (the chevron still folds). Edited inline (编辑)
/// or read rendered (预览), saved to ~/.tfa/group-notes/<id>.md via AppModel.
struct GroupNoteView: View {
    @Environment(AppModel.self) private var appModel
    let groupID: UUID

    @State private var text = ""
    @State private var dirty = false
    @State private var savedFlash = false
    @State private var preview = true

    private var groupName: String { appModel.groups.first { $0.id == groupID }?.name ?? "分组" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if preview {
                MarkdownPreviewView(text: text)
            } else {
                CodeEditor(text: $text, syntax: .markdown)
                    .onChange(of: text) { dirty = true; savedFlash = false }
            }
        }
        .background(Theme.canvas)
        .onAppear { load() }
        .onChange(of: groupID) { load() }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            Button { appModel.toggleSidebar() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.borderless)
                .help(appModel.sidebarCollapsed ? "显示侧栏 (⌘\\)" : "隐藏侧栏 (⌘\\)")
                .accessibilityLabel(appModel.sidebarCollapsed ? "显示侧栏" : "隐藏侧栏")

            Image(systemName: "folder").foregroundStyle(Theme.brand)
            Text(groupName).font(Theme.Font.headerTitle).lineLimit(1)
            Text("分组说明").font(Theme.Font.headerMeta).foregroundStyle(.tertiary)
            Spacer()
            Picker("", selection: $preview) {
                Text("编辑").tag(false)
                Text("预览").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if savedFlash { Text("已保存 ✓").font(.caption).foregroundStyle(Theme.Status.positive) }
            Button("保存") { save() }
                .disabled(!dirty || preview)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.canvas)
    }

    private func load() {
        text = appModel.groupNote(groupID)
        dirty = false; savedFlash = false; preview = true
    }

    private func save() {
        appModel.saveGroupNote(groupID, text)
        dirty = false; savedFlash = true
    }
}
