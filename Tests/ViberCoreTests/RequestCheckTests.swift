import XCTest
@testable import ViberCore

final class RequestCheckTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_790_000_000)

    private func t(_ seconds: TimeInterval) -> Date { at.addingTimeInterval(seconds) }

    func testMessageNamesTheTestCommandOrLetsClaudeFindIt() {
        let given = RequestCheck(enabled: true, testCommand: "  swift test \n").message
        XCTAssertTrue(given.contains("Run the tests with `swift test`, and fix what fails."))
        XCTAssertTrue(given.contains("own `code-review` skill"))
        XCTAssertTrue(given.contains("Don't push."))
        let found = RequestCheck(enabled: true).message
        XCTAssertTrue(found.contains("the way it runs them"))
        XCTAssertFalse(found.contains("``"))
    }

    func testChecksARequestOnceItsDoneAndNotWhatTheCheckChanged() {
        var progress = CheckProgress()
        progress.requestStarted(at: t(0))
        XCTAssertEqual(progress.turnEnded(state: .finished, lastEdit: nil, agentsRunning: false, interruptedAt: nil), .nothing,
                       "outside git, nothing tells a request without edits apart")
        progress.requestStarted(at: t(20))
        XCTAssertEqual(progress.turnEnded(state: .finished, lastEdit: t(25), agentsRunning: false, interruptedAt: nil), .check)
        progress.checkSent(at: t(30))
        XCTAssertTrue(progress.isChecking)
        XCTAssertEqual(progress.turnEnded(state: .finished, lastEdit: t(40), agentsRunning: false, interruptedAt: nil), .nothing)
        XCTAssertFalse(progress.isChecking)
        XCTAssertTrue(progress.checked)
        XCTAssertEqual(progress.turnEnded(state: .finished, lastEdit: t(50), agentsRunning: false, interruptedAt: nil), .nothing,
                       "a turn of its own afterwards, such as an agent's result, isn't checked again")
        progress.requestStarted(at: t(60))
        XCTAssertFalse(progress.checked)
        XCTAssertEqual(progress.turnEnded(state: .finished, lastEdit: t(65), agentsRunning: false, interruptedAt: nil), .check)
    }

    func testComparesTheWorkTreeWhenNoEditToolRan() {
        var progress = CheckProgress()
        progress.requestStarted(at: t(0))
        progress.setBaseline(42, for: t(0))
        XCTAssertEqual(progress.turnEnded(state: .finished, lastEdit: nil, agentsRunning: false, interruptedAt: nil), .compare(42))
        progress.comparing = true
        progress.requestStarted(at: t(10))
        XCTAssertFalse(progress.comparing, "a new request drops the comparison")
        progress.setBaseline(7, for: t(0))
        XCTAssertNil(progress.baseline, "a state read for an earlier request")
        XCTAssertEqual(progress.turnEnded(state: .finished, lastEdit: t(5), agentsRunning: false, interruptedAt: nil), .nothing,
                       "edits from before the request")
    }

    func testSkipsStoppedFailedAndBusyRequests() {
        var progress = CheckProgress()
        progress.requestStarted(at: t(0))
        progress.setBaseline(1, for: t(0))
        XCTAssertEqual(progress.turnEnded(state: .finished, lastEdit: t(5), agentsRunning: true, interruptedAt: nil), .nothing)
        XCTAssertEqual(progress.turnEnded(state: .failed, lastEdit: t(5), agentsRunning: false, interruptedAt: nil), .nothing,
                       "a usage limit or an error: its continue decides")
        XCTAssertEqual(progress.turnEnded(state: .finished, lastEdit: t(25), agentsRunning: false, interruptedAt: nil), .check,
                       "the turn the agent's result started")
        XCTAssertEqual(progress.turnEnded(state: .finished, lastEdit: t(25), agentsRunning: false, interruptedAt: t(26)), .nothing,
                       "you stopped Claude during the request")
    }

    func testAFailedCheckWaitsAndStoppingOneEndsIt() {
        var progress = CheckProgress()
        progress.requestStarted(at: t(0))
        progress.checkSent(at: t(10))
        XCTAssertEqual(progress.turnEnded(state: .failed, lastEdit: t(15), agentsRunning: false, interruptedAt: nil), .nothing)
        XCTAssertTrue(progress.isChecking, "a usage limit's continue carries the check on")
        XCTAssertEqual(progress.turnEnded(state: .finished, lastEdit: t(25), agentsRunning: false, interruptedAt: t(24)), .nothing)
        XCTAssertFalse(progress.isChecking, "you stopped it")

        progress.requestStarted(at: t(30))
        progress.checkSent(at: t(40))
        progress.requestStarted(at: t(50))
        XCTAssertFalse(progress.isChecking, "your next request drops a check left unfinished")
        XCTAssertEqual(progress.turnEnded(state: .finished, lastEdit: t(55), agentsRunning: false, interruptedAt: t(24)), .check)
    }

    func testFingerprintChangesWithShellEditsCommitsAndUntrackedFiles() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("fingerprint-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: repo + "/sub", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let git = { (args: [String]) in _ = Shell.run("git", ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@t"] + args) }
        git(["init", "-q"])
        XCTAssertNotNil(Worktree.fingerprint(repo), "a repository without commits")
        try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        git(["add", "."]); git(["commit", "-qm", "one"])
        let start = try XCTUnwrap(Worktree.fingerprint(repo + "/sub"))
        XCTAssertEqual(Worktree.fingerprint(repo), start, "the same from a subfolder")

        try "two\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        let edited = try XCTUnwrap(Worktree.fingerprint(repo))
        XCTAssertNotEqual(edited, start)
        try "three\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        XCTAssertNotEqual(Worktree.fingerprint(repo), edited, "another change to an already changed file")
        git(["commit", "-qam", "three"])
        let committed = try XCTUnwrap(Worktree.fingerprint(repo))
        XCTAssertNotEqual(committed, start)

        try "new\n".write(toFile: repo + "/sub/b.txt", atomically: true, encoding: .utf8)
        let untracked = try XCTUnwrap(Worktree.fingerprint(repo))
        XCTAssertNotEqual(untracked, committed)
        try "newer, longer\n".write(toFile: repo + "/sub/b.txt", atomically: true, encoding: .utf8)
        XCTAssertNotEqual(Worktree.fingerprint(repo), untracked, "an untracked file that changed")

        XCTAssertNil(Worktree.fingerprint(FileManager.default.temporaryDirectory.path), "outside git")
    }

    func testCodableRoundTrip() throws {
        let checks = ["/repo": RequestCheck(enabled: true, testCommand: "swift test")]
        let data = try JSONEncoder().encode(checks)
        XCTAssertEqual(try JSONDecoder().decode([String: RequestCheck].self, from: data), checks)
    }
}
