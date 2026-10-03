import AppKit

/// Unsaved buffers survive navigation between tool panes. Never claim a failed write succeeded.
@MainActor
enum EditorSafety {
    static var drafts: [URL: String] = [:]

    static func report(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "文件操作失败"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    static func save(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = url.appendingPathExtension("bak")
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: url, to: backup)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        drafts[url] = nil
    }

    static func mayLeave(_ url: URL?) -> Bool {
        guard let url, let draft = drafts[url] else { return true }
        let alert = NSAlert()
        alert.messageText = "保存 \(url.lastPathComponent) 的改动？"
        alert.informativeText = "保存成功后继续；取消将保留当前编辑。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "放弃改动")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do { try save(draft, to: url); return true }
            catch { report(error); return false }
        case .alertSecondButtonReturn: drafts[url] = nil; return true
        default: return false
        }
    }
}
