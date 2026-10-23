import XCTest
@testable import ViberCore

/// Talks to the real `claude` CLI (costs a few cents). Run with: VIBER_LIVE_TEST=1 swift test --filter LiveCLITests
/// Set VIBER_LIVE_PROFILE to go through `clauth start <profile>` instead of plain `claude`.
final class LiveCLITests: XCTestCase {
    func testPermissionRoundTripAgainstRealCLI() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["VIBER_LIVE_TEST"] == "1", "set VIBER_LIVE_TEST=1 to run")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viber-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var chat = ChatTranscript()
        let spec = LaunchSpec(profile: env["VIBER_LIVE_PROFILE"], cwd: dir.path, model: "haiku")
        let process = try ClaudeProcess(spec: spec, paneID: "live-test", binDir: nil)
        let finished = expectation(description: "turn finished")
        var sawPermission = false
        process.onMessage = { message in
            for reply in chat.apply(message) { process.send(reply) }
            if chat.state == .permission, let card = chat.items.last(where: {
                if case .permission(let p) = $0.kind { return p.decision == nil }; return false
            }) {
                sawPermission = true
                if let reply = chat.decidePermission(itemID: card.id, allow: true) { process.send(reply) }
            }
            if message["type"]?.string == "result" { finished.fulfill() }
        }
        process.send(chat.request("initialize"))
        process.send(chat.userMessage("Use the Bash tool to run exactly: touch out.txt   Then reply with the single word DONE."))
        wait(for: [finished], timeout: 120)
        process.terminate()

        XCTAssertFalse(chat.commands.isEmpty, "initialize returned slash commands")
        XCTAssertNotNil(chat.sessionID)
        XCTAssertTrue(sawPermission, "the Bash call came back as a permission card")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("out.txt").path))
        XCTAssertEqual(chat.state, .finished)
        XCTAssertNotNil(chat.cache, "usage produced a cache estimate")
        XCTAssertTrue(chat.items.contains { if case .assistant(let t) = $0.kind { return t.contains("DONE") }; return false })
    }

    /// The settings sheet's requests against the real CLI. No model turn, so this one costs nothing.
    func testSettingsRequestsAgainstRealCLI() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["VIBER_LIVE_TEST"] == "1", "set VIBER_LIVE_TEST=1 to run")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viber-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var chat = ChatTranscript()
        let process = try ClaudeProcess(spec: LaunchSpec(profile: env["VIBER_LIVE_PROFILE"], cwd: dir.path), paneID: "live-settings", binDir: nil)
        let done = expectation(description: "replies arrived")
        process.onMessage = { message in
            for reply in chat.apply(message) { process.send(reply) }
            let c = chat.controls
            if c.mcp != nil, c.context != nil, c.rules != nil, c.hooks != nil, c.effort != nil || c.appliedModel != nil, c.busy.isEmpty {
                done.fulfill()
            }
        }
        process.send(chat.request("initialize"))
        for tab in [SettingsTab.context, .permissions, .hooks, .model] { for request in chat.refresh(tab) { process.send(request) } }
        process.send(chat.setSessionRules([RuleEdit(behavior: "allow", rule: "Bash(echo viber:*)")]))
        wait(for: [done], timeout: 60)
        process.terminate()

        XCTAssertGreaterThan(chat.controls.context?.maxTokens ?? 0, 0)
        XCTAssertFalse(chat.controls.context?.categories.isEmpty ?? true)
        XCTAssertNotNil(chat.controls.costText)
        XCTAssertTrue(chat.controls.rules?.contains { $0.rule == "Bash(echo viber:*)" && $0.scope == .session } == true,
                      "the session rule came back from the flag layer: \(chat.controls.rules ?? [])")
        XCTAssertTrue(chat.controls.errors.isEmpty, "\(chat.controls.errors)")
    }

    /// A session given a `//` message answers it, and that answer is what Viber posts back as the reply.
    func testRelayedMessageProducesReply() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["VIBER_LIVE_TEST"] == "1", "set VIBER_LIVE_TEST=1 to run")
        var chat = ChatTranscript()
        let spec = LaunchSpec(profile: env["VIBER_LIVE_PROFILE"], cwd: FileManager.default.temporaryDirectory.path, model: "haiku")
        let process = try ClaudeProcess(spec: spec, paneID: "live-relay", binDir: nil)
        let finished = expectation(description: "turn finished")
        process.onMessage = { message in
            for reply in chat.apply(message) { process.send(reply) }
            if message["type"]?.string == "result" { finished.fulfill() }
        }
        process.send(chat.request("initialize"))
        process.send(chat.receiveRelay(from: "OTA firmware updates", text: "Reply with exactly the word PINEAPPLE and nothing else. Do not use tools."))
        let received = try XCTUnwrap(chat.lastItemID)
        wait(for: [finished], timeout: 120)
        process.terminate()

        let reply = chat.assistantText(after: received)
        XCTAssertTrue(reply.uppercased().contains("PINEAPPLE"), "reply was: \(reply)")
    }
}
