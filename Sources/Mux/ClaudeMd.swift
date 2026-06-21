import SwiftUI
import AppKit

/// A dedicated editor for the global user rules file `~/.claude/CLAUDE.md` — the instructions Claude
/// Code applies to every project. Reuses the Markdown-highlighting `CodeEditor`; saves keep a one-time
/// `.bak`. The file is created on first save if it doesn't exist yet.
struct ClaudeMdView: View {
    @State private var text = ""
    @State private var savedText = ""
    @State private var dirty = false
    @State private var savedFlash = false
    @State private var existed = true
    @State private var confirmReload = false

    private var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/CLAUDE.md")
    }
    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
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
            CodeEditor(text: $text, syntax: .markdown)
                .onChange(of: text) {
                    dirty = (text != savedText)
                    if dirty { savedFlash = false }
                }
        }
        .background(Theme.canvas)
        .onAppear(perform: load)
        .alert("放弃未保存的改动？", isPresented: $confirmReload) {
            Button("重新加载", role: .destructive) { load() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("当前有未保存的编辑，从磁盘重新加载会丢失这些改动。")
        }
    }

    private func load() {
        existed = FileManager.default.fileExists(atPath: url.path)
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        savedText = content
        text = content
        dirty = false
        savedFlash = false
    }

    private func save() {
        // Keep a one-time backup of the original before the first overwrite.
        let bak = url.appendingPathExtension("bak")
        if existed, !FileManager.default.fileExists(atPath: bak.path),
           let cur = try? String(contentsOf: url, encoding: .utf8) {
            try? cur.write(to: bak, atomically: true, encoding: .utf8)
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            savedText = text
            existed = true
            dirty = false
            savedFlash = true
        } catch {
            NSSound.beep()
        }
    }
}
