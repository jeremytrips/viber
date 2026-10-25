import Foundation

/// A saved Jira query a project's Planning tab can show: "My issues", "Current sprint", "Backlog".
public struct JiraView: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var jql: String
    /// Load the epics and the issues outside them first, and an epic's issues when it is opened.
    public var byEpic: Bool

    public init(id: String = UUID().uuidString, name: String, jql: String, byEpic: Bool = false) {
        self.id = id; self.name = name; self.jql = jql; self.byEpic = byEpic
    }
}

/// Where a project's issues come from when not from Viber's own list: a Jira site, read with its views.
/// Every change to Jira goes through Claude and the repository's skills; Viber only reads.
public struct ProjectTracker: Codable, Equatable, Sendable {
    public var site: String
    public var views: [JiraView]
    /// The first message of a session started from an issue; `<key>` becomes the issue's key.
    public var startMessage: String
    /// The clauth profile sessions use; nil for the default login.
    public var profile: String?
    /// Refresh the shown view this often.
    public var refreshSeconds: Int

    public init(site: String, views: [JiraView] = [], startMessage: String = ProjectTracker.defaultStartMessage,
                profile: String? = nil, refreshSeconds: Int = 60) {
        self.site = site; self.views = views; self.startMessage = startMessage; self.profile = profile; self.refreshSeconds = refreshSeconds
    }

    public static let defaultStartMessage = "/work-issue <key>"

    /// The views a project starts with, for its Jira project keys.
    public static func defaultViews(projectKeys: [String]) -> [JiraView] {
        let keys = projectKeys.isEmpty ? "" : "project in (\(projectKeys.joined(separator: ", "))) AND "
        return [
            JiraView(name: "My issues", jql: "\(keys)assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"),
            JiraView(name: "Current sprint", jql: "\(keys)sprint in openSprints() ORDER BY Rank"),
            JiraView(name: "Backlog", jql: "\(keys)statusCategory != Done ORDER BY Rank", byEpic: true),
        ]
    }

    /// The first message for an issue, with its key and a summary of the issue for Claude to start from.
    public func firstMessage(for issue: JiraIssue) -> String {
        var text = startMessage.replacingOccurrences(of: "<key>", with: issue.key)
        if text.trimmingCharacters(in: .whitespaces).isEmpty { text = issue.key }
        text += "\n\n\(issue.key): \(issue.summary) (\(issue.type), \(issue.status))"
        if !issue.description.isEmpty { text += "\n\n" + issue.description }
        return text
    }
}

/// Each project's tracker, when it isn't Viber's own list. Stored by Viber, not in the repo.
public struct TrackerList: Codable, Equatable {
    public private(set) var projects: [String: ProjectTracker] = [:]

    public init() {}

    public func tracker(for project: String) -> ProjectTracker? { projects[project] }

    public mutating func set(_ tracker: ProjectTracker?, for project: String) { projects[project] = tracker }

    public static func load(from url: URL = ViberPaths.trackers) -> TrackerList {
        guard let data = try? Data(contentsOf: url) else { return TrackerList() }
        return (try? JSONDecoder().decode(TrackerList.self, from: data)) ?? TrackerList()
    }

    public func save(to url: URL = ViberPaths.trackers) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
