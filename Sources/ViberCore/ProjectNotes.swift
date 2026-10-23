import Foundation

/// A note for the sessions that work in one project, written by the user or by an earlier session.
public struct ProjectNote: Codable, Equatable {
    public var text: String
    public var updatedAt: Date
    /// "you" for the user, otherwise the title of the session that wrote it.
    public var updatedBy: String
}

/// Project notes keyed by project path (the repo root for worktree sessions, else the session's folder).
/// Viber adds a project's note to the system prompt of every session it starts there.
public struct ProjectNotes: Codable, Equatable {
    public private(set) var notes: [String: ProjectNote] = [:]
    /// Keeps the system prompt small and requests well under HookInbox's size limit.
    public static let maxLength = 8000

    public init() {}

    public func note(for project: String) -> ProjectNote? { notes[project] }

    /// Replaces a project's note. Empty text removes it.
    public mutating func set(_ text: String, for project: String, by author: String, at now: Date = Date()) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxLength))
        notes[project] = trimmed.isEmpty ? nil : ProjectNote(text: trimmed, updatedAt: now, updatedBy: author)
    }

    public static func load(from url: URL = ViberPaths.notes) -> ProjectNotes {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: url), let notes = try? decoder.decode(ProjectNotes.self, from: data) else { return ProjectNotes() }
        return notes
    }

    public func save(to url: URL = ViberPaths.notes) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The text passed to `claude --append-system-prompt`.
    public static func systemPrompt(projectName: String, note: ProjectNote) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let author = note.updatedBy == "you" ? "the user" : "the session “\(note.updatedBy)”"
        return """
        # Project note

        The user keeps this note in Viber for every session in \(projectName). It was last updated \
        \(formatter.string(from: note.updatedAt)) by \(author). It may be out of date, so check it against the code \
        before relying on it.

        \(note.text)

        Run `viber note` to see the latest version. To leave something for the next sessions, run \
        `viber note set -` with the full new note on stdin, keeping what the user wrote.
        """
    }
}
