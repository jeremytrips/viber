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

    func testDraftPromptAndEditedPermission() throws {
        let prompt = ProjectTracker.draftPrompt("invite emails bounce for gmail users", site: "pinsound.atlassian.net")
        XCTAssertTrue(prompt.hasPrefix("Draft a Jira issue: invite emails bounce for gmail users"))
        XCTAssertTrue(prompt.contains("createJiraIssue"))
        XCTAssertTrue(prompt.contains("don't create another"))

        var chat = ChatTranscript()
        _ = chat.apply(["type": "control_request", "request_id": "r1", "request": ["subtype": "can_use_tool", "tool_name": "mcp__atlassian__createJiraIssue",
                                                                              "input": ["projectKey": "NEX", "summary": "Draft"], "tool_use_id": "t1"]])
        let item = try XCTUnwrap(chat.items.last { if case .permission = $0.kind { return true }; return false })
        let reply = try XCTUnwrap(chat.decidePermission(itemID: item.id, allow: true, updatedInput: ["projectKey": "NEX", "summary": "Edited"]))
        XCTAssertEqual(reply["response"]?["response"]?["updatedInput"]?["summary"]?.string, "Edited")
        if case .permission(let decided) = chat.items.first(where: { $0.id == item.id })?.kind {
            XCTAssertEqual(decided.input["summary"]?.string, "Edited", "the card shows what was sent")
        } else { XCTFail("no permission item") }
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

final class JiraRunTests: XCTestCase {
    private func issue(_ key: String, _ summary: String = "x", status: String = "To Do", category: JiraCategory = .todo, type: String = "Story",
                       epic: Bool = false, assignee: String? = nil, labels: [String] = []) -> JiraIssue {
        JiraIssue(key: key, summary: summary, status: status, category: category, type: type, isEpic: epic, assignee: assignee, labels: labels)
    }

    func testEligibility() {
        XCTAssertNil(JiraRun.ineligible(issue("NEX-1"), mine: false), "unassigned is fine")
        XCTAssertNil(JiraRun.ineligible(issue("NEX-1", assignee: "Jeremy"), mine: true))
        XCTAssertEqual(JiraRun.ineligible(issue("NEX-1", assignee: "Sofie"), mine: false), "Assigned to Sofie.")
        XCTAssertEqual(JiraRun.ineligible(issue("NEX-1", "DECISION: keep history?"), mine: true), "A decision: it needs you, not code.")
        XCTAssertNotNil(JiraRun.ineligible(issue("NEX-1", labels: ["decision"]), mine: true))
        XCTAssertNotNil(JiraRun.ineligible(issue("NEX-1", status: "In Progress", category: .progress), mine: true))
        XCTAssertNotNil(JiraRun.ineligible(issue("NEX-1", epic: true), mine: true))
    }

    func testTakesKeysThatAreStillToDo() {
        var run = JiraRun(project: "/repo", keys: ["NEX-1", "NEX-2", "NEX-3"], epicKey: "NEX-30", label: "E14", sessionsAtOnce: 2,
                          worktreesAtMost: 8, permissionMode: "auto", profile: nil, branchPattern: "feat/<key>-<slug>")
        let known = ["NEX-1": issue("NEX-1"), "NEX-2": issue("NEX-2", status: "In Progress", category: .progress), "NEX-3": issue("NEX-3")]
        XCTAssertEqual(run.takeNext(known: known, openWorktrees: 0), "NEX-1")
        XCTAssertEqual(run.takeNext(known: known, openWorktrees: 1), "NEX-3", "NEX-2 was taken meanwhile")
        XCTAssertTrue(run.reports["NEX-2"]?.text.contains("Skipped") == true)
        XCTAssertNil(run.takeNext(known: known, openWorktrees: 2))
        run.finish("NEX-1", stuck: false, report: "Landed")
        XCTAssertEqual(run.tally, "1 in review")
        XCTAssertEqual(run.active, ["NEX-3"])
        XCTAssertEqual(run.branchPattern, "feat/<key>-<slug>")
        run.enqueue("NEX-1")
        XCTAssertTrue(run.queue.isEmpty, "a handled key isn't queued again")
    }

    func testWhatTheRunAllows() {
        XCTAssertEqual(JiraRun.mcpTool("mcp__atlassian__transitionJiraIssue", servers: ProjectTracker.defaultMcpServers), "transitionJiraIssue")
        XCTAssertNil(JiraRun.mcpTool("Bash", servers: ProjectTracker.defaultMcpServers))
        XCTAssertEqual(JiraRun.decide(tool: "getJiraIssue", input: ["issueIdOrKey": "NEX-9"], key: "NEX-1"), .allow)
        XCTAssertEqual(JiraRun.decide(tool: "searchJiraIssuesUsingJql", input: [:], key: "NEX-1"), .allow)
        XCTAssertEqual(JiraRun.decide(tool: "transitionJiraIssue", input: ["issueIdOrKey": "nex-1", "transition": ["id": "21"]], key: "NEX-1"), .allow)
        XCTAssertEqual(JiraRun.decide(tool: "addCommentToJiraIssue", input: ["issueIdOrKey": "NEX-1"], key: "NEX-1"), .allow)
        XCTAssertEqual(JiraRun.decide(tool: "transitionJiraIssue", input: ["issueIdOrKey": "NEX-2"], key: "NEX-1"), .ask, "another issue")
        XCTAssertEqual(JiraRun.decide(tool: "createJiraIssue", input: ["projectKey": "NEX"], key: "NEX-1"), .ask)
        XCTAssertEqual(JiraRun.decide(tool: "editJiraIssue", input: ["issueIdOrKey": "NEX-1"], key: "NEX-1"), .ask)
        XCTAssertEqual(JiraRun.askRules(servers: ["atlassian"]), [RuleEdit(behavior: "ask", rule: "mcp__atlassian")])
        let prompt = JiraRun.prompt(for: issue("NEX-233", "Paginate"), tracker: ProjectTracker(site: "x"), startBranch: "feat/nex-251-api")
        XCTAssertTrue(prompt.hasPrefix("Autopilot: NEX-233 Paginate\n\n/work-issue NEX-233"))
        XCTAssertTrue(prompt.contains("starts from `feat/nex-251-api`"))
        XCTAssertTrue(prompt.contains("Don't push or merge."))
    }
}

final class AskClaudeTests: XCTestCase {
    func testPromptsFitTheTracker() {
        let own = AskClaude.review.prompt(project: "/dev/estafette", tracker: nil)
        XCTAssertTrue(own.hasPrefix("Review the backlog of estafette."))
        XCTAssertTrue(own.contains("viber issue list"))
        XCTAssertTrue(own.contains("EST-12"))
        XCTAssertTrue(own.contains("make the changes directly"))
        let jira = AskClaude.breakDown(key: "NEX-233").prompt(project: "/dev/nexus-cloud", tracker: ProjectTracker(site: "pinsound.atlassian.net"))
        XCTAssertTrue(jira.contains("pinsound.atlassian.net"))
        XCTAssertTrue(jira.contains("Every change to Jira asks the user first"))
        XCTAssertTrue(jira.contains("sub-tasks (or child issues) of NEX-233"))
        XCTAssertEqual(AskClaude.standup.title, "Standup note")
        XCTAssertTrue(AskClaude.next.prompt(project: "/x", tracker: nil).contains("Don't change anything"))
    }
}
