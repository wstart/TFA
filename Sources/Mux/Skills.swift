import SwiftUI
import AppKit

// MARK: - Model

/// A node in a skill's directory tree. The top-level nodes are skill folders (each carrying its
/// SKILL.md name/description as `subtitle`); their descendants are the real files & subfolders.
struct SkillNode: Identifiable, Hashable {
    var url: URL
    var isDirectory: Bool
    var name: String          // display name (skill name for roots, file name otherwise)
    var subtitle: String?     // SKILL.md description — only set on skill roots
    var isRoot: Bool          // true for a top-level skill folder
    var children: [SkillNode]?
    var id: String { url.path }
}

// MARK: - Store

/// Scans / loads / saves skills under ~/.claude/skills. Each skill is a *folder* (`<name>/SKILL.md`
/// + any extra scripts/docs); we expose the whole folder as a browsable tree.
@MainActor @Observable
final class SkillsStore {
    private(set) var tree: [SkillNode] = []

    var skillsDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills") }

    var isEmpty: Bool { tree.isEmpty }

    func reload() {
        let fm = FileManager.default
        var roots: [SkillNode] = []
        if let subs = try? fm.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for sub in subs {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let md = sub.appendingPathComponent("SKILL.md")
                guard fm.fileExists(atPath: md.path) else { continue }   // a skill must have SKILL.md
                let (name, desc) = Self.frontmatter(md, fallback: sub.lastPathComponent)
                roots.append(SkillNode(url: sub, isDirectory: true, name: name, subtitle: desc,
                                       isRoot: true, children: Self.children(of: sub)))
            }
        }
        tree = roots.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Recursively list a directory: folders first, then files, alpha; hide dotfiles and `.bak` backups.
    /// Resolves symlinks first — many gstack skills are symlinks, and `contentsOfDirectory` returns
    /// nothing for an unresolved symlink URL (which made those folders look un-expandable).
    private static func children(of dir: URL, depth: Int = 0) -> [SkillNode] {
        let fm = FileManager.default
        // Depth cap: a skill is a small folder; bounding recursion guards against symlink cycles
        // inside a (resolved) skill dir blowing the stack — same failure mode the file manager hit.
        guard depth < 12 else { return [] }
        let real = dir.resolvingSymlinksInPath()
        guard let items = try? fm.contentsOfDirectory(at: real, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var nodes: [SkillNode] = []
        for item in items {
            let leaf = item.lastPathComponent
            if leaf.hasPrefix(".") || leaf.hasSuffix(".bak") { continue }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &isDir)
            if isDir.boolValue {
                nodes.append(SkillNode(url: item, isDirectory: true, name: leaf, subtitle: nil,
                                       isRoot: false, children: children(of: item, depth: depth + 1)))
            } else {
                nodes.append(SkillNode(url: item, isDirectory: false, name: leaf, subtitle: nil,
                                       isRoot: false, children: nil))
            }
        }
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.lowercased() < $1.name.lowercased()
        }
    }

    /// Find a node anywhere in the tree by its id (path).
    func node(id: String) -> SkillNode? { Self.find(id, in: tree) }
    private static func find(_ id: String, in nodes: [SkillNode]) -> SkillNode? {
        for n in nodes {
            if n.id == id { return n }
            if let kids = n.children, let hit = find(id, in: kids) { return hit }
        }
        return nil
    }

    /// Parse `name:` / `description:` from the leading `--- … ---` YAML frontmatter.
    static func frontmatter(_ url: URL, fallback: String) -> (String, String) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (fallback, "") }
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (fallback, "") }
        var name = fallback, desc = ""
        var i = 1
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == "---" { break }
            if t.hasPrefix("name:") {
                name = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("description:") {
                let v = String(t.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                if v.isEmpty || v == "|" || v == ">" {           // block scalar → take next line
                    if i + 1 < lines.count { desc = lines[i + 1].trimmingCharacters(in: .whitespaces) }
                } else { desc = v }
            }
            i += 1
        }
        return (name.isEmpty ? fallback : name, desc)
    }

    func content(of url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// Save a file, keeping a one-time `.bak` of the original.
    func save(_ content: String, to url: URL) throws {
        let bak = url.appendingPathExtension("bak")
        if !FileManager.default.fileExists(atPath: bak.path),
           let cur = try? String(contentsOf: url, encoding: .utf8) {
            try? cur.write(to: bak, atomically: true, encoding: .utf8)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        reload()
    }

    /// Create a new skill folder + template SKILL.md. Returns the SKILL.md url to select.
    @discardableResult
    func create(name raw: String) -> URL? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let dir = skillsDir.appendingPathComponent(name)
        let md = dir.appendingPathComponent("SKILL.md")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: md.path) {
            let template = "---\nname: \(name)\ndescription: \n---\n\n# \(name)\n\n"
            try? template.write(to: md, atomically: true, encoding: .utf8)
        }
        reload()
        return md
    }

    /// Delete the whole skill directory.
    func delete(_ node: SkillNode) {
        try? FileManager.default.removeItem(at: node.url)
        reload()
    }
}

// MARK: - View

/// The Skills manager (detail pane): a directory tree on the left (skill folders → their files),
/// a syntax-highlighting editor on the right.
struct SkillsView: View {
    @State private var store = SkillsStore()
    @State private var selectedID: String?
    @State private var expanded: Set<String> = []
    @State private var fileURL: URL?
    @State private var text = ""
    @State private var dirty = false
    @State private var savedFlash = false
    @State private var showNew = false
    @State private var newName = ""
    @State private var deleteTarget: SkillNode?
    @State private var search = ""
    /// Markdown files (SKILL.md) default to the rendered preview (tables read clearly); toggle to edit.
    @State private var preview = false

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    var body: some View {
        HSplitView {
            // Left: search + skill directory tree
            VStack(spacing: 0) {
                if !store.isEmpty { searchField; Divider() }
                if store.isEmpty {
                    ContentUnavailableView("没有 Skill", systemImage: "wand.and.stars",
                        description: Text("~/.claude/skills 下没有带 SKILL.md 的目录。点下方「新建」创建一个。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let rows = visibleRows()
                    if rows.isEmpty {
                        ContentUnavailableView("没有匹配的 Skill", systemImage: "magnifyingglass",
                            description: Text("没有名称或描述包含「\(search)」的 skill。"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, vr in
                                    rowView(vr, isFirst: idx == 0)
                                }
                            }
                            .padding(.vertical, Theme.Space.sm)
                            .padding(.horizontal, Theme.Space.sm)
                        }
                    }
                }
                Divider()
                HStack {
                    Button { newName = ""; showNew = true } label: { Label("新建", systemImage: "plus") }
                        .buttonStyle(.borderless)
                    Spacer()
                    Text("\(store.tree.count) 个 skill").font(.caption).foregroundStyle(.tertiary)
                    Button { store.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("刷新")
                }
                .padding(Theme.Space.sm)
            }
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)

            // Right: editor
            Group {
                if let url = fileURL {
                    let isMarkdown = Syntax.from(url) == .markdown
                    VStack(spacing: 0) {
                        HStack(spacing: Theme.Space.sm) {
                            Text(url.path.replacingOccurrences(of: home, with: "~"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            // Markdown gets an 编辑 / 预览 switch (preview renders tables as aligned grids).
                            if isMarkdown {
                                Picker("", selection: $preview) {
                                    Text("编辑").tag(false)
                                    Text("预览").tag(true)
                                }
                                .pickerStyle(.segmented).labelsHidden().fixedSize()
                            }
                            Text(Syntax.from(url).label).font(.caption2)
                                .foregroundStyle(.tertiary).monospaced()
                            if savedFlash {
                                Text("已保存 ✓").font(.caption).foregroundStyle(Theme.Status.positive)
                            }
                            Button("保存") { saveCurrent() }
                                .disabled(!dirty || (isMarkdown && preview))
                                .keyboardShortcut("s", modifiers: .command)
                        }
                        .padding(Theme.Space.sm)
                        Divider()
                        if isMarkdown && preview {
                            MarkdownPreviewView(text: text)
                        } else {
                            CodeEditor(text: $text, syntax: Syntax.from(url))
                                .onChange(of: text) { dirty = true; savedFlash = false }
                        }
                    }
                } else {
                    ContentUnavailableView("选择一个文件", systemImage: "doc.text",
                        description: Text("从左侧目录树选择文件查看 / 编辑。\nSKILL.md 是每个 skill 的主文件。"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
        .onAppear { store.reload() }
        .onChange(of: selectedID) { loadSelected() }
        .alert("新建 Skill", isPresented: $showNew) {
            TextField("名称（小写连字符，如 my-skill）", text: $newName)
            Button("创建") {
                if let md = store.create(name: newName) {
                    expanded.insert(md.deletingLastPathComponent().path)   // reveal its SKILL.md
                    selectedID = md.path
                }
                newName = ""
            }
            Button("取消", role: .cancel) { newName = "" }
        }
        .alert("删除 Skill?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("删除", role: .destructive) {
                if let t = deleteTarget {
                    if let f = fileURL, f.path.hasPrefix(t.url.path) { selectedID = nil }
                    store.delete(t)
                }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("将删除整个 skill 目录，不可恢复（编辑过的文件留有 .bak 备份）。")
        }
    }

    /// A flattened tree row: a node plus its indentation depth.
    private struct VisibleRow: Identifiable { let node: SkillNode; let depth: Int; var id: String { node.id } }

    /// Search box: filters the top-level skills by name / description (live).
    private var searchField: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField("搜索 skill（名称 / 描述）", text: $search)
                .textFieldStyle(.plain).font(Theme.Font.rowSubtitle)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
    }

    /// Walk the tree, emitting only rows whose ancestors are all expanded. When searching, only
    /// top-level skills whose name or description matches are shown.
    private func visibleRows() -> [VisibleRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let roots = q.isEmpty ? store.tree : store.tree.filter {
            ($0.name + " " + ($0.subtitle ?? "")).lowercased().contains(q)
        }
        var out: [VisibleRow] = []
        func walk(_ nodes: [SkillNode], _ depth: Int) {
            for n in nodes {
                out.append(VisibleRow(node: n, depth: depth))
                if n.isDirectory, expanded.contains(n.id), let kids = n.children { walk(kids, depth + 1) }
            }
        }
        walk(roots, 0)
        return out
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // Self-drawn tree row. We do NOT use `List(children:)` / `Button`-in-`List`: on some macOS
    // versions List eats the row's tap so disclosure never fires. A plain ScrollView row + an
    // explicit `onTapGesture` is reliable — tapping a folder toggles, tapping a file selects it.
    @ViewBuilder private func rowView(_ vr: VisibleRow, isFirst: Bool) -> some View {
        if vr.node.isRoot {
            skillRow(vr.node, isFirst: isFirst)
        } else {
            fileRow(vr)
        }
    }

    /// A top-level skill: a roomy card-like header — wand icon + name + up-to-2-line description, with
    /// breathing room above each skill so the list reads as distinct entries, not a dense tree.
    @ViewBuilder private func skillRow(_ node: SkillNode, isFirst: Bool) -> some View {
        let isOpen = expanded.contains(node.id)
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            // No chevron — the wand marks a skill and the filled background shows it's open.
            Image(systemName: "wand.and.stars")
                .foregroundStyle(isOpen ? Theme.brand : Theme.textTertiary).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let s = node.subtitle, !s.isEmpty {
                    Text(s).font(Theme.Font.rowSubtitle).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.md)
        .padding(.horizontal, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isOpen ? Theme.surface2 : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .contentShape(Rectangle())
        .onTapGesture { toggle(node.id) }
        .contextMenu { folderMenu(node) }
        .padding(.top, isFirst ? 0 : Theme.Space.md)   // gap between skills
    }

    /// A child file (or sub-folder) under a skill: light, indented, secondary — clearly subordinate.
    @ViewBuilder private func fileRow(_ vr: VisibleRow) -> some View {
        let node = vr.node
        let isSelected = !node.isDirectory && selectedID == node.id
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: node.isDirectory
                  ? (expanded.contains(node.id) ? "chevron.down" : "chevron.right")
                  : Self.icon(for: node.url))
                .font(.system(size: 13)).foregroundStyle(isSelected ? Theme.brand : .secondary).frame(width: 16)
            Text(node.name)
                .font(.system(size: 14))   // same size as the skill title; weight + color carry the hierarchy
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(vr.depth) * 16)
        .padding(.vertical, 4)
        .padding(.horizontal, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.brand.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { if node.isDirectory { toggle(node.id) } else { selectedID = node.id } }
        .contextMenu { node.isDirectory ? AnyView(folderMenu(node)) : AnyView(fileMenu(node)) }
    }

    @ViewBuilder private func fileMenu(_ node: SkillNode) -> some View {
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
    }

    @ViewBuilder private func folderMenu(_ node: SkillNode) -> some View {
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
        if node.isRoot {
            Divider()
            Button("删除…", role: .destructive) { deleteTarget = node }
        }
    }

    private static func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": return "doc.richtext"
        case "py":             return "chevron.left.forwardslash.chevron.right"
        case "sh", "bash", "zsh": return "terminal"
        case "json", "yaml", "yml", "toml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        default:               return "doc.text"
        }
    }

    private func loadSelected() {
        guard let id = selectedID, let node = store.node(id: id), !node.isDirectory else {
            fileURL = nil; text = ""; dirty = false; savedFlash = false; return
        }
        fileURL = node.url
        text = store.content(of: node.url)
        dirty = false; savedFlash = false
        preview = Syntax.from(node.url) == .markdown   // open docs in the readable preview by default
    }

    private func saveCurrent() {
        guard let url = fileURL else { return }
        try? store.save(text, to: url)
        dirty = false; savedFlash = true
    }
}

// MARK: - Syntax highlighting

enum Syntax: Equatable {
    case markdown, python, shell, json, plain

    var label: String {
        switch self {
        case .markdown: return "markdown"
        case .python:   return "python"
        case .shell:    return "shell"
        case .json:     return "json"
        case .plain:    return "text"
        }
    }

    static func from(_ url: URL) -> Syntax {
        switch url.pathExtension.lowercased() {
        case "md", "markdown":            return .markdown
        case "py":                        return .python
        case "sh", "bash", "zsh":         return .shell
        case "json":                      return .json
        default:                          return .plain
        }
    }
}

/// An editable NSTextView (wrapped for SwiftUI) that applies regex-based syntax highlighting.
/// Plain text on disk, colored only in the view — we never write attributes back.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var syntax: Syntax

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.allowsUndo = true
        tv.font = Self.font
        tv.textColor = .textColor
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.string = text
        context.coordinator.textView = tv
        context.coordinator.lastSyntax = syntax
        context.coordinator.highlight()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        context.coordinator.parent = self
        if tv.string != text {
            tv.string = text
            context.coordinator.lastSyntax = syntax
            context.coordinator.highlight()
        } else if context.coordinator.lastSyntax != syntax {
            context.coordinator.lastSyntax = syntax
            context.coordinator.highlight()
        }
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        var lastSyntax: Syntax?
        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            highlight()
        }

        func highlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            SyntaxHighlighter.apply(to: storage, syntax: parent.syntax, font: CodeEditor.font)
        }
    }
}

/// Applies foreground colors (and bold/italic) to an NSTextStorage by running per-language regex
/// rules in order — later rules win, so strings/comments are applied last to override keywords.
enum SyntaxHighlighter {
    struct Rule {
        let regex: NSRegularExpression
        let color: NSColor
        var group: Int = 0
        var trait: NSFontTraitMask? = nil
    }

    static func apply(to storage: NSTextStorage, syntax: Syntax, font: NSFont) {
        let str = storage.string
        let full = NSRange(location: 0, length: (str as NSString).length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: full)
        for rule in rules(for: syntax) {
            rule.regex.enumerateMatches(in: str, options: [], range: full) { m, _, _ in
                guard let m else { return }
                let r = (rule.group > 0 && m.numberOfRanges > rule.group) ? m.range(at: rule.group) : m.range
                guard r.location != NSNotFound, r.length > 0 else { return }
                storage.addAttribute(.foregroundColor, value: rule.color, range: r)
                if let trait = rule.trait {
                    let f = NSFontManager.shared.convert(font, toHaveTrait: trait)
                    storage.addAttribute(.font, value: f, range: r)
                }
            }
        }
        storage.endEditing()
    }

    private static func rules(for syntax: Syntax) -> [Rule] {
        switch syntax {
        case .python:           return python
        case .markdown:         return markdown
        case .shell:            return shell
        case .json:             return json
        case .plain:            return []
        }
    }

    private static func rx(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are compile-time constants; force-try is safe and surfaces typos immediately in tests.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static var brand: NSColor { NSColor(Theme.brand) }

    // Order matters: keywords/numbers first, strings & comments LAST so they override.
    private static let python: [Rule] = [
        Rule(regex: rx(#"\b\d+(?:\.\d+)?\b"#), color: .systemBlue),
        Rule(regex: rx(#"@\w+"#), color: .systemTeal),
        Rule(regex: rx(#"\b(?:def|class)\s+(\w+)"#), color: .systemPurple, group: 1, trait: .boldFontMask),
        Rule(regex: rx(#"\b(?:def|class|return|if|elif|else|for|while|import|from|as|with|try|except|finally|raise|pass|break|continue|in|not|and|or|is|None|True|False|lambda|yield|global|nonlocal|assert|del|async|await|self)\b"#), color: .systemPink),
        Rule(regex: rx(#"(?:"""[\s\S]*?"""|'''[\s\S]*?'''|"[^"\n]*"|'[^'\n]*')"#), color: .systemRed),
        Rule(regex: rx(#"#[^\n]*"#), color: .systemGreen),
    ]

    private static let markdown: [Rule] = [
        Rule(regex: rx(#"^#{1,6}\s.*$"#, .anchorsMatchLines), color: brand, trait: .boldFontMask),
        Rule(regex: rx(#"^\s*([-*+]|\d+\.)\s"#, .anchorsMatchLines), color: .systemOrange, group: 1),
        Rule(regex: rx(#"^\s*>.*$"#, .anchorsMatchLines), color: .systemGray),
        Rule(regex: rx(#"\[[^\]]+\]\([^)]+\)"#), color: .systemBlue),
        Rule(regex: rx(#"\*[^*\n]+\*"#), color: .secondaryLabelColor, trait: .italicFontMask),
        Rule(regex: rx(#"\*\*[^*\n]+\*\*"#), color: .labelColor, trait: .boldFontMask),
        Rule(regex: rx(#"`[^`\n]+`"#), color: .systemPurple),
        Rule(regex: rx(#"```[\s\S]*?```"#), color: .systemTeal),
    ]

    private static let shell: [Rule] = [
        Rule(regex: rx(#"\$\{?\w+\}?"#), color: .systemTeal),
        Rule(regex: rx(#"\b(?:if|then|else|elif|fi|for|while|do|done|case|esac|in|function|return|export|local|echo|cd|exit|source)\b"#), color: .systemPink),
        Rule(regex: rx(#"(?:"[^"\n]*"|'[^'\n]*')"#), color: .systemRed),
        Rule(regex: rx(#"#[^\n]*"#), color: .systemGreen),
    ]

    private static let json: [Rule] = [
        Rule(regex: rx(#"\b-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#), color: .systemBlue),
        Rule(regex: rx(#"\b(?:true|false|null)\b"#), color: .systemPink),
        Rule(regex: rx(#""(?:[^"\\\n]|\\.)*""#), color: .systemRed),            // all strings (values)
        Rule(regex: rx(#""(?:[^"\\\n]|\\.)*"(?=\s*:)"#), color: .systemTeal),   // keys override values
    ]
}

// MARK: - Markdown preview (SKILL.md)

/// A read-only Markdown preview for SKILL.md. The point is TABLES: in the raw editor a skill's
/// `| col | col |` tables are unaligned pipe-text and hard to read — here they render as aligned
/// grids. Headings / lists / code / paragraphs get light rendering too. NOT a full CommonMark engine,
/// just enough to read a skill's doc clearly; editing still happens in the CodeEditor.
struct MarkdownPreviewView: View {
    let text: String

    private enum Block: Identifiable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullets([String])
        case code(String)
        case table(header: [String], rows: [[String]])
        var id: String {
            switch self {
            case .heading(_, let t): return "h:" + t
            case .paragraph(let t): return "p:" + t
            case .bullets(let b): return "b:" + b.joined()
            case .code(let c): return "c:" + c
            case .table(let h, let r): return "t:" + h.joined() + "\(r.count)"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                ForEach(Array(parse().enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(Theme.Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .background(Theme.canvas)
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let t):
            inline(t)
                .font(level <= 1 ? .title2.bold() : (level == 2 ? .title3.weight(.semibold) : .headline))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, level <= 2 ? Theme.Space.sm : 0)
        case .paragraph(let t):
            inline(t).font(Theme.Font.emptyBody).foregroundStyle(Theme.textSecondary)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                        Text("•").foregroundStyle(Theme.textTertiary)
                        inline(item).font(Theme.Font.emptyBody).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        case .code(let code):
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.md)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
        case .table(let header, let rows):
            tableView(header: header, rows: rows)
        }
    }

    /// The whole reason for the preview: an aligned grid with a shaded header and hairline row rules.
    private func tableView(header: [String], rows: [[String]]) -> some View {
        let cols = max(header.count, rows.map(\.count).max() ?? 0)
        return Grid(alignment: .topLeading, horizontalSpacing: Theme.Space.lg, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<cols, id: \.self) { c in
                    inline(c < header.count ? header[c] : "")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Theme.Space.sm).padding(.horizontal, Theme.Space.md)
                }
            }
            .background(Theme.surface2)
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<cols, id: \.self) { c in
                        inline(c < row.count ? row[c] : "")
                            .font(Theme.Font.emptyBody)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, Theme.Space.sm).padding(.horizontal, Theme.Space.md)
                    }
                }
                Divider()
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).stroke(Theme.border, lineWidth: 1))
    }

    /// Inline markdown (**bold**, `code`, [links]) → a styled Text; falls back to plain on parse error.
    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }

    // MARK: parsing

    private func parse() -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var i = 0
        var para: [String] = []
        func flushPara() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: " "))); para = [] }
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // fenced code block
            if trimmed.hasPrefix("```") {
                flushPara()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1 // closing fence
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            // heading
            if let hashes = trimmed.range(of: #"^#{1,6}\s"#, options: .regularExpression) {
                flushPara()
                let level = trimmed.distance(from: trimmed.startIndex, to: hashes.upperBound) - 1
                blocks.append(.heading(level: level, text: String(trimmed[hashes.upperBound...])))
                i += 1; continue
            }

            // table: a `|...|` line whose NEXT line is a separator (---|:--- etc.)
            if trimmed.contains("|"), i + 1 < lines.count, Self.isSeparator(lines[i + 1]) {
                flushPara()
                let header = Self.cells(trimmed)
                var rows: [[String]] = []
                i += 2 // header + separator
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(Self.cells(lines[i])); i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // bullet list
            if trimmed.range(of: #"^[-*+]\s"#, options: .regularExpression) != nil {
                flushPara()
                var items: [String] = []
                while i < lines.count,
                      let r = lines[i].trimmingCharacters(in: .whitespaces).range(of: #"^[-*+]\s"#, options: .regularExpression) {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    items.append(String(t[r.upperBound...])); i += 1
                }
                blocks.append(.bullets(items))
                continue
            }

            // blank line → paragraph break
            if trimmed.isEmpty { flushPara(); i += 1; continue }

            para.append(trimmed); i += 1
        }
        flushPara()
        return blocks
    }

    /// A GitHub-style table separator row: only `|`, `-`, `:`, spaces, and at least one `-`.
    private static func isSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    /// Split a `| a | b |` row into trimmed cell strings (dropping the empty edges).
    private static func cells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
