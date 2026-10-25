import XCTest
@testable import ViberCore

final class AutopilotTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_790_000_000)

    private func pilot(_ issues: [Issue], finish: Autopilot.Finish = .pullRequest, pattern: String = "viber/<slug>") -> Autopilot {
        Autopilot(project: "/repo", issues: issues.map(\.id), finish: finish, target: "master", permissionMode: "auto",
                  profile: nil, branchPattern: pattern)
    }

    func testTakesIdeasOldestFirstSkippingOnesNoLongerToPlan() throws {
        var list = IssueList()
        let first = try XCTUnwrap(list.add("first", project: "/repo", by: "you", at: at))
        let planned = try XCTUnwrap(list.add("planned meanwhile", project: "/repo", by: "you", at: at.addingTimeInterval(1)))
        let third = try XCTUnwrap(list.add("third", project: "/repo", by: "you", at: at.addingTimeInterval(2)))
        list.add("elsewhere", project: "/other", by: "you")
        XCTAssertEqual(list.toPlan(in: "/repo").map(\.text), ["first", "planned meanwhile", "third"])

        var run = pilot(list.toPlan(in: "/repo"))
        XCTAssertEqual(run.takeNext(from: list)?.id, first.id)
        XCTAssertNil(run.takeNext(from: list), "one issue at a time")
        list.start(planned.id, sessionID: "p", sessionTitle: "Planned")
        XCTAssertEqual(run.upcoming(in: list).map(\.id), [third.id])

        run.finish(first.id, stuck: false)
        XCTAssertEqual(run.takeNext(from: list)?.id, third.id, "an issue planned by hand is skipped")
        run.finish(third.id, stuck: true)
        XCTAssertNil(run.takeNext(from: list))
        XCTAssertTrue(run.active.isEmpty)
        XCTAssertEqual(run.tally, "1 done, 1 stuck")
    }

    func testEnqueueAddsOnceAndNotTheCurrentIdea() throws {
        var list = IssueList()
        let a = try XCTUnwrap(list.add("a", project: "/repo", by: "you"))
        let b = try XCTUnwrap(list.add("b", project: "/repo", by: "you"))
        var run = pilot([a])
        _ = run.takeNext(from: list)
        run.enqueue(a.id)
        run.enqueue(b.id)
        run.enqueue(b.id)
        XCTAssertEqual(run.queue, [b.id])
    }

    func testRemindsTwiceThenGivesUpButWaitsForBackgroundWork() throws {
        var list = IssueList()
        let a = try XCTUnwrap(list.add("a", project: "/repo", by: "you"))
        var run = pilot([a])
        _ = run.takeNext(from: list)
        XCTAssertEqual(run.afterTurn(for: a.id, backgroundWork: true), .wait)
        XCTAssertEqual(run.afterTurn(for: a.id, backgroundWork: false), .nudge)
        XCTAssertTrue(run.nudge(for: a.id).contains("After 2 more turns"))
        run.nudged(a.id)
        XCTAssertEqual(run.afterTurn(for: a.id, backgroundWork: false), .nudge)
        XCTAssertTrue(run.nudge(for: a.id).contains("If the next turn ends without either"))
        run.nudged(a.id)
        XCTAssertEqual(run.afterTurn(for: a.id, backgroundWork: false), .giveUp)
        XCTAssertEqual(run.afterTurn(for: a.id, backgroundWork: true), .wait)

        run.resume()
        XCTAssertEqual(run.afterTurn(for: a.id, backgroundWork: false), .nudge, "resuming starts the reminders over")
    }

    func testCountsStuckIdeasInARow() throws {
        var list = IssueList()
        let issues = try (0..<4).map { try XCTUnwrap(list.add("issue \($0)", project: "/repo", by: "you")) }
        var run = pilot(issues)
        for _ in 0..<2 { let id = run.takeNext(from: list)!.id; run.finish(id, stuck: true) }
        XCTAssertEqual(run.stuckInARow, 2)
        do { let id = run.takeNext(from: list)!.id; run.finish(id, stuck: false) }
        XCTAssertEqual(run.stuckInARow, 0, "one that ships resets the count")
        do { let id = run.takeNext(from: list)!.id; run.finish(id, stuck: true) }
        XCTAssertEqual(run.stuckInARow, 1)
        run.resume()
        XCTAssertEqual(run.stuckInARow, 0)
        XCTAssertEqual(run.tally, "1 done, 3 stuck")
    }

    func testSeveralAtOnceWithinTheWorktreeCap() throws {
        var list = IssueList()
        let issues = try (0..<5).map { try XCTUnwrap(list.add("issue \($0)", project: "/repo", by: "you", at: at)) }
        var run = Autopilot(project: "/repo", issues: issues.map(\.id), finish: .pullRequest, target: nil, permissionMode: "auto",
                            profile: nil, branchPattern: "viber/<slug>", sessionsAtOnce: 3, worktreesAtMost: 4)
        XCTAssertEqual(run.takeNext(from: list, openWorktrees: 0)?.id, issues[0].id)
        XCTAssertEqual(run.takeNext(from: list, openWorktrees: 1)?.id, issues[1].id)
        XCTAssertEqual(run.takeNext(from: list, openWorktrees: 2)?.id, issues[2].id)
        XCTAssertNil(run.takeNext(from: list, openWorktrees: 3), "three at once")
        XCTAssertEqual(run.active, issues.prefix(3).map(\.id))
        run.finish(issues[1].id, stuck: false)
        XCTAssertNil(run.takeNext(from: list, openWorktrees: 4), "a slot is free, but the project has four worktrees open")
        XCTAssertEqual(run.takeNext(from: list, openWorktrees: 3)?.id, issues[3].id)
        XCTAssertEqual(run.active, [issues[0].id, issues[2].id, issues[3].id])
        XCTAssertEqual(Autopilot(project: "/repo", issues: [], finish: .commit, target: nil, permissionMode: "auto", profile: nil,
                                 branchPattern: "viber/<slug>", sessionsAtOnce: 20, worktreesAtMost: 1).sessionsAtOnce, Autopilot.maxSessions)
    }

    func testBlockedIssuesWaitForTheirBlockerInTheRun() throws {
        var list = IssueList()
        let api = try XCTUnwrap(list.add("API", project: "/repo", by: "you", at: at))
        let web = try XCTUnwrap(list.add("Web", project: "/repo", by: "you", blockedBy: [api.key], at: at))
        let other = try XCTUnwrap(list.add("Other", project: "/repo", by: "you", at: at))
        let outside = try XCTUnwrap(list.add("Outside", project: "/repo", by: "you", at: at))
        let last = try XCTUnwrap(list.add("Last", project: "/repo", by: "you", blockedBy: [outside.key], at: at))
        var run = Autopilot(project: "/repo", issues: [api.id, web.id, other.id, last.id], finish: .commit, target: nil,
                            permissionMode: "auto", profile: nil, branchPattern: "viber/<slug>", sessionsAtOnce: 3)
        XCTAssertEqual(run.takeNext(from: list)?.id, api.id)
        XCTAssertEqual(run.takeNext(from: list)?.id, other.id, "Web waits for API, which is active")
        XCTAssertEqual(run.takeNext(from: list)?.id, last.id, "Outside isn't in the run, so Last isn't held back")
        XCTAssertEqual(run.waiting(in: list).map { $0.issue.id }, [web.id])
        XCTAssertEqual(run.waiting(in: list).first?.for.map(\.id), [api.id])
        run.finish(other.id, stuck: false)
        XCTAssertNil(run.takeNext(from: list), "only Web is left, and API is still active")
        list.report(api.id, "Shipped", finished: true)
        run.finish(api.id, stuck: false)
        XCTAssertEqual(run.takeNext(from: list)?.id, web.id)
        XCTAssertTrue(run.prompt(for: web, in: list, startBranch: "viber/rep-1-api").contains("starts from `viber/rep-1-api`"))
    }

    func testBranchPatternMustNameABranchPerIdea() throws {
        XCTAssertEqual(pilot([], pattern: "feat/<slug>").branchPattern, "feat/<slug>")
        XCTAssertEqual(pilot([], pattern: "feat/NEX-<id>-<slug>").branchPattern, Worktree.defaultBranchPattern, "only you know <id>")
        XCTAssertEqual(pilot([], pattern: "wip").branchPattern, Worktree.defaultBranchPattern, "one branch for every issue")
        XCTAssertEqual(pilot([], pattern: "feat/<key>-<slug>").branchPattern, "feat/<key>-<slug>", "Viber fills in the issue's key")
    }

    func testPromptCarriesTheIdeaHowToShipAndHowToReport() throws {
        var list = IssueList()
        let blocker = try XCTUnwrap(list.add("Index messages", project: "/repo", by: "you", at: at))
        let issue = try XCTUnwrap(list.add("Add search\nTo the Messages panel.", project: "/repo", by: "you", blockedBy: [blocker.key], at: at))
        let pr = pilot([issue], finish: .pullRequest).prompt(for: issue, in: list)
        XCTAssertTrue(pr.hasPrefix("Autopilot: REP-2 Add search\n"), "past sessions are listed by their first line")
        XCTAssertTrue(pr.contains("Add search\nTo the Messages panel."))
        XCTAssertTrue(pr.contains("blocked by REP-1 (to do)"))
        XCTAssertTrue(pr.contains("open a pull request"))
        XCTAssertTrue(pr.contains("viber issue done"))
        XCTAssertTrue(pr.contains("viber issue failed"))
        XCTAssertFalse(pr.contains("--ff-only"))

        let merge = Autopilot(project: "/Users/me/My App", issues: [issue.id], finish: .merge, target: "master",
                              permissionMode: "auto", profile: nil, branchPattern: "viber/<slug>").prompt(for: issue, in: list)
        XCTAssertTrue(merge.contains("merge `master` into this branch"))
        XCTAssertTrue(merge.contains("git -C '/Users/me/My App' merge --ff-only"))
        XCTAssertTrue(merge.contains("Don't push."))

        let commit = pilot([issue], finish: .commit).prompt(for: issue, in: list)
        XCTAssertTrue(commit.contains("don't push or merge"))
        list.setStatus(blocker.id, .done)
        XCTAssertFalse(pilot([issue], finish: .commit).prompt(for: issue, in: list).contains("blocked by"), "a done blocker is no blocker")
    }

    func testPromptReviewsBeforeShippingWhenTheProjectChecksEachRequest() throws {
        var list = IssueList()
        let issue = try XCTUnwrap(list.add("Add search", project: "/repo", by: "you", at: at))
        let plain = pilot([issue]).prompt(for: issue, in: list)
        XCTAssertFalse(plain.contains("code-review"))
        XCTAssertTrue(plain.contains("\n5. Report, as your last step"))

        let checked = pilot([issue]).prompt(for: issue, in: list, check: RequestCheck(enabled: true, testCommand: "swift test"))
        let review = try XCTUnwrap(checked.range(of: "4. Before shipping, the project asks for its tests and a code review: Run the tests with `swift test`"))
        let ship = try XCTUnwrap(checked.range(of: "5. Ship it: commit, push the branch"))
        XCTAssertLessThan(review.lowerBound, ship.lowerBound, "reviewed before it ships")
        XCTAssertTrue(checked.contains("own `code-review` skill"))
        XCTAssertTrue(checked.contains("\n6. Report, as your last step"))
    }

    func testReportsFinishOrKeepTheIdeaStarted() throws {
        var list = IssueList()
        let shipped = try XCTUnwrap(list.add("shipped", project: "/repo", by: "you"))
        let stuck = try XCTUnwrap(list.add("stuck", project: "/repo", by: "you"))
        list.start(shipped.id, sessionID: "p1", sessionTitle: "Shipped")
        list.start(stuck.id, sessionID: "p2", sessionTitle: "Stuck")
        XCTAssertEqual(list.issue(startedIn: "p2")?.id, stuck.id)
        XCTAssertNil(list.issue(startedIn: "p3"))

        list.report(shipped.id, "Added search", finished: true, at: at)
        list.report(stuck.id, "Tests fail on master", finished: false, at: at)
        XCTAssertEqual(list.issue(shipped.id)?.status, .done)
        XCTAssertEqual(list.issue(shipped.id)?.report, Issue.Report(text: "Added search", finished: true, at: at))
        XCTAssertEqual(list.issue(stuck.id)?.status, .started, "a stuck issue stays with its session")
        XCTAssertEqual(list.issue(stuck.id)?.sessionID, "p2")

        list.setStatus(stuck.id, .open)
        XCTAssertNil(list.issue(stuck.id)?.report, "back to plan forgets the report")
        list.report(stuck.id, "Couldn't make its worktree", finished: false)
        list.start(stuck.id, sessionID: "p4", sessionTitle: "Stuck again")
        XCTAssertNil(list.issue(stuck.id)?.report, "a new session starts clean")
    }

    func testIdeasWithoutAReportStillLoad() throws {
        // issues.json from before reports; older Viber versions ignore the new field in turn.
        let json = #"{"issues":[{"id":"a","project":"/repo","text":"t","createdAt":1790000000,"createdBy":"you","status":"open","updatedAt":1790000000}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let list = try decoder.decode(IssueList.self, from: Data(json.utf8))
        XCTAssertNil(list.issue("a")?.report)
    }

    func testReportRequests() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viber-req-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ViberRequest(paneID: "p1", command: .issueDone, text: "Added search").write(to: dir)
        try ViberRequest(paneID: "p1", command: .issueFailed, text: "Tests fail").write(to: dir)
        let drained = ViberRequest.drain(dir)
        XCTAssertEqual(drained.map(\.command), [.issueDone, .issueFailed])
        XCTAssertEqual(drained.last?.text, "Tests fail")
    }
}
