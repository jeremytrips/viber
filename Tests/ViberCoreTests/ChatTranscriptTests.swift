import XCTest
@testable import ViberCore

final class ChatTranscriptTests: XCTestCase {
    private func assistant(_ id: String, _ blocks: [JSON], usage: JSON? = nil) -> JSON {
        var message: [String: JSON] = ["id": .string(id), "role": "assistant", "model": "claude-haiku", "content": .array(blocks)]
        if let usage { message["usage"] = usage }
        return ["type": "assistant", "message": .object(message)]
    }

    func testInitializeResponseFillsCommandsAndModels() {
        var chat = ChatTranscript()
        chat.state = .starting
        let request = chat.request("initialize")
        let id = request["request_id"]!.string!
        chat.apply(["type": "control_response", "response": ["subtype": "success", "request_id": .string(id), "response": [
            "commands": [["name": "compact", "description": "Summarize"], ["name": "viber:cleanup", "description": "Clean"]],
            "models": [["value": "opus", "displayName": "Opus"]],
            "current_permission_mode": "default"]]])
        XCTAssertEqual(chat.commands.map(\.name), ["compact", "viber:cleanup"])
        XCTAssertEqual(chat.models.first?.displayName, "Opus")
        XCTAssertEqual(chat.permissionMode, "default")
        XCTAssertEqual(chat.state, .idle)
    }

    func testToolPermissionRoundTrip() {
        var chat = ChatTranscript()
        _ = chat.userMessage("touch a file")
        chat.apply(assistant("m1", [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "touch out.txt"]]]))
        let out = chat.apply(["type": "control_request", "request_id": "r1", "request": [
            "subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "touch out.txt"], "tool_use_id": "t1",
            "permission_suggestions": [["type": "addRules", "behavior": "allow"]]]])
        XCTAssertTrue(out.isEmpty)
        XCTAssertEqual(chat.state, .permission)
        guard let card = chat.items.last, case .permission = card.kind else { return XCTFail("no permission card") }

        let reply = chat.decidePermission(itemID: card.id, allow: true, always: true)
        XCTAssertEqual(reply?["response"]?["request_id"]?.string, "r1")
        XCTAssertEqual(reply?["response"]?["response"]?["behavior"]?.string, "allow")
        XCTAssertEqual(reply?["response"]?["response"]?["updatedInput"]?["command"]?.string, "touch out.txt")
        XCTAssertEqual(reply?["response"]?["response"]?["updatedPermissions"]?.array?.count, 1)
        XCTAssertEqual(chat.state, .working)
        XCTAssertNil(chat.decidePermission(itemID: card.id, allow: true), "a card is answered once")

        chat.apply(["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "t1", "content": "ok", "is_error": false]]]])
        guard case .tool(let call) = chat.items.first(where: { $0.id == "tool:t1" })?.kind else { return XCTFail() }
        XCTAssertEqual(call.result, "ok")
        XCTAssertTrue(call.done)

        chat.apply(["type": "result", "subtype": "success", "is_error": false, "total_cost_usd": 0.01, "duration_ms": 1500])
        XCTAssertEqual(chat.state, .finished)
        XCTAssertEqual(chat.lastTurnSeconds, 1.5)
    }

    func testQuestionAnswerAddsAnswersToInput() {
        var chat = ChatTranscript()
        let input: JSON = ["questions": [["question": "Split how?", "header": "Split", "multiSelect": false,
                                          "options": [["label": "By screen", "description": "one per panel"], ["label": "By layer", "description": "render/input"]]]]]
        chat.apply(assistant("m1", [["type": "tool_use", "id": "q1", "name": "AskUserQuestion", "input": input]]))
        chat.apply(["type": "control_request", "request_id": "r2", "request": [
            "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": input, "tool_use_id": "q1"]])
        XCTAssertEqual(chat.state, .input)
        XCTAssertEqual(chat.items.count, 1, "the tool row becomes the question card")
        guard case .question(let q) = chat.items[0].kind else { return XCTFail() }
        XCTAssertEqual(q.questions.first?.options.map(\.label), ["By screen", "By layer"])

        let reply = chat.answerQuestion(itemID: chat.items[0].id, answers: ["Split how?": "By layer"])
        XCTAssertEqual(reply?["response"]?["response"]?["updatedInput"]?["answers"]?["Split how?"]?.string, "By layer")
        XCTAssertEqual(chat.state, .working)
    }

    func testPlanApprovalSwitchesMode() {
        var chat = ChatTranscript()
        chat.apply(["type": "control_request", "request_id": "r3", "request": [
            "subtype": "can_use_tool", "tool_name": "ExitPlanMode", "input": ["plan": "# Plan\n1. do it"]]])
        XCTAssertEqual(chat.state, .plan)
        let id = chat.items[0].id
        let out = chat.decidePlan(itemID: id, decision: .approvedAuto)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0]["response"]?["response"]?["behavior"]?.string, "allow")
        XCTAssertEqual(out[1]["request"]?["subtype"]?.string, "set_permission_mode")
        XCTAssertEqual(out[1]["request"]?["mode"]?.string, "acceptEdits")
        XCTAssertEqual(chat.permissionMode, "acceptEdits")
    }

    func testKeepPlanningDeniesWithFeedback() {
        var chat = ChatTranscript()
        chat.apply(["type": "control_request", "request_id": "r4", "request": [
            "subtype": "can_use_tool", "tool_name": "ExitPlanMode", "input": ["plan": "x"]]])
        let out = chat.decidePlan(itemID: chat.items[0].id, decision: .keepPlanning, feedback: "cover signing")
        XCTAssertEqual(out.first?["response"]?["response"]?["behavior"]?.string, "deny")
        XCTAssertTrue(out.first?["response"]?["response"]?["message"]?.string?.contains("cover signing") == true)
    }

    func testCancelRequestClosesCard() {
        var chat = ChatTranscript()
        chat.apply(["type": "control_request", "request_id": "r5", "request": [
            "subtype": "can_use_tool", "tool_name": "Write", "input": ["file_path": "/a"]]])
        chat.apply(["type": "control_cancel_request", "request_id": "r5"])
        guard case .permission(let p) = chat.items[0].kind else { return XCTFail() }
        XCTAssertEqual(p.decision, .cancelled)
        XCTAssertEqual(chat.state, .working)
    }

    func testUnsupportedControlRequestGetsAnError() {
        var chat = ChatTranscript()
        let out = chat.apply(["type": "control_request", "request_id": "h1", "request": ["subtype": "hook_callback"]])
        XCTAssertEqual(out.first?["response"]?["subtype"]?.string, "error")
    }

    func testCacheEstimateFromUsage() {
        var chat = ChatTranscript()
        let t0 = Date(timeIntervalSince1970: 1000)
        chat.apply(assistant("m1", [["type": "text", "text": "hi"]], usage: [
            "input_tokens": 4, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 50,
            "cache_creation": ["ephemeral_1h_input_tokens": 50, "ephemeral_5m_input_tokens": 0]]), now: t0)
        XCTAssertEqual(chat.cache?.ttl, 3600)
        XCTAssertEqual(chat.lastUsage?.contextTokens, 154)
        // A second block of the same message must not restart the clock.
        chat.apply(assistant("m1", [["type": "text", "text": "more"]], usage: ["cache_read_input_tokens": 100]), now: t0.addingTimeInterval(30))
        XCTAssertEqual(chat.cache?.observedAt, t0)
        // A later read-only message carries the TTL over.
        chat.apply(assistant("m2", [["type": "text", "text": "x"]], usage: ["cache_read_input_tokens": 200]), now: t0.addingTimeInterval(60))
        XCTAssertEqual(chat.cache?.ttl, 3600)
        XCTAssertEqual(chat.cache?.observedAt, t0.addingTimeInterval(60))
    }

    func testStreamingTextIsReplacedByFinalText() {
        var chat = ChatTranscript()
        chat.apply(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Hel"]]])
        chat.apply(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "lo"]]])
        XCTAssertEqual(chat.streamingText, "Hello")
        chat.apply(assistant("m1", [["type": "text", "text": "Hello"]]))
        XCTAssertEqual(chat.streamingText, "")
        XCTAssertEqual(chat.items.count, 1)
    }

    func testHistoryShowsUserTextAndSlashCommands() {
        var chat = ChatTranscript()
        let rows = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-10-23T08:00:00Z","message":{"role":"user","content":"Fix the login"}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-23T08:00:05Z","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Done."}]}}"#,
            #"{"type":"user","uuid":"u2","timestamp":"2026-10-23T08:01:00Z","message":{"role":"user","content":"<command-name>/cleanup</command-name>\n<command-args></command-args>"}}"#,
            #"{"type":"user","uuid":"u3","isMeta":true,"timestamp":"2026-10-23T08:01:00Z","message":{"role":"user","content":"skill body"}}"#,
            #"{"type":"user","uuid":"u1","timestamp":"2026-10-23T08:00:00Z","message":{"role":"user","content":"Fix the login"}}"#
        ]
        chat.loadHistory(Data(rows.joined(separator: "\n").utf8))
        let kinds = chat.items.map(\.kind)
        XCTAssertEqual(kinds, [.user("Fix the login"), .assistant("Done."), .user("/cleanup")])
        XCTAssertEqual(chat.state, .idle)
    }

    func testFailedResultShowsNotice() {
        var chat = ChatTranscript()
        _ = chat.userMessage("hi")
        chat.apply(["type": "result", "subtype": "success", "is_error": true, "result": "Failed to authenticate"])
        XCTAssertEqual(chat.state, .failed)
        XCTAssertEqual(chat.items.last?.kind, .notice("Failed to authenticate", isError: true))
    }
}
