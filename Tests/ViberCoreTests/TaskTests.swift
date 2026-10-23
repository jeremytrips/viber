import XCTest
@testable import ViberCore

final class TaskTests: XCTestCase {
    private func reply(to request: JSON, _ body: JSON) -> JSON {
        ["type": "control_response", "response": ["subtype": "success", "request_id": request["request_id"]!, "response": body]]
    }

    /// The messages a backgrounded `sleep 3` produced in a real CLI run (2.1.309), trimmed.
    func testBackgroundShellLifecycle() {
        var chat = ChatTranscript()
        chat.apply(["type": "system", "subtype": "background_tasks_changed", "tasks": [
            ["task_id": "be3mb3i1u", "run_id": "r", "task_type": "local_bash", "description": "Sleep for 3 seconds in background"]]])
        chat.apply(["type": "system", "subtype": "task_started", "task_id": "be3mb3i1u", "tool_use_id": "toolu_1",
                    "description": "Sleep for 3 seconds in background", "is_backgrounded": true, "task_type": "local_bash"])
        XCTAssertEqual(chat.controls.runningTasks.map(\.id), ["be3mb3i1u"])
        let task = chat.controls.tasks[0]
        XCTAssertEqual(task.kindLabel, "Shell")
        XCTAssertTrue(task.backgrounded)
        XCTAssertTrue(task.hasOutput)
        XCTAssertEqual(task.toolUseID, "toolu_1")

        chat.apply(["type": "system", "subtype": "task_updated", "task_id": "be3mb3i1u", "patch": ["status": "completed", "end_time": 1792791282831]])
        chat.apply(["type": "system", "subtype": "task_notification", "task_id": "be3mb3i1u", "tool_use_id": "toolu_1", "status": "completed",
                    "output_file": "/tmp/x.output", "summary": "Background command \"Sleep for 3 seconds in background\" completed (exit code 0)"])
        chat.apply(["type": "system", "subtype": "background_tasks_changed", "tasks": []])
        XCTAssertTrue(chat.controls.runningTasks.isEmpty)
        XCTAssertEqual(chat.controls.tasks.first?.status, "completed")
        XCTAssertEqual(chat.controls.tasks.first?.summary, "Background command \"Sleep for 3 seconds in background\" completed (exit code 0)")
        XCTAssertTrue(chat.items.isEmpty, "task events stay out of the chat")
    }

    func testSubagentProgressShowsOnItsToolRow() {
        var chat = ChatTranscript()
        chat.apply(["type": "assistant", "message": ["id": "m1", "role": "assistant", "content": [
            ["type": "tool_use", "id": "toolu_a", "name": "Task", "input": ["description": "Explore code", "subagent_type": "Explore"]]]]])
        chat.apply(["type": "system", "subtype": "task_started", "task_id": "a1", "tool_use_id": "toolu_a", "description": "Explore code",
                    "subagent_type": "Explore", "task_type": "local_agent", "is_backgrounded": false])
        chat.apply(["type": "system", "subtype": "task_progress", "task_id": "a1", "tool_use_id": "toolu_a", "description": "Explore code",
                    "usage": ["total_tokens": 1200, "tool_uses": 3, "duration_ms": 900], "last_tool_name": "Grep", "summary": "Searching for the parser"])
        guard case .tool(let call) = chat.items[0].kind else { return XCTFail() }
        XCTAssertEqual(call.progress, "Grep · Searching for the parser")
        let task = chat.controls.tasks[0]
        XCTAssertEqual(task.kindLabel, "Agent · Explore")
        XCTAssertEqual(task.toolUses, 3)
        XCTAssertEqual(task.tokens, 1200)
        XCTAssertFalse(task.hasOutput, "only shells and monitors have output to read")
    }

    func testStopAndOutputRequests() {
        var chat = ChatTranscript()
        chat.apply(["type": "system", "subtype": "task_started", "task_id": "b1", "description": "npm run dev", "task_type": "local_bash"])
        let stop = chat.stopTask("b1")
        XCTAssertEqual(stop["request"], ["subtype": "stop_task", "task_id": "b1"])
        XCTAssertTrue(chat.controls.busy.contains("task:b1"))
        chat.apply(reply(to: stop, [:]))
        XCTAssertFalse(chat.controls.busy.contains("task:b1"))

        let refresh = chat.refresh(.tasks)
        XCTAssertEqual(refresh.map { $0["request"]?["subtype"]?.string }, ["get_task_output"], "refresh reads running shells' output")
        chat.apply(reply(to: refresh[0], ["output": "ready on :3000\n", "total_bytes": 20000, "truncated": true]))
        XCTAssertEqual(chat.controls.taskOutput["b1"], TaskOutput(text: "ready on :3000\n", totalBytes: 20000, truncated: true))
    }

    func testEndedTasksAreTrimmed() {
        var chat = ChatTranscript()
        for i in 0..<25 {
            chat.apply(["type": "system", "subtype": "task_notification", "task_id": .string("t\(i)"), "status": "completed", "summary": "done"])
        }
        chat.apply(["type": "system", "subtype": "task_started", "task_id": "live", "description": "watch", "task_type": "monitor"])
        XCTAssertEqual(chat.controls.tasks.count, 21)
        XCTAssertEqual(chat.controls.tasks.first?.id, "t5", "the oldest ended ones go first")
        XCTAssertEqual(chat.controls.runningTasks.map(\.id), ["live"])
    }

    func testTasksCommandsOpenTheTab() {
        XCTAssertEqual(SlashRouter.route("/tasks", commands: []), .openSettings(.tasks))
        XCTAssertEqual(SlashRouter.route("/bashes", commands: []), .openSettings(.tasks))
    }
}
