import Foundation

/// Works through a project's issues without the user, one at a time. Each issue gets a worktree and a session that
/// implements it, checks it, ships it and says how it went with `viber issue done` or `viber issue failed`;
/// then the next one starts. The app keeps one per project while it runs. It isn't saved across relaunches.
public struct Autopilot: Equatable, Sendable {
    /// What a session does with an issue once it works.
    public enum Finish: String, CaseIterable, Sendable {
        /// Push the branch and open a pull request.
        case pullRequest
        /// Merge the branch into the one checked out in the project's folder.
        case merge
        /// Commit on the branch and leave it there.
        case commit
    }

    /// What to do when the current issue's session ends a turn without saying how it went.
    public enum AfterTurn: Equatable, Sendable {
        /// Its background work will wake it up again.
        case wait
        /// Remind it to finish or report.
        case nudge
        /// Count the issue as stuck and move on.
        case giveUp
    }

    /// Reminders a session gets before its issue counts as stuck.
    public static let maxNudges = 2
    /// This many stuck issues in a row pause the run: something about the project (failing checks, a dead login)
    /// would likely stop the next one too.
    public static let maxStuckInARow = 3
    /// A session idle this long is reminded even while its background commands run: one may never end, like a dev server.
    public static let stallInterval: TimeInterval = 15 * 60

    /// The project's path: its main checkout.
    public var project: String
    public var finish: Finish
    /// The branch checked out in the project's folder when it started, which `merge` merges into.
    public var target: String?
    public var permissionMode: String
    public var profile: String?
    /// The branch pattern new worktrees get; see `usablePattern`.
    public var branchPattern: String
    /// Issues still to implement, in order. Ones planned, done or deleted meanwhile are skipped.
    public private(set) var queue: [String]
    /// The issue being implemented now.
    public private(set) var current: String?
    /// Every issue it took, in order, the current one last: what to look at once it is through.
    public private(set) var handled: [String] = []
    public private(set) var finished = 0
    public private(set) var stuck = 0
    public private(set) var stuckInARow = 0
    /// Why it stopped taking issues, until it is resumed.
    public var paused: String?
    /// End the run once the current issue is through.
    public var stopping = false
    /// Reminders the current session got for ending a turn without a report.
    public private(set) var nudges = 0

    public init(project: String, issues: [String], finish: Finish, target: String?, permissionMode: String,
                profile: String?, branchPattern: String) {
        self.project = project; self.queue = issues; self.finish = finish; self.target = target
        self.permissionMode = permissionMode; self.profile = profile
        self.branchPattern = Self.usablePattern(branchPattern)
    }

    /// The project's branch pattern if it names a new branch for each issue by itself, else Viber's default.
    /// A part only the user knows (`<id>`) can't be filled in, and a pattern without `<slug>` names one branch for all.
    public static func usablePattern(_ pattern: String) -> String {
        Worktree.needsInput(pattern, key: "KEY-1") || !pattern.contains("<slug>") ? Worktree.defaultBranchPattern : pattern
    }

    /// Adds an issue to the end of the queue, such as one you wrote while it runs.
    public mutating func enqueue(_ id: String) {
        guard id != current, !queue.contains(id) else { return }
        queue.append(id)
    }

    /// Makes the next issue still to plan the current one. Nil when none is left.
    public mutating func takeNext(from list: IssueList) -> Issue? {
        guard current == nil else { return nil }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            if let issue = list.issue(id), issue.status == .open {
                current = id
                handled.append(id)
                nudges = 0
                return issue
            }
        }
        return nil
    }

    /// The current issue is through: shipped, or stuck.
    public mutating func finishCurrent(stuck isStuck: Bool) {
        guard current != nil else { return }
        current = nil
        if isStuck { stuck += 1; stuckInARow += 1 } else { finished += 1; stuckInARow = 0 }
    }

    /// Resuming after a pause for stuck issues starts the count again.
    public mutating func resume() {
        paused = nil
        nudges = 0
        stuckInARow = 0
    }

    /// "3 done, 1 stuck"
    public var tally: String {
        stuck == 0 ? "\(finished) done" : "\(finished) done, \(stuck) stuck"
    }

    /// The issues it will still take, in order.
    public func upcoming(in list: IssueList) -> [Issue] {
        queue.compactMap { list.issue($0) }.filter { $0.status == .open }
    }

    public func afterTurn(backgroundWork: Bool) -> AfterTurn {
        if backgroundWork { return .wait }
        return nudges < Self.maxNudges ? .nudge : .giveUp
    }

    public mutating func nudged() { nudges += 1 }

    /// The first message of an issue's session: the issue, and how to see it through alone.
    /// Its first line names the issue, since lists of past sessions title them by their first message.
    public func prompt(for issue: Issue, in list: IssueList) -> String {
        var blocked = ""
        let blockers = list.blockers(of: issue)
        if !blockers.isEmpty {
            blocked = "\nIt is marked as blocked by " + blockers.map { "\($0.key) (\($0.status.label.lowercased()))" }.joined(separator: ", ")
                + ". If that work really is missing here, report failed right away and say so.\n"
        }
        return """
        Autopilot: \(issue.key) \(issue.title)

        Viber's autopilot started this session to implement an issue from the project's list. Nobody is watching: \
        work it through to the end on your own, then report how it went.

        The issue, \(issue.key):

        \(issue.text)
        \(blocked)

        1. Read the code it touches and decide how to do it. Don't ask questions or wait for approval. \
        Where something is unclear, pick what fits the project best and say so in the commit message.
        2. Implement it in this worktree, on its branch. Keep to the issue: save anything else worth doing with \
        `viber issue add` (the /issue skill) instead of doing it.
        3. Check it the way the project requires (its CLAUDE.md, AGENTS.md or skills): build, run the tests and checks, \
        and fix what fails. Stop any dev server or other background command you started.
        4. \(finishStep)
        5. Report, as your last step: `viber issue done "<what shipped, in a sentence>"` once it is shipped, or \
        `viber issue failed "<why>"` if you can't finish it (it can't be done as described, it needs a decision only \
        the user can make, or the checks keep failing). Either one ends your work here; Viber starts the next issue \
        in a session of its own.

        The project's rules for commits, checks and shipping come first. This run approves the steps above, \
        so don't stop to ask before them.
        """
    }

    private var finishStep: String {
        switch finish {
        case .pullRequest:
            return "Ship it: commit, push the branch and open a pull request against origin's default branch, as /ship does. "
                + "This run approves the push, so don't ask first. Never force-push, and don't merge the pull request yourself."
        case .merge:
            let target = target ?? "the branch checked out there"
            let folder = Self.quoted(project)
            return "Ship it: commit, merge `\(target)` into this branch, resolve any conflicts and run the checks again. "
                + "Then bring `\(target)` up to this branch in the project's folder: `git -C \(folder) merge --ff-only <this branch>`. "
                + "If `\(target)` moved meanwhile, merge it in again, check, and retry. If that folder has uncommitted changes "
                + "or isn't on `\(target)`, leave it alone and report failed. Don't push."
        case .commit:
            return "Commit it on this branch, and stop there: don't push or merge it. The user reviews the branch."
        }
    }

    /// Sent when the session ended a turn without a report.
    public func nudge() -> String {
        let left = Self.maxNudges - nudges
        return "Viber's autopilot: your turn ended without a report. If the issue is shipped, run "
            + "`viber issue done \"<what shipped>\"`. If you can't finish it, run `viber issue failed \"<why>\"`. "
            + "Otherwise carry on with it. "
            + (left <= 1 ? "If the next turn ends without either, the issue counts as stuck."
                         : "After \(left) more turns without either, the issue counts as stuck.")
    }

    /// Sent to the current issue's session when you resume a paused run.
    public static let resumeMessage = "Viber's autopilot resumed. Carry on with the issue where you left off, and report with "
        + "`viber issue done \"<what shipped>\"` or `viber issue failed \"<why>\"` when you're through."

    /// A path as a shell word.
    static func quoted(_ path: String) -> String {
        path.allSatisfy { $0.isLetter || $0.isNumber || "/._-~".contains($0) } ? path
            : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
