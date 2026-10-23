import XCTest
@testable import ViberCore

final class CoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func data(_ row: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: row) }
    func transcript(time: Date? = nil, messageID: String = "m1", usage: [String: Any] = [:],
                    content: [[String: Any]] = [], stop: String = "end_turn") throws -> Event {
        let row: [String: Any] = ["uuid": UUID().uuidString, "sessionId": "s1", "cwd": "/work/project",
            "timestamp": (time ?? now).timeIntervalSince1970, "type": "assistant",
            "message": ["id": messageID, "usage": usage, "content": content, "stop_reason": stop]]
        return try XCTUnwrap(EventParser.transcript(data(row), path: "/tmp/s1.jsonl"))
    }
    func hook(_ name: String, time: Date? = nil, tool: String = "", notification: String = "", id: String = "h1") throws -> Event {
        try XCTUnwrap(EventParser.hook(data(["event_id": id, "observed_at": (time ?? now).timeIntervalSince1970,
            "session_id": "s1", "cwd": "/work/project", "hook_event_name": name,
            "tool_name": tool, "notification_type": notification])))
    }
    func testTTLAndMixedTTL() throws {
        let hour = try transcript(usage: ["cache_creation": ["ephemeral_1h_input_tokens": 50]])
        XCTAssertEqual(hour.cacheTTL, 3600)
        let mixed = try transcript(usage: ["cache_creation": ["ephemeral_1h_input_tokens": 50, "ephemeral_5m_input_tokens": 20]])
        XCTAssertEqual(mixed.cacheTTL, 300)
        XCTAssertTrue(mixed.cacheBasis!.contains("Mixed"))
    }
    func testUnknownReadTTLUsesExplicitAssumption() throws {
        let event = try transcript(usage: ["cache_read_input_tokens": 500])
        XCTAssertEqual(event.cacheTTL, 300)
        XCTAssertTrue(event.cacheBasis!.contains("assumed"))
        XCTAssertNil(try transcript().cacheTTL)
    }
    func testDuplicateStreamingMessageDoesNotRefreshClock() throws {
        var store = SessionStore()
        store.apply(try transcript(usage: ["cache_read_input_tokens": 5]))
        store.apply(try transcript(time: now.addingTimeInterval(80), usage: ["cache_creation": ["ephemeral_1h_input_tokens": 10]]))
        XCTAssertEqual(store.sessions["s1"]?.cache?.observedAt, now)
        XCTAssertEqual(store.sessions["s1"]?.cache?.ttl, 3600)
    }
    func testZeroUsageDoesNotRefreshCache() throws {
        var store = SessionStore()
        store.apply(try transcript(usage: ["cache_read_input_tokens": 5]))
        store.apply(try transcript(time: now.addingTimeInterval(100), messageID: "m2"))
        XCTAssertEqual(store.sessions["s1"]?.cache?.observedAt, now)
    }
    func testInterleavedMessageReplayDoesNotReplaceNewerCache() throws {
        var store = SessionStore()
        store.apply(try transcript(usage: ["cache_read_input_tokens": 5]))
        store.apply(try transcript(time: now.addingTimeInterval(10), messageID: "m2", usage: ["cache_read_input_tokens": 5]))
        store.apply(try transcript(time: now.addingTimeInterval(20), messageID: "m1", usage: ["cache_read_input_tokens": 5]))
        XCTAssertEqual(store.sessions["s1"]?.cache?.generation, "m2")
        XCTAssertEqual(store.sessions["s1"]?.cache?.observedAt, now.addingTimeInterval(10))
    }
    func testOutOfOrderDoesNotRegressStateOrCache() throws {
        var store = SessionStore()
        store.apply(try hook("PermissionRequest"))
        store.apply(try transcript(time: now.addingTimeInterval(-20), usage: ["cache_read_input_tokens": 5]))
        XCTAssertEqual(store.sessions["s1"]?.state, .permission)
        store.apply(try transcript(time: now.addingTimeInterval(-40), messageID: "old", usage: ["cache_read_input_tokens": 5]))
        XCTAssertEqual(store.sessions["s1"]?.cache?.observedAt, now.addingTimeInterval(-20))
    }
    func testHookStatesAndQuestionPlanInference() throws {
        XCTAssertEqual(try hook("Stop").state, .finished)
        XCTAssertEqual(try hook("StopFailure").state, .failed)
        XCTAssertEqual(try hook("PermissionRequest").state, .permission)
        XCTAssertEqual(try hook("PermissionRequest", tool: "ExitPlanMode").state, .plan)
        XCTAssertEqual(try hook("PreToolUse", tool: "AskUserQuestion").state, .input)
        XCTAssertTrue(try hook("PreToolUse", tool: "AskUserQuestion").estimated)
        XCTAssertEqual(try hook("PostToolUse").state, .working)
        XCTAssertEqual(try hook("SessionEnd").state, .ended)
        let plan = try transcript(content: [["type": "tool_use", "name": "ExitPlanMode", "id": "t1"]])
        XCTAssertEqual(plan.state, .plan)
        XCTAssertTrue(plan.estimated)
    }
    func testIdleNotificationIsNotAQuestion() throws {
        XCTAssertNil(EventParser.hook(try data(["event_id": "x", "observed_at": now.timeIntervalSince1970,
            "session_id": "s1", "hook_event_name": "Notification", "notification_type": "idle_prompt"])))
    }
    func testSubagentHooksAreIgnored() throws {
        for name in ["Stop", "PreToolUse", "PermissionRequest", "PostToolUse"] {
            let sanitized = try HookInbox.sanitized(data(["session_id": "s1", "hook_event_name": name,
                "agent_id": "a1", "agent_type": "Explore"]), now: now)
            XCTAssertNil(EventParser.hook(sanitized), name)
        }
    }
    func testFinishAfterAgentReportDoesNotAlert() throws {
        func row(_ fields: [String: Any], at offset: TimeInterval) throws -> Event {
            try XCTUnwrap(EventParser.transcript(data(fields.merging(["uuid": UUID().uuidString, "sessionId": "s1",
                "cwd": "/work/project", "timestamp": now.addingTimeInterval(offset).timeIntervalSince1970]) { a, _ in a }),
                path: "/tmp/s1.jsonl"))
        }
        let human = try row(["type": "user", "origin": ["kind": "human"], "message": ["content": "hi"]], at: -30)
        let queued = try row(["type": "attachment", "attachment": ["type": "queued_command",
            "origin": ["kind": "task-notification"], "prompt": "<task-notification>"]], at: -20)
        let peer = try row(["type": "user", "origin": ["kind": "peer", "from": "a1"], "message": ["content": "report"]], at: -20)
        XCTAssertEqual(human.automatedTurn, false)
        XCTAssertNil(queued.state)
        for trigger in [queued, peer] {
            var store = SessionStore()
            var ledger = AlertLedger()
            store.apply(human)
            store.apply(try transcript(time: now.addingTimeInterval(-25)))
            store.apply(trigger)
            let before = store.sessions
            store.apply(try transcript(time: now, messageID: "m2"))
            XCTAssertEqual(store.sessions["s1"]?.state, .finished)
            XCTAssertTrue(ledger.alerts(previous: before, current: store.sessions, now: now, threshold: 600, bootstrap: false).isEmpty)
            store.apply(try transcript(time: now.addingTimeInterval(1), messageID: "m3",
                content: [["type": "tool_use", "name": "AskUserQuestion", "id": "q1"]], stop: "tool_use"))
            XCTAssertEqual(ledger.alerts(previous: before, current: store.sessions, now: now.addingTimeInterval(1), threshold: 600, bootstrap: false).count, 1)
        }
    }
    func testDelayedGenericPermissionDoesNotDuplicatePlanAlert() throws {
        var store = SessionStore()
        var ledger = AlertLedger()
        store.apply(try hook("PermissionRequest", tool: "ExitPlanMode"))
        XCTAssertEqual(ledger.alerts(previous: [:], current: store.sessions, now: now, threshold: 600, bootstrap: false).count, 1)
        let before = store.sessions
        store.apply(try hook("Notification", time: now.addingTimeInterval(6), notification: "permission_prompt", id: "notice"))
        XCTAssertEqual(store.sessions["s1"]?.state, .plan)
        XCTAssertTrue(ledger.alerts(previous: before, current: store.sessions, now: now.addingTimeInterval(6), threshold: 600, bootstrap: false).isEmpty)
    }
    func testReplayedToolDoesNotReopenResolvedQuestion() throws {
        var store = SessionStore()
        let tool = [["type": "tool_use", "name": "AskUserQuestion", "id": "t1"]]
        store.apply(try transcript(content: tool))
        store.apply(try hook("PostToolUse", time: now.addingTimeInterval(1)))
        store.apply(try transcript(time: now.addingTimeInterval(2), content: tool))
        XCTAssertEqual(store.sessions["s1"]?.state, .working)
    }
    func testStateNotificationDedupAndRestartBootstrap() throws {
        var store = SessionStore()
        var ledger = AlertLedger()
        store.apply(try hook("UserPromptSubmit", time: now.addingTimeInterval(-1)))
        let before = store.sessions
        store.apply(try hook("Stop"))
        XCTAssertEqual(ledger.alerts(previous: before, current: store.sessions, now: now, threshold: 600, bootstrap: false).count, 1)
        var restored = try JSONDecoder().decode(AlertLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertTrue(restored.alerts(previous: before, current: store.sessions, now: now, threshold: 600, bootstrap: false).isEmpty)
        XCTAssertTrue(restored.alerts(previous: [:], current: store.sessions, now: now, threshold: 600, bootstrap: true).isEmpty)
    }
    func testNewLiveSessionCanAlert() throws {
        var store = SessionStore()
        var ledger = AlertLedger()
        store.apply(try hook("PermissionRequest"))
        XCTAssertEqual(ledger.alerts(previous: [:], current: store.sessions, now: now, threshold: 600, bootstrap: false).count, 1)
    }
    func testThresholdOncePerCacheGenerationAndRefresh() throws {
        var store = SessionStore()
        var ledger = AlertLedger()
        store.apply(try transcript(usage: ["cache_creation": ["ephemeral_1h_input_tokens": 1]]))
        XCTAssertTrue(ledger.alerts(previous: store.sessions, current: store.sessions, now: now, threshold: 600, bootstrap: false).isEmpty)
        let later = now.addingTimeInterval(3000)
        XCTAssertEqual(ledger.alerts(previous: store.sessions, current: store.sessions, now: later, threshold: 600, bootstrap: false).count, 1)
        XCTAssertTrue(ledger.alerts(previous: store.sessions, current: store.sessions, now: later, threshold: 600, bootstrap: false).isEmpty)
        store.apply(try transcript(time: later, messageID: "m2", usage: ["cache_read_input_tokens": 1]))
        XCTAssertEqual(ledger.alerts(previous: store.sessions, current: store.sessions, now: later, threshold: 600, bootstrap: false).count, 1)
    }
    func testExpiredCachesDoNotNotify() throws {
        var store = SessionStore()
        var ledger = AlertLedger()
        store.apply(try transcript(usage: ["cache_read_input_tokens": 1]))
        XCTAssertTrue(ledger.alerts(previous: store.sessions, current: store.sessions, now: now.addingTimeInterval(301), threshold: 600, bootstrap: false).isEmpty)
    }
    func testSanitizerExcludesSensitiveContent() throws {
        let sanitized = try HookInbox.sanitized(data(["session_id": "s1", "hook_event_name": "Stop",
            "last_assistant_message": "secret", "tool_input": ["password": "secret"], "prompt": "secret"]), now: now)
        XCTAssertFalse(String(decoding: sanitized, as: UTF8.self).contains("secret"))
        XCTAssertEqual(EventParser.hook(sanitized)?.state, .finished)
    }
    func testMalformedAndSubagentRowsIgnored() throws {
        XCTAssertNil(EventParser.transcript(Data("garbage".utf8), path: "/s.jsonl"))
        let row = try data(["type": "assistant", "sessionId": "parent", "timestamp": now.timeIntervalSince1970])
        XCTAssertNil(EventParser.transcript(row, path: "/parent/subagents/a.jsonl"))
    }
    func testIncrementalWatcherPartialAppendAndRotation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("s.jsonl")
        let row = try data(["type": "user", "sessionId": "s1", "timestamp": now.timeIntervalSince1970])
        try row.write(to: file)
        let watcher = TranscriptWatcher(root: root)
        XCTAssertTrue(watcher.scan(fallbackTTL: 300).events.isEmpty)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([10]))
        try handle.close()
        XCTAssertEqual(watcher.scan(fallbackTTL: 300).events.count, 1)
        XCTAssertTrue(watcher.scan(fallbackTTL: 300).events.isEmpty)
        try (row + Data([10])).write(to: file, options: .atomic)
        XCTAssertEqual(watcher.scan(fallbackTTL: 300).events.count, 1)
    }
    func testNewNestedFilesAndTruncation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = TranscriptWatcher(root: root)
        XCTAssertTrue(watcher.scan(fallbackTTL: 300).events.isEmpty)
        let nested = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("s.jsonl")
        let row = try data(["type": "user", "timestamp": now.timeIntervalSince1970]) + Data([10])
        try (row + row).write(to: file)
        XCTAssertEqual(watcher.scan(fallbackTTL: 300).events.count, 2)
        try row.write(to: file)
        XCTAssertEqual(watcher.scan(fallbackTTL: 300).events.count, 1)
    }
    func testHookInboxAtomicDeliveryAndExpiry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try data(["session_id": "s1", "hook_event_name": "Stop"])
        try HookInbox.write(HookInbox.sanitized(input, now: now), to: root)
        try HookInbox.write(HookInbox.sanitized(input, now: now.addingTimeInterval(-90_000)), to: root)
        XCTAssertEqual(try HookInbox.drain(root, now: now).count, 1)
        XCTAssertTrue(try HookInbox.drain(root, now: now).isEmpty)
    }
    func testISO8601WithAndWithoutFractionalSeconds() {
        XCTAssertNotNil(Dates.parse("2026-09-30T10:00:00.123Z"))
        XCTAssertNotNil(Dates.parse("2026-09-30T10:00:00Z"))
    }
}
