import XCTest
@testable import ViberCore

final class ChatTranscriptTests: XCTestCase {
    private func assistant(_ id: String, _ blocks: [JSON], usage: JSON? = nil) -> JSON {
        var message: [String: JSON] = ["id": .string(id), "role": "assistant", "model": "claude-haiku", "content": .array(blocks)]
        if let usage { message["usage"] = usage }
        return ["type": "assistant", "message": .object(message)]
    }

    func testInitializeResponseFillsCommandsAndModels() {
        var chat = ChatTranscript()
        chat.state = .starting
        let request = chat.request("initialize")
        let id = request["request_id"]!.string!
        chat.apply(["type": "control_response", "response": ["subtype": "success", "request_id": .string(id), "response": [
            "commands": [["name": "compact", "description": "Summarize"], ["name": "viber:cleanup", "description": "Clean"]],
            "models": [["value": "opus", "displayName": "Opus"]],
            "current_permission_mode": "default"]]])
        XCTAssertEqual(chat.commands.map(\.name), ["compact", "viber:cleanup"])
        XCTAssertEqual(chat.models.first?.displayName, "Opus")
        XCTAssertEqual(chat.permissionMode, "default")
        XCTAssertEqual(chat.state, .idle)
    }

    func testToolPermissionRoundTrip() {
        var chat = ChatTranscript()
        _ = chat.userMessage("touch a file")
        chat.apply(assistant("m1", [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "touch out.txt"]]]))
        let out = chat.apply(["type": "control_request", "request_id": "r1", "request": [
            "subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "touch out.txt"], "tool_use_id": "t1",
            "permission_suggestions": [["type": "addRules", "behavior": "allow"]]]])
        XCTAssertTrue(out.isEmpty)
        XCTAssertEqual(chat.state, .permission)
        guard let card = chat.items.last, case .permission = card.kind else { return XCTFail("no permission card") }

        let reply = chat.decidePermission(itemID: card.id, allow: true, always: true)
        XCTAssertEqual(reply?["response"]?["request_id"]?.string, "r1")
        XCTAssertEqual(reply?["response"]?["response"]?["behavior"]?.string, "allow")
        XCTAssertEqual(reply?["response"]?["response"]?["updatedInput"]?["command"]?.string, "touch out.txt")
        XCTAssertEqual(reply?["response"]?["response"]?["updatedPermissions"]?.array?.count, 1)
        XCTAssertEqual(chat.state, .working)
        XCTAssertNil(chat.decidePermission(itemID: card.id, allow: true), "a card is answered once")

        chat.apply(["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "t1", "content": "ok", "is_error": false]]]])
        guard case .tool(let call) = chat.items.first(where: { $0.id == "tool:t1" })?.kind else { return XCTFail() }
        XCTAssertEqual(call.result, "ok")
        XCTAssertTrue(call.done)

        chat.apply(["type": "result", "subtype": "success", "is_error": false, "total_cost_usd": 0.01, "duration_ms": 1500])
        XCTAssertEqual(chat.state, .finished)
        XCTAssertEqual(chat.lastTurnSeconds, 1.5)
    }

    func testQuestionAnswerAddsAnswersToInput() {
        var chat = ChatTranscript()
        let input: JSON = ["questions": [["question": "Split how?", "header": "Split", "multiSelect": false,
                                          "options": [["label": "By screen", "description": "one per panel"], ["label": "By layer", "description": "render/input"]]]]]
        chat.apply(assistant("m1", [["type": "tool_use", "id": "q1", "name": "AskUserQuestion", "input": input]]))
        chat.apply(["type": "control_request", "request_id": "r2", "request": [
            "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": input, "tool_use_id": "q1"]])
        XCTAssertEqual(chat.state, .input)
        XCTAssertEqual(chat.items.count, 1, "the tool row becomes the question card")
        guard case .question(let q) = chat.items[0].kind else { return XCTFail() }
        XCTAssertEqual(q.questions.first?.options.map(\.label), ["By screen", "By layer"])

        let reply = chat.answerQuestion(itemID: chat.items[0].id, answers: ["Split how?": "By layer"])
        XCTAssertEqual(reply?["response"]?["response"]?["updatedInput"]?["answers"]?["Split how?"]?.string, "By layer")
        XCTAssertEqual(chat.state, .working)
    }

    func testPlanApprovalSwitchesMode() {
        var chat = ChatTranscript()
        chat.apply(["type": "control_request", "request_id": "r3", "request": [
            "subtype": "can_use_tool", "tool_name": "ExitPlanMode", "input": ["plan": "# Plan\n1. do it"]]])
        XCTAssertEqual(chat.state, .plan)
        let id = chat.items[0].id
        let out = chat.decidePlan(itemID: id, decision: .approved(.acceptEdits))
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0]["response"]?["response"]?["behavior"]?.string, "allow")
        XCTAssertEqual(out[1]["request"]?["subtype"]?.string, "set_permission_mode")
        XCTAssertEqual(out[1]["request"]?["mode"]?.string, "acceptEdits")
        XCTAssertEqual(chat.decidePlan(itemID: id, decision: .approved(.auto)), [], "decided once")
    }

    func testModeFollowsTheCLI() {
        var chat = ChatTranscript()
        func notices() -> [String] { chat.items.compactMap { if case .notice(let text, _) = $0.kind { return text } else { return nil } } }
        chat.apply(["type": "system", "subtype": "init", "session_id": "s", "permissionMode": "default"])
        XCTAssertEqual(notices(), [], "the starting mode needs no notice")

        // Refused (auto mode is unavailable on some models): the mode stays, the reason shows.
        let refused = chat.setPermissionMode("auto")["request_id"]!.string!
        XCTAssertEqual(chat.permissionMode, "default", "waits for the CLI")
        chat.apply(ChatTranscript.controlError(refused, "Cannot set permission mode to auto: auto mode unavailable for this model"))
        XCTAssertEqual(chat.permissionMode, "default")

        // Accepted: the reply and the status message agree, and the switch is noted once.
        let accepted = chat.setPermissionMode("auto")["request_id"]!.string!
        chat.apply(ChatTranscript.controlSuccess(accepted, ["mode": "auto"]))
        chat.apply(["type": "system", "subtype": "status", "status": .null, "permissionMode": "auto", "uuid": "u1"])
        XCTAssertEqual(chat.permissionMode, "auto")

        // The CLI leaves auto mode on its own when the model switches to one without it.
        chat.apply(["type": "system", "subtype": "status", "status": .null, "permissionMode": "default", "uuid": "u2"])
        XCTAssertEqual(chat.permissionMode, "default")

        XCTAssertEqual(notices().count, 3, "\(notices())")
        XCTAssertTrue(notices()[0].contains("auto mode unavailable"))
        XCTAssertEqual(Array(notices().dropFirst()), [PermissionMode.auto.notice, "Mode: Ask before edits"])
    }

    func testToolBlockedByAutoMode() {
        var chat = ChatTranscript()
        _ = chat.userMessage("go")
        chat.apply(assistant("m1", [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls"]],
                                    ["type": "tool_use", "id": "t2", "name": "Bash", "input": ["command": "git push --force"]]]))
        chat.apply(["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "t1", "content": "a.txt", "is_error": false],
            ["type": "tool_result", "tool_use_id": "t2", "content": "Blocked: force push", "is_error": true]]],
            "tool_result_meta": [
                ["id": "t1", "permission_decision": ["decision": "accept", "source": "config", "reason_type": "classifier"]],
                ["id": "t2", "permission_decision": ["decision": "reject", "source": "config", "reason_type": "classifier"]]]])
        let calls = chat.items.compactMap { if case .tool(let call) = $0.kind { return call } else { return nil } }
        XCTAssertEqual(calls.map(\.blockedByAutoMode), [false, true])
        XCTAssertEqual(calls.last?.result, "Blocked: force push")
    }

    func testKeepPlanningDeniesWithFeedback() {
        var chat = ChatTranscript()
        chat.apply(["type": "control_request", "request_id": "r4", "request": [
            "subtype": "can_use_tool", "tool_name": "ExitPlanMode", "input": ["plan": "x"]]])
        let out = chat.decidePlan(itemID: chat.items[0].id, decision: .keepPlanning, feedback: "cover signing")
        XCTAssertEqual(out.first?["response"]?["response"]?["behavior"]?.string, "deny")
        XCTAssertTrue(out.first?["response"]?["response"]?["message"]?.string?.contains("cover signing") == true)
    }

    func testCancelRequestClosesCard() {
        var chat = ChatTranscript()
        chat.apply(["type": "control_request", "request_id": "r5", "request": [
            "subtype": "can_use_tool", "tool_name": "Write", "input": ["file_path": "/a"]]])
        chat.apply(["type": "control_cancel_request", "request_id": "r5"])
        guard case .permission(let p) = chat.items[0].kind else { return XCTFail() }
        XCTAssertEqual(p.decision, .cancelled)
        XCTAssertEqual(chat.state, .working)
    }

    /// Like clauth's runtime folder: `runtime/projects` links to `real/projects`, where the memory folder is.
    private func linkedMemoryFolder() throws -> (base: URL, folder: String) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("viber-memory-\(UUID().uuidString)")
        try fm.createDirectory(at: base.appendingPathComponent("real/projects/-repo/memory"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("runtime"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: base.appendingPathComponent("runtime/projects"),
                                  withDestinationURL: base.appendingPathComponent("real/projects"))
        return (base, base.path + "/runtime/projects/-repo/memory/")
    }

    func testMemoryWritesAreAllowedWithoutACard() throws {
        let (base, folder) = try linkedMemoryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        var chat = ChatTranscript()
        chat.apply(["type": "system", "subtype": "init", "session_id": "s", "memory_paths": ["auto": .string(folder)]])
        XCTAssertEqual(chat.memoryFolder, folder)
        let out = chat.apply(["type": "control_request", "request_id": "r1", "request": [
            "subtype": "can_use_tool", "tool_name": "Write", "input": ["file_path": .string(folder + "notes.md"), "content": "x"],
            "tool_use_id": "t1"]])
        XCTAssertEqual(out.first?["response"]?["request_id"]?.string, "r1")
        XCTAssertEqual(out.first?["response"]?["response"]?["behavior"]?.string, "allow")
        XCTAssertEqual(out.first?["response"]?["response"]?["toolUseID"]?.string, "t1")
        XCTAssertTrue(chat.items.isEmpty)

        let other = chat.apply(["type": "control_request", "request_id": "r2", "request": [
            "subtype": "can_use_tool", "tool_name": "Edit", "input": ["file_path": .string(base.path + "/real/projects/-other/memory/x.md")]]])
        XCTAssertTrue(other.isEmpty)
        XCTAssertEqual(chat.state, .permission)
    }

    func testOnlyMarkdownThatStaysInTheMemoryFolderIsAllowed() throws {
        let (base, folder) = try linkedMemoryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real/projects/-repo/memory")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("outside"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: real.appendingPathComponent("away"), withDestinationURL: base.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(at: real.appendingPathComponent("link.md"),
                                                   withDestinationURL: base.appendingPathComponent("outside/x.md"))
        func allows(_ tool: String, _ path: String) -> Bool {
            MemoryWrite.allows(toolName: tool, input: ["file_path": .string(path)], folder: folder)
        }
        XCTAssertTrue(allows("Edit", folder + "MEMORY.md"))
        XCTAssertTrue(allows("Write", folder + "logs/2026-10-24.md"), "a new subfolder of the memory folder")
        XCTAssertFalse(allows("Bash", folder + "MEMORY.md"))
        XCTAssertFalse(allows("Write", folder + "notes.txt"))
        XCTAssertFalse(allows("Write", folder + ".hidden.md"))
        XCTAssertFalse(allows("Write", folder + "../escape.md"))
        XCTAssertFalse(allows("Write", folder + "away/x.md"), "a folder that links out")
        XCTAssertFalse(allows("Edit", folder + "link.md"), "a file that links out")
        XCTAssertFalse(allows("Write", base.path + "/runtime/projects/-repo/memory-two/x.md"))
    }

    func testUnsupportedControlRequestGetsAnError() {
        var chat = ChatTranscript()
        let out = chat.apply(["type": "control_request", "request_id": "h1", "request": ["subtype": "hook_callback"]])
        XCTAssertEqual(out.first?["response"]?["subtype"]?.string, "error")
    }

    func testCacheEstimateFromUsage() {
        var chat = ChatTranscript()
        let t0 = Date(timeIntervalSince1970: 1000)
        chat.apply(assistant("m1", [["type": "text", "text": "hi"]], usage: [
            "input_tokens": 4, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 50,
            "cache_creation": ["ephemeral_1h_input_tokens": 50, "ephemeral_5m_input_tokens": 0]]), now: t0)
        XCTAssertEqual(chat.cache?.ttl, 3600)
        XCTAssertEqual(chat.lastUsage?.contextTokens, 154)
        // A second block of the same message must not restart the clock.
        chat.apply(assistant("m1", [["type": "text", "text": "more"]], usage: ["cache_read_input_tokens": 100]), now: t0.addingTimeInterval(30))
        XCTAssertEqual(chat.cache?.observedAt, t0)
        // A later read-only message carries the TTL over.
        chat.apply(assistant("m2", [["type": "text", "text": "x"]], usage: ["cache_read_input_tokens": 200]), now: t0.addingTimeInterval(60))
        XCTAssertEqual(chat.cache?.ttl, 3600)
        XCTAssertEqual(chat.cache?.observedAt, t0.addingTimeInterval(60))
    }

    func testStreamingTextIsReplacedByFinalText() {
        var chat = ChatTranscript()
        chat.apply(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Hel"]]])
        chat.apply(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "lo"]]])
        XCTAssertEqual(chat.streamingText, "Hello")
        chat.apply(assistant("m1", [["type": "text", "text": "Hello"]]))
        XCTAssertEqual(chat.streamingText, "")
        XCTAssertEqual(chat.items.count, 1)
    }

    func testHistoryShowsUserTextAndSlashCommands() {
        var chat = ChatTranscript()
        let rows = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-10-23T08:00:00Z","message":{"role":"user","content":"Fix the login"}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-23T08:00:05Z","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Done."}]}}"#,
            #"{"type":"user","uuid":"u2","timestamp":"2026-10-23T08:01:00Z","message":{"role":"user","content":"<command-name>/cleanup</command-name>\n<command-args></command-args>"}}"#,
            #"{"type":"user","uuid":"u3","isMeta":true,"timestamp":"2026-10-23T08:01:00Z","message":{"role":"user","content":"skill body"}}"#,
            #"{"type":"user","uuid":"u1","timestamp":"2026-10-23T08:00:00Z","message":{"role":"user","content":"Fix the login"}}"#
        ]
        chat.loadHistory(Data(rows.joined(separator: "\n").utf8))
        let kinds = chat.items.map(\.kind)
        XCTAssertEqual(kinds, [.user("Fix the login"), .assistant("Done."), .user("/cleanup")])
        XCTAssertEqual(chat.state, .idle)
    }

    private func reply(to request: JSON, _ response: JSON = .null, error: String? = nil) -> JSON {
        let id = request["request_id"]!
        if let error { return ["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": .string(error)]] }
        return ["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response]]
    }

    func testInitializeAsksForMcpStatus() {
        var chat = ChatTranscript()
        let out = chat.apply(reply(to: chat.request("initialize"), ["commands": [], "output_style": "default",
                                                                     "available_output_styles": ["default", "Concise"]]))
        XCTAssertEqual(out.first?["request"]?["subtype"]?.string, "mcp_status")
        XCTAssertEqual(chat.controls.outputStyles, ["default", "Concise"])
        XCTAssertTrue(chat.controls.busy.contains("mcp"))
    }

    func testMcpStatusFillsServers() {
        var chat = ChatTranscript()
        // Trimmed from a real `mcp_status` reply (claude 2.1.309).
        chat.apply(reply(to: chat.refresh(.mcp)[0], ["mcpServers": [
            ["name": "plugin:posthog:posthog", "status": "needs-auth", "config": ["type": "http", "url": "https://mcp.posthog.com/mcp"],
             "transport": "http", "scope": "dynamic", "source": "plugin"],
            ["name": "claude.ai Notion", "status": "connected", "serverInfo": ["name": "Notion MCP", "version": "1.2.0"],
             "config": ["type": "claudeai-proxy"], "transport": "claudeai-proxy", "scope": "claudeai", "source": "claudeai",
             "tools": [["name": "notion-search"], ["name": "notion-fetch"]]],
            ["name": "local", "status": "failed", "error": "spawn ENOENT", "transport": "stdio"]
        ]]))
        let servers = try! XCTUnwrap(chat.controls.mcp)
        XCTAssertEqual(servers.map(\.status), [.needsAuth, .connected, .failed])
        XCTAssertEqual(servers[1].tools, ["notion-search", "notion-fetch"])
        XCTAssertEqual(servers[1].version, "1.2.0")
        XCTAssertTrue(servers[0].canSignOut)
        XCTAssertFalse(servers[1].canSignOut)
        XCTAssertEqual(servers[2].error, "spawn ENOENT")
        XCTAssertEqual(chat.controls.mcpSummary?.connected, 1)
        XCTAssertEqual(chat.controls.mcpSummary?.attention, true)
        XCTAssertFalse(chat.controls.busy.contains("mcp"))
    }

    func testInitMessageUpdatesServerStatusKeepingTools() {
        var chat = ChatTranscript()
        chat.apply(reply(to: chat.refresh(.mcp)[0], ["mcpServers": [["name": "a", "status": "pending", "tools": [["name": "t"]]]]]))
        chat.apply(["type": "system", "subtype": "init", "mcp_servers": [["name": "a", "status": "connected"], ["name": "b", "status": "failed"]]])
        XCTAssertEqual(chat.controls.mcp?.map(\.name), ["a", "b"])
        XCTAssertEqual(chat.controls.mcp?.first?.status, .connected)
        XCTAssertEqual(chat.controls.mcp?.first?.tools, ["t"])
    }

    func testToggleClearsBusyAndRereadsStatus() {
        var chat = ChatTranscript()
        let toggle = chat.mcpToggle("a", enabled: false)
        XCTAssertEqual(toggle["request"]?["enabled"]?.bool, false)
        XCTAssertTrue(chat.controls.busy.contains("mcp:a"))
        let out = chat.apply(reply(to: toggle))
        XCTAssertFalse(chat.controls.busy.contains("mcp:a"))
        XCTAssertEqual(out.first?["request"]?["subtype"]?.string, "mcp_status")
    }

    func testSignInOpensThePageAndRemembersTheServer() {
        var chat = ChatTranscript()
        let now = Date(timeIntervalSince1970: 50)
        chat.apply(reply(to: chat.mcpAuthenticate("claude.ai Gmail"),
                         ["authUrl": "https://claude.ai/settings/connectors", "requiresUserAction": true, "callbackExpected": false]), now: now)
        XCTAssertEqual(chat.controls.authURL?.host, "claude.ai")
        XCTAssertEqual(chat.controls.signingIn["claude.ai Gmail"], now)
        XCTAssertEqual(chat.controls.takeReturnReconnects(), ["claude.ai Gmail"])
        XCTAssertTrue(chat.controls.reconnectOnReturn.isEmpty)
    }

    func testSignInThatNeverConnectsIsMarkedUntilTheServerConnects() {
        var chat = ChatTranscript()
        let start = Date(timeIntervalSince1970: 50)
        chat.apply(reply(to: chat.mcpAuthenticate("atlassian"),
                         ["authUrl": "https://auth.atlassian.com/authorize", "requiresUserAction": true, "callbackExpected": true]), now: start)
        chat.controls.expireSignIns(now: start.addingTimeInterval(119))
        XCTAssertNotNil(chat.controls.signingIn["atlassian"])
        XCTAssertTrue(chat.controls.signInsUnfinished.isEmpty)

        chat.controls.expireSignIns(now: start.addingTimeInterval(120))
        XCTAssertTrue(chat.controls.signingIn.isEmpty)
        XCTAssertEqual(chat.controls.signInsUnfinished, ["atlassian"])

        // Signing in again starts over; the server connecting ends it.
        _ = chat.mcpAuthenticate("atlassian")
        XCTAssertTrue(chat.controls.signInsUnfinished.isEmpty)
        chat.controls.signInsUnfinished = ["atlassian"]
        chat.apply(reply(to: chat.refresh(.mcp)[0], ["mcpServers": [["name": "atlassian", "status": "connected"]]]))
        XCTAssertTrue(chat.controls.signInsUnfinished.isEmpty)
        chat.controls.signInsUnfinished = ["atlassian"]
        chat.apply(["type": "system", "subtype": "init", "mcp_servers": [["name": "atlassian", "status": "connected"]]])
        XCTAssertTrue(chat.controls.signInsUnfinished.isEmpty)
    }

    func testOAuthSignInsLastOneSessionUnderClauth() {
        let own = McpServer(name: "atlassian", status: .needsAuth, transport: "http")
        let connector = McpServer(name: "claude.ai Atlassian MCP", status: .needsAuth, transport: "claudeai-proxy")
        XCTAssertTrue(own.signInLastsOneSession(underClauth: true))
        XCTAssertFalse(own.signInLastsOneSession(underClauth: false))
        XCTAssertFalse(connector.signInLastsOneSession(underClauth: true))
    }

    func testSettingsErrorsStayOutOfTheChat() {
        var chat = ChatTranscript()
        chat.apply(reply(to: chat.mcpReconnect("a"), error: "Server not found: a"))
        XCTAssertEqual(chat.controls.errors["mcp:a"], "Server not found: a")
        XCTAssertTrue(chat.items.isEmpty)
        // Other requests still report in the chat.
        chat.apply(reply(to: chat.setModel("nope"), error: "bad model"))
        XCTAssertEqual(chat.items.last?.kind, .notice("set_model failed: bad model", isError: true))
    }

    func testCommandsChangedRefreshesTheMenu() {
        var chat = ChatTranscript()
        chat.apply(["type": "system", "subtype": "commands_changed", "commands": [["name": "posthog:llma-cc-setup", "description": "Set up"]]])
        XCTAssertEqual(chat.commands.map(\.name), ["posthog:llma-cc-setup"])
    }

    func testContextRulesHooksAndSettingsReplies() {
        var chat = ChatTranscript()
        let context = chat.refresh(.context)
        chat.apply(reply(to: context[0], ["categories": [
            ["name": "System prompt", "tokens": 2509, "kind": "used"], ["name": "Free space", "tokens": 952349, "kind": "free"]],
            "totalTokens": 14651, "maxTokens": 1000000, "model": "claude-opus-5-5", "isAutoCompactEnabled": true]))
        chat.apply(reply(to: context[1], ["text": "Total cost: $0.0000"]))
        XCTAssertEqual(chat.controls.context?.categories.map(\.name), ["System prompt", "Free space"])
        XCTAssertEqual(chat.controls.context?.fraction ?? 0, 0.014651, accuracy: 0.000001)
        XCTAssertEqual(chat.controls.costText, "Total cost: $0.0000")

        chat.apply(reply(to: chat.refresh(.permissions)[0], ["state": [
            "rules": [["behavior": "allow", "source": "userSettings", "rule": "Bash(npx ng build:*)"],
                      ["behavior": "allow", "source": "flagSettings", "rule": "Bash(echo viber:*)"],
                      ["behavior": "deny", "source": "policySettings", "rule": "WebFetch"]],
            "workspaceDirectories": [["path": "/tmp/x", "source": "session"]]]]))
        XCTAssertEqual(chat.controls.rules?.map(\.scope), [.user, .session, nil])
        XCTAssertEqual(chat.controls.rules?.last?.sourceLabel, "Managed policy")
        XCTAssertEqual(chat.controls.directories, ["/tmp/x"])

        chat.apply(reply(to: chat.refresh(.hooks)[0], ["hooks": [
            ["event": "PreToolUse", "matcher": "__exec$", "source": "pluginHook", "pluginName": "posthog@posthog", "displayText": "gate.sh", "timeout": 5],
            ["event": "Stop", "matcher": "", "source": "userSettings", "sourceLabel": "User settings (~/.claude/settings.json)", "displayText": "keep-awake.sh stop"]]]))
        XCTAssertEqual(chat.controls.hooks?.map(\.source), ["Plugin posthog@posthog", "User settings (~/.claude/settings.json)"])

        chat.apply(reply(to: chat.refresh(.model)[0], ["applied": ["model": "claude-opus-5-5", "effort": "xhigh"], "effective": ["outputStyle": "Concise"]]))
        XCTAssertEqual(chat.controls.appliedModel, "claude-opus-5-5")
        XCTAssertEqual(chat.controls.effort, "xhigh")
        XCTAssertEqual(chat.controls.outputStyle, "Concise")
    }

    func testSessionRulesGoToTheFlagLayerAndRefreshTheList() {
        var chat = ChatTranscript()
        let apply = chat.setSessionPermissions(rules: [RuleEdit(behavior: "allow", rule: "Bash(echo:*)")], directories: ["/work/shared"])
        XCTAssertEqual(apply["request"]?["settings"]?["permissions"]?["allow"], ["Bash(echo:*)"])
        XCTAssertEqual(apply["request"]?["settings"]?["permissions"]?["deny"], [], "every list is sent so removals clear")
        XCTAssertEqual(apply["request"]?["settings"]?["permissions"]?["additionalDirectories"], ["/work/shared"], "folders ride along so neither drops the other")
        XCTAssertEqual(chat.setSessionPermissions(rules: [])["request"]?["settings"]?["permissions"]?["additionalDirectories"], [])
        let out = chat.apply(reply(to: apply))
        XCTAssertEqual(out.first?["request"]?["subtype"]?.string, "list_permission_rules")
    }

    func testFailedResultShowsNotice() {
        var chat = ChatTranscript()
        _ = chat.userMessage("hi")
        chat.apply(["type": "result", "subtype": "success", "is_error": true, "result": "Failed to authenticate"])
        XCTAssertEqual(chat.state, .failed)
        XCTAssertEqual(chat.items.last?.kind, .notice("Failed to authenticate", isError: true))
    }

    func testThinkingBlocksBecomeFoldedRows() {
        var chat = ChatTranscript()
        _ = chat.userMessage("solve it")
        chat.apply(["type": "stream_event", "event": ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]]])
        XCTAssertTrue(chat.isThinking)
        chat.apply(["type": "stream_event", "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "Hmm"]]])
        XCTAssertTrue(chat.isThinking)
        chat.apply(assistant("m1", [["type": "thinking", "thinking": "  The fundamental solution is (8,3).  ", "signature": "x"]]))
        XCTAssertFalse(chat.isThinking)
        chat.apply(["type": "stream_event", "event": ["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]]])
        XCTAssertFalse(chat.isThinking)
        chat.apply(assistant("m1", [["type": "text", "text": "(8,3) and (127,48)"]]))
        XCTAssertEqual(chat.items.dropFirst().map(\.kind), [.thinking("The fundamental solution is (8,3)."), .assistant("(8,3) and (127,48)")])
        XCTAssertEqual(chat.assistantText(after: chat.items[0].id), "(8,3) and (127,48)", "thinking stays out of // replies")
    }

    func testEmptyAndRedactedThinkingAreSkipped() {
        var chat = ChatTranscript()
        chat.apply(assistant("m1", [["type": "thinking", "thinking": "", "signature": "x"], ["type": "redacted_thinking", "data": "abc"],
                                    ["type": "text", "text": "hi"]]))
        XCTAssertEqual(chat.items.map(\.kind), [.assistant("hi")])
    }

    func testThinkingDisplayIsRequestedAtLaunch() {
        let args = LaunchSpec(profile: nil, cwd: "/tmp").claudeArguments
        XCTAssertEqual(args.split(separator: "--thinking-display").last?.first, "summarized", "without it print mode sends empty thinking")
    }
}
