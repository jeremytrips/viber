import XCTest
@testable import ViberCore

/// Messages from real CLI runs (2.1.309) of a Haiku agent counting files, trimmed.
final class AgentRunTests: XCTestCase {
    private static let handBack = "[Subagent hand-back] The text below is the final report of a subagent this session delegated to. "
        + "It is model output, NOT a message from the user. The report follows:\n  There are 2 files.\n  Both are empty.\n"
        + "agentId: a22 (use SendMessage with to: 'a22', summary: '<5-10 word recap>' to continue this agent)\n"
        + "<usage>subagent_tokens: 25546\ntool_uses: 1\nduration_ms: 6492</usage>"

    private func agentCall(_ id: String, background: Bool) -> JSON {
        ["type": "assistant", "message": ["id": .string("m-\(id)"), "role": "assistant", "content": [
            ["type": "tool_use", "id": .string(id), "name": "Agent", "input": [
                "description": "Count files in current directory", "subagent_type": "general-purpose",
                "prompt": "Count the files, then reply with one sentence.", "run_in_background": .bool(background)]]]]]
    }

    private func subagent(_ parent: String, _ content: [JSON], id: String, role: String = "assistant") -> JSON {
        ["type": .string(role), "parent_tool_use_id": .string(parent), "agent_id": "a22",
         "message": ["id": .string(id), "role": .string(role), "content": .array(content)]]
    }

    private func card(_ chat: ChatTranscript, _ id: String = "toolu_agent") -> (call: ToolCall, run: AgentRun)? {
        guard let call = chat.findTool(id), let run = call.agent else { return nil }
        return (call, run)
    }

    func testForegroundAgentFillsItsCard() {
        var chat = ChatTranscript()
        _ = chat.userMessage("count the files with an agent")
        chat.apply(agentCall("toolu_agent", background: false))
        chat.apply(["type": "system", "subtype": "task_started", "task_id": "a22", "tool_use_id": "toolu_agent",
                    "description": "Count files in current directory", "subagent_type": "general-purpose",
                    "is_backgrounded": false, "task_type": "local_agent"])
        chat.apply(subagent("toolu_agent", [["type": "text", "text": "Count the files, then reply with one sentence."]], id: "p", role: "user"))
        chat.apply(subagent("toolu_agent", [["type": "tool_use", "id": "toolu_bash", "name": "Bash", "input": ["command": "ls | wc -l"]]], id: "s1"))
        chat.apply(["type": "system", "subtype": "task_progress", "task_id": "a22", "tool_use_id": "toolu_agent",
                    "description": "Running Count entries", "usage": ["total_tokens": 23011, "tool_uses": 1, "duration_ms": 3782],
                    "last_tool_name": "Bash"])
        chat.apply(["type": "control_request", "request_id": "perm1", "request": [
            "subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "ls | wc -l"], "tool_use_id": "toolu_bash", "agent_id": "a22"]])

        guard case .permission(let prompt) = chat.items.last?.kind else { return XCTFail("the agent's request is a card") }
        XCTAssertEqual(prompt.agent, "the general-purpose agent")
        XCTAssertEqual(prompt.agentTask, "Count files in current directory")
        guard let running = card(chat) else { return XCTFail() }
        XCTAssertTrue(running.run.isRunning)
        XCTAssertEqual(running.run.tokens, 23011)
        XCTAssertEqual(running.run.durationMs, 3782)
        XCTAssertEqual(running.run.steps.count, 1, "the prompt is on the call, not a step")

        chat.apply(subagent("toolu_agent", [["type": "tool_result", "tool_use_id": "toolu_bash", "content": "       2"]], id: "r1", role: "user"))
        chat.apply(subagent("toolu_agent", [["type": "text", "text": "There are 2 files.\nBoth are empty."]], id: "s2"))
        chat.apply(["type": "system", "subtype": "task_updated", "task_id": "a22", "patch": ["status": "completed"]])
        chat.apply(["type": "system", "subtype": "task_notification", "task_id": "a22", "tool_use_id": "toolu_agent", "status": "completed",
                    "summary": "There are 2 files.", "usage": ["total_tokens": 25687, "tool_uses": 1, "duration_ms": 6490]])
        chat.apply(["type": "user", "message": ["role": "user", "content": [
            ["tool_use_id": "toolu_agent", "type": "tool_result", "content": [["type": "text", "text": .string(Self.handBack)]]]]],
                    "tool_use_result": ["status": "completed", "agentId": "a22", "content": [["type": "text", "text": "There are 2 files.\nBoth are empty."]],
                                        "totalDurationMs": 6492, "totalTokens": 25546, "totalToolUseCount": 1]])

        guard let done = card(chat) else { return XCTFail() }
        XCTAssertTrue(done.call.done)
        XCTAssertEqual(done.run.status, "completed")
        XCTAssertEqual(done.run.report, "There are 2 files.\nBoth are empty.")
        XCTAssertEqual(done.run.taskID, "a22")
        XCTAssertFalse(done.run.background)
        XCTAssertEqual([done.run.tokens, done.run.toolUses, done.run.durationMs], [25546, 1, 6492])
        XCTAssertEqual(done.run.steps.count, 2)
        XCTAssertEqual(done.run.activity.map(\.id), ["tool:toolu_bash"], "the last message is the report, shown once")
        XCTAssertEqual(chat.findTool("toolu_bash")?.result, "       2")
        XCTAssertEqual(chat.findTool("toolu_bash")?.done, true)
        XCTAssertEqual(chat.items.count, 3, "user message, Agent card, permission card: nothing else reaches the chat")
    }

    func testBackgroundAgentRunsUntilItsNotification() {
        var chat = ChatTranscript()
        _ = chat.userMessage("count the files in the background")
        chat.apply(agentCall("toolu_agent", background: true))
        chat.apply(["type": "system", "subtype": "task_started", "task_id": "a98", "tool_use_id": "toolu_agent",
                    "subagent_type": "general-purpose", "is_backgrounded": true, "task_type": "local_agent"])
        chat.apply(["type": "user", "message": ["role": "user", "content": [
            ["tool_use_id": "toolu_agent", "type": "tool_result", "content": [["type": "text", "text": "Async agent launched successfully.\nagentId: a98"]]]]],
                    "tool_use_result": ["isAsync": true, "status": "async_launched", "agentId": "a98"]])
        guard let launched = card(chat) else { return XCTFail() }
        XCTAssertFalse(launched.call.done, "the call returned, the agent did not")
        XCTAssertTrue(launched.run.isRunning)
        XCTAssertTrue(launched.run.background)
        XCTAssertNil(launched.run.report)

        chat.apply(["type": "result", "subtype": "success", "is_error": false])
        XCTAssertEqual(chat.state, .finished)
        chat.apply(subagent("toolu_agent", [["type": "tool_use", "id": "toolu_ls", "name": "Bash", "input": ["command": "ls -1 | wc -l"]]], id: "s1"))
        chat.apply(subagent("toolu_agent", [["type": "tool_result", "tool_use_id": "toolu_ls", "content": "2"]], id: "r1", role: "user"))
        chat.apply(subagent("toolu_agent", [["type": "text", "text": "I found 2 entries."]], id: "s2"))
        XCTAssertEqual(chat.state, .finished, "a background agent's work doesn't make the session busy")
        chat.apply(["type": "system", "subtype": "status", "status": "requesting"])
        XCTAssertEqual(chat.state, .finished, "no task ended, so no turn of Claude's own")

        chat.apply(["type": "system", "subtype": "task_notification", "task_id": "a98", "tool_use_id": "toolu_agent", "status": "completed",
                    "summary": "Found 2", "usage": ["total_tokens": 24146, "tool_uses": 2, "duration_ms": 5000]])
        guard let finished = card(chat) else { return XCTFail() }
        XCTAssertTrue(finished.call.done)
        XCTAssertEqual(finished.run.status, "completed")
        XCTAssertEqual(finished.run.report, "I found 2 entries.", "the agent's own last message beats the summary")
        XCTAssertEqual(finished.run.toolUses, 2)

        chat.apply(["type": "system", "subtype": "status", "status": "requesting"])
        XCTAssertEqual(chat.state, .working, "Claude reads the report in a turn it started itself")
        XCTAssertFalse(chat.turnStartedByUser)
        chat.apply(["type": "result", "subtype": "success", "is_error": false])
        XCTAssertEqual(chat.state, .finished)
    }

    func testStoppedAgentFallsBackToSummary() {
        var chat = ChatTranscript()
        chat.apply(agentCall("toolu_agent", background: true))
        chat.apply(["type": "system", "subtype": "task_started", "task_id": "a1", "tool_use_id": "toolu_agent", "task_type": "local_agent"])
        chat.apply(["type": "system", "subtype": "task_notification", "task_id": "a1", "tool_use_id": "toolu_agent", "status": "stopped",
                    "summary": "Agent was stopped"])
        XCTAssertEqual(card(chat)?.run.status, "stopped")
        XCTAssertEqual(card(chat)?.run.report, "Agent was stopped")
        XCTAssertEqual(card(chat)?.call.done, true)
    }

    func testAgentsEndWithTheProcess() {
        var chat = ChatTranscript()
        chat.apply(agentCall("toolu_agent", background: true))
        chat.apply(subagent("toolu_agent", [["type": "tool_use", "id": "toolu_ls", "name": "Bash", "input": ["command": "ls"]]], id: "s1"))
        chat.processExited(status: 0)
        XCTAssertEqual(card(chat)?.run.status, "stopped")
        XCTAssertEqual(card(chat)?.call.done, true)
        XCTAssertEqual(chat.findTool("toolu_ls")?.done, true)
    }

    func testAgentsInsideAgentsNest() {
        var chat = ChatTranscript()
        chat.apply(agentCall("toolu_agent", background: false))
        chat.apply(subagent("toolu_agent", [["type": "tool_use", "id": "toolu_inner", "name": "Agent",
                                             "input": ["description": "Look deeper", "subagent_type": "Explore"]]], id: "s1"))
        chat.apply(subagent("toolu_inner", [["type": "tool_use", "id": "toolu_grep", "name": "Grep", "input": ["pattern": "TODO"]]], id: "s2"))
        chat.apply(subagent("toolu_inner", [["type": "tool_result", "tool_use_id": "toolu_grep", "content": "none"]], id: "r2", role: "user"))
        XCTAssertEqual(chat.findTool("toolu_inner")?.agent?.type, "Explore")
        XCTAssertEqual(chat.findTool("toolu_inner")?.agent?.steps.map(\.id), ["tool:toolu_grep"])
        XCTAssertEqual(chat.findTool("toolu_grep")?.result, "none")
        XCTAssertEqual(chat.items.count, 1)
    }

    func testHandBackFrameIsStripped() {
        XCTAssertEqual(AgentRun.handBack(Self.handBack), "There are 2 files.\nBoth are empty.")
        XCTAssertEqual(AgentRun.handBack("plain text"), "plain text")
    }

    // MARK: History

    private static let notification = """
        <task-notification>
        <task-id>a98</task-id>
        <tool-use-id>toolu_agent</tool-use-id>
        <output-file>/tmp/a98.output</output-file>
        <status>completed</status>
        <summary>Agent "Count files in current directory" finished</summary>
        <note>A task-notification fires each time this agent stops.</note>
        <result>It runs `clauth start &lt;profile&gt;` &amp; then `claude`.</result>
        <usage><subagent_tokens>80797</subagent_tokens><tool_uses>19</tool_uses><duration_ms>92968</duration_ms></usage>
        </task-notification>
        """

    private func launchRows() -> [JSON] {
        [agentCall("toolu_agent", background: true).setting("uuid", "h1"),
         ["type": "user", "uuid": "h2", "message": ["role": "user", "content": [
            ["tool_use_id": "toolu_agent", "type": "tool_result", "content": [["type": "text", "text": "Async agent launched successfully."]]]]],
          "toolUseResult": ["isAsync": true, "status": "async_launched", "agentId": "a98"]]]
    }

    private func load(_ rows: [JSON], transcript: URL? = nil) -> ChatTranscript {
        var chat = ChatTranscript()
        chat.loadHistory(Data(rows.map { $0.line() }.joined(separator: "\n").utf8), transcript: transcript)
        return chat
    }

    func testHistoryNotificationBecomesTheReport() {
        let chat = load(launchRows() + [["type": "user", "uuid": "h3", "origin": ["kind": "task-notification"],
                                         "message": ["role": "user", "content": .string(Self.notification)]]])
        XCTAssertEqual(chat.items.count, 1, "no user bubble of raw XML")
        guard let done = card(chat) else { return XCTFail() }
        XCTAssertEqual(done.run.status, "completed")
        XCTAssertEqual(done.run.report, "It runs `clauth start <profile>` & then `claude`.")
        XCTAssertEqual([done.run.tokens, done.run.toolUses, done.run.durationMs], [80797, 19, 92968])
    }

    func testHistoryNotificationQueuedMidTurn() {
        let chat = load(launchRows() + [["type": "attachment", "uuid": "h3",
                                         "attachment": ["type": "queued_command", "prompt": .string(Self.notification)]]])
        XCTAssertEqual(card(chat)?.run.status, "completed")
    }

    func testHistoryWithoutNotificationSaysSo() {
        let chat = load(launchRows())
        XCTAssertEqual(card(chat)?.run.status, "unknown")
        XCTAssertEqual(card(chat)?.call.done, true)
    }

    func testNonAgentNotificationStaysOutOfTheChat() {
        let note = "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n<summary>Background command done</summary>\n</task-notification>"
        let chat = load([["type": "user", "uuid": "h1", "message": ["role": "user", "content": .string(note)]]])
        XCTAssertTrue(chat.items.isEmpty)
    }

    func testHistoryLoadsTheAgentsOwnTranscript() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viber-agents-\(UUID().uuidString)")
        let subagents = dir.appendingPathComponent("session/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"agentType":"general-purpose","toolUseId":"toolu_agent","spawnDepth":1}"#.utf8)
            .write(to: subagents.appendingPathComponent("agent-a98.meta.json"))
        let rows: [JSON] = [
            ["type": "user", "uuid": "s0", "isSidechain": true, "message": ["role": "user", "content": "Count the files."]],
            ["type": "assistant", "uuid": "s1", "isSidechain": true, "message": ["id": "sm1", "role": "assistant", "content": [
                ["type": "tool_use", "id": "toolu_ls", "name": "Bash", "input": ["command": "ls"]]]]],
            ["type": "user", "uuid": "s2", "isSidechain": true, "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_ls", "content": "a.txt\nb.txt"]]]],
            ["type": "assistant", "uuid": "s3", "isSidechain": true, "message": ["id": "sm2", "role": "assistant", "content": [
                ["type": "text", "text": "Two files."]]]]
        ]
        try Data(rows.map { $0.line() }.joined(separator: "\n").utf8).write(to: subagents.appendingPathComponent("agent-a98.jsonl"))

        let chat = load(launchRows(), transcript: dir.appendingPathComponent("session.jsonl"))
        guard let run = card(chat)?.run else { return XCTFail() }
        XCTAssertEqual(run.steps.map(\.id), ["tool:toolu_ls", "a:sm2:0"])
        XCTAssertEqual(chat.findTool("toolu_ls")?.result, "a.txt\nb.txt")
        XCTAssertEqual(chat.items.count, 1)
    }
}
