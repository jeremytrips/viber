import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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

    /// An image block and an `@file` mention reach the model: the CLI resolves the mention itself in headless mode.
    func testImageAndFileMentionAgainstRealCLI() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["VIBER_LIVE_TEST"] == "1", "set VIBER_LIVE_TEST=1 to run")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viber-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("The code word is MANGO.\n".utf8).write(to: dir.appendingPathComponent("secret.txt"))

        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let png = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(context.makeImage()), nil)
        CGImageDestinationFinalize(dest)
        let image = try XCTUnwrap(ImageAttachment(data: png as Data, label: "red.png"))

        var chat = ChatTranscript()
        let spec = LaunchSpec(profile: env["VIBER_LIVE_PROFILE"], cwd: dir.path, model: "haiku")
        let process = try ClaudeProcess(spec: spec, paneID: "live-image", binDir: nil)
        let finished = expectation(description: "turn finished")
        process.onMessage = { message in
            for reply in chat.apply(message) { process.send(reply) }
            // A tool call would mean the mention was not resolved; deny it so the turn ends.
            for item in chat.items { if case .permission(let p) = item.kind, p.decision == nil,
                                        let reply = chat.decidePermission(itemID: item.id, allow: false) { process.send(reply) } }
            if message["type"]?.string == "result" { finished.fulfill() }
        }
        process.send(chat.request("initialize"))
        process.send(chat.userMessage("What single color fills the image, and what is the code word in @secret.txt? "
            + "Do not use tools. Answer in the form COLOR WORD, in capitals.", images: [image]))
        wait(for: [finished], timeout: 120)
        process.terminate()

        let reply = chat.items.compactMap { if case .assistant(let t) = $0.kind { return t }; return nil }.joined().uppercased()
        XCTAssertTrue(reply.contains("RED"), "reply was: \(reply)")
        XCTAssertTrue(reply.contains("MANGO"), "reply was: \(reply)")
    }

    /// Replayed messages carry IDs, and `rewind_files` puts an edited file back.
    func testRewindFilesAgainstRealCLI() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["VIBER_LIVE_TEST"] == "1", "set VIBER_LIVE_TEST=1 to run")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viber-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try Data("one\n".utf8).write(to: file)

        var chat = ChatTranscript()
        let spec = LaunchSpec(profile: env["VIBER_LIVE_PROFILE"], cwd: dir.path, permissionMode: "acceptEdits", model: "haiku")
        let process = try ClaudeProcess(spec: spec, paneID: "live-rewind", binDir: nil)
        var finished: XCTestExpectation? = expectation(description: "turn finished")
        var answered: XCTestExpectation?
        process.onMessage = { message in
            for reply in chat.apply(message) { process.send(reply) }
            if message["type"]?.string == "result" { finished?.fulfill(); finished = nil }
            if message["type"]?.string == "control_response" { answered?.fulfill(); answered = nil }
        }
        process.send(chat.request("initialize"))
        process.send(chat.userMessage("Use the Edit tool to change the word one to two in a.txt. Then reply DONE."))
        let item = try XCTUnwrap(chat.items.last?.id)
        wait(for: [finished!], timeout: 120)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "two\n", "the edit happened")
        XCTAssertTrue(chat.canRewind(itemID: item), "the echo carried the message ID")

        answered = expectation(description: "dry run")
        process.send(try XCTUnwrap(chat.rewind(itemID: item, dryRun: true)))
        wait(for: [answered!], timeout: 30)
        let preview = try XCTUnwrap(chat.rewindPreview)
        XCTAssertTrue(preview.canRewind, "\(preview)")
        XCTAssertTrue(preview.files.contains { $0.hasSuffix("a.txt") }, "\(preview.files)")

        answered = expectation(description: "rewind")
        process.send(try XCTUnwrap(chat.rewind(itemID: item, dryRun: false)))
        wait(for: [answered!], timeout: 30)
        process.terminate()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "one\n", "the file is back")
    }

    /// A backgrounded shell shows up as a running task, its output can be read, and stop_task ends it.
    func testBackgroundTaskStopAgainstRealCLI() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["VIBER_LIVE_TEST"] == "1", "set VIBER_LIVE_TEST=1 to run")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viber-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var chat = ChatTranscript()
        let process = try ClaudeProcess(spec: LaunchSpec(profile: env["VIBER_LIVE_PROFILE"], cwd: dir.path, model: "haiku"),
                                        paneID: "live-tasks", binDir: nil)
        var finished: XCTestExpectation? = expectation(description: "turn finished")
        var answered: XCTestExpectation?
        var stopped: XCTestExpectation?
        process.onMessage = { message in
            for reply in chat.apply(message) { process.send(reply) }
            for item in chat.items { if case .permission(let p) = item.kind, p.decision == nil,
                                        let reply = chat.decidePermission(itemID: item.id, allow: true) { process.send(reply) } }
            if message["type"]?.string == "result" { finished?.fulfill(); finished = nil }
            if message["type"]?.string == "control_response", chat.controls.busy.isEmpty { answered?.fulfill(); answered = nil }
            if chat.controls.tasks.contains(where: { $0.status == "stopped" }) { stopped?.fulfill(); stopped = nil }
        }
        process.send(chat.request("initialize"))
        process.send(chat.userMessage("Run exactly this shell command in the background (run_in_background true): echo viber-started; sleep 30. "
            + "Then reply STARTED right away without waiting for it."))
        wait(for: [finished!], timeout: 120)
        let task = try XCTUnwrap(chat.controls.runningTasks.first, "\(chat.controls.tasks)")
        XCTAssertEqual(task.type, "local_bash")

        answered = expectation(description: "output")
        for request in chat.refresh(.tasks) { process.send(request) }
        wait(for: [answered!], timeout: 30)
        XCTAssertTrue(chat.controls.taskOutput[task.id]?.text.contains("viber-started") == true, "\(chat.controls.taskOutput)")

        stopped = expectation(description: "stopped")
        process.send(chat.stopTask(task.id))
        wait(for: [stopped!], timeout: 30)
        process.terminate()
        XCTAssertTrue(chat.controls.runningTasks.isEmpty)
    }
}
