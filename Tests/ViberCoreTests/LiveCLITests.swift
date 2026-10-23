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
}
