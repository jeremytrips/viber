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
    /// Refresh the shown view this often.
    public var refreshSeconds: Int
    /// The MCP servers that reach Jira in sessions, by name: what an autopilot run makes ask so it can allow the
    /// skill's own changes and hold the rest.
    public var mcpServers: [String]

    public init(site: String, views: [JiraView] = [], startMessage: String = ProjectTracker.defaultStartMessage,
                refreshSeconds: Int = 60, mcpServers: [String] = ProjectTracker.defaultMcpServers) {
        self.site = site; self.views = views; self.startMessage = startMessage; self.refreshSeconds = refreshSeconds
        self.mcpServers = mcpServers
    }

    private enum CodingKeys: String, CodingKey { case site, views, startMessage, refreshSeconds, mcpServers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        site = try c.decode(String.self, forKey: .site)
        views = try c.decodeIfPresent([JiraView].self, forKey: .views) ?? []
        startMessage = try c.decodeIfPresent(String.self, forKey: .startMessage) ?? Self.defaultStartMessage
        refreshSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshSeconds) ?? 60
        mcpServers = try c.decodeIfPresent([String].self, forKey: .mcpServers) ?? Self.defaultMcpServers
    }

    public static let defaultStartMessage = "/work-issue <key>"
    /// Atlassian's MCP server as `claude mcp add` names it, and as the claude.ai connector appears.
    public static let defaultMcpServers = ["atlassian", "claude_ai_Atlassian"]

    /// The views a project starts with, for its Jira project keys.
    public static func defaultViews(projectKeys: [String]) -> [JiraView] {
        let keys = projectKeys.isEmpty ? "" : "project in (\(projectKeys.joined(separator: ", "))) AND "
        return [
            JiraView(name: "My issues", jql: "\(keys)assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"),
            JiraView(name: "Current sprint", jql: "\(keys)sprint in openSprints() ORDER BY Rank"),
            JiraView(name: "Backlog", jql: "\(keys)statusCategory != Done ORDER BY Rank", byEpic: true),
        ]
    }

    /// The first message of a session that writes a Jira ticket up from a line the user typed and creates it. The create
    /// call is what Viber shows as an editable ticket card, so nothing reaches Jira before the user has seen it.
    public static func draftPrompt(_ text: String, site: String) -> String {
        """
        Draft a Jira issue: \(text)

        Write this up as a Jira issue on \(site) and create it. Steps:
        1. If the project has a skill or instructions about Jira (such as a `jira-tracker` skill, CLAUDE.md or AGENTS.md), \
        read them first: they decide the project key, the issue type, labels and any template.
        2. Search Jira for issues about the same thing (`searchJiraIssuesUsingJql`, a few words from the title, and \
        the same project). If one already covers this, don't create another: say which one, and stop.
        3. Read the code it touches, so the description says where the problem is (files, functions) and what "done" \
        means. Keep it to what you can see; don't invent acceptance criteria.
        4. Create the issue with the Atlassian tool `createJiraIssue`, in one call, with the summary, the description, \
        the issue type, and labels or priority when the project's rules call for them. Viber shows that call to the user \
        to edit and approve before it is made; if it is denied, don't try again, just say so.
        5. Report the new key in one line, and stop. Don't start working on the issue.
        """
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
