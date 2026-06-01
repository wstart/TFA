import SwiftUI
import AppKit

// MARK: - Model

/// A node in the file-explorer tree. Directories carry lazily-built `children`; files have `nil`.
struct FileNode: Identifiable, Hashable {
    var url: URL
    var isDirectory: Bool
    var name: String
    var children: [FileNode]?
    var id: String { url.path }
}

/// Scans / loads / saves files under a root directory (a session's current working directory).
/// Reuses the same conventions as the Skills tree: resolve symlinks, dirs-first sorting, hide
/// dotfiles & `.bak`. Text editing only — binaries are detected and shown read-only.
@MainActor @Observable
final class FileExplorerStore {
    let root: URL
    private(set) var tree: [FileNode] = []

    /// Files larger than this aren't loaded into the editor (treated like a binary blob).
    static let maxEditBytes = 4 << 20 // 4 MB

    init(root: URL) { self.root = root }

    func reload() { tree = Self.children(of: root) }

    static func children(of dir: URL) -> [FileNode] {
        let fm = FileManager.default
        let real = dir.resolvingSymlinksInPath()
        guard let items = try? fm.contentsOfDirectory(at: real, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var nodes: [FileNode] = []
        for item in items {
            let leaf = item.lastPathComponent
            if leaf.hasPrefix(".") || leaf.hasSuffix(".bak") { continue }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &isDir)
            nodes.append(FileNode(url: item, isDirectory: isDir.boolValue, name: leaf,
                                  children: isDir.boolValue ? children(of: item) : nil))
        }
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.lowercased() < $1.name.lowercased()
        }
    }

    func node(id: String) -> FileNode? { Self.find(id, in: tree) }
    private static func find(_ id: String, in nodes: [FileNode]) -> FileNode? {
        for n in nodes {
            if n.id == id { return n }
            if let kids = n.children, let hit = find(id, in: kids) { return hit }
        }
        return nil
    }

    /// Load a file as text, or nil if it's too big / not valid UTF-8 (i.e. binary).
    func textContent(of url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maxEditBytes
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Save text, keeping a one-time `.bak` of the original. Reloads the tree.
    func save(_ content: String, to url: URL) throws {
        let bak = url.appendingPathExtension("bak")
        if !FileManager.default.fileExists(atPath: bak.path),
           let cur = try? String(contentsOf: url, encoding: .utf8) {
            try? cur.write(to: bak, atomically: true, encoding: .utf8)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        reload()
    }

    /// Create an empty file in `dir` (defaults to root). Returns its url. No-op if it exists.
    @discardableResult
    func createFile(named raw: String, in dir: URL? = nil) -> URL? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let url = (dir ?? root).appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        reload()
        return url
    }

    /// Move a file/dir to the Trash (recoverable). Reloads.
    func trash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reload()
    }
}

// MARK: - View (independent window opened from a session's right-click menu)

/// A minimal file manager rooted at a session's current working directory: a directory tree on the
/// left, a syntax-highlighting editor on the right (Markdown / Python / shell / JSON highlighted,
/// everything else plain text). Opened in its own window via `openWindow(value:)`.
struct FileExplorerView: View {
    let root: URL
    @State private var store: FileExplorerStore
    @State private var expanded: Set<String> = []
    @State private var selectedID: String?
    @State private var fileURL: URL?
    @State private var text = ""
    @State private var savedText = ""
    @State private var savedFlash = false
    @State private var isBinary = false
    @State private var showNewFile = false
    @State private var newFileName = ""
    @State private var deleteTarget: FileNode?

    init(root: URL) {
        self.root = root
        _store = State(initialValue: FileExplorerStore(root: root))
    }

    private var dirty: Bool { fileURL != nil && !isBinary && text != savedText }
    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    var body: some View {
        HSplitView {
            // Left: directory tree
            VStack(spacing: 0) {
                if store.tree.isEmpty {
                    ContentUnavailableView("空目录", systemImage: "folder",
                        description: Text(displayRoot)).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(visibleRows()) { vr in rowView(vr) }
                        }
                        .padding(Theme.Space.sm)
                    }
                }
                Divider()
                HStack {
                    Button { newFileName = ""; newFileTarget = nil; showNewFile = true } label: { Image(systemName: "doc.badge.plus") }
                        .buttonStyle(.borderless).help("在根目录新建文件")
                    Button { NSWorkspace.shared.open(root) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("在 Finder 中打开")
                    Spacer()
                    Button { store.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("刷新")
                }
                .padding(Theme.Space.sm)
            }
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 460)

            // Right: editor
            Group {
                if let url = fileURL {
                    VStack(spacing: 0) {
                        HStack(spacing: Theme.Space.sm) {
                            Text(url.lastPathComponent).font(Theme.Font.rowTitle).lineLimit(1)
                            Text(url.path.replacingOccurrences(of: home, with: "~"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if !isBinary {
                                Text(Syntax.from(url).label).font(.caption2).foregroundStyle(.tertiary).monospaced()
                                if savedFlash { Text("已保存 ✓").font(.caption).foregroundStyle(Theme.Status.connected) }
                                Button("保存") { saveCurrent() }
                                    .disabled(!dirty).keyboardShortcut("s", modifiers: .command)
                            }
                        }
                        .padding(Theme.Space.sm)
                        Divider()
                        if isBinary {
                            ContentUnavailableView("无法编辑", systemImage: "doc.questionmark",
                                description: Text("这是二进制或过大的文件，文件管理器只编辑文本（md / py / 脚本 / 配置等）。"))
                        } else {
                            CodeEditor(text: $text, syntax: Syntax.from(url))
                                .onChange(of: text) { if text != savedText { savedFlash = false } }
                        }
                    }
                } else {
                    ContentUnavailableView("选择一个文件", systemImage: "doc.text",
                        description: Text("从左侧选择文件查看 / 编辑。md / py 等会语法高亮，其它按纯文本处理。"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 460)
        .navigationTitle("文件管理器 — \(root.lastPathComponent)")
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { store.reload() }
        .onChange(of: selectedID) { loadSelected() }
        .alert("新建文件", isPresented: $showNewFile) {
            TextField("文件名（如 notes.md）", text: $newFileName)
            Button("创建") {
                if let u = store.createFile(named: newFileName, in: newFileTarget) {
                    if let parent = newFileTarget { expanded.insert(parent.path) }
                    selectedID = u.path
                }
                newFileName = ""; newFileTarget = nil
            }
            Button("取消", role: .cancel) { newFileName = ""; newFileTarget = nil }
        }
        .alert("移到废纸篓?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("移到废纸篓", role: .destructive) {
                if let t = deleteTarget {
                    if let f = fileURL, f.path.hasPrefix(t.url.path) { selectedID = nil }
                    store.trash(t.url)
                }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("将「\(deleteTarget?.name ?? "")」移到废纸篓（可从废纸篓恢复）。")
        }
    }

    private var displayRoot: String { root.path.replacingOccurrences(of: home, with: "~") }

    // MARK: tree rendering (self-drawn — avoids macOS List disclosure quirks)

    private struct VisibleRow: Identifiable { let node: FileNode; let depth: Int; var id: String { node.id } }

    private func visibleRows() -> [VisibleRow] {
        var out: [VisibleRow] = []
        func walk(_ nodes: [FileNode], _ depth: Int) {
            for n in nodes {
                out.append(VisibleRow(node: n, depth: depth))
                if n.isDirectory, expanded.contains(n.id), let kids = n.children { walk(kids, depth + 1) }
            }
        }
        walk(store.tree, 0)
        return out
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    @ViewBuilder private func rowView(_ vr: VisibleRow) -> some View {
        let node = vr.node
        let isSelected = !node.isDirectory && selectedID == node.id
        HStack(spacing: 4) {
            if node.isDirectory {
                Image(systemName: expanded.contains(node.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 12)
            } else {
                Color.clear.frame(width: 12)
            }
            Label(node.name, systemImage: node.isDirectory ? "folder" : Self.icon(for: node.url)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(vr.depth) * 14)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.brand.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { if node.isDirectory { toggle(node.id) } else { selectedID = node.id } }
        .contextMenu {
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            if node.isDirectory {
                Button("新建文件…") { newFileTarget = node.url; newFileName = ""; showNewFile = true }
            }
            Divider()
            Button("移到废纸篓…", role: .destructive) { deleteTarget = node }
        }
    }

    // a directory chosen via a folder's context menu to create a file inside (nil = root)
    @State private var newFileTarget: URL?

    private static func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": return "doc.richtext"
        case "py":             return "chevron.left.forwardslash.chevron.right"
        case "sh", "bash", "zsh": return "terminal"
        case "json", "yaml", "yml", "toml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "pdf": return "photo"
        default:               return "doc.text"
        }
    }

    private func loadSelected() {
        guard let id = selectedID, let node = store.node(id: id), !node.isDirectory else {
            fileURL = nil; text = ""; savedText = ""; isBinary = false; savedFlash = false; return
        }
        fileURL = node.url
        if let content = store.textContent(of: node.url) {
            text = content; savedText = content; isBinary = false
        } else {
            text = ""; savedText = ""; isBinary = true
        }
        savedFlash = false
    }

    private func saveCurrent() {
        guard let url = fileURL, !isBinary else { return }
        do { try store.save(text, to: url); savedText = text; savedFlash = true } catch { NSSound.beep() }
    }
}
