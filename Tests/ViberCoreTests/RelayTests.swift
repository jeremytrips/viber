import XCTest
@testable import ViberCore

final class RelayTests: XCTestCase {
    let sessions = [
        RelayCandidate(id: "ux", title: "HTML mockups of every screen", project: "nexus-cloud", branch: "viber/ux-mockups",
                       context: "Writing ux/login.html and the shared stylesheet"),
        RelayCandidate(id: "api", title: "Backend auth API", project: "nexus-cloud", branch: "viber/backend-auth",
                       context: "Added /auth/otp/send endpoint and tests for the OTP flow"),
        RelayCandidate(id: "ota", title: "OTA firmware updates", project: "nexus-device", branch: "viber/ota",
                       context: "partitions.csv, esp_https_ota, rollback")
    ]

    func testOnlyDoubleSlashIsARelay() {
        XCTAssertTrue(Relay.rank("/plan", candidates: sessions).isEmpty)
        XCTAssertEqual(Relay.rank("//", candidates: sessions).count, 3)
    }

    func testRanksByWhatTheMessageIsAbout() {
        XCTAssertEqual(Relay.rank("//we need a firmware download endpoint for OTA", candidates: sessions).first?.candidate.id, "ota")
        XCTAssertEqual(Relay.rank("//the OTP endpoints need rate limiting", candidates: sessions).first?.candidate.id, "api")
        XCTAssertEqual(Relay.rank("//update the login mockup stylesheet", candidates: sessions).first?.candidate.id, "ux")
    }

    func testAddressingByNameWinsAndIsStripped() {
        let top = Relay.rank("//backend: rate limit the login", candidates: sessions).first
        XCTAssertEqual(top?.candidate.id, "api")
        XCTAssertTrue(top?.addressed == true)
        XCTAssertEqual(top?.message, "rate limit the login")
        XCTAssertEqual(Relay.rank("//ota check the rollback", candidates: sessions).first?.message, "check the rollback")
    }

    func testUnaddressedMessageKeepsAllText() {
        let top = Relay.rank("//firmware endpoint please", candidates: sessions).first
        XCTAssertEqual(top?.addressed, false)
        XCTAssertEqual(top?.message, "firmware endpoint please")
    }

    func testTiesKeepCallerOrder() {
        XCTAssertEqual(Relay.rank("//hello there", candidates: sessions).map(\.candidate.id), ["ux", "api", "ota"])
    }

    func testEnvelopeRoundTrip() {
        let text = Relay.envelope(from: "OTA firmware updates", text: "Expose GET /firmware/latest")
        let parsed = Relay.parseEnvelope(text)
        XCTAssertEqual(parsed?.from, "OTA firmware updates")
        XCTAssertEqual(parsed?.text, "Expose GET /firmware/latest")
    }
}

final class RelayChatTests: XCTestCase {
    func testReceiveSendsEnvelopeAndShowsSender() {
        var chat = ChatTranscript()
        let message = chat.receiveRelay(from: "OTA firmware updates", text: "Expose GET /firmware/latest")
        XCTAssertEqual(chat.items.last?.kind, .received(from: "OTA firmware updates", text: "Expose GET /firmware/latest"))
        XCTAssertEqual(chat.state, .working)
        let content = message["message"]?["content"]?.string ?? ""
        XCTAssertEqual(Relay.parseEnvelope(content)?.text, "Expose GET /firmware/latest")
    }

    func testSentItemCanBeMarkedDelivered() {
        var chat = ChatTranscript()
        let id = chat.recordSent(to: "Backend", text: "hi", queued: true)
        chat.markDelivered(itemID: id)
        XCTAssertEqual(chat.items.last?.kind, .sent(to: "Backend", text: "hi", queued: false))
    }

    private func text(_ id: String, _ text: String) -> JSON {
        ["type": "assistant", "message": ["id": .string(id), "role": "assistant", "content": [["type": "text", "text": .string(text)]]]]
    }

    private func tool(_ id: String) -> JSON {
        ["type": "assistant", "message": ["id": .string("m-\(id)"), "role": "assistant",
                                          "content": [["type": "tool_use", "id": .string(id), "name": "Bash", "input": ["command": "make"]]]]]
    }

    private func toolResult(_ id: String) -> JSON {
        ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": .string(id), "content": "ok"]]]]
    }

    /// What the CLI prints when it hands a queued message to Claude.
    private func echo(of message: JSON) -> JSON {
        ["type": "user", "isReplay": true, "uuid": message["uuid"]!, "message": message["message"]!]
    }

    private let result: JSON = ["type": "result", "subtype": "success", "is_error": false]

    /// A busy Claude reads the message after its running tool call; the first thing it says then is the answer.
    func testMidTurnRelayIsAnsweredByFirstTextAfterReading() {
        var chat = ChatTranscript()
        _ = chat.userMessage("refactor the API")
        chat.apply(tool("t1"))
        let message = chat.receiveRelay(from: "OTA", text: "which endpoint?")
        let item = chat.lastItemID!
        chat.apply(text("m1", "Now the tests."))
        XCTAssertEqual(chat.takeRelayUpdates(), [], "not read yet: that text was not about the message")

        chat.apply(toolResult("t1"))
        chat.apply(echo(of: message))
        XCTAssertEqual(chat.takeRelayUpdates(), [.read(itemID: item)])
        chat.apply(text("m2", "It's GET /firmware/latest."))
        XCTAssertEqual(chat.takeRelayUpdates(), [.answered(itemID: item, text: "It's GET /firmware/latest.")])

        chat.apply(text("m3", "Refactor done."))
        chat.apply(result)
        XCTAssertEqual(chat.takeRelayUpdates(), [], "answered once")
    }

    /// A message that starts a turn is answered by everything Claude says in it.
    func testRelayToIdleSessionIsAnsweredAtTurnEnd() {
        var chat = ChatTranscript()
        let message = chat.receiveRelay(from: "OTA", text: "which endpoint?")
        let item = chat.lastItemID!
        chat.apply(echo(of: message))
        chat.apply(text("m1", "Let me check."))
        chat.apply(tool("t1"))
        chat.apply(toolResult("t1"))
        chat.apply(text("m2", "GET /firmware/latest."))
        XCTAssertEqual(chat.takeRelayUpdates(), [.read(itemID: item)])
        chat.apply(result)
        XCTAssertEqual(chat.takeRelayUpdates(), [.answered(itemID: item, text: "Let me check.\n\nGET /firmware/latest.")])
    }

    /// Sent while Claude wrote its last words: the CLI runs it as a turn of its own, which shows as working.
    func testRelayUnreadAtTurnEndGetsATurnOfItsOwn() {
        var chat = ChatTranscript()
        _ = chat.userMessage("summarize")
        chat.apply(tool("t1"))
        let message = chat.receiveRelay(from: "OTA", text: "which endpoint?")
        let item = chat.lastItemID!
        chat.apply(toolResult("t1"))
        chat.apply(text("m1", "Here is the summary."))
        chat.apply(result)
        XCTAssertEqual(chat.takeRelayUpdates(), [])
        XCTAssertEqual(chat.state, .finished)

        chat.apply(["type": "system", "subtype": "status", "status": "requesting"])
        XCTAssertEqual(chat.state, .working)
        chat.apply(echo(of: message))
        chat.apply(text("m2", "Let me check."))
        chat.apply(text("m3", "GET /firmware/latest."))
        XCTAssertEqual(chat.takeRelayUpdates(), [.read(itemID: item)], "a turn of its own is answered at its end")
        chat.apply(result)
        XCTAssertEqual(chat.takeRelayUpdates(), [.answered(itemID: item, text: "Let me check.\n\nGET /firmware/latest.")])
    }

    func testRelayKeepsAPendingPermissionCard() {
        var chat = ChatTranscript()
        chat.state = .permission
        _ = chat.receiveRelay(from: "OTA", text: "which endpoint?")
        _ = chat.receiveReply(from: "OTA", text: "thanks")
        XCTAssertEqual(chat.state, .permission)
    }

    func testEchoMatchesOnTheIDTheMessageWentOutWith() {
        var chat = ChatTranscript()
        let message = chat.receiveRelay(from: "OTA", text: "which endpoint?")
        let item = chat.lastItemID!
        let uuid = message["uuid"]?.string
        XCTAssertNotNil(uuid)
        chat.apply(["type": "user", "isReplay": true, "uuid": .string(uuid!), "message": ["role": "user", "content": "rewritten"]])
        XCTAssertEqual(chat.takeRelayUpdates(), [.read(itemID: item)])
        XCTAssertTrue(chat.canRewind(itemID: item))
    }

    func testExitAnswersOpenRelays() {
        var chat = ChatTranscript()
        let message = chat.receiveRelay(from: "OTA", text: "first")
        let read = chat.lastItemID!
        _ = chat.receiveRelay(from: "UX", text: "second")
        let unread = chat.lastItemID!
        chat.apply(echo(of: message))
        chat.apply(text("m1", "Working on it."))
        _ = chat.takeRelayUpdates()
        chat.processExited(status: 0)
        let updates = chat.takeRelayUpdates()
        XCTAssertEqual(updates.count, 2)
        XCTAssertTrue(updates.contains(.answered(itemID: read, text: "Working on it.")))
        XCTAssertTrue(updates.contains(.answered(itemID: unread, text: "Working on it.")), "never echoed: all it said after arriving")
    }

    func testHistoryRestoresReceivedMessages() {
        var chat = ChatTranscript()
        let envelope = Relay.envelope(from: "UX", text: "use the new tokens")
        let row: JSON = ["type": "user", "uuid": "u9", "timestamp": "2026-10-23T08:00:00Z",
                         "message": ["role": "user", "content": .string(envelope)]]
        chat.loadHistory(Data(row.line().utf8))
        XCTAssertEqual(chat.items.map(\.kind), [.received(from: "UX", text: "use the new tokens")])
    }
}

final class RelayLogTests: XCTestCase {
    func testLifecycleAndUnread() {
        var log = RelayLog()
        let t0 = Date(timeIntervalSince1970: 1000)
        let id = log.add(source: ("a", "OTA"), target: ("b", "Backend"), text: "which endpoint?", queued: true, at: t0)
        XCTAssertEqual(log.record(id)?.status, .queued)
        XCTAssertEqual(log.unreadCount, 1)
        log.lastSeen = t0
        XCTAssertEqual(log.unreadCount, 0)
        log.markDelivered(id, at: t0.addingTimeInterval(5))
        XCTAssertEqual(log.record(id)?.status, .delivered)
        log.recordReply(id, text: "  GET /firmware/latest ", at: t0.addingTimeInterval(20))
        XCTAssertEqual(log.record(id)?.status, .replied)
        XCTAssertEqual(log.record(id)?.reply, "GET /firmware/latest")
        XCTAssertEqual(log.unreadCount, 1, "a reply counts as new")
        XCTAssertEqual(log.records(for: "b").count, 1)
    }

    func testEmptyReplyIsNoReply() {
        var log = RelayLog()
        let id = log.add(source: ("a", "A"), target: ("b", "B"), text: "x", queued: false)
        log.recordReply(id, text: "   ")
        XCTAssertEqual(log.record(id)?.status, .noReply)
    }

    func testReplyEnvelopeAndAssistantText() {
        let env = Relay.replyEnvelope(from: "Backend", text: "GET /firmware/latest")
        XCTAssertEqual(Relay.parseReplyEnvelope(env)?.from, "Backend")
        XCTAssertEqual(Relay.parseReplyEnvelope(env)?.text, "GET /firmware/latest")
        XCTAssertNil(Relay.parseEnvelope(env))

        var chat = ChatTranscript()
        _ = chat.receiveRelay(from: "OTA", text: "which endpoint?")
        let received = chat.lastItemID!
        chat.apply(["type": "assistant", "message": ["id": "m1", "content": [["type": "text", "text": "Checking."]]]])
        chat.apply(["type": "assistant", "message": ["id": "m2", "content": [["type": "text", "text": "GET /firmware/latest"]]]])
        XCTAssertEqual(chat.assistantText(after: received), "Checking.\n\nGET /firmware/latest")

        let reply = chat.receiveReply(from: "Backend", text: "ok")
        XCTAssertEqual(chat.items.last?.kind, .reply(from: "Backend", text: "ok"))
        XCTAssertNotNil(Relay.parseReplyEnvelope(reply["message"]?["content"]?.string ?? ""))
    }
}
