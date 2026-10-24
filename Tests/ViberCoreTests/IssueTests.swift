import XCTest
@testable import ViberCore

final class IssueTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_790_000_000)

    func testKeysComeFromTheFolderNameAndCountUp() throws {
        XCTAssertEqual(IssueList.defaultPrefix(forProject: "/Users/me/dev/estafette"), "EST")
        XCTAssertEqual(IssueList.defaultPrefix(forProject: "/Users/me/dev/nexus-cloud"), "NC")
        XCTAssertEqual(IssueList.defaultPrefix(forProject: "/Users/me/dev/blog.jeremytrips.com"), "BJC")
        XCTAssertEqual(IssueList.defaultPrefix(forProject: "/Users/me/dev/3ngine"), "3NG")
        XCTAssertEqual(IssueList.defaultPrefix(forProject: "/tmp/..."), "ISSUE")

        var list = IssueList()
        let a = try XCTUnwrap(list.add("a", project: "/dev/estafette", by: "you", at: at))
        let b = try XCTUnwrap(list.add("b", project: "/dev/estafette", by: "you", at: at))
        let other = try XCTUnwrap(list.add("c", project: "/dev/viber", by: "you", at: at))
        XCTAssertEqual([a.key, b.key, other.key], ["EST-1", "EST-2", "VIB-1"])
        list.remove(b.id)
        XCTAssertEqual(list.add("d", project: "/dev/estafette", by: "you")?.key, "EST-3", "a deleted key isn't given out again")
        XCTAssertEqual(list.issue("est-1", in: "/dev/estafette")?.id, a.id, "keys match in any case")
        XCTAssertNil(list.issue("EST-1", in: "/dev/viber"))
    }

    func testChangingThePrefixRenamesTheKeys() throws {
        var list = IssueList()
        let a = try XCTUnwrap(list.add("a", project: "/dev/estafette", by: "you", at: at))
        list.setPrefix("relay", project: "/dev/estafette")
        XCTAssertEqual(list.prefix(for: "/dev/estafette"), "RELAY")
        XCTAssertEqual(list.issue(a.id)?.key, "RELAY-1")
        XCTAssertEqual(list.add("b", project: "/dev/estafette", by: "you")?.key, "RELAY-2")
        list.setPrefix("", project: "/dev/estafette")
        XCTAssertEqual(list.issue(a.id)?.key, "EST-1", "back to the default")
        XCTAssertEqual(IssueList.cleanPrefix(" my-app 2 "), "MYAPP2")
    }

    func testStatusNames() {
        XCTAssertEqual(Issue.Status.parse("todo"), .open)
        XCTAssertEqual(Issue.Status.parse("In Progress"), .started)
        XCTAssertEqual(Issue.Status.parse("review"), .review)
        XCTAssertEqual(Issue.Status.parse("done"), .done)
        XCTAssertNil(Issue.Status.parse("later"))
        XCTAssertEqual(Issue.Status.review.label, "In review")
    }

    func testAnIssueIsFoundByItsBranch() throws {
        var list = IssueList()
        let one = try XCTUnwrap(list.add("Login", project: "/repo", by: "you", at: at))
        let twelve = (2...12).map { _ in list.add("x", project: "/repo", by: "you", at: at)! }.last!
        XCTAssertEqual(one.key, "REP-1")
        XCTAssertEqual(twelve.key, "REP-12")
        XCTAssertEqual(list.issue(forBranch: "viber/rep-12-login", in: "/repo")?.id, twelve.id)
        XCTAssertEqual(list.issue(forBranch: "feat/REP-1", in: "/repo")?.id, one.id)
        XCTAssertNil(list.issue(forBranch: "feat/rep-123-login", in: "/repo"), "REP-12 isn't REP-123")
        XCTAssertNil(list.issue(forBranch: "main", in: "/repo"))
        XCTAssertNil(list.issue(forBranch: "viber/rep-1", in: "/other"))
    }

    func testSubIssuesAndBlockers() throws {
        var list = IssueList()
        let epic = try XCTUnwrap(list.add("Readiness check", project: "/repo", by: "you", at: at))
        let consent = try XCTUnwrap(list.add("Consent flow", project: "/repo", by: "you", parent: epic.key, at: at))
        let report = try XCTUnwrap(list.add("Report page", project: "/repo", by: "you", parent: "rep-1", blockedBy: [consent.key, "nope"], at: at))
        XCTAssertEqual(list.children(of: epic.id).map(\.key), ["REP-2", "REP-3"])
        XCTAssertEqual(list.issue(report.id)?.blockedBy, [consent.id], "unknown keys are dropped")
        XCTAssertEqual(list.blockers(of: list.issue(report.id)!).map(\.key), ["REP-2"])

        list.setStatus(consent.id, .done)
        XCTAssertTrue(list.blockers(of: list.issue(report.id)!).isEmpty, "a done issue blocks nothing")

        list.setLinks(report.id, parent: nil, blockedBy: [report.key, epic.key])
        XCTAssertNil(list.issue(report.id)?.parentID)
        XCTAssertEqual(list.issue(report.id)?.blockedBy, [epic.id], "not by itself")

        list.remove(epic.id)
        XCTAssertNil(list.issue(consent.id)?.parentID, "sub-issues of a removed issue stand alone")
        XCTAssertEqual(list.issue(report.id)?.blockedBy, [])
    }

    func testCommentsAndDetail() throws {
        var list = IssueList()
        let issue = try XCTUnwrap(list.add("Add search\nTo the Messages panel.", project: "/repo", by: "you", at: at))
        list.comment(issue.id, "Lives in Sources/Viber/ChatView.swift", by: "Backend", at: at)
        list.comment(issue.id, "  ", by: "you")
        XCTAssertEqual(list.issue(issue.id)?.comments.count, 1)
        let detail = list.detail(list.issue(issue.id)!)
        XCTAssertTrue(detail.hasPrefix("REP-1 · To do\n\nAdd search\nTo the Messages panel."))
        XCTAssertTrue(detail.contains("- Backend, 2026-09-21: Lives in Sources/Viber/ChatView.swift"))
        XCTAssertEqual(issue.body, "To the Messages panel.")
    }

    func testIdeasFromBeforeKeysGetThem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viber-issues-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ideas = dir.appendingPathComponent("ideas.json")
        try Data(#"{"ideas":[{"id":"a","project":"/dev/estafette","text":"first","createdAt":1790000000,"createdBy":"you","status":"done","updatedAt":1790000000},{"id":"b","project":"/dev/estafette","text":"second","createdAt":1790000001,"createdBy":"you","status":"open","updatedAt":1790000001}]}"#.utf8)
            .write(to: ideas)
        let issues = dir.appendingPathComponent("issues.json")
        var list = IssueList.load(from: issues, legacyIdeas: ideas, legacyNotes: dir.appendingPathComponent("notes.json"))
        XCTAssertEqual(list.issues.map(\.key), ["EST-1", "EST-2"])
        XCTAssertEqual(list.issues.map(\.blockedBy), [[], []])
        XCTAssertEqual(list.add("third", project: "/dev/estafette", by: "you", at: at)?.key, "EST-3")

        try list.save(to: issues)
        XCTAssertEqual(IssueList.load(from: issues, legacyIdeas: ideas, legacyNotes: ideas), list, "issues.json wins once it exists")
    }

    func testKeyInBranchPatterns() {
        XCTAssertEqual(Worktree.defaultBranch(forName: "Docker image", pattern: "feat/<key>-<slug>", key: "EST-12"), "feat/est-12-docker-image")
        XCTAssertEqual(Worktree.defaultBranch(forName: "Docker image", pattern: "viber/<slug>", key: "EST-12"), "viber/est-12-docker-image",
                       "a pattern with no place for the key puts it in front of the slug")
        XCTAssertEqual(Worktree.defaultBranch(forName: "Docker image", pattern: "feat/<id>-<slug>", key: "EST-12"), "feat/<id>-docker-image",
                       "a part only the user knows is left for the sheet")
        XCTAssertEqual(Worktree.defaultBranch(forName: "Docker image", pattern: "viber/<slug>"), "viber/docker-image")
        XCTAssertFalse(Worktree.needsInput("feat/<key>-<slug>", key: "EST-12"))
        XCTAssertTrue(Worktree.needsInput("feat/<key>-<slug>"), "a plain new session has no key")
        XCTAssertTrue(Worktree.needsInput("feat/<id>-<key>-<slug>", key: "EST-12"))
    }
}
