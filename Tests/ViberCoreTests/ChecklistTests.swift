import XCTest
@testable import ViberCore

final class ChecklistTests: XCTestCase {
    private func use(_ id: String, _ name: String, _ input: JSON) -> JSON {
        ["type": "assistant", "message": ["id": .string("m-\(id)"), "role": "assistant", "content": [
            ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]]]]
    }

    private func result(_ id: String, _ text: String, _ structured: JSON? = nil, isError: Bool = false) -> JSON {
        var row: [String: JSON] = ["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": .string(id), "content": .string(text), "is_error": .bool(isError)]]]]
        if let structured { row["tool_use_result"] = structured }
        return .object(row)
    }

    func testTodoWriteReplacesTheList() {
        var chat = ChatTranscript()
        chat.apply(use("t1", "TodoWrite", ["todos": [
            ["content": "Write tests", "status": "completed", "activeForm": "Writing tests"],
            ["content": "Fix bug", "status": "in_progress", "activeForm": "Fixing bug"],
            ["content": "Ship", "status": "pending", "activeForm": "Shipping"]]]))
        XCTAssertEqual(chat.todos.map(\.content), ["Write tests", "Fix bug", "Ship"])
        XCTAssertEqual(chat.todos.map(\.status), ["completed", "in_progress", "pending"])
        XCTAssertEqual(chat.todos[1].activeForm, "Fixing bug")
        XCTAssertEqual(ToolSummary.summary(name: "TodoWrite", input: ["todos": [["content": "a"]]]), "1 items")
    }

    /// TaskCreate/TaskUpdate as a real CLI run with CLAUDE_CODE_ENABLE_TODO_TOOLS=1 produced them (2.1.309).
    func testTaskListToolsBuildTheList() {
        var chat = ChatTranscript()
        chat.apply(use("c1", "TaskCreate", ["subject": "Write tests", "description": "Write tests"]))
        XCTAssertTrue(chat.todos.isEmpty, "the ID only comes with the result")
        chat.apply(result("c1", "Task #1 created successfully: Write tests", ["task": ["id": "1", "subject": "Write tests"]]))
        chat.apply(use("c2", "TaskCreate", ["subject": "Fix bug", "description": "Fix bug", "activeForm": "Fixing the bug"]))
        chat.apply(result("c2", "Task #2 created successfully: Fix bug", ["task": ["id": "2", "subject": "Fix bug"]]))
        chat.apply(use("u1", "TaskUpdate", ["taskId": "1", "status": "in_progress"]))
        chat.apply(result("u1", "Updated task #1 status", ["success": true, "taskId": "1", "updatedFields": ["status"]]))
        chat.apply(use("u2", "TaskUpdate", ["taskId": "2", "status": "completed"]))
        chat.apply(result("u2", "Updated task #2 status"))
        XCTAssertEqual(chat.todos, [TodoItem(id: "1", content: "Write tests", status: "in_progress"),
                                    TodoItem(id: "2", content: "Fix bug", activeForm: "Fixing the bug", status: "completed")])
        XCTAssertEqual(ToolSummary.summary(name: "TaskCreate", input: ["subject": "Fix bug", "description": "long text"]), "Fix bug")
        XCTAssertEqual(ToolSummary.summary(name: "TaskUpdate", input: ["taskId": "1", "status": "in_progress"]), "#1 → in progress")
    }

    func testFailedCallsAndDeletes() {
        var chat = ChatTranscript()
        chat.apply(use("c1", "TaskCreate", ["subject": "A"]))
        chat.apply(result("c1", "Task #1 created successfully: A"))
        XCTAssertEqual(chat.todos.map(\.id), ["1"], "the ID is read from the text when there is no structured result")
        chat.apply(use("u1", "TaskUpdate", ["taskId": "1", "status": "completed"]))
        chat.apply(result("u1", "Task not found", isError: true))
        XCTAssertEqual(chat.todos.first?.status, "pending", "a failed update changes nothing")
        chat.apply(use("u2", "TaskUpdate", ["taskId": "1", "status": "deleted"]))
        chat.apply(result("u2", "Updated task #1 deleted"))
        XCTAssertTrue(chat.todos.isEmpty)
    }

    func testHistoryRestoresTheChecklist() {
        let rows: [JSON] = [
            ["type": "assistant", "uuid": "a1", "message": ["id": "m1", "role": "assistant", "content": [
                ["type": "tool_use", "id": "c1", "name": "TaskCreate", "input": ["subject": "Port the parser"]]]]],
            ["type": "user", "uuid": "r1", "toolUseResult": ["task": ["id": "7", "subject": "Port the parser"]], "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "c1", "content": "Task #7 created successfully: Port the parser"]]]]
        ]
        var chat = ChatTranscript()
        chat.loadHistory(Data(rows.map { $0.line() }.joined(separator: "\n").utf8))
        XCTAssertEqual(chat.todos, [TodoItem(id: "7", content: "Port the parser")])
    }
}
