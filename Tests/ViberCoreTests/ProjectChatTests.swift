import XCTest
@testable import ViberCore

final class ProjectChatTests: XCTestCase {
    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }

    func testReadOnlyLaunchTakesTheEditToolsAwayAndAsks() {
        let spec = LaunchSpec(profile: nil, cwd: "/tmp", permissionMode: "auto", readOnly: true, appendSystemPrompt: "Read-only")
        let args = spec.claudeArguments
        XCTAssertEqual(value(after: "--permission-mode", in: args), "default", "a settings file's defaultMode or the session's own mode must not win")
        XCTAssertEqual(args.filter { $0 == "--permission-mode" }.count, 1)
        let disallowed = value(after: "--disallowedTools", in: args)?.split(separator: ",").map(String.init) ?? []
        XCTAssertEqual(Set(disallowed), ["Edit", "MultiEdit", "Write", "NotebookEdit", "EnterPlanMode", "ExitPlanMode"])
        XCTAssertEqual(value(after: "--append-system-prompt", in: args), "Read-only")

        let session = LaunchSpec(profile: nil, cwd: "/tmp", permissionMode: "auto").claudeArguments
        XCTAssertEqual(value(after: "--permission-mode", in: session), "auto")
        XCTAssertFalse(session.contains("--disallowedTools"))
        XCTAssertFalse(session.contains("--append-system-prompt"))
    }

    func testSessionsSavedBeforeChatsStillLoad() throws {
        let old = #"{"cwd":"/tmp","resume":"abc","permissionMode":"plan"}"#
        let spec = try JSONDecoder().decode(LaunchSpec.self, from: Data(old.utf8))
        XCTAssertNil(spec.readOnly)
        XCTAssertNil(spec.appendSystemPrompt)
        XCTAssertEqual(spec.permissionMode, "plan")

        let chat = LaunchSpec(profile: "Private", cwd: "/tmp", readOnly: true, appendSystemPrompt: "x")
        XCTAssertEqual(try JSONDecoder().decode(LaunchSpec.self, from: JSONEncoder().encode(chat)), chat)
    }

    func testTitleIsTheFirstLineCutAtAWord() {
        XCTAssertEqual(ProjectChat.title(from: "  How does   the cache ring work?\nMore detail"), "How does the cache ring work?")
        XCTAssertEqual(ProjectChat.title(from: "\n\nPlan it"), "Plan it")
        XCTAssertEqual(ProjectChat.title(from: "   "), ProjectChat.untitled)
        XCTAssertEqual(ProjectChat.title(from: "/model opus"), ProjectChat.untitled, "a command leaves the title to the next message")
        let long = ProjectChat.title(from: "Where do we decide which account a session starts with when the project has none")
        XCTAssertEqual(long, "Where do we decide which account a session starts…")
        XCTAssertLessThanOrEqual(long.count, 51)
    }

    func testPromptPointsAtTheProjectsTracker() {
        let own = ProjectChat.systemPrompt(project: "/Users/me/dev/estafette", tracker: nil)
        XCTAssertTrue(own.contains("estafette"))
        XCTAssertTrue(own.contains("viber issue list"))
        XCTAssertTrue(own.contains("can't edit or create files"))

        let jira = ProjectChat.systemPrompt(project: "/Users/me/dev/nexus", tracker: ProjectTracker(site: "acme.atlassian.net"))
        XCTAssertTrue(jira.contains("acme.atlassian.net"))
        XCTAssertFalse(jira.contains("viber issue"))
    }

    func testAlwaysAllowCantSwitchAChatsMode() {
        let request: JSON = ["type": "control_request", "request_id": "r1", "request": [
            "subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "mkdir notes"], "tool_use_id": "t1",
            "permission_suggestions": [["type": "addRules", "behavior": "allow"],
                                       ["type": "setMode", "mode": "acceptEdits", "destination": "session"]]]]
        for keepsMode in [false, true] {
            var chat = ChatTranscript()
            chat.keepsMode = keepsMode
            chat.apply(request)
            guard let card = chat.items.last, case .permission = card.kind else { return XCTFail("no permission card") }
            let reply = chat.decidePermission(itemID: card.id, allow: true, always: true)
            let kinds = reply?["response"]?["response"]?["updatedPermissions"]?.array?.compactMap { $0["type"]?.string }
            XCTAssertEqual(kinds, keepsMode ? ["addRules"] : ["addRules", "setMode"])
        }
    }
}
