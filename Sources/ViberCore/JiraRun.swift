import Foundation

/// The autopilot on a Jira project: works through Jira issues, several at a time, each in a worktree with a session
/// that runs the repository's own skill (`/work-issue <key>`), commits on its branch and reports. The run makes only
/// the Jira changes that skill needs, on the issue's own key; any other Jira change holds the run for the user.
/// Nothing is pushed or merged: the user ships each branch and its skill moves the issue to Done.
public struct JiraRun: Equatable, Sendable {
    public struct Report: Equatable, Sendable {
        public var text: String
        public var finished: Bool
        public init(text: String, finished: Bool) { self.text = text; self.finished = finished }
    }

    public static let maxSessions = Autopilot.maxSessions
    public static let maxNudges = Autopilot.maxNudges
    public static let maxStuckInARow = Autopilot.maxStuckInARow

    public var project: String
    /// The epic it was started on, if one.
    public var epicKey: String?
    /// "E14 Leaderboard v2", or "issues you picked".
    public var label: String
    public var sessionsAtOnce: Int
    public var worktreesAtMost: Int
    public var permissionMode: String
    public var profile: String?
    public var branchPattern: String
    /// Keys still to do, in order.
    public private(set) var queue: [String]
    /// Keys with a session now, in the order they started.
    public private(set) var active: [String] = []
    public private(set) var handled: [String] = []
    public private(set) var reports: [String: Report] = [:]
    /// Keys left out when the run was made, with why.
    public var leftOut: [(key: String, why: String)] = []
    public private(set) var finished = 0
    public private(set) var stuck = 0
    public private(set) var stuckInARow = 0
    public var paused: String?
    /// The session whose held Jira change paused the run; answering it resumes the run.
    public var heldBy: String?
    public var stopping = false
    private var nudges: [String: Int] = [:]

    public static func == (a: JiraRun, b: JiraRun) -> Bool {
        a.project == b.project && a.queue == b.queue && a.active == b.active && a.handled == b.handled && a.paused == b.paused
            && a.stopping == b.stopping && a.finished == b.finished && a.stuck == b.stuck && a.reports == b.reports
            && a.leftOut.map(\.key) == b.leftOut.map(\.key)
    }

    public init(project: String, keys: [String], epicKey: String?, label: String, sessionsAtOnce: Int, worktreesAtMost: Int,
                permissionMode: String, profile: String?, branchPattern: String) {
        self.project = project; self.queue = keys; self.epicKey = epicKey; self.label = label
        self.sessionsAtOnce = min(max(sessionsAtOnce, 1), Self.maxSessions)
        self.worktreesAtMost = max(worktreesAtMost, self.sessionsAtOnce)
        self.permissionMode = permissionMode; self.profile = profile
        self.branchPattern = Autopilot.usablePattern(branchPattern)
    }

    // MARK: Eligibility

    /// Why the run can't take an issue, or nil when it can. `mine` says whether it is assigned to the signed-in user.
    public static func ineligible(_ issue: JiraIssue, mine: Bool) -> String? {
        if issue.isEpic { return "An epic; the run takes its issues instead." }
        if issue.category == .done { return "Already done." }
        if issue.category == .progress { return "Already \(issue.status.lowercased()); someone may be on it." }
        if issue.labels.contains("decision") || issue.summary.uppercased().hasPrefix("DECISION") { return "A decision: it needs you, not code." }
        if let who = issue.assignee, !mine { return "Assigned to \(who)." }
        return nil
    }

    // MARK: Queue

    public mutating func enqueue(_ key: String) {
        guard !active.contains(key), !queue.contains(key), !handled.contains(key) else { return }
        queue.append(key)
    }

    public func hasRoom(openWorktrees: Int) -> Bool {
        active.count < sessionsAtOnce && openWorktrees < worktreesAtMost
    }

    /// The next key to start, read again from `known` so one moved or taken meanwhile is skipped.
    public mutating func takeNext(known: [String: JiraIssue], openWorktrees: Int) -> String? {
        guard hasRoom(openWorktrees: openWorktrees) else { return nil }
        while let key = queue.first {
            queue.removeFirst()
            if let issue = known[key], issue.category != .todo || issue.isEpic {
                reports[key] = Report(text: "Skipped: it was \(issue.status.lowercased()) by the time its turn came.", finished: false)
                handled.append(key)
                continue
            }
            active.append(key)
            handled.append(key)
            nudges[key] = 0
            return key
        }
        return nil
    }

    public mutating func finish(_ key: String, stuck isStuck: Bool, report: String) {
        guard active.contains(key) else { return }
        active.removeAll { $0 == key }
        nudges[key] = nil
        reports[key] = Report(text: report, finished: !isStuck)
        if isStuck { stuck += 1; stuckInARow += 1 } else { finished += 1; stuckInARow = 0 }
    }

    public mutating func resume() {
        paused = nil
        heldBy = nil
        nudges = nudges.mapValues { _ in 0 }
        stuckInARow = 0
    }

    public var tally: String { stuck == 0 ? "\(finished) in review" : "\(finished) in review, \(stuck) back in To Do" }

    public func afterTurn(for key: String, backgroundWork: Bool) -> Autopilot.AfterTurn {
        if backgroundWork { return .wait }
        return (nudges[key] ?? 0) < Self.maxNudges ? .nudge : .giveUp
    }

    public mutating func nudged(_ key: String) { nudges[key, default: 0] += 1 }

    public func nudge(for key: String) -> String {
        let left = Self.maxNudges - (nudges[key] ?? 0)
        return "Viber's autopilot: your turn ended without a report. If \(key) is in review, run `viber issue done \"<what landed>\"`. "
            + "If you can't finish it, move it back to To Do with a comment and run `viber issue failed \"<why>\"`. Otherwise carry on. "
            + (left <= 1 ? "If the next turn ends without either, the issue counts as stuck." : "After \(left) more turns without either, the issue counts as stuck.")
    }

    public static let resumeMessage = "Viber's autopilot resumed. Carry on with the issue where you left off, and report with "
        + "`viber issue done \"<what landed>\"` or `viber issue failed \"<why>\"` when you're through."

    // MARK: The session's first message

    public static func prompt(for issue: JiraIssue, tracker: ProjectTracker, startBranch: String? = nil) -> String {
        let start = tracker.startMessage.replacingOccurrences(of: "<key>", with: issue.key)
        var notes = ""
        if let startBranch { notes = "\nThis worktree starts from `\(startBranch)`, which has the work this issue builds on; it isn't merged yet.\n" }
        return """
        Autopilot: \(issue.key) \(issue.summary)

        \(start)

        Viber's autopilot started this session for \(issue.key) from the project's Jira. Nobody is watching: work it through \
        on your own with the project's own skill and rules, then report.

        \(issue.key): \(issue.summary) (\(issue.type), \(issue.status))
        \(issue.description.isEmpty ? "" : "\n" + issue.description + "\n")\(notes)
        Rules for this run:
        - Don't ask questions or wait for approval. Where something is unclear, pick what fits the project best and say so \
        in the issue's results comment.
        - Jira: this run lets you read anything, and move \(issue.key) and comment on it, as the project's skill does. Any other \
        Jira change (a new issue, editing another one, Done, Wontfix) waits for the user, so avoid it; put what you'd have \
        written in \(issue.key)'s comment instead.
        - Finish: commit on this branch and stop at the status the project's skill uses for "landed, not merged" (In Review). \
        Don't push or merge. The user ships the branch.
        - Report, as your last step: `viber issue done "<what landed, in a sentence>"` once the branch is committed and the \
        issue moved, or `viber issue failed "<why>"` if you can't finish it; before that, move \(issue.key) back to To Do \
        with a comment saying why, so the board is honest. Either one ends your work here.
        """
    }

    // MARK: What the run allows without asking

    public enum Decision: Equatable, Sendable { case allow, ask }

    /// `mcp__<server>__<tool>` → (server, tool), for a tool of one of `servers`.
    public static func mcpTool(_ toolName: String, servers: [String]) -> String? {
        for server in servers {
            let prefix = "mcp__\(server)__"
            if toolName.hasPrefix(prefix) { return String(toolName.dropFirst(prefix.count)) }
        }
        return nil
    }

    /// Reads are fine anywhere; moving the run's own issue and commenting on it are what the skill does. Everything
    /// else on Jira asks the user and holds the run.
    public static func decide(tool: String, input: JSON, key: String) -> Decision {
        let name = tool.lowercased()
        if ["get", "search", "lookup", "list", "fetch", "atlassianuserinfo", "getaccessible"].contains(where: { name.hasPrefix($0) }) { return .allow }
        guard ["transitionjiraissue", "addcommenttojiraissue"].contains(name) else { return .ask }
        let target = ["issueIdOrKey", "issueKey", "issueId", "key"].compactMap { input[$0]?.string }.first ?? ""
        return target.uppercased() == key.uppercased() ? .allow : .ask
    }

    /// The session rules that make every call to the Jira servers ask, so `decide` sees them all.
    public static func askRules(servers: [String]) -> [RuleEdit] {
        servers.map { RuleEdit(behavior: "ask", rule: "mcp__\($0)") }
    }
}
