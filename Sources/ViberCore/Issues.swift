import Foundation

/// A piece of work in a project: an idea to do later, a task in progress, or one that shipped. Written by the user or
/// by a session, and moved along by what sessions do with it.
public struct Issue: Codable, Equatable, Identifiable {
    public enum Status: String, Codable, CaseIterable, Sendable {
        /// Nobody is working on it yet.
        case open
        /// A session was started for it.
        case started
        /// Its session shipped it; the branch waits to be merged.
        case review
        case done

        public var label: String {
            switch self {
            case .open: return "To do"
            case .started: return "In progress"
            case .review: return "In review"
            case .done: return "Done"
            }
        }

        /// The names the `viber issue` command accepts, such as "todo", "in progress" or "review".
        public static func parse(_ name: String) -> Status? {
            switch name.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ") {
            case "open", "todo", "to do", "backlog": return .open
            case "started", "progress", "in progress", "doing": return .started
            case "review", "in review", "shipped": return .review
            case "done", "closed": return .done
            default: return nil
            }
        }
    }

    public struct Report: Codable, Equatable {
        public var text: String
        /// False when it got stuck: the issue stays started, linked to its session, so you can see why.
        public var finished: Bool
        public var at: Date

        public init(text: String, finished: Bool, at: Date) {
            self.text = text; self.finished = finished; self.at = at
        }
    }

    /// A note on an issue: what a session shipped, why it moved, or something the user wrote.
    public struct Comment: Codable, Equatable, Identifiable {
        public var id: String
        public var text: String
        /// "you" for the user, otherwise the title of the session that wrote it.
        public var by: String
        public var at: Date

        public init(id: String = UUID().uuidString, text: String, by: String, at: Date) {
            self.id = id; self.text = text; self.by = by; self.at = at
        }
    }

    public var id: String
    /// Keyed like sessions' projects: the main checkout of the session's repository, else the session's folder.
    public var project: String
    /// Short and unique in the project, such as `EST-12`: what branches, commits and sessions call it.
    public var key: String
    public var text: String
    public var createdAt: Date
    /// "you" for the user, otherwise the title of the session that added it.
    public var createdBy: String
    public var status: Status
    public var updatedAt: Date
    /// The session started for this issue, and its title at the time.
    public var sessionID: String?
    public var sessionTitle: String?
    /// What that session said at the end (`viber issue done` or `failed`), or why the autopilot couldn't start one.
    public var report: Report?
    /// The issue this one is a part of.
    public var parentID: String?
    /// Issues that have to be done before this one can start.
    public var blockedBy: [String]
    public var comments: [Comment]

    public init(id: String = UUID().uuidString, project: String, key: String = "", text: String, createdAt: Date, createdBy: String,
                status: Status = .open, updatedAt: Date? = nil, parentID: String? = nil, blockedBy: [String] = []) {
        self.id = id; self.project = project; self.key = key; self.text = text; self.createdAt = createdAt
        self.createdBy = createdBy; self.status = status; self.updatedAt = updatedAt ?? createdAt
        self.parentID = parentID; self.blockedBy = blockedBy; self.comments = []
    }

    private enum CodingKeys: String, CodingKey {
        case id, project, key, text, createdAt, createdBy, status, updatedAt, sessionID, sessionTitle, report, parentID, blockedBy, comments
    }

    /// Files from before keys, sub-issues and comments lack those fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        project = try c.decode(String.self, forKey: .project)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        createdBy = try c.decode(String.self, forKey: .createdBy)
        status = try c.decode(Status.self, forKey: .status)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        sessionTitle = try c.decodeIfPresent(String.self, forKey: .sessionTitle)
        report = try c.decodeIfPresent(Report.self, forKey: .report)
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
        blockedBy = try c.decodeIfPresent([String].self, forKey: .blockedBy) ?? []
        comments = try c.decodeIfPresent([Comment].self, forKey: .comments) ?? []
    }

    /// The first line, short enough for a session title and branch name.
    public var title: String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return String(line.trimmingCharacters(in: CharacterSet(charactersIn: "#*-").union(.whitespaces)).prefix(50))
    }

    /// Everything after the title.
    public var body: String {
        guard let newline = text.firstIndex(where: \.isNewline) else { return "" }
        return text[newline...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The number in the key: 12 for `EST-12`.
    public var number: Int? {
        key.split(separator: "-").last.flatMap { Int($0) }
    }

    /// Whether `branch` is this issue's: its key, in any case, appears between separators (`feat/est-12-login`).
    public func matches(branch: String) -> Bool {
        guard !key.isEmpty else { return false }
        let haystack = branch.lowercased(), needle = key.lowercased()
        var range = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: range) {
            let before = found.lowerBound == haystack.startIndex || !haystack[haystack.index(before: found.lowerBound)].isLetter && !haystack[haystack.index(before: found.lowerBound)].isNumber
            let after = found.upperBound == haystack.endIndex || !haystack[found.upperBound].isLetter && !haystack[found.upperBound].isNumber
            if before && after { return true }
            range = found.upperBound..<haystack.endIndex
        }
        return false
    }
}

/// Every project's issues, oldest first. Stored by Viber, not in the repo.
public struct IssueList: Codable, Equatable {
    public private(set) var issues: [Issue] = []
    /// A project's key prefix when the user chose one; otherwise it comes from the folder's name.
    public private(set) var prefixes: [String: String] = [:]
    /// The next key number per project, so a deleted issue's key isn't given out again.
    private var nextNumbers: [String: Int] = [:]
    /// Keeps an issue readable in a row, and requests well under ViberRequest's size limit.
    public static let maxLength = 4000

    public init() {}

    private enum CodingKeys: String, CodingKey { case issues, prefixes, nextNumbers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issues = try c.decodeIfPresent([Issue].self, forKey: .issues) ?? []
        prefixes = try c.decodeIfPresent([String: String].self, forKey: .prefixes) ?? [:]
        nextNumbers = try c.decodeIfPresent([String: Int].self, forKey: .nextNumbers) ?? [:]
    }

    // MARK: Keys

    /// The prefix a project's keys get until the user sets one: initials of a multi-word folder name (`nexus-cloud`
    /// → `NC`), else its first three letters (`viber` → `VIB`).
    public static func defaultPrefix(forProject path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let words = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let prefix: String
        if words.count >= 2 { prefix = words.prefix(4).compactMap { $0.first.map(String.init) }.joined() }
        else { prefix = String((words.first ?? "").prefix(3)) }
        let cleaned = Self.cleanPrefix(prefix)
        return cleaned.isEmpty ? "ISSUE" : cleaned
    }

    /// Upper case letters and digits only, at most 10.
    public static func cleanPrefix(_ raw: String) -> String {
        String(raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(10))
    }

    public func prefix(for project: String) -> String {
        prefixes[project] ?? Self.defaultPrefix(forProject: project)
    }

    /// Changes a project's prefix, renaming its issues' keys with it (the numbers stay). An empty or unchanged
    /// prefix goes back to the default.
    public mutating func setPrefix(_ raw: String, project: String) {
        let cleaned = Self.cleanPrefix(raw)
        prefixes[project] = cleaned.isEmpty || cleaned == Self.defaultPrefix(forProject: project) ? nil : cleaned
        let prefix = prefix(for: project)
        for index in issues.indices where issues[index].project == project {
            if let number = issues[index].number { issues[index].key = "\(prefix)-\(number)" }
        }
    }

    /// Hands out the project's next key.
    private mutating func nextKey(for project: String) -> String {
        let taken = issues.filter { $0.project == project }.compactMap(\.number).max() ?? 0
        let number = max(nextNumbers[project] ?? 1, taken + 1)
        nextNumbers[project] = number + 1
        return "\(prefix(for: project))-\(number)"
    }

    /// Gives keys to issues from before keys, in the order they were added.
    public mutating func assignMissingKeys() -> Bool {
        var changed = false
        for index in issues.indices where issues[index].key.isEmpty {
            issues[index].key = nextKey(for: issues[index].project)
            changed = true
        }
        return changed
    }

    // MARK: Changes

    /// Adds an issue to do. Empty text adds nothing. `parent` and `blockedBy` are keys or ids in the same project.
    @discardableResult
    public mutating func add(_ text: String, project: String, by author: String, parent: String? = nil, blockedBy: [String] = [],
                             at now: Date = Date()) -> Issue? {
        let trimmed = Self.clean(text)
        guard !trimmed.isEmpty else { return nil }
        var issue = Issue(project: project, key: nextKey(for: project), text: trimmed, createdAt: now, createdBy: author)
        issue.parentID = parent.flatMap { self.issue($0, in: project)?.id }
        issue.blockedBy = blockedBy.compactMap { self.issue($0, in: project)?.id }
        issues.append(issue)
        return issue
    }

    /// Replaces an issue's text. Empty text is ignored; remove the issue instead.
    public mutating func edit(_ id: String, text: String, at now: Date = Date()) {
        let trimmed = Self.clean(text)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.text = trimmed; $0.updatedAt = now }
    }

    /// Makes an issue a part of another (nil for none), and sets what it waits for.
    public mutating func setLinks(_ id: String, parent: String?, blockedBy: [String], at now: Date = Date()) {
        guard let issue = issue(id) else { return }
        let parentID = parent.flatMap { self.issue($0, in: issue.project)?.id }
        let blockers = blockedBy.compactMap { self.issue($0, in: issue.project)?.id }.filter { $0 != id }
        update(id) {
            $0.parentID = parentID == id ? nil : parentID
            $0.blockedBy = Array(NSOrderedSet(array: blockers)) as? [String] ?? blockers
            $0.updatedAt = now
        }
    }

    /// Links an issue to the session started for it.
    public mutating func start(_ id: String, sessionID: String, sessionTitle: String, at now: Date = Date()) {
        update(id) {
            $0.status = .started
            $0.sessionID = sessionID
            $0.sessionTitle = sessionTitle
            $0.report = nil
            $0.updatedAt = now
        }
    }

    /// Moving an issue back to open forgets the session it was started in, and what it reported.
    public mutating func setStatus(_ id: String, _ status: Issue.Status, at now: Date = Date()) {
        update(id) {
            $0.status = status
            $0.updatedAt = now
            if status == .open { $0.sessionID = nil; $0.sessionTitle = nil; $0.report = nil }
        }
    }

    /// Records how an issue went. A finished one is done; a stuck one keeps its status and session.
    public mutating func report(_ id: String, _ text: String, finished: Bool, at now: Date = Date()) {
        update(id) {
            $0.report = Issue.Report(text: Self.clean(text), finished: finished, at: now)
            if finished { $0.status = .done }
            $0.updatedAt = now
        }
    }

    public mutating func comment(_ id: String, _ text: String, by author: String, at now: Date = Date()) {
        let trimmed = Self.clean(text)
        guard !trimmed.isEmpty else { return }
        update(id) {
            $0.comments.append(Issue.Comment(text: trimmed, by: author, at: now))
            $0.updatedAt = now
        }
    }

    /// Removes an issue. Its sub-issues stay, on their own; issues it blocked are unblocked.
    public mutating func remove(_ id: String) {
        issues.removeAll { $0.id == id }
        for index in issues.indices {
            if issues[index].parentID == id { issues[index].parentID = nil }
            issues[index].blockedBy.removeAll { $0 == id }
        }
    }

    /// Files issues under other projects, such as the repository a subfolder belongs to. Returns whether any moved.
    public mutating func moveProjects(_ transform: (String) -> String) -> Bool {
        var moved = false
        for index in issues.indices {
            let project = transform(issues[index].project)
            if project != issues[index].project { issues[index].project = project; moved = true }
        }
        return moved
    }

    // MARK: Lookup

    public func issue(_ id: String) -> Issue? { issues.first { $0.id == id } }

    /// An issue by key (in any case) or by id, in a project.
    public func issue(_ keyOrID: String, in project: String) -> Issue? {
        let wanted = keyOrID.trimmingCharacters(in: .whitespaces).uppercased()
        return issues.first { $0.project == project && ($0.key == wanted || $0.id == keyOrID) }
    }

    /// The issue a session was started for, if any.
    public func issue(startedIn sessionID: String) -> Issue? {
        issues.last { $0.sessionID == sessionID }
    }

    /// The project's issue whose key is in a branch name, such as `EST-12` in `feat/est-12-login`.
    public func issue(forBranch branch: String, in project: String) -> Issue? {
        issues.last { $0.project == project && $0.matches(branch: branch) }
    }

    public func issues(in project: String) -> [Issue] { issues.filter { $0.project == project } }

    public func children(of id: String) -> [Issue] { issues.filter { $0.parentID == id } }

    /// The issues that still have to be done before this one.
    public func blockers(of issue: Issue) -> [Issue] {
        issue.blockedBy.compactMap { id in self.issue(id) }.filter { $0.status != .done }
    }

    /// A project's issues that are not done: the ones to do, newest first, then the started ones, then those in review.
    public func pending(in project: String) -> [Issue] {
        let mine = issues(in: project)
        return [Issue.Status.open, .started, .review].flatMap { status in Array(mine.filter { $0.status == status }.reversed()) }
    }

    /// A project's issues to do, oldest first: the order the autopilot takes them in.
    public func toPlan(in project: String) -> [Issue] {
        issues.filter { $0.project == project && $0.status == .open }
    }

    public func toPlanCount(in project: String) -> Int {
        issues.filter { $0.project == project && $0.status == .open }.count
    }

    // MARK: For the `viber issue` command

    /// Each issue with its key, status, who added it, and what it waits for.
    public static func listing(_ issues: [Issue], in list: IssueList, projectName: String) -> String {
        guard !issues.isEmpty else { return "No issues for \(projectName) that are not done." }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let lines = issues.map { issue -> String in
            let author = issue.createdBy == "you" ? "the user" : "session “\(issue.createdBy)”"
            var meta = ["\(issue.status.label.lowercased())", "added by \(author) \(formatter.string(from: issue.createdAt))"]
            if issue.status == .started, let session = issue.sessionTitle { meta.append("session “\(session)”") }
            if let parent = issue.parentID.flatMap({ id in list.issue(id) }) { meta.append("part of \(parent.key)") }
            let blockers = list.blockers(of: issue)
            if !blockers.isEmpty { meta.append("blocked by " + blockers.map(\.key).joined(separator: ", ")) }
            return "- \(issue.key): " + issue.text.replacingOccurrences(of: "\n", with: "\n  ") + "\n  (\(meta.joined(separator: "; ")))"
        }
        return "Issues for \(projectName) that are not done:\n" + lines.joined(separator: "\n")
    }

    /// One issue in full: text, links, report and comments.
    public func detail(_ issue: Issue) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        var lines = ["\(issue.key) · \(issue.status.label)", "", issue.text, ""]
        lines.append("Added by \(issue.createdBy == "you" ? "the user" : "session “\(issue.createdBy)”") on \(formatter.string(from: issue.createdAt)).")
        if let parent = issue.parentID.flatMap({ id in self.issue(id) }) { lines.append("Part of \(parent.key): \(parent.title)") }
        let kids = children(of: issue.id)
        if !kids.isEmpty { lines.append("Sub-issues: " + kids.map { "\($0.key) (\($0.status.label.lowercased()))" }.joined(separator: ", ")) }
        let blockers = issue.blockedBy.compactMap { id in self.issue(id) }
        if !blockers.isEmpty { lines.append("Blocked by: " + blockers.map { "\($0.key) (\($0.status.label.lowercased()))" }.joined(separator: ", ")) }
        if issue.status != .open, let session = issue.sessionTitle { lines.append("Session: “\(session)”") }
        if let report = issue.report { lines.append((report.finished ? "Shipped: " : "Stuck: ") + report.text) }
        if !issue.comments.isEmpty {
            lines.append("")
            lines.append("Comments:")
            for comment in issue.comments {
                lines.append("- \(comment.by == "you" ? "the user" : comment.by), \(formatter.string(from: comment.at)): "
                             + comment.text.replacingOccurrences(of: "\n", with: "\n  "))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Storage

    /// Reads `issues.json`; before that, the same list was `ideas.json`, and before ideas each project had one note.
    public static func load(from url: URL = ViberPaths.issues, legacyIdeas: URL = ViberPaths.ideas, legacyNotes: URL = ViberPaths.notes) -> IssueList {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var list: IssueList
        if let data = try? Data(contentsOf: url) {
            list = (try? decoder.decode(IssueList.self, from: data)) ?? IssueList()
        } else if let data = try? Data(contentsOf: legacyIdeas), let legacy = try? decoder.decode(LegacyIdeas.self, from: data) {
            list = IssueList()
            list.issues = legacy.ideas
        } else if let data = try? Data(contentsOf: legacyNotes), let legacy = try? decoder.decode(LegacyNotes.self, from: data) {
            list = IssueList()
            list.issues = legacy.notes.sorted { $0.value.updatedAt < $1.value.updatedAt }.map { project, note in
                Issue(project: project, text: note.text, createdAt: note.updatedAt, createdBy: note.updatedBy)
            }
        } else {
            return IssueList()
        }
        _ = list.assignMissingKeys()
        return list
    }

    public func save(to url: URL = ViberPaths.issues) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    private static func clean(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
    }

    private mutating func update(_ id: String, _ change: (inout Issue) -> Void) {
        guard let index = issues.firstIndex(where: { $0.id == id }) else { return }
        change(&issues[index])
    }

    /// The ideas.json format: the same issues under another name.
    private struct LegacyIdeas: Decodable {
        var ideas: [Issue]
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
