import SwiftUI
import AppKit

/// Edits the global rules file for Claude Code or Codex. Reuses the Markdown-highlighting
/// `CodeEditor`; saves keep a one-time `.bak`. Missing files are created on first save.
struct ClaudeMdView: View {
    var projectDirectory: URL? = nil
    @State private var platform: AgentPlatform = .claude
    @State private var text = ""
    @State private var savedText = ""
    @State private var dirty = false
    @State private var savedFlash = false
    @State private var existed = true
    @State private var confirmReload = false
    @State private var loadError: String?

    private var url: URL { projectDirectory?.appendingPathComponent(platform.rulesFileName) ?? platform.rulesURL }
    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
                Picker("Agent", selection: Binding(get: { platform }, set: { next in
                    if EditorSafety.mayLeave(url) { platform = next }
                })) {
                    ForEach(AgentPlatform.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(dirty ? "请先保存或重新加载当前改动" : "选择要编辑的 Agent 全局规则")
                Text(url.path.replacingOccurrences(of: home, with: "~"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if !existed {
                    Text("尚未创建 · 保存即新建").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Text("markdown").font(.caption2).foregroundStyle(.tertiary).monospaced()
                if savedFlash {
                    Text("已保存 ✓").font(.caption).foregroundStyle(Theme.Status.positive)
                }
                Button { dirty ? (confirmReload = true) : load() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("从磁盘重新加载")
                Button("保存") { save() }
                    .disabled(!dirty).keyboardShortcut("s", modifiers: .command)
            }
            .padding(Theme.Space.sm)
            Divider()
            if let error = loadError { Text(error).font(.caption).foregroundStyle(Theme.Status.error).padding(8) }
            CodeEditor(text: $text, syntax: .markdown)
                .disabled(loadError != nil)
                .onChange(of: text) {
                    dirty = (text != savedText)
                    EditorSafety.drafts[url] = dirty ? text : nil
                    if dirty { savedFlash = false }
                }
        }
        .background(Theme.canvas)
        .onAppear(perform: load)
        .onChange(of: platform) { load() }
        .alert("放弃未保存的改动？", isPresented: $confirmReload) {
            Button("重新加载", role: .destructive) { EditorSafety.drafts[url] = nil; load() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("当前有未保存的编辑，从磁盘重新加载会丢失这些改动。")
        }
    }

    private func load() {
        loadError = nil
        existed = FileManager.default.fileExists(atPath: url.path)
        do {
            let content = existed ? try String(contentsOf: url, encoding: .utf8) : ""
            savedText = content
            text = EditorSafety.drafts[url] ?? content
            dirty = text != content
        } catch {
            loadError = error.localizedDescription
            savedText = ""; text = ""; dirty = false
        }
        savedFlash = false
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try EditorSafety.save(text, to: url)
            savedText = text
            existed = true
            dirty = false
            savedFlash = true
        } catch {
            EditorSafety.report(error)
        }
    }
}
