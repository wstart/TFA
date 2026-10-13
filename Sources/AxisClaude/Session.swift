import Foundation

struct SessionRecord: Codable {
    var id: String
    var cwd: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [Message]
}

/// Persists conversations as `<root>/<sanitized-cwd>/<timestamp-uuid>.json`.
struct SessionStore {
    let root: URL

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".axis-claude/sessions")
    }

    static func sanitize(_ path: String) -> String {
        String(path.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" ? $0 : "-" })
    }

    static func newID(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: now) + "-" + UUID().uuidString.prefix(8).lowercased()
    }

    func directory(for cwd: URL) -> URL {
        root.appendingPathComponent(Self.sanitize(cwd.standardizedFileURL.path))
    }

    func save(_ record: SessionRecord) throws {
        let dir = directory(for: URL(fileURLWithPath: record.cwd))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(record).write(to: dir.appendingPathComponent(record.id + ".json"), options: .atomic)
    }

    func load(id: String, cwd: URL) -> SessionRecord? {
        decode(directory(for: cwd).appendingPathComponent(id + ".json"))
    }

    /// Most recently written session for `cwd` (by file modification time, then name).
    func latest(for cwd: URL) -> SessionRecord? {
        let dir = directory(for: cwd)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let sorted = urls.filter { $0.pathExtension == "json" }.map { url -> (URL, Date) in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }.sorted { a, b in a.1 != b.1 ? a.1 > b.1 : a.0.lastPathComponent > b.0.lastPathComponent }
        for (url, _) in sorted {
            if let r = decode(url) { return r }
        }
        return nil
    }

    private func decode(_ url: URL) -> SessionRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(SessionRecord.self, from: data)
    }
}
