import Foundation

/// One earlier Claude Code session, read from its transcript, for the Resume sheet and a project's Earlier Sessions.
public struct SessionSummary: Equatable, Identifiable, Sendable {
    public var id: String
    /// The folder it ran in.
    public var workspace: String?
    public var updatedDate: Date?
    public var firstMessage: String?
    public var lastMessage: String?
    /// The account Viber last ran it on; nil when Viber doesn't know (it ran elsewhere, or before Viber recorded it).
    public var lastRanProfile: String?

    public init(id: String, workspace: String?, updatedDate: Date?, firstMessage: String?, lastMessage: String?, lastRanProfile: String? = nil) {
        self.id = id; self.workspace = workspace; self.updatedDate = updatedDate
        self.firstMessage = firstMessage; self.lastMessage = lastMessage; self.lastRanProfile = lastRanProfile
    }

    /// First message with wrappers like <ide_opened_file> removed, for a readable title.
    public var title: String {
        var text = firstMessage ?? ""
        // Drop whole wrapper blocks (<ide_opened_file>…</ide_opened_file>), then any stray tags.
        text = text.replacingOccurrences(of: #"<([a-z_-]+)[^>]*>[\s\S]*?</\1>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"</?[a-z_-]+[^>]*>"#, with: "", options: .regularExpression)
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? ""
        return line.isEmpty ? "Untitled session" : String(line.prefix(80))
    }
}

/// Lists the sessions in ~/.claude/projects, newest first, from the start and end of each transcript.
public enum SessionIndex {
    /// Bytes read from each end of a transcript: enough for the first and last few lines, however long the session.
    static let chunk = 256 * 1024
    static let headLimit = 8 * 1024 * 1024

    public static func scan(root: URL = Paths.projects, limit: Int = 400) -> [SessionSummary] {
        let fm = FileManager.default
        var files: [(url: URL, modified: Date)] = []
        for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in entries where file.pathExtension == "jsonl" && !file.lastPathComponent.hasPrefix("agent-") {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                files.append((file, modified))
            }
        }
        return files.sorted { $0.modified > $1.modified }.prefix(limit).compactMap { summary(of: $0.url, modified: $0.modified) }
    }

    /// The session in one transcript; nil when it holds no message from the user.
    public static func summary(of url: URL, modified: Date?) -> SessionSummary? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        // The first message can be a long line (a pasted screenshot): read on until it is whole, up to a limit.
        var head = Data()
        var cwd: String?
        var first: String?
        while first == nil, head.count < headLimit, let more = try? handle.read(upToCount: chunk), !more.isEmpty {
            head.append(more)
            for line in lines(head) {
                if cwd == nil { cwd = line["cwd"] as? String }
                if first == nil { first = userText(line) }
                if cwd != nil && first != nil { break }
            }
        }
        guard let first else { return nil }
        var tail = head
        if size > UInt64(head.count) {
            try? handle.seek(toOffset: size - min(size, UInt64(chunk)))
            tail = (try? handle.read(upToCount: chunk)) ?? Data()
        }
        let last = lines(tail).reversed().lazy.compactMap(userText).first
        return SessionSummary(id: url.deletingPathExtension().lastPathComponent, workspace: cwd, updatedDate: modified,
                              firstMessage: first, lastMessage: last)
    }

    /// The complete JSON lines in a chunk; one cut at either end is skipped.
    private static func lines(_ data: Data) -> [[String: Any]] {
        data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    /// What the user typed, from a transcript line: not tool results, and not the CLI's own notes.
    static func userText(_ line: [String: Any]) -> String? {
        guard line["type"] as? String == "user", line["isMeta"] as? Bool != true, line["isSidechain"] as? Bool != true,
              let message = line["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text.isEmpty ? nil : text }
        let blocks = message["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
