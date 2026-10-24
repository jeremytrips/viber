import XCTest
@testable import ViberCore

final class AutopilotTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_790_000_000)

    private func pilot(_ ideas: [Idea], finish: Autopilot.Finish = .pullRequest, pattern: String = "viber/<slug>") -> Autopilot {
        Autopilot(project: "/repo", ideas: ideas.map(\.id), finish: finish, target: "master", permissionMode: "auto",
                  profile: nil, branchPattern: pattern)
    }

    func testTakesIdeasOldestFirstSkippingOnesNoLongerToPlan() throws {
        var list = IdeaList()
        let first = try XCTUnwrap(list.add("first", project: "/repo", by: "you", at: at))
        let planned = try XCTUnwrap(list.add("planned meanwhile", project: "/repo", by: "you", at: at.addingTimeInterval(1)))
        let third = try XCTUnwrap(list.add("third", project: "/repo", by: "you", at: at.addingTimeInterval(2)))
        list.add("elsewhere", project: "/other", by: "you")
        XCTAssertEqual(list.toPlan(in: "/repo").map(\.text), ["first", "planned meanwhile", "third"])

        var run = pilot(list.toPlan(in: "/repo"))
        XCTAssertEqual(run.takeNext(from: list)?.id, first.id)
        XCTAssertNil(run.takeNext(from: list), "one idea at a time")
        list.start(planned.id, sessionID: "p", sessionTitle: "Planned")
        XCTAssertEqual(run.upcoming(in: list).map(\.id), [third.id])

        run.finishCurrent(stuck: false)
        XCTAssertEqual(run.takeNext(from: list)?.id, third.id, "an idea planned by hand is skipped")
        run.finishCurrent(stuck: true)
        XCTAssertNil(run.takeNext(from: list))
        XCTAssertNil(run.current)
        XCTAssertEqual(run.tally, "1 done, 1 stuck")
    }

    func testEnqueueAddsOnceAndNotTheCurrentIdea() throws {
        var list = IdeaList()
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
        var list = IdeaList()
        let a = try XCTUnwrap(list.add("a", project: "/repo", by: "you"))
        var run = pilot([a])
        _ = run.takeNext(from: list)
        XCTAssertEqual(run.afterTurn(backgroundWork: true), .wait)
        XCTAssertEqual(run.afterTurn(backgroundWork: false), .nudge)
        XCTAssertTrue(run.nudge().contains("After 2 more turns"))
        run.nudged()
        XCTAssertEqual(run.afterTurn(backgroundWork: false), .nudge)
        XCTAssertTrue(run.nudge().contains("If the next turn ends without either"))
        run.nudged()
        XCTAssertEqual(run.afterTurn(backgroundWork: false), .giveUp)
        XCTAssertEqual(run.afterTurn(backgroundWork: true), .wait)

        run.resume()
        XCTAssertEqual(run.afterTurn(backgroundWork: false), .nudge, "resuming starts the reminders over")
    }

    func testCountsStuckIdeasInARow() throws {
        var list = IdeaList()
        let ideas = try (0..<4).map { try XCTUnwrap(list.add("idea \($0)", project: "/repo", by: "you")) }
        var run = pilot(ideas)
        for _ in 0..<2 { _ = run.takeNext(from: list); run.finishCurrent(stuck: true) }
        XCTAssertEqual(run.stuckInARow, 2)
        _ = run.takeNext(from: list); run.finishCurrent(stuck: false)
        XCTAssertEqual(run.stuckInARow, 0, "one that ships resets the count")
        _ = run.takeNext(from: list); run.finishCurrent(stuck: true)
        XCTAssertEqual(run.stuckInARow, 1)
        run.resume()
        XCTAssertEqual(run.stuckInARow, 0)
        XCTAssertEqual(run.tally, "1 done, 3 stuck")
    }

    func testBranchPatternMustNameABranchPerIdea() throws {
        XCTAssertEqual(pilot([], pattern: "feat/<slug>").branchPattern, "feat/<slug>")
        XCTAssertEqual(pilot([], pattern: "feat/NEX-<id>-<slug>").branchPattern, Worktree.defaultBranchPattern, "only you know <id>")
        XCTAssertEqual(pilot([], pattern: "wip").branchPattern, Worktree.defaultBranchPattern, "one branch for every idea")
    }

    func testPromptCarriesTheIdeaHowToShipAndHowToReport() throws {
        let idea = Idea(project: "/repo", text: "Add search\nTo the Messages panel.", createdAt: at, createdBy: "you")
        let pr = pilot([idea], finish: .pullRequest).prompt(for: idea)
        XCTAssertTrue(pr.hasPrefix("Autopilot: Add search\n"), "past sessions are listed by their first line")
        XCTAssertTrue(pr.contains("Add search\nTo the Messages panel."))
        XCTAssertTrue(pr.contains("open a pull request"))
        XCTAssertTrue(pr.contains("viber idea done"))
        XCTAssertTrue(pr.contains("viber idea failed"))
        XCTAssertFalse(pr.contains("--ff-only"))

        let merge = Autopilot(project: "/Users/me/My App", ideas: [idea.id], finish: .merge, target: "master",
                              permissionMode: "auto", profile: nil, branchPattern: "viber/<slug>").prompt(for: idea)
        XCTAssertTrue(merge.contains("merge `master` into this branch"))
        XCTAssertTrue(merge.contains("git -C '/Users/me/My App' merge --ff-only"))
        XCTAssertTrue(merge.contains("Don't push."))

        let commit = pilot([idea], finish: .commit).prompt(for: idea)
        XCTAssertTrue(commit.contains("don't push or merge"))
    }

    func testReportsFinishOrKeepTheIdeaStarted() throws {
        var list = IdeaList()
        let shipped = try XCTUnwrap(list.add("shipped", project: "/repo", by: "you"))
        let stuck = try XCTUnwrap(list.add("stuck", project: "/repo", by: "you"))
        list.start(shipped.id, sessionID: "p1", sessionTitle: "Shipped")
        list.start(stuck.id, sessionID: "p2", sessionTitle: "Stuck")
        XCTAssertEqual(list.idea(startedIn: "p2")?.id, stuck.id)
        XCTAssertNil(list.idea(startedIn: "p3"))

        list.report(shipped.id, "Added search", finished: true, at: at)
        list.report(stuck.id, "Tests fail on master", finished: false, at: at)
        XCTAssertEqual(list.idea(shipped.id)?.status, .done)
        XCTAssertEqual(list.idea(shipped.id)?.report, Idea.Report(text: "Added search", finished: true, at: at))
        XCTAssertEqual(list.idea(stuck.id)?.status, .started, "a stuck idea stays with its session")
        XCTAssertEqual(list.idea(stuck.id)?.sessionID, "p2")

        list.setStatus(stuck.id, .open)
        XCTAssertNil(list.idea(stuck.id)?.report, "back to plan forgets the report")
        list.report(stuck.id, "Couldn't make its worktree", finished: false)
        list.start(stuck.id, sessionID: "p4", sessionTitle: "Stuck again")
        XCTAssertNil(list.idea(stuck.id)?.report, "a new session starts clean")
    }

    func testIdeasWithoutAReportStillLoad() throws {
        // ideas.json from before reports; older Viber versions ignore the new field in turn.
        let json = #"{"ideas":[{"id":"a","project":"/repo","text":"t","createdAt":1790000000,"createdBy":"you","status":"open","updatedAt":1790000000}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let list = try decoder.decode(IdeaList.self, from: Data(json.utf8))
        XCTAssertNil(list.idea("a")?.report)
    }

    func testReportRequests() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viber-req-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ViberRequest(paneID: "p1", command: .ideaDone, text: "Added search").write(to: dir)
        try ViberRequest(paneID: "p1", command: .ideaFailed, text: "Tests fail").write(to: dir)
        let drained = ViberRequest.drain(dir)
        XCTAssertEqual(drained.map(\.command), [.ideaDone, .ideaFailed])
        XCTAssertEqual(drained.last?.text, "Tests fail")
    }
}
