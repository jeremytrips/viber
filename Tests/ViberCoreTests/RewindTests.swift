import XCTest
@testable import ViberCore

final class RewindTests: XCTestCase {
    private func echo(_ text: String, uuid: String) -> JSON {
        ["type": "user", "isReplay": true, "uuid": .string(uuid), "session_id": "s", "parent_tool_use_id": .null,
         "message": ["role": "user", "content": .string(text)]]
    }

    private func reply(to request: JSON, _ body: JSON) -> JSON {
        ["type": "control_response", "response": ["subtype": "success", "request_id": request["request_id"]!, "response": body]]
    }

    func testEchoedMessagesGetTheirIDs() {
        var chat = ChatTranscript()
        _ = chat.userMessage("first")
        let first = chat.lastItemID!
        _ = chat.userMessage("second")
        let second = chat.lastItemID!
        XCTAssertFalse(chat.canRewind(itemID: first), "no ID until the CLI echoes it")

        chat.apply(echo("first", uuid: "u1"))
        XCTAssertTrue(chat.canRewind(itemID: first))
        XCTAssertEqual(chat.items.count, 2, "echoes add nothing to the chat")
        chat.apply(echo("second", uuid: "u2"))
        let request = chat.rewind(itemID: second, dryRun: true)
        XCTAssertEqual(request?["request"], ["subtype": "rewind_files", "user_message_id": "u2", "dry_run": true])
    }

    func testAMessageNeverEchoedIsSkippedNotMismatched() {
        var chat = ChatTranscript()
        _ = chat.userMessage("/compact")
        let compact = chat.lastItemID!
        _ = chat.userMessage("next")
        let next = chat.lastItemID!
        chat.apply(echo("next", uuid: "u9"))
        XCTAssertTrue(chat.canRewind(itemID: next))
        XCTAssertFalse(chat.canRewind(itemID: compact))
    }

    func testRelayedAndImageMessagesMatchOnWhatWentOut() {
        var chat = ChatTranscript()
        let relay = chat.receiveRelay(from: "backend", text: "API is ready")
        let relayItem = chat.lastItemID!
        _ = chat.userMessage("", images: [ImageAttachment(label: "a.png", mediaType: "image/png", data: Data([1]))])
        let imageItem = chat.lastItemID!
        chat.apply(echo(relay["message"]!["content"]!.string!, uuid: "r1"))
        chat.apply(["type": "user", "isReplay": true, "uuid": "i1", "message": ["role": "user", "content": [
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "AQ=="]]]]])
        XCTAssertTrue(chat.canRewind(itemID: relayItem))
        XCTAssertTrue(chat.canRewind(itemID: imageItem))
    }

    func testHistoryRowsKeepTheirIDs() {
        var chat = ChatTranscript()
        let rows: [JSON] = [
            ["type": "user", "uuid": "h1", "message": ["role": "user", "content": "fix the bug"]],
            ["type": "user", "uuid": "h2", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]]]
        ]
        chat.loadHistory(Data(rows.map { $0.line() }.joined(separator: "\n").utf8))
        XCTAssertEqual(chat.items.count, 1)
        XCTAssertEqual(chat.rewind(itemID: chat.items[0].id, dryRun: true)?["request"]?["user_message_id"], "h1")
    }

    func testDryRunFillsPreviewThenRewindReports() {
        var chat = ChatTranscript()
        _ = chat.userMessage("edit it")
        let item = chat.lastItemID!
        chat.apply(echo("edit it", uuid: "u1"))

        let dry = chat.rewind(itemID: item, dryRun: true)!
        chat.apply(reply(to: dry, ["canRewind": true, "filesChanged": ["/p/a.txt", "/p/b.txt"], "insertions": 3, "deletions": 1]))
        XCTAssertEqual(chat.rewindPreview, RewindPreview(itemID: item, canRewind: true, error: nil,
                                                         files: ["/p/a.txt", "/p/b.txt"], insertions: 3, deletions: 1))

        let real = chat.rewind(itemID: item, dryRun: false)!
        XCTAssertNil(chat.rewindPreview, "confirming closes the preview")
        XCTAssertEqual(real["request"]?["dry_run"], false)
        chat.apply(reply(to: real, ["canRewind": true, "filesChanged": ["/p/a.txt", "/p/b.txt"], "insertions": 3, "deletions": 1]))
        XCTAssertEqual(chat.items.last?.kind, .notice("Rewound 2 files (+3 −1) to before that message. The conversation is unchanged.", isError: false))
    }

    func testFailuresShowInTheChat() {
        var chat = ChatTranscript()
        _ = chat.userMessage("x")
        let item = chat.lastItemID!
        chat.apply(echo("x", uuid: "u1"))
        let dry = chat.rewind(itemID: item, dryRun: true)!
        chat.apply(reply(to: dry, ["canRewind": false, "error": "No file checkpoint found for this message."]))
        XCTAssertEqual(chat.rewindPreview?.canRewind, false)
        XCTAssertEqual(chat.rewindPreview?.error, "No file checkpoint found for this message.")

        let real = chat.rewind(itemID: item, dryRun: false)!
        chat.apply(["type": "control_response", "response": ["subtype": "error", "request_id": real["request_id"]!, "error": "boom"]])
        XCTAssertEqual(chat.items.last?.kind, .notice("Could not rewind files: boom", isError: true))
    }

    func testLaunchReplaysUserMessages() {
        XCTAssertTrue(LaunchSpec(profile: nil, cwd: "/tmp").claudeArguments.contains("--replay-user-messages"))
    }
}
