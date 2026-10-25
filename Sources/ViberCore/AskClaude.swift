import Foundation

/// The Ask Claude actions on a project's issues: each is a session in the project with a prompt, and no worktree.
/// On Viber's own list Claude changes issues with `viber issue`; on Jira every change goes through the Atlassian
/// tools, which ask.
public enum AskClaude: Equatable, Sendable {
    /// Duplicates, stale issues, issues done but still open, rough sizes.
    case review
    /// The issue to start now, and why.
    case next
    /// Sub-issues for one issue, from the code.
    case breakDown(key: String)
    /// What moved since yesterday, as a draft to post.
    case standup

    public var title: String {
        switch self {
        case .review: return "Review the backlog"
        case .next: return "What's next?"
        case .breakDown(let key): return "Break down \(key)"
        case .standup: return "Standup note"
        }
    }

    /// `tracker` is nil for Viber's own list.
    public func prompt(project: String, tracker: ProjectTracker?) -> String {
        let name = URL(fileURLWithPath: project).lastPathComponent
        let where_: String
        if let tracker {
            where_ = """
            The project's issues are in Jira (\(tracker.site)); read them with the Atlassian tools (`searchJiraIssuesUsingJql`, \
            `getJiraIssue`). If the project has instructions about Jira (a `jira-tracker` skill, CLAUDE.md, AGENTS.md), follow them. \
            Every change to Jira asks the user first, so make each one a separate, well-named call and explain it in a line before.
            """
        } else {
            where_ = """
            The project's issues are Viber's own list: `viber issue list` shows the ones not done (with keys like \(IssueList.defaultPrefix(forProject: project))-12), \
            `viber issue show <key>` one in full, `viber issue add [--parent <key>] [--blocked-by <key,…>] <text>` adds one, \
            `viber issue update <key> --status todo|progress|review|done|--parent|--blocked-by` changes one, and \
            `viber issue comment <key> <text>` adds a note. The list is the user's private one, so make the changes directly; \
            each shows in Viber at once and can be undone there. Say what you changed in your reply.
            """
        }
        switch self {
        case .review:
            return """
            Review the backlog of \(name).

            \(where_)

            Go through the issues that are not done, and the code where it helps, and tidy the list:
            - Duplicates: two issues asking for the same work. Fold the newer into the older (its text as a note on the older one), \
            and close the newer with a note saying where it went.
            - Done but still open: an issue whose work is already on the main branch (check the git log and the code). Mark it done \
            with a note saying which commit.
            - Stale: untouched for weeks with nothing to show. Don't close them; list them for the user with a one-line view on each.
            - Size: for each issue to do, a rough size (S, M, L) from the code it would touch, as a note, only where you looked.
            Then report in a short list: what you changed, and what you'd ask the user about. Don't start working on any issue.
            """
        case .next:
            return """
            What should be worked on next in \(name)?

            \(where_)

            Read the issues that are not done, what blocks what, what is already in progress or in review, and the code where it \
            helps. Recommend one issue to start now, and say why in a few lines: what depends on it, what it unblocks, and how big \
            it looks. Name a runner-up. Don't change anything, and don't start working on it.
            """
        case .breakDown(let key):
            return """
            Break down \(key) in \(name) into sub-issues.

            \(where_)

            Read \(key) and the code it touches. Propose 2 to 6 sub-issues, each a piece of work a session can finish on its own, \
            with a short title and a few lines on where it lives and what done means; say which depend on which. \
            \(tracker == nil
              ? "Add them with `viber issue add --parent \(key)` (and `--blocked-by` where one depends on another), then list them."
              : "Create them in Jira as sub-tasks (or child issues) of \(key), one call each; each asks the user, so explain each before. Then list them.")
            Don't start working on them.
            """
        case .standup:
            return """
            Write a standup note for \(name).

            \(where_)

            Cover what moved since yesterday: issues that changed status, what their sessions reported (`viber issue show` has the \
            notes; the git log of the last day has the commits), what is in progress now, and what is blocked and by what. \
            Three short sections: Yesterday, Today, Blocked. Plain text, no headings, ready to paste; put it in your reply and \
            change nothing. Say if there is nothing to report for a section.
            """
        }
    }
}
