import Foundation

/// Something to do later in a project that nobody has planned yet, written by the user or by a session.
public struct Idea: Codable, Equatable, Identifiable {
    public enum Status: String, Codable {
        /// Not planned yet.
        case open
        /// A session was started for it.
        case started
        case done
    }

    public var id: String
    /// Keyed like sessions' projects: the repo root for worktree sessions, else the session's folder.
    public var project: String
    public var text: String
    public var createdAt: Date
    /// "you" for the user, otherwise the title of the session that added it.
    public var createdBy: String
    public var status: Status
    public var updatedAt: Date
    /// The session started for this idea, and its title at the time.
    public var sessionID: String?
    public var sessionTitle: String?

    public init(id: String = UUID().uuidString, project: String, text: String, createdAt: Date, createdBy: String,
                status: Status = .open, updatedAt: Date? = nil) {
        self.id = id; self.project = project; self.text = text; self.createdAt = createdAt
        self.createdBy = createdBy; self.status = status; self.updatedAt = updatedAt ?? createdAt
    }

    /// The first line, short enough for a session title and branch name.
    public var title: String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return String(line.trimmingCharacters(in: CharacterSet(charactersIn: "#*-").union(.whitespaces)).prefix(50))
    }
}

/// Every project's ideas, oldest first. Stored by Viber, not in the repo.
public struct IdeaList: Codable, Equatable {
    public private(set) var ideas: [Idea] = []
    /// Keeps an idea readable in a row, and requests well under ViberRequest's size limit.
    public static let maxLength = 4000

    public init() {}

    /// Adds an idea that is not planned yet. Empty text adds nothing.
    @discardableResult
    public mutating func add(_ text: String, project: String, by author: String, at now: Date = Date()) -> Idea? {
        let trimmed = Self.clean(text)
        guard !trimmed.isEmpty else { return nil }
        let idea = Idea(project: project, text: trimmed, createdAt: now, createdBy: author)
        ideas.append(idea)
        return idea
    }

    /// Replaces an idea's text. Empty text is ignored; remove the idea instead.
    public mutating func edit(_ id: String, text: String, at now: Date = Date()) {
        let trimmed = Self.clean(text)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.text = trimmed; $0.updatedAt = now }
    }

    /// Links an idea to the session started for it.
    public mutating func start(_ id: String, sessionID: String, sessionTitle: String, at now: Date = Date()) {
        update(id) {
            $0.status = .started
            $0.sessionID = sessionID
            $0.sessionTitle = sessionTitle
            $0.updatedAt = now
        }
    }

    /// Moving an idea back to open forgets the session it was started in.
    public mutating func setStatus(_ id: String, _ status: Idea.Status, at now: Date = Date()) {
        update(id) {
            $0.status = status
            $0.updatedAt = now
            if status == .open { $0.sessionID = nil; $0.sessionTitle = nil }
        }
    }

    public mutating func remove(_ id: String) { ideas.removeAll { $0.id == id } }

    public func idea(_ id: String) -> Idea? { ideas.first { $0.id == id } }

    /// A project's ideas that are not done: the ones still to plan, newest first, then the started ones.
    public func pending(in project: String) -> [Idea] {
        let mine = ideas.filter { $0.project == project }
        return Array(mine.filter { $0.status == .open }.reversed()) + Array(mine.filter { $0.status == .started }.reversed())
    }

    public func toPlanCount(in project: String) -> Int {
        ideas.filter { $0.project == project && $0.status == .open }.count
    }

    /// What `viber idea list` prints: each idea with who added it, and the session started for it.
    public static func listing(_ ideas: [Idea], projectName: String) -> String {
        guard !ideas.isEmpty else { return "No ideas for \(projectName) yet." }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let lines = ideas.map { idea -> String in
            let author = idea.createdBy == "you" ? "the user" : "session “\(idea.createdBy)”"
            var meta = "added by \(author), \(formatter.string(from: idea.createdAt))"
            if idea.status == .started, let session = idea.sessionTitle { meta += "; started in session “\(session)”" }
            return "- " + idea.text.replacingOccurrences(of: "\n", with: "\n  ") + "\n  (\(meta))"
        }
        return "Ideas for \(projectName) that are not done (started ones last):\n" + lines.joined(separator: "\n")
    }

    public static func load(from url: URL = ViberPaths.ideas, legacyNotes: URL = ViberPaths.notes) -> IdeaList {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: url) {
            return (try? decoder.decode(IdeaList.self, from: data)) ?? IdeaList()
        }
        // Before ideas, each project had one free-text note. Keep each one as an idea so nothing is lost.
        guard let data = try? Data(contentsOf: legacyNotes),
              let legacy = try? decoder.decode(LegacyNotes.self, from: data) else { return IdeaList() }
        var list = IdeaList()
        list.ideas = legacy.notes.sorted { $0.value.updatedAt < $1.value.updatedAt }.map { project, note in
            Idea(project: project, text: note.text, createdAt: note.updatedAt, createdBy: note.updatedBy)
        }
        return list
    }

    public func save(to url: URL = ViberPaths.ideas) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    private static func clean(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
    }

    private mutating func update(_ id: String, _ change: (inout Idea) -> Void) {
        guard let index = ideas.firstIndex(where: { $0.id == id }) else { return }
        change(&ideas[index])
    }

    /// The notes.json format from before ideas.
    private struct LegacyNotes: Decodable {
        struct Note: Decodable {
            var text: String
            var updatedAt: Date
            var updatedBy: String
        }
        var notes: [String: Note]
    }
}
