import XCTest
@testable import ViberCore

final class ElicitationTests: XCTestCase {
    private let schema: JSON = [
        "type": "object",
        "properties": [
            "name": ["type": "string", "title": "Name", "description": "Who you are"],
            "age": ["type": "integer"],
            "plan": ["type": "string", "enum": ["free", "pro"], "enumNames": ["Free", "Pro"]],
            "tags": ["type": "array", "items": ["anyOf": [["const": "a", "title": "Alpha"], ["const": "b"]]]],
            "subscribe": ["type": "boolean", "default": true]
        ],
        "required": ["name", "plan"]
    ]

    func testFieldsFollowPropertyOrderAndTypes() {
        let fields = ElicitationField.parse(schema, order: ["plan", "name", "age"])
        XCTAssertEqual(fields.map(\.name), ["plan", "name", "age", "subscribe", "tags"], "listed order first, then the rest sorted")
        XCTAssertEqual(fields[0].kind, .choice([.init(value: "free", label: "Free"), .init(value: "pro", label: "Pro")]))
        XCTAssertEqual(fields[1].title, "Name")
        XCTAssertTrue(fields[1].required)
        XCTAssertEqual(fields[2].kind, .integer)
        XCTAssertEqual(fields[2].value(from: "42"), 42)
        XCTAssertNil(fields[2].value(from: "4.2"))
        XCTAssertEqual(fields[3].kind, .boolean)
        XCTAssertEqual(fields[4].kind, .multiChoice([.init(value: "a", label: "Alpha"), .init(value: "b", label: "b")]))
    }

    func testFormRoundTrip() {
        var chat = ChatTranscript()
        _ = chat.userMessage("sign me up")
        let out = chat.apply(["type": "control_request", "request_id": "e1", "request": [
            "subtype": "elicitation", "mcp_server_name": "signup", "message": "Fill this in",
            "mode": "form", "requested_schema": schema, "property_order": ["name", "plan"]]])
        XCTAssertTrue(out.isEmpty, "no error reply any more")
        XCTAssertEqual(chat.state, .input)
        XCTAssertEqual(chat.pendingPromptCount, 1)
        guard let item = chat.items.last, case .elicitation(let prompt) = item.kind else { return XCTFail("no card") }
        XCTAssertEqual(prompt.heading, "signup needs input")
        XCTAssertEqual(prompt.missing(["name": "Ada"]).map(\.name), ["plan"])

        let reply = chat.answerElicitation(itemID: item.id, action: "accept", content: ["name": "Ada", "plan": "pro"])
        XCTAssertEqual(reply?["response"]?["request_id"]?.string, "e1")
        XCTAssertEqual(reply?["response"]?["response"], ["action": "accept", "content": ["name": "Ada", "plan": "pro"]])
        XCTAssertEqual(chat.state, .working)
        XCTAssertNil(chat.answerElicitation(itemID: item.id, action: "accept"), "answered once")
    }

    func testURLModeWaitsForCompletion() {
        var chat = ChatTranscript()
        chat.apply(["type": "control_request", "request_id": "e2", "request": [
            "subtype": "elicitation", "mcp_server_name": "github", "display_name": "GitHub", "message": "Authorize",
            "mode": "url", "url": "https://example.com/auth", "elicitation_id": "x1"]])
        guard let item = chat.items.last, case .elicitation(let prompt) = item.kind else { return XCTFail("no card") }
        XCTAssertTrue(prompt.isURL)
        XCTAssertEqual(prompt.url?.host, "example.com")
        XCTAssertEqual(prompt.server, "GitHub")

        let reply = chat.answerElicitation(itemID: item.id, action: "accept", content: ["ignored": true])
        XCTAssertEqual(reply?["response"]?["response"], ["action": "accept"], "URL mode sends no content")
        chat.apply(["type": "system", "subtype": "elicitation_complete", "mcp_server_name": "github", "elicitation_id": "x1"])
        guard case .elicitation(let done) = chat.items.last?.kind else { return XCTFail() }
        XCTAssertTrue(done.completed)
        XCTAssertEqual(done.decision, .answered)
    }

    func testDeclineAndCancel() {
        var chat = ChatTranscript()
        chat.apply(["type": "control_request", "request_id": "e3", "request": ["subtype": "elicitation", "mcp_server_name": "s", "message": "?"]])
        let id = chat.items.last!.id
        XCTAssertEqual(chat.answerElicitation(itemID: id, action: "decline")?["response"]?["response"], ["action": "decline"])
        guard case .elicitation(let declined) = chat.items.last?.kind else { return XCTFail() }
        XCTAssertEqual(declined.decision, .declined)

        chat.apply(["type": "control_request", "request_id": "e4", "request": ["subtype": "elicitation", "mcp_server_name": "s", "message": "?"]])
        chat.apply(["type": "control_cancel_request", "request_id": "e4"])
        guard case .elicitation(let cancelled) = chat.items.last?.kind else { return XCTFail() }
        XCTAssertEqual(cancelled.decision, .cancelled)
        XCTAssertEqual(chat.pendingPromptCount, 0)
    }

    func testProcessExitCancelsOpenElicitation() {
        var chat = ChatTranscript()
        chat.apply(["type": "control_request", "request_id": "e5", "request": ["subtype": "elicitation", "mcp_server_name": "s", "message": "?"]])
        chat.processExited(status: 0)
        guard case .elicitation(let e) = chat.items.last?.kind else { return XCTFail() }
        XCTAssertEqual(e.decision, .cancelled)
    }
}
