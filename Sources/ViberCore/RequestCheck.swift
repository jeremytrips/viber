import Foundation

/// What a project's sessions do once a request that changed files is done, when the project asks for it: run the
/// tests and a code review, and fix what they find. Autopilot sessions do it before they ship instead. Set on the
/// project's Settings tab; stored by Viber, not in the repository.
public struct RequestCheck: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Runs the project's tests, such as `swift test`. Empty: Claude runs them the way the project says.
    public var testCommand: String

    public init(enabled: Bool = false, testCommand: String = "") {
        self.enabled = enabled; self.testCommand = testCommand
    }

    /// Named exactly: with a plugin's pull-request review installed too, Claude picked that one.
    static let reviewSkill = "Claude Code's own `code-review` skill: that exact name, not a plugin's pull-request review "
        + "such as `code-review:code-review`"

    /// "Run the tests with `swift test`", or the project's own way when no command is set.
    var runTests: String {
        let command = testCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty
            ? "Run the project's tests the way it runs them (its CLAUDE.md, AGENTS.md, README or build files say how)"
            : "Run the tests with `\(command)`"
    }

    /// The message the session gets once its request is done.
    public var message: String {
        """
        Viber's check after a request: this project has its tests and a code review run once a request that changed files is done.

        1. \(runTests), and fix what fails.
        2. Review the changes this request made with \(Self.reviewSkill). Point it at the branch if the changes are \
        committed already. Fix the findings you agree with and leave the rest.
        3. If you changed anything, run the tests again.
        4. If the request's work is committed, commit the fixes on top. Don't push.
        5. Finish with a short report: how the tests went, what you fixed, and the findings you left, each with why.
        """
    }

    /// The step an autopilot session takes once its work is checked and before it ships or commits it.
    public var beforeShipping: String {
        "\(runTests), and fix what fails. Then review your changes with \(Self.reviewSkill). Fix the findings you agree "
            + "with, run the tests again if you changed anything, and note the findings you left, with why, in the commit message."
    }
}

/// Where one session is with checking its request: when the request started and the state of the work tree then,
/// whether a check is running, and whether the request was checked.
public struct CheckProgress: Equatable, Sendable {
    /// What to do once a turn ends.
    public enum Next: Equatable, Sendable {
        case nothing
        /// Claude's edit tools changed files in this request: send the check.
        case check
        /// Read the work tree and send the check if it differs from this state at the request's start: shell commands
        /// change files too, and the chat can't see those.
        case compare(Int)
    }

    /// When the request being worked on started: a message that found Claude idle. Ones sent while it works join it.
    public private(set) var requestStartedAt: Date?
    /// The work tree's state when the request started (Worktree.fingerprint), once it is read; nil outside git.
    public private(set) var baseline: Int?
    /// When Viber sent the check that is running.
    public private(set) var checkStartedAt: Date?
    /// The request was checked, or its check stopped: nothing more until the next request, so what a check fixes
    /// isn't checked again.
    public private(set) var checked = false
    /// The work tree is being read to tell whether the request changed it. Its "Finished" notification waits for that.
    public var comparing = false

    public init() {}

    public var isChecking: Bool { checkStartedAt != nil }

    /// A message that starts a new request. A check left unfinished (its turn failed) is dropped.
    public mutating func requestStarted(at date: Date) {
        requestStartedAt = date
        baseline = nil
        checkStartedAt = nil
        checked = false
        comparing = false
    }

    /// The work tree as it was when `request` started. Ignored once another request started.
    public mutating func setBaseline(_ state: Int?, for request: Date) {
        if request == requestStartedAt { baseline = state }
    }

    public mutating func checkSent(at date: Date) {
        checkStartedAt = date
        comparing = false
    }

    /// A turn ended. The request gets its check once it is done (finished, and none of Claude's agents still run:
    /// the turn their result starts decides), nobody stopped it, and it changed files. A check's own turn ends the check.
    public mutating func turnEnded(state: PaneState, lastEdit: Date?, agentsRunning: Bool, interruptedAt: Date?) -> Next {
        let done = state == .finished && !agentsRunning
        if let started = checkStartedAt {
            // A failed check waits for the usage limit's continue; your next message drops it.
            let stopped = interruptedAt.map { $0 >= started } ?? false
            guard done || stopped else { return .nothing }
            checkStartedAt = nil
            checked = true
            return .nothing
        }
        let since = requestStartedAt ?? .distantPast
        guard done, !checked else { return .nothing }
        // You stopped Claude during the request.
        if let interruptedAt, interruptedAt >= since { return .nothing }
        if let lastEdit, lastEdit > since { return .check }
        return baseline.map(Next.compare) ?? .nothing
    }
}
