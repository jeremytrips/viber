import Foundation

/// Works through a project's issues without the user, several at a time. Each issue gets a worktree and a session
/// that implements it, checks it, ships it and says how it went with `viber issue done` or `viber issue failed`;
/// then the next one takes its place. The app keeps one per project while it runs. It isn't saved across relaunches.
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

    /// What to do when an issue's session ends a turn without saying how it went.
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
    /// The most sessions a run keeps going at once.
    public static let maxSessions = 8

    /// The project's path: its main checkout.
    public var project: String
    public var finish: Finish
    /// The branch checked out in the project's folder when it started, which `merge` merges into.
    public var target: String?
    public var permissionMode: String
    public var profile: String?
    /// The branch pattern new worktrees get; see `usablePattern`.
    public var branchPattern: String
    /// How many issues it works on at once.
    public var sessionsAtOnce: Int
    /// The most worktrees the project may have open, counting ones waiting for review: a finished issue keeps its
    /// worktree until it is shipped and cleaned up, so this is how far the run can get ahead of the user.
    public var worktreesAtMost: Int
    /// Issues still to implement, in order. Ones planned, done or deleted meanwhile are skipped; ones blocked by
    /// another issue in the run wait for it.
    public private(set) var queue: [String]
    /// The issues being implemented now, in the order they started.
    public private(set) var active: [String] = []
    /// Every issue it took, in order, the active ones last: what to look at once it is through.
    public private(set) var handled: [String] = []
    public private(set) var finished = 0
    public private(set) var stuck = 0
    public private(set) var stuckInARow = 0
    /// Why it stopped taking issues, until it is resumed.
    public var paused: String?
    /// End the run once the active issues are through.
    public var stopping = false
    /// Reminders each active session got for ending a turn without a report.
    private var nudges: [String: Int] = [:]

    public init(project: String, issues: [String], finish: Finish, target: String?, permissionMode: String,
                profile: String?, branchPattern: String, sessionsAtOnce: Int = 1, worktreesAtMost: Int = maxSessions) {
        self.project = project; self.queue = issues; self.finish = finish; self.target = target
        self.permissionMode = permissionMode; self.profile = profile
        self.branchPattern = Self.usablePattern(branchPattern)
        self.sessionsAtOnce = min(max(sessionsAtOnce, 1), Self.maxSessions)
        self.worktreesAtMost = max(worktreesAtMost, self.sessionsAtOnce)
    }

    /// The project's branch pattern if it names a new branch for each issue by itself, else Viber's default.
    /// A part only the user knows (`<id>`) can't be filled in, and a pattern without `<slug>` names one branch for all.
    public static func usablePattern(_ pattern: String) -> String {
        Worktree.needsInput(pattern, key: "KEY-1") || !pattern.contains("<slug>") ? Worktree.defaultBranchPattern : pattern
    }

    /// Adds an issue to the end of the queue, such as one you wrote while it runs.
    public mutating func enqueue(_ id: String) {
        guard !active.contains(id), !queue.contains(id) else { return }
        queue.append(id)
    }

    /// Whether another issue could start now: a session slot is free, and the project has room for its worktree.
    public func hasRoom(openWorktrees: Int) -> Bool {
        active.count < sessionsAtOnce && openWorktrees < worktreesAtMost
    }

    /// An issue that waits for another one in this run, which has to ship first.
    public func deferred(_ issue: Issue, in list: IssueList) -> Bool {
        list.blockers(of: issue).contains { active.contains($0.id) || queue.contains($0.id) }
    }

    /// Starts the next issue to do that isn't waiting for one in the run. Nil when none can start now:
    /// there is no room, nothing is left, or everything left waits for an active issue.
    public mutating func takeNext(from list: IssueList, openWorktrees: Int = 0) -> Issue? {
        guard hasRoom(openWorktrees: openWorktrees) else { return nil }
        for id in queue {
            guard let issue = list.issue(id), issue.status == .open else {
                queue.removeAll { $0 == id }
                continue
            }
            if deferred(issue, in: list) { continue }
            queue.removeAll { $0 == id }
            active.append(id)
            handled.append(id)
            nudges[id] = 0
            return issue
        }
        return nil
    }

    /// An active issue is through: shipped, or stuck.
    public mutating func finish(_ id: String, stuck isStuck: Bool) {
        guard active.contains(id) else { return }
        active.removeAll { $0 == id }
        nudges[id] = nil
        if isStuck { stuck += 1; stuckInARow += 1 } else { finished += 1; stuckInARow = 0 }
    }

    /// Resuming after a pause for stuck issues starts the count again.
    public mutating func resume() {
        paused = nil
        nudges = nudges.mapValues { _ in 0 }
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

    /// The issues left that wait for an active one, with what they wait for.
    public func waiting(in list: IssueList) -> [(issue: Issue, for: [Issue])] {
        upcoming(in: list).compactMap { issue in
            let blockers = list.blockers(of: issue).filter { active.contains($0.id) || queue.contains($0.id) }
            return blockers.isEmpty ? nil : (issue, blockers)
        }
    }

    public func afterTurn(for id: String, backgroundWork: Bool) -> AfterTurn {
        if backgroundWork { return .wait }
        return (nudges[id] ?? 0) < Self.maxNudges ? .nudge : .giveUp
    }

    public mutating func nudged(_ id: String) { nudges[id, default: 0] += 1 }

    /// The first message of an issue's session: the issue, and how to see it through alone. `startBranch` is the
    /// branch the worktree starts from when that isn't the usual base: a blocker's, shipped but not merged.
    /// Its first line names the issue, since lists of past sessions title them by their first message.
    public func prompt(for issue: Issue, in list: IssueList, startBranch: String? = nil) -> String {
        var notes: [String] = []
        if let startBranch {
            notes.append("This worktree starts from `\(startBranch)`, which has the work this issue builds on; it isn't merged yet.")
        }
        let blockers = list.blockers(of: issue)
        if !blockers.isEmpty {
            notes.append("It is marked as blocked by " + blockers.map { "\($0.key) (\($0.status.label.lowercased()))" }.joined(separator: ", ")
                + ". If that work really is missing here, report failed right away and say so.")
        }
        let extra = notes.isEmpty ? "" : "\n" + notes.joined(separator: "\n") + "\n"
        return """
        Autopilot: \(issue.key) \(issue.title)

        Viber's autopilot started this session to implement an issue from the project's list. Nobody is watching: \
        work it through to the end on your own, then report how it went.

        The issue, \(issue.key):

        \(issue.text)
        \(extra)
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
                + "If `\(target)` moved meanwhile (other sessions ship there too), merge it in again, check, and retry. "
                + "If that folder has uncommitted changes or isn't on `\(target)`, leave it alone and report failed. Don't push."
        case .commit:
            return "Commit it on this branch, and stop there: don't push or merge it. The user reviews the branch."
        }
    }

    /// Sent when the session ended a turn without a report.
    public func nudge(for id: String) -> String {
        let left = Self.maxNudges - (nudges[id] ?? 0)
        return "Viber's autopilot: your turn ended without a report. If the issue is shipped, run "
            + "`viber issue done \"<what shipped>\"`. If you can't finish it, run `viber issue failed \"<why>\"`. "
            + "Otherwise carry on with it. "
            + (left <= 1 ? "If the next turn ends without either, the issue counts as stuck."
                         : "After \(left) more turns without either, the issue counts as stuck.")
    }

    /// Sent to an active issue's session when you resume a paused run.
    public static let resumeMessage = "Viber's autopilot resumed. Carry on with the issue where you left off, and report with "
        + "`viber issue done \"<what shipped>\"` or `viber issue failed \"<why>\"` when you're through."

    /// A path as a shell word.
    static func quoted(_ path: String) -> String {
        path.allSatisfy { $0.isLetter || $0.isNumber || "/._-~".contains($0) } ? path
            : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
