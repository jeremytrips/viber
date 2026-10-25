import XCTest
@testable import ViberCore

final class JiraTests: XCTestCase {
    func testSiteHosts() {
        XCTAssertEqual(JiraSite(host: "https://pinsound.atlassian.net/jira/", email: "me@x").host, "pinsound.atlassian.net")
        XCTAssertEqual(JiraSite(host: " PinSound ", email: "me@x").host, "pinsound.atlassian.net")
        XCTAssertEqual(JiraSite(host: "jira.company.com", email: "me@x").browseURL("NEX-1")?.absoluteString, "https://jira.company.com/browse/NEX-1")
    }

    func testParsesASearchPage() throws {
        let json = JSON(any: try JSONSerialization.jsonObject(with: Data("""
        {"issues":[{"key":"NEX-224","fields":{"summary":"User admin: invites","status":{"name":"In Review","statusCategory":{"key":"indeterminate"}},
          "issuetype":{"name":"Story","hierarchyLevel":0},"priority":{"name":"High"},"assignee":{"displayName":"Jeremy","accountId":"a1"},
          "parent":{"key":"NEX-17"},"labels":["mvp"],"updated":"2026-10-24T10:02:37.000+0200",
          "description":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Invites "},{"type":"text","text":"and links."}]},
            {"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"one"}]}]}]}]}}},
         {"key":"NEX-17","fields":{"summary":"Admin","status":{"name":"To Do","statusCategory":{"key":"new"}},"issuetype":{"name":"Epic","hierarchyLevel":1}}}],
         "nextPageToken":"abc","isLast":false}
        """.utf8)))
        let page = JiraClient.parsePage(json)
        XCTAssertEqual(page.nextPageToken, "abc")
        XCTAssertFalse(page.isLast)
        let issue = try XCTUnwrap(page.issues.first)
        XCTAssertEqual(issue.key, "NEX-224")
        XCTAssertEqual(issue.category, .progress)
        XCTAssertEqual(issue.priority, "High")
        XCTAssertEqual(issue.assigneeID, "a1")
        XCTAssertEqual(issue.parentKey, "NEX-17")
        XCTAssertEqual(issue.labels, ["mvp"])
        XCTAssertEqual(issue.description, "Invites and links.\n- one")
        XCTAssertEqual(issue.updated?.timeIntervalSince1970, 1792828957, "10:02:37 in +02:00 is 08:02:37 UTC")
        XCTAssertFalse(issue.isEpic)
        XCTAssertTrue(page.issues[1].isEpic)
        XCTAssertEqual(page.issues[1].category, .todo)
        XCTAssertEqual(issue.projectKey, "NEX")
    }

    func testKeysInBranches() {
        XCTAssertEqual(JiraIssue.key(inBranch: "feat/nex-224-user-admin-invites"), "NEX-224")
        XCTAssertEqual(JiraIssue.key(inBranch: "NEX-7"), "NEX-7")
        XCTAssertEqual(JiraIssue.key(inBranch: "feature/0017-catalog"), nil, "digits first aren't a key")
        XCTAssertEqual(JiraIssue.key(inBranch: "main"), nil)
        XCTAssertEqual(JiraIssue.key(inBranch: "chore/dev-up"), nil)
    }

    func testTrackerDefaultsAndFirstMessage() {
        let views = ProjectTracker.defaultViews(projectKeys: ["NEX", "NEXF"])
        XCTAssertEqual(views.map(\.name), ["My issues", "Current sprint", "Backlog"])
        XCTAssertTrue(views[0].jql.hasPrefix("project in (NEX, NEXF) AND assignee = currentUser()"))
        XCTAssertTrue(views[2].byEpic)
        let tracker = ProjectTracker(site: "pinsound.atlassian.net")
        let issue = JiraIssue(key: "NEX-233", summary: "Paginate", status: "To Do", category: .todo, type: "Story", description: "Past 100 scores.")
        XCTAssertEqual(tracker.firstMessage(for: issue), "/work-issue NEX-233\n\nNEX-233: Paginate (Story, To Do)\n\nPast 100 scores.")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viber-trackers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var list = TrackerList()
        list.set(tracker, for: "/repo")
        XCTAssertNoThrow(try list.save(to: dir.appendingPathComponent("trackers.json")))
        XCTAssertEqual(TrackerList.load(from: dir.appendingPathComponent("trackers.json")), list)
    }
}
