import Foundation

/// What a Viber session is doing, as far as you are concerned.
public enum PaneState: String, Codable, Sendable {
    case idle, starting, working, permission, input, plan, finished, failed, exited

    public var needsYou: Bool { [.permission, .input, .plan].contains(self) }
    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .working: return "Working"
        case .permission: return "Needs permission"
        case .input: return "Has a question"
        case .plan: return "Plan to review"
        case .finished: return "Done"
        case .failed: return "Failed"
        case .exited: return "Stopped"
        }
    }
}

public struct ToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    public var input: JSON
    public var result: String?
    public var isError = false
    public var done = false
    /// Auto mode's classifier refused the call; `result` holds what Claude was told.
    public var blockedByAutoMode = false
    /// What a running subagent is doing, from `task_progress`.
    public var progress: String?
    /// For Agent calls: the subagent's run.
    public var agent: AgentRun?

    public init(id: String, name: String, input: JSON, result: String? = nil, isError: Bool = false, done: Bool = false) {
        self.id = id; self.name = name; self.input = input; self.result = result; self.isError = isError; self.done = done
    }
}

public enum PromptDecision: Equatable, Sendable {
    case allowed, alwaysAllowed, denied, answered, declined, keepPlanning, cancelled
    /// A plan approved, continuing in this mode.
    case approved(PermissionMode)
}

public struct PermissionPrompt: Equatable, Sendable {
    public var requestID: String
    public var toolName: String
    public var input: JSON
    public var toolUseID: String?
    public var description: String?
    public var suggestions: [JSON]
    public var decision: PromptDecision?
    /// Who asks when it is a subagent, like "the Explore agent", and what that agent was sent to do.
    public var agent: String?
    public var agentTask: String?
}

public struct Question: Equatable, Sendable {
    public var question: String
    public var header: String
    public var options: [(label: String, description: String)]
    public var multiSelect: Bool

    public static func == (a: Question, b: Question) -> Bool {
        a.question == b.question && a.header == b.header && a.multiSelect == b.multiSelect
            && a.options.map(\.label) == b.options.map(\.label) && a.options.map(\.description) == b.options.map(\.description)
    }
}

public struct QuestionPrompt: Equatable, Sendable {
    public var requestID: String?
    public var input: JSON
    public var questions: [Question]
    public var answers: [String: String]?
    public var decision: PromptDecision?
}

public struct PlanPrompt: Equatable, Sendable {
    public var requestID: String?
    public var input: JSON
    public var plan: String
    public var decision: PromptDecision?
}

public struct ChatItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case user(String)
        /// Images sent with the next user message, by label.
        case attachments([String])
        case assistant(String)
        /// Claude's (summarized) thinking before it answered.
        case thinking(String)
        case tool(ToolCall)
        case permission(PermissionPrompt)
        case question(QuestionPrompt)
        case plan(PlanPrompt)
        /// An MCP server asking for input: a form, or a page to open.
        case elicitation(ElicitationPrompt)
        case notice(String, isError: Bool)
        /// A `//` message another session sent here.
        case received(from: String, text: String)
        /// The answer to a `//` message this session sent, posted back automatically.
        case reply(from: String, text: String)
        /// A `//` message this session sent elsewhere; `queued` until the target's turn ends.
        case sent(to: String, text: String, queued: Bool)
    }
    public let id: String
    public var kind: Kind
}

public struct SlashCommand: Equatable, Sendable {
    public var name: String
    public var description: String
    public var argumentHint: String
    public init(name: String, description: String, argumentHint: String = "") {
        self.name = name; self.description = description; self.argumentHint = argumentHint
    }
}

public struct ModelOption: Equatable, Sendable {
    public var value: String
    public var displayName: String
    public init(value: String, displayName: String) { self.value = value; self.displayName = displayName }
}

public struct TurnUsage: Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheCreation = 0
    public var contextTokens: Int { input + cacheRead + cacheCreation }
}

/// One entry of Claude's checklist: from `TodoWrite`, or the task list tools (`TaskCreate`/`TaskUpdate`).
public struct TodoItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var content: String
    /// Present-tense label shown while the item is in progress ("Running tests").
    public var activeForm: String?
    /// pending, in_progress or completed.
    public var status: String

    public init(id: String, content: String, activeForm: String? = nil, status: String = "pending") {
        self.id = id; self.content = content; self.activeForm = activeForm; self.status = status
    }

    public var isDone: Bool { status == "completed" }
    public var isActive: Bool { status == "in_progress" }
}

/// What rewinding files to before a message would change (`rewind_files` with `dry_run`).
public struct RewindPreview: Equatable, Sendable {
    public var itemID: String
    public var canRewind: Bool
    public var error: String?
    public var files: [String]
    public var insertions: Int
    public var deletions: Int
}

/// Folds the CLI's stream-json output (and transcript rows when restoring history) into a chat.
/// The protocol is the one the Agent SDK speaks; unknown messages are ignored.
public struct ChatTranscript {
    public private(set) var items: [ChatItem] = []
    public var state: PaneState = .idle
    public var sessionID: String?
    public var cwd: String?
    public var model: String?
    /// As reported by the CLI.
    public var permissionMode: String?
    public var streamingText = ""
    /// Claude is thinking right now (thinking deltas are streaming).
    public var isThinking = false
    public var cache: CacheEstimate?
    public var lastUsage: TurnUsage?
    public var costUSD: Double = 0
    public var lastTurnSeconds: Double?
    public var commands: [SlashCommand] = []
    public var models: [ModelOption] = []
    public var turnStartedByUser = true
    /// MCP servers, context, rules and the like, for the settings sheet.
    public var controls = SessionControls()
    /// When Claude last changed a file in this process's lifetime, so the preview can tell whether a hot update followed.
    public private(set) var lastFileEditAt: Date?
    /// A rewind waiting for the user to confirm it.
    public var rewindPreview: RewindPreview?
    /// Claude's checklist for the work at hand, as its todo or task list tools last left it.
    public private(set) var todos: [TodoItem] = []

    private struct PendingRequest {
        var subtype: String
        /// Set for settings-sheet requests: their busy flag and where their error shows.
        var key: String?
        var body: [String: JSON]
    }

    private var toolIndex: [String: Int] = [:]
    /// Subagents' tool calls, by ID, and the Agent call each ran under.
    private var stepParent: [String: String] = [:]
    /// A background task ended while Claude was idle, so the CLI is about to start a turn by itself.
    private var turnExpected = false
    private var pendingRequests: [String: PendingRequest] = [:]
    private var blockCounts: [String: Int] = [:]
    private var seenRows: Set<String> = []
    private var nextID = 0
    /// Messages sent but not yet echoed back with their ID: the chat item and the text that went out.
    private var awaitingEcho: [(itemID: String, text: String)] = []
    /// The CLI's ID for each user message item, which rewinding needs.
    private var userMessageIDs: [String: String] = [:]
    /// Rewind requests in flight, by request ID, and the item they rewind to.
    private var rewinds: [String: String] = [:]

    public init() {}

    public var pendingPromptCount: Int {
        items.reduce(0) { count, item in
            switch item.kind {
            case .permission(let p) where p.decision == nil: return count + 1
            case .question(let q) where q.decision == nil && q.requestID != nil: return count + 1
            case .plan(let p) where p.decision == nil && p.requestID != nil: return count + 1
            case .elicitation(let e) where e.decision == nil: return count + 1
            default: return count
            }
        }
    }

    // MARK: Outgoing

    /// A message typed by the user. Images go first, as the API recommends, then the text.
    public mutating func userMessage(_ text: String, images: [ImageAttachment] = []) -> JSON {
        if !images.isEmpty { append(.attachments(images.map(\.label))) }
        if !text.isEmpty || images.isEmpty { append(.user(text)) }
        awaitingEcho.append((items[items.count - 1].id, text))
        state = .working
        turnStartedByUser = true
        let content: JSON = images.isEmpty ? .string(text)
            : .array(images.map(\.block) + (text.isEmpty ? [] : [["type": "text", "text": .string(text)]]))
        return ["type": "user", "message": ["role": "user", "content": content]]
    }

    public mutating func request(_ subtype: String, _ extra: [String: JSON] = [:], key: String? = nil) -> JSON {
        nextID += 1
        let id = "viber-\(nextID)-\(subtype)"
        pendingRequests[id] = PendingRequest(subtype: subtype, key: key, body: extra)
        if let key { controls.busy.insert(key); controls.errors[key] = nil }
        var body = extra
        body["subtype"] = .string(subtype)
        return ["type": "control_request", "request_id": .string(id), "request": .object(body)]
    }

    public static func controlSuccess(_ requestID: String, _ response: JSON) -> JSON {
        ["type": "control_response", "response": ["subtype": "success", "request_id": .string(requestID), "response": response]]
    }

    public static func controlError(_ requestID: String, _ message: String) -> JSON {
        ["type": "control_response", "response": ["subtype": "error", "request_id": .string(requestID), "error": .string(message)]]
    }

    /// Answer a permission card. `always` applies the CLI's own suggested rules for the rest of the session.
    public mutating func decidePermission(itemID: String, allow: Bool, always: Bool = false, message: String? = nil) -> JSON? {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              case .permission(var prompt) = items[index].kind, prompt.decision == nil else { return nil }
        prompt.decision = allow ? (always ? .alwaysAllowed : .allowed) : .denied
        items[index].kind = .permission(prompt)
        resumeAfterPrompt()
        var response: [String: JSON]
        if allow {
            response = ["behavior": "allow", "updatedInput": prompt.input]
            if always, !prompt.suggestions.isEmpty { response["updatedPermissions"] = .array(prompt.suggestions) }
        } else {
            response = ["behavior": "deny", "message": .string(message ?? "The user denied this tool use.")]
        }
        if let toolUseID = prompt.toolUseID { response["toolUseID"] = .string(toolUseID) }
        return Self.controlSuccess(prompt.requestID, .object(response))
    }

    public mutating func answerQuestion(itemID: String, answers: [String: String]) -> JSON? {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              case .question(var prompt) = items[index].kind, prompt.decision == nil,
              let requestID = prompt.requestID else { return nil }
        prompt.decision = .answered
        prompt.answers = answers
        items[index].kind = .question(prompt)
        resumeAfterPrompt()
        let updated = prompt.input.setting("answers", .object(answers.mapValues { .string($0) }))
        return Self.controlSuccess(requestID, ["behavior": "allow", "updatedInput": updated])
    }

    /// Approve or reject a plan. Approval also returns the permission-mode change to send next.
    public mutating func decidePlan(itemID: String, decision: PromptDecision, feedback: String = "") -> [JSON] {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              case .plan(var prompt) = items[index].kind, prompt.decision == nil,
              let requestID = prompt.requestID else { return [] }
        prompt.decision = decision
        items[index].kind = .plan(prompt)
        resumeAfterPrompt()
        switch decision {
        case .approved(let mode):
            return [Self.controlSuccess(requestID, ["behavior": "allow", "updatedInput": prompt.input]), setPermissionMode(mode.rawValue)]
        default:
            let note = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = note.isEmpty ? "The user wants to keep planning. Ask what to change." : "The user wants to keep planning: \(note)"
            if !note.isEmpty { append(.user(note)) }
            return [Self.controlSuccess(requestID, ["behavior": "deny", "message": .string(message)])]
        }
    }

    /// Answer an MCP server's request: "accept" with the form's values (or consent to open the page), "decline" or "cancel".
    public mutating func answerElicitation(itemID: String, action: String, content: [String: JSON] = [:]) -> JSON? {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              case .elicitation(var prompt) = items[index].kind, prompt.decision == nil else { return nil }
        prompt.decision = action == "accept" ? .answered : action == "decline" ? .declined : .cancelled
        items[index].kind = .elicitation(prompt)
        resumeAfterPrompt()
        var response: [String: JSON] = ["action": .string(action)]
        if action == "accept", !prompt.isURL { response["content"] = .object(content) }
        return Self.controlSuccess(prompt.requestID, .object(response))
    }

    /// `permissionMode` changes once the CLI confirms; it refuses auto mode on some models.
    public mutating func setPermissionMode(_ mode: String) -> JSON {
        request("set_permission_mode", ["mode": .string(mode)])
    }

    public mutating func setModel(_ value: String?) -> JSON {
        model = value ?? model
        return request("set_model", value.map { ["model": .string($0)] } ?? [:])
    }

    // MARK: Settings sheet (the control requests behind terminal-only commands)

    /// What a tab needs to show itself.
    public mutating func refresh(_ tab: SettingsTab) -> [JSON] {
        switch tab {
        case .mcp: return [request("mcp_status", key: "mcp")]
        case .context: return [request("get_context_usage", ["detail": "full"], key: "context"), request("get_session_cost", key: "cost")]
        case .permissions: return [request("list_permission_rules", key: "permissions")]
        case .hooks: return [request("get_hooks_listing", key: "hooks")]
        // Tasks arrive as events; refreshing re-reads the output of running shells.
        case .tasks: return controls.runningTasks.filter(\.hasOutput).map { taskOutput($0.id) }
        case .model: return [request("get_settings", key: "settings")]
        }
    }

    /// Enabling or disabling is saved per project by the CLI, as `/mcp` does in the terminal.
    public mutating func mcpToggle(_ server: String, enabled: Bool) -> JSON {
        request("mcp_toggle", ["serverName": .string(server), "enabled": .bool(enabled)], key: "mcp:\(server)")
    }

    public mutating func mcpReconnect(_ server: String) -> JSON {
        request("mcp_reconnect", ["serverName": .string(server)], key: "mcp:\(server)")
    }

    /// Starts an OAuth sign-in; the reply carries the page to open. The CLI reconnects once it completes.
    public mutating func mcpAuthenticate(_ server: String) -> JSON {
        request("mcp_authenticate", ["serverName": .string(server)], key: "mcp:\(server)")
    }

    public mutating func mcpClearAuth(_ server: String) -> JSON {
        request("mcp_clear_auth", ["serverName": .string(server)], key: "mcp:\(server)")
    }

    /// Effort for this session only, through the CLI's session settings layer.
    public mutating func setEffort(_ level: String) -> JSON {
        controls.effort = level
        return request("apply_flag_settings", ["settings": ["effortLevel": .string(level)]], key: "effort")
    }

    /// Saved to the project's .claude/settings.local.json by the CLI itself, as `/output-style` does.
    public mutating func setOutputStyle(_ style: String) -> JSON {
        controls.outputStyle = style
        return request("update_settings", ["source": "localSettings", "settings": ["outputStyle": .string(style)]], key: "outputStyle")
    }

    /// Replaces this session's own permission rules and extra folders (the CLI's flag settings layer).
    /// Both go in one `permissions` object so neither update drops the other.
    public mutating func setSessionPermissions(rules: [RuleEdit], directories: [String] = []) -> JSON {
        let permissions = SettingsFile.permissionsJSON(rules).setting("additionalDirectories", .array(directories.map(JSON.string)))
        return request("apply_flag_settings", ["settings": ["permissions": permissions]], key: "sessionRules")
    }

    public mutating func note(_ text: String, isError: Bool = false) { append(.notice(text, isError: isError)) }

    // MARK: Tasks

    /// Stops a background shell or subagent. The CLI reports the end with `task_notification`.
    public mutating func stopTask(_ id: String) -> JSON {
        request("stop_task", ["task_id": .string(id)], key: "task:\(id)")
    }

    /// The last 8 KiB a shell task wrote.
    public mutating func taskOutput(_ id: String) -> JSON {
        request("get_task_output", ["task_id": .string(id)], key: "output:\(id)")
    }

    private mutating func applyTask(_ message: JSON) {
        let subtype = message["subtype"]?.string
        if subtype == "background_tasks_changed" {
            // The full set of live background tasks; ended ones get their own task_notification.
            for t in message["tasks"]?.array ?? [] {
                guard let id = t["task_id"]?.string else { continue }
                updateTask(id, type: t["task_type"]?.string, description: t["description"]?.string) { task in
                    task.backgrounded = true
                    if let v = t["subagent_type"]?.string { task.subagentType = v }
                }
            }
            return
        }
        guard let id = message["task_id"]?.string else { return }
        let task = updateTask(id, type: message["task_type"]?.string, description: message["description"]?.string) { task in
            if let v = message["tool_use_id"]?.string { task.toolUseID = v }
            if let v = message["subagent_type"]?.string { task.subagentType = v }
            if let v = message["is_backgrounded"]?.bool { task.backgrounded = v }
            if let v = message["summary"]?.string, !v.isEmpty { task.summary = v }
            if let v = message["last_tool_name"]?.string { task.lastTool = v }
            if let usage = message["usage"] { task.tokens = usage["total_tokens"]?.int; task.toolUses = usage["tool_uses"]?.int }
            switch subtype {
            case "task_updated":
                if let v = message["patch"]?["status"]?.string { task.status = v }
                if let v = message["patch"]?["is_backgrounded"]?.bool { task.backgrounded = v }
                if let v = message["patch"]?["description"]?.string { task.description = v }
            case "task_notification":
                task.status = message["status"]?.string ?? "completed"
            default: break
            }
        }
        // A foreground subagent shows what it is doing on its own tool row.
        if subtype == "task_progress", let toolUseID = task.toolUseID {
            updateTool(toolUseID) { $0.progress = [task.lastTool, task.summary].compactMap { $0 }.joined(separator: " · ") }
        }
        if subtype == "task_notification", [.idle, .finished, .failed].contains(state) { turnExpected = true }
        // An agent's card follows its run.
        guard task.type == "local_agent", let toolUseID = task.toolUseID else { return }
        updateTool(toolUseID) { call in
            guard var run = call.agent else { return }
            run.taskID = task.id
            run.type = task.subagentType ?? run.type
            run.background = run.background || task.backgrounded
            if let usage = message["usage"] {
                run.tokens = usage["total_tokens"]?.int ?? run.tokens
                run.toolUses = usage["tool_uses"]?.int ?? run.toolUses
                run.durationMs = usage["duration_ms"]?.int ?? run.durationMs
            }
            switch subtype {
            case "task_updated":
                if let status = message["patch"]?["status"]?.string { run.status = status }
            case "task_notification":
                run.finish(status: task.status, summary: message["summary"]?.string)
                call.done = !run.isRunning
            default: break
            }
            call.agent = run
        }
    }

    /// Changes a tool call wherever it sits: in the chat, or among a subagent's steps.
    @discardableResult
    private mutating func updateTool(_ id: String, _ change: (inout ToolCall) -> Void) -> Bool {
        if let index = toolIndex[id] {
            guard case .tool(var call) = items[index].kind else { return false }
            change(&call)
            items[index].kind = .tool(call)
            return true
        }
        guard let parent = stepParent[id] else { return false }
        var found = false
        updateTool(parent) { agent in
            guard let step = agent.agent?.steps.firstIndex(where: { $0.id == "tool:\(id)" }),
                  case .tool(var call)? = agent.agent?.steps[step].kind else { return }
            change(&call)
            agent.agent?.steps[step].kind = .tool(call)
            found = true
        }
        return found
    }

    /// A tool call wherever it sits.
    public func findTool(_ id: String) -> ToolCall? {
        if let index = toolIndex[id] {
            if case .tool(let call) = items[index].kind { return call }
            return nil
        }
        guard let parent = stepParent[id], let step = findTool(parent)?.agent?.steps.first(where: { $0.id == "tool:\(id)" }),
              case .tool(let call) = step.kind else { return nil }
        return call
    }

    /// Nothing runs on once the process is gone or history ends. An agent still running then gets `unfinished` as its status.
    static func settle(_ call: inout ToolCall, unfinished: String) {
        call.done = true
        guard var run = call.agent else { return }
        if run.isRunning { run.status = unfinished }
        for index in run.steps.indices {
            if case .tool(var step) = run.steps[index].kind {
                settle(&step, unfinished: unfinished)
                run.steps[index].kind = .tool(step)
            }
        }
        call.agent = run
    }

    /// A background task's end as a transcript records it: an agent's card gets its status and report.
    private mutating func applyNotification(_ note: TaskNotification) {
        guard let id = note.toolUseID else { return }
        updateTool(id) { call in
            guard var run = call.agent else { return }
            run.taskID = note.taskID
            run.finish(note)
            call.agent = run
            call.done = !run.isRunning
        }
    }

    @discardableResult
    private mutating func updateTask(_ id: String, type: String?, description: String?, _ change: (inout SessionTask) -> Void) -> SessionTask {
        var tasks = controls.tasks
        let index = tasks.firstIndex { $0.id == id } ?? {
            tasks.append(SessionTask(id: id, type: type ?? "task", description: description ?? ""))
            return tasks.count - 1
        }()
        if let type { tasks[index].type = type }
        if let description, !description.isEmpty { tasks[index].description = description }
        change(&tasks[index])
        let task = tasks[index]
        // Keep every running task and the last 20 that ended.
        let ended = tasks.filter { !$0.isRunning }
        if ended.count > 20 {
            let drop = Set(ended.prefix(ended.count - 20).map(\.id))
            tasks.removeAll { drop.contains($0.id) }
        }
        controls.tasks = tasks
        return task
    }

    // MARK: Rewind

    /// Whether files can be rewound to before this item: the CLI has told us the message's ID.
    public func canRewind(itemID: String) -> Bool { userMessageIDs[itemID] != nil }

    /// Restores files to how they were before a message. A dry run fills `rewindPreview` for confirmation.
    public mutating func rewind(itemID: String, dryRun: Bool) -> JSON? {
        guard let id = userMessageIDs[itemID] else { return nil }
        if !dryRun { rewindPreview = nil }
        let message = request("rewind_files", ["user_message_id": .string(id), "dry_run": .bool(dryRun)])
        if let requestID = message["request_id"]?.string { rewinds[requestID] = itemID }
        return message
    }

    /// Delivers a `//` message from another session as a user turn, keeping who sent it.
    public mutating func receiveRelay(from source: String, text: String) -> JSON {
        append(.received(from: source, text: text))
        state = .working
        turnStartedByUser = true
        let wire = Relay.envelope(from: source, text: text)
        awaitingEcho.append((items[items.count - 1].id, wire))
        return ["type": "user", "message": ["role": "user", "content": .string(wire)]]
    }

    /// Posts the answer to an earlier `//` message back into the sender's conversation.
    public mutating func receiveReply(from source: String, text: String) -> JSON {
        append(.reply(from: source, text: text))
        state = .working
        turnStartedByUser = true
        let wire = Relay.replyEnvelope(from: source, text: text)
        awaitingEcho.append((items[items.count - 1].id, wire))
        return ["type": "user", "message": ["role": "user", "content": .string(wire)]]
    }

    public var lastItemID: String? { items.last?.id }

    /// Everything Claude said after an item, used as the reply to a `//` message.
    public func assistantText(after itemID: String) -> String {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return "" }
        return items[(index + 1)...].compactMap { item -> String? in
            if case .assistant(let text) = item.kind { return text }
            return nil
        }.joined(separator: "\n\n")
    }

    /// Records a `//` message sent from here. Returns the item id so delivery can be marked later.
    @discardableResult
    public mutating func recordSent(to target: String, text: String, queued: Bool) -> String {
        append(.sent(to: target, text: text, queued: queued))
        return items[items.count - 1].id
    }

    public mutating func markDelivered(itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              case .sent(let to, let text, true) = items[index].kind else { return }
        items[index].kind = .sent(to: to, text: text, queued: false)
    }

    public mutating func clear() {
        items.removeAll(); toolIndex.removeAll(); stepParent.removeAll(); streamingText = ""
    }

    public mutating func processExited(status: Int32) {
        streamingText = ""
        isThinking = false
        for index in items.indices {
            switch items[index].kind {
            case .permission(var p) where p.decision == nil: p.decision = .cancelled; items[index].kind = .permission(p)
            case .question(var q) where q.decision == nil && q.requestID != nil: q.decision = .cancelled; items[index].kind = .question(q)
            case .plan(var p) where p.decision == nil && p.requestID != nil: p.decision = .cancelled; items[index].kind = .plan(p)
            case .elicitation(var e) where e.decision == nil: e.decision = .cancelled; items[index].kind = .elicitation(e)
            // Subagents run inside the CLI's process and end with it.
            case .tool(var call) where call.agent?.isRunning == true: Self.settle(&call, unfinished: "stopped"); items[index].kind = .tool(call)
            default: break
            }
        }
        turnExpected = false
        if state != .failed { state = .exited }
        if status != 0 { append(.notice("Claude exited with status \(status).", isError: true)) }
    }

    // MARK: Incoming

    /// Apply one NDJSON message. Returns messages that must be written back to the CLI.
    @discardableResult
    public mutating func apply(_ message: JSON, now: Date = Date(), history: Bool = false) -> [JSON] {
        if let uuid = message["uuid"]?.string {
            guard seenRows.insert(uuid).inserted else { return [] }
        }
        switch message["type"]?.string {
        case "system": applySystem(message)
        case "assistant": applyAssistant(message, now: history ? (Dates.parse(message["timestamp"]?.any) ?? now) : now)
        case "user": applyUser(message, history: history, now: now)
        case "stream_event": applyStreamEvent(message)
        case "result": applyResult(message)
        case "control_request": return applyControlRequest(message)
        case "control_cancel_request": cancelPrompt(requestID: message["request_id"]?.string ?? "")
        case "control_response": return applyControlResponse(message, now: now)
        case "attachment":
            // In transcripts, a task notification that came in mid-turn is stored as a queued command.
            if let prompt = message["attachment"]?["prompt"]?.string, let note = TaskNotification.parse(prompt) { applyNotification(note) }
        default: break
        }
        return []
    }

    /// Rebuild the chat from a transcript file so resumed sessions show their history.
    /// `transcript` is the file the data came from: subagents' own transcripts sit beside it.
    public mutating func loadHistory(_ data: Data, transcript: URL? = nil) {
        for line in data.split(separator: 10) {
            guard let row = JSON(data: Data(line)) else { continue }
            if row["isSidechain"]?.bool == true || row["isMeta"]?.bool == true { continue }
            apply(row, history: true)
        }
        if let transcript { loadSubagents(transcript.deletingPathExtension().appendingPathComponent("subagents")) }
        for index in items.indices {
            if case .tool(var call) = items[index].kind { Self.settle(&call, unfinished: "unknown"); items[index].kind = .tool(call) }
        }
        streamingText = ""
        state = .idle
    }

    /// Each `agent-<id>.jsonl` holds what one subagent did; its `.meta.json` names the Agent call.
    /// Outer agents go first, so agents they started find their call.
    private mutating func loadSubagents(_ dir: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let runs = files.filter { $0.lastPathComponent.hasSuffix(".meta.json") }
            .compactMap { url -> (url: URL, meta: JSON)? in
                guard let data = try? Data(contentsOf: url), let meta = JSON(data: data) else { return nil }
                return (url, meta)
            }
            .sorted { ($0.meta["spawnDepth"]?.int ?? 1) < ($1.meta["spawnDepth"]?.int ?? 1) }
        for run in runs {
            let name = run.url.lastPathComponent.replacingOccurrences(of: ".meta.json", with: ".jsonl")
            guard let toolUseID = run.meta["toolUseId"]?.string, findTool(toolUseID)?.agent != nil,
                  let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { continue }
            for line in data.split(separator: 10) {
                guard let row = JSON(data: Data(line)), row["isMeta"]?.bool != true else { continue }
                apply(row.setting("parent_tool_use_id", .string(toolUseID)), history: true)
            }
        }
    }

    private mutating func applySystem(_ message: JSON) {
        switch message["subtype"]?.string {
        case "init":
            sessionID = message["session_id"]?.string ?? sessionID
            cwd = message["cwd"]?.string ?? cwd
            model = message["model"]?.string ?? model
            applyMode(message["permissionMode"]?.string)
            if let servers = message["mcp_servers"] { mergeServerStatus(McpServer.parse(servers)) }
            if state == .starting { state = .idle }
        case "status":
            // The CLI announces every mode change here, including ones it makes itself,
            // like leaving auto mode when the model switches to one without it.
            applyMode(message["permissionMode"]?.string)
            // The turn the CLI starts by itself to hand Claude a background task's result shows as working too.
            if message["status"]?.string == "requesting" {
                if turnExpected, [.idle, .finished, .failed].contains(state) {
                    state = .working
                    turnStartedByUser = false
                }
                turnExpected = false
            }
        case "commands_changed":
            // Plugin and MCP commands that finished loading after initialize.
            if let list = message["commands"] { commands = Self.commands(list) }
        case "compact_boundary":
            append(.notice("Conversation compacted", isError: false))
        case "task_started", "task_progress", "task_updated", "task_notification", "background_tasks_changed":
            applyTask(message)
        case "elicitation_complete":
            // A URL-mode elicitation the user accepted: the server says the page flow finished.
            guard let id = message["elicitation_id"]?.string else { break }
            for index in items.indices {
                if case .elicitation(var e) = items[index].kind, e.elicitationID == id {
                    e.completed = true
                    items[index].kind = .elicitation(e)
                }
            }
        default: break
        }
    }

    private mutating func applyAssistant(_ message: JSON, now: Date) {
        guard let body = message["message"] else { return }
        let messageID = body["id"]?.string ?? UUID().uuidString
        if let parent = message["parent_tool_use_id"]?.string { return applyAgentAssistant(body, messageID: messageID, parent: parent) }
        for block in body["content"]?.array ?? [] {
            let n = blockCounts[messageID, default: 0]
            blockCounts[messageID] = n + 1
            switch block["type"]?.string {
            case "thinking":
                // Empty when the display is "omitted"; redacted thinking has a different type and is skipped.
                let text = (block["thinking"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                isThinking = false
                if !text.isEmpty { append(.thinking(text), id: "th:\(messageID):\(n)") }
            case "text":
                let text = block["text"]?.string ?? ""
                streamingText = ""
                isThinking = false
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    append(.assistant(text), id: "a:\(messageID):\(n)")
                }
            case "tool_use":
                let id = block["id"]?.string ?? "\(messageID):\(n)"
                var call = Self.newToolCall(id: id, block)
                streamingText = ""
                if let existing = toolIndex[id] {
                    if case .tool(let old) = items[existing].kind { call.agent = old.agent ?? call.agent; items[existing].kind = .tool(call) }
                } else if call.name == "ExitPlanMode" {
                    append(.plan(PlanPrompt(requestID: nil, input: call.input, plan: call.input["plan"]?.string ?? "")), id: "tool:\(id)")
                    toolIndex[id] = items.count - 1
                } else if call.name == "AskUserQuestion" {
                    append(.question(QuestionPrompt(requestID: nil, input: call.input, questions: Self.questions(call.input))), id: "tool:\(id)")
                    toolIndex[id] = items.count - 1
                } else {
                    append(.tool(call), id: "tool:\(id)")
                    toolIndex[id] = items.count - 1
                }
                if call.name == "TodoWrite" { todos = Self.todoList(call.input) }
                if !state.needsYou { state = .working }
            default: break
            }
        }
        if let usage = body["usage"], body["model"]?.string != "<synthetic>" {
            applyUsage(usage, messageID: messageID, now: now)
        }
    }

    /// A subagent's message goes into its Agent call's steps. It never changes the session's own state or usage.
    private mutating func applyAgentAssistant(_ body: JSON, messageID: String, parent: String) {
        for block in body["content"]?.array ?? [] {
            let n = blockCounts[messageID, default: 0]
            blockCounts[messageID] = n + 1
            let step: ChatItem
            switch block["type"]?.string {
            case "text":
                let text = block["text"]?.string ?? ""
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                step = ChatItem(id: "a:\(messageID):\(n)", kind: .assistant(text))
            case "tool_use":
                let id = block["id"]?.string ?? "\(messageID):\(n)"
                step = ChatItem(id: "tool:\(id)", kind: .tool(Self.newToolCall(id: id, block)))
                stepParent[id] = parent
            default: continue
            }
            updateTool(parent) { call in
                guard let steps = call.agent?.steps, !steps.contains(where: { $0.id == step.id }) else { return }
                call.agent?.steps.append(step)
            }
        }
    }

    /// A call from a `tool_use` block. Agent calls get a run to follow.
    static func newToolCall(id: String, _ block: JSON) -> ToolCall {
        var call = ToolCall(id: id, name: block["name"]?.string ?? "Tool", input: block["input"] ?? .null)
        if AgentRun.toolNames.contains(call.name) {
            call.agent = AgentRun(type: call.input["subagent_type"]?.string, background: call.input["run_in_background"]?.bool == true)
        }
        return call
    }

    private mutating func applyUsage(_ usage: JSON, messageID: String, now: Date) {
        var turn = TurnUsage()
        turn.input = usage["input_tokens"]?.int ?? 0
        turn.output = usage["output_tokens"]?.int ?? 0
        turn.cacheRead = usage["cache_read_input_tokens"]?.int ?? 0
        turn.cacheCreation = usage["cache_creation_input_tokens"]?.int ?? 0
        if turn.contextTokens > 0 { lastUsage = turn }
        let five = (usage["cache_creation"]?["ephemeral_5m_input_tokens"]?.int ?? 0) > 0
        let hour = (usage["cache_creation"]?["ephemeral_1h_input_tokens"]?.int ?? 0) > 0
        guard turn.cacheRead > 0 || turn.cacheCreation > 0 || five || hour else { return }
        // Same rule as claude-cache: the clock starts at the first sighting of each message ID.
        guard cache?.generation != messageID else { return }
        let ttl: TimeInterval = five ? 300 : hour ? 3600 : (cache?.ttl ?? 300)
        let basis = five ? "5m cache write observed" : hour ? "1h cache write observed" : "Cache read; TTL carried over"
        if let current = cache, current.observedAt > now { return }
        cache = CacheEstimate(observedAt: now, ttl: ttl, basis: basis, generation: messageID)
    }

    private mutating func applyUser(_ message: JSON, history: Bool, now: Date) {
        guard let body = message["message"] else { return }
        if message["parent_tool_use_id"]?.string != nil {
            // A subagent's tool results. Its prompt is already on the Agent call.
            for block in body["content"]?.array ?? [] where block["type"]?.string == "tool_result" {
                if let id = block["tool_use_id"]?.string { applyToolResult(id, block: block, message: message, history: history, now: now) }
            }
            return
        }
        if message["isReplay"]?.bool == true {
            let text = Self.userText(body["content"])
            if let note = TaskNotification.parse(text) { return applyNotification(note) }
            if let uuid = message["uuid"]?.string { matchEcho(uuid: uuid, text: text) }
            return
        }
        let before = items.count
        defer {
            // In history, the row's ID belongs to the item it produced.
            if history, items.count > before, let uuid = message["uuid"]?.string { userMessageIDs[items[items.count - 1].id] = uuid }
        }
        if let text = body["content"]?.string {
            if history { appendUserText(text) }
            return
        }
        let blocks = body["content"]?.array ?? []
        if history {
            let images = blocks.filter { $0["type"]?.string == "image" }.count
            if images > 0 { append(.attachments(Array(repeating: "Image", count: images))) }
        }
        for block in blocks {
            switch block["type"]?.string {
            case "tool_result":
                if let id = block["tool_use_id"]?.string { applyToolResult(id, block: block, message: message, history: history, now: now) }
            case "text":
                if history, let text = block["text"]?.string { appendUserText(text) }
            default: break
            }
        }
    }

    static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    private mutating func applyToolResult(_ id: String, block: JSON, message: JSON, history: Bool, now: Date) {
        let meta = message["tool_use_result"] ?? message["toolUseResult"]
        var finished: ToolCall?
        updateTool(id) { call in
            call.result = Self.resultText(block["content"])
            call.isError = block["is_error"]?.bool ?? false
            call.done = true
            call.blockedByAutoMode = Self.blockedByAutoMode(id, meta: message["tool_result_meta"])
            if var run = call.agent {
                // A background agent's call returns as soon as it starts; the run goes on.
                run.applyResult(meta, text: call.result ?? "", isError: call.isError)
                call.done = !run.isRunning
                call.agent = run
            }
            finished = call
        }
        guard let call = finished, !call.isError else { return }
        // A subagent's edits change files too, so the preview waits for them as well.
        if !history, Self.editTools.contains(call.name) { lastFileEditAt = now }
        // Claude's checklist follows its own task list tools, not a subagent's.
        if toolIndex[id] != nil { applyTaskListResult(call, result: meta) }
    }
    /// Pairs an echoed message with the item it was sent as. Messages the CLI never echoes are skipped, not mismatched.
    private mutating func matchEcho(uuid: String, text: String) {
        guard let index = awaitingEcho.firstIndex(where: { $0.text == text }) else { return }
        userMessageIDs[awaitingEcho[index].itemID] = uuid
        awaitingEcho.removeFirst(index + 1)
    }

    static func userText(_ content: JSON?) -> String {
        if let text = content?.string { return text }
        return (content?.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
    }

    public static func todoList(_ input: JSON) -> [TodoItem] {
        (input["todos"]?.array ?? []).enumerated().compactMap { index, t in
            guard let content = t["content"]?.string else { return nil }
            return TodoItem(id: t["id"]?.string ?? "\(index)", content: content, activeForm: t["activeForm"]?.string,
                            status: t["status"]?.string ?? "pending")
        }
    }

    /// The task list tools change the checklist once their call succeeds: TaskCreate learns its ID from the result.
    private mutating func applyTaskListResult(_ call: ToolCall, result: JSON?) {
        switch call.name {
        case "TaskCreate":
            let text = call.result ?? ""
            guard let subject = call.input["subject"]?.string,
                  let id = result?["task"]?["id"]?.string ?? Self.between(text, "Task #", " ") else { return }
            todos.removeAll { $0.id == id }
            todos.append(TodoItem(id: id, content: subject, activeForm: call.input["activeForm"]?.string))
        case "TaskUpdate":
            guard let id = call.input["taskId"]?.string, let index = todos.firstIndex(where: { $0.id == id }) else { return }
            if call.input["status"]?.string == "deleted" { todos.remove(at: index); return }
            if let v = call.input["status"]?.string { todos[index].status = v }
            if let v = call.input["subject"]?.string { todos[index].content = v }
            if let v = call.input["activeForm"]?.string { todos[index].activeForm = v }
        default: break
        }
    }

    private mutating func appendUserText(_ raw: String) {
        // Slash commands are stored with XML-ish wrappers; show them the way they were typed.
        if let name = Self.between(raw, "<command-name>", "</command-name>") {
            let args = Self.between(raw, "<command-args>", "</command-args>") ?? ""
            append(.user(args.isEmpty ? name : "\(name) \(args)"))
            return
        }
        if raw.hasPrefix("<local-command") || raw.hasPrefix("<system-reminder>") || raw.hasPrefix("Caveat:") { return }
        // The CLI wrote this for Claude, not the user. An agent's report goes on its card; other tasks stay out of the chat, as live.
        if let note = TaskNotification.parse(raw) { return applyNotification(note) }
        if let relayed = Relay.parseEnvelope(raw) {
            append(.received(from: relayed.from, text: relayed.text))
            return
        }
        if let reply = Relay.parseReplyEnvelope(raw) {
            append(.reply(from: reply.from, text: reply.text))
            return
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { append(.user(text)) }
    }

    private mutating func applyStreamEvent(_ message: JSON) {
        guard message["parent_tool_use_id"]?.string == nil, let event = message["event"] else { return }
        switch event["type"]?.string {
        case "message_start": streamingText = ""
        case "content_block_start": isThinking = event["content_block"]?["type"]?.string == "thinking"
        case "content_block_delta":
            switch event["delta"]?["type"]?.string {
            case "text_delta": streamingText += event["delta"]?["text"]?.string ?? ""; isThinking = false
            case "thinking_delta": isThinking = true
            default: break
            }
        default: break
        }
    }

    private mutating func applyResult(_ message: JSON) {
        streamingText = ""
        isThinking = false
        if let cost = message["total_cost_usd"]?.double { costUSD = cost }
        if let ms = message["duration_ms"]?.double { lastTurnSeconds = ms / 1000 }
        let isError = message["is_error"]?.bool ?? false
        let subtype = message["subtype"]?.string ?? "success"
        if isError || subtype != "success" {
            let detail = message["result"]?.string ?? (message["errors"]?.array?.compactMap(\.string).joined(separator: "\n"))
            append(.notice(detail.flatMap { $0.isEmpty ? nil : $0 } ?? "The turn ended with \(subtype).", isError: true))
        }
        guard pendingPromptCount == 0 else { return }
        state = isError ? .failed : .finished
    }

    private mutating func applyControlRequest(_ message: JSON) -> [JSON] {
        let requestID = message["request_id"]?.string ?? ""
        guard let request = message["request"], ["can_use_tool", "elicitation"].contains(request["subtype"]?.string) else {
            return [Self.controlError(requestID, "Viber does not handle \(message["request"]?["subtype"]?.string ?? "this request").")]
        }
        if request["subtype"]?.string == "elicitation" {
            streamingText = ""
            append(.elicitation(ElicitationPrompt.parse(requestID: requestID, request)), id: "e:\(requestID)")
            state = .input
            return []
        }
        let toolName = request["tool_name"]?.string ?? "Tool"
        let input = request["input"] ?? .null
        let toolUseID = request["tool_use_id"]?.string
        let existing = toolUseID.flatMap { toolIndex[$0] }
        streamingText = ""
        switch toolName {
        case "AskUserQuestion":
            let prompt = QuestionPrompt(requestID: requestID, input: input, questions: Self.questions(input))
            if let existing { items[existing].kind = .question(prompt) } else { append(.question(prompt), id: "q:\(requestID)") }
            state = .input
        case "ExitPlanMode":
            let prompt = PlanPrompt(requestID: requestID, input: input, plan: input["plan"]?.string ?? "")
            if let existing { items[existing].kind = .plan(prompt) } else { append(.plan(prompt), id: "p:\(requestID)") }
            state = .plan
        default:
            var prompt = PermissionPrompt(requestID: requestID, toolName: toolName, input: input, toolUseID: toolUseID,
                                          description: request["description"]?.string ?? request["decision_reason"]?.string,
                                          suggestions: request["permission_suggestions"]?.array ?? [])
            if let agentID = request["agent_id"]?.string {
                let task = controls.tasks.first { $0.id == agentID }
                prompt.agent = task?.subagentType.map { "the \($0) agent" } ?? "a subagent"
                prompt.agentTask = task?.toolUseID.flatMap { findTool($0)?.input["description"]?.string }
            }
            append(.permission(prompt), id: "perm:\(requestID)")
            state = .permission
        }
        return []
    }

    private mutating func cancelPrompt(requestID: String) {
        for index in items.indices {
            switch items[index].kind {
            case .permission(var p) where p.requestID == requestID && p.decision == nil:
                p.decision = .cancelled; items[index].kind = .permission(p)
            case .question(var q) where q.requestID == requestID && q.decision == nil:
                q.decision = .cancelled; items[index].kind = .question(q)
            case .plan(var p) where p.requestID == requestID && p.decision == nil:
                p.decision = .cancelled; items[index].kind = .plan(p)
            case .elicitation(var e) where e.requestID == requestID && e.decision == nil:
                e.decision = .cancelled; items[index].kind = .elicitation(e)
            default: continue
            }
        }
        resumeAfterPrompt()
    }

    private mutating func applyControlResponse(_ message: JSON, now: Date) -> [JSON] {
        guard let response = message["response"], let id = response["request_id"]?.string,
              let pending = pendingRequests.removeValue(forKey: id) else { return [] }
        let subtype = pending.subtype
        let server = pending.body["serverName"]?.string
        if let key = pending.key { controls.busy.remove(key) }
        if response["subtype"]?.string == "error" {
            let error = response["error"]?.string ?? "unknown error"
            if subtype == "rewind_files" {
                rewinds[id] = nil
                append(.notice("Could not rewind files: \(error)", isError: true))
                return []
            }
            // Settings-sheet errors show in the sheet, next to what failed.
            if let key = pending.key { controls.errors[key] = error } else { append(.notice("\(subtype) failed: \(error)", isError: true)) }
            if let server { controls.signingIn[server] = nil }
            return []
        }
        let body = response["response"]
        switch subtype {
        case "initialize":
            guard let body else { return [] }
            commands = Self.commands(body["commands"])
            models = (body["models"]?.array ?? []).compactMap { m in
                guard let value = m["value"]?.string else { return nil }
                return ModelOption(value: value, displayName: m["displayName"]?.string ?? value)
            }
            applyMode(body["current_permission_mode"]?.string)
            controls.outputStyle = body["output_style"]?.string ?? controls.outputStyle
            controls.outputStyles = (body["available_output_styles"]?.array ?? []).compactMap(\.string)
            if state == .starting { state = .idle }
            // The header's MCP count, before the first turn's init message would bring it.
            return [request("mcp_status", key: "mcp")]
        case "set_permission_mode":
            applyMode(body?["mode"]?.string)
        case "mcp_status":
            let servers = McpServer.parse(body?["mcpServers"])
            controls.mcp = servers
            for s in servers where s.status == .connected { controls.signingIn[s.name] = nil }
        case "mcp_toggle", "mcp_reconnect", "mcp_clear_auth":
            return [request("mcp_status", key: "mcp")]
        case "mcp_authenticate":
            if let url = body?["authUrl"]?.string.flatMap(URL.init(string:)), body?["requiresUserAction"]?.bool != false {
                controls.authURL = url
                if let server {
                    controls.signingIn[server] = now
                    // claude.ai connectors are connected on claude.ai; nothing calls the CLI back.
                    if body?["callbackExpected"]?.bool == false { controls.reconnectOnReturn.insert(server) }
                }
                return []
            }
            return [request("mcp_status", key: "mcp")] // already signed in
        case "get_context_usage":
            controls.context = ContextUsage.parse(body)
        case "get_session_cost":
            controls.costText = body?["text"]?.string
        case "list_permission_rules":
            (controls.rules, controls.directories) = PermissionRule.parse(body)
        case "get_hooks_listing":
            controls.hooks = HookEntry.parseListing(body)
        case "get_task_output":
            guard let task = pending.body["task_id"]?.string else { break }
            controls.taskOutput[task] = TaskOutput(text: body?["output"]?.string ?? "", totalBytes: body?["total_bytes"]?.int ?? 0,
                                                   truncated: body?["truncated"]?.bool ?? false)
        case "get_settings":
            controls.appliedModel = body?["applied"]?["model"]?.string ?? controls.appliedModel
            controls.effort = body?["applied"]?["effort"]?.string ?? controls.effort
            controls.outputStyle = body?["effective"]?["outputStyle"]?.string ?? controls.outputStyle
        case "rewind_files":
            guard let itemID = rewinds.removeValue(forKey: id) else { return [] }
            let files = (body?["filesChanged"]?.array ?? []).compactMap(\.string)
            let insertions = body?["insertions"]?.int ?? 0, deletions = body?["deletions"]?.int ?? 0
            if pending.body["dry_run"]?.bool == true {
                rewindPreview = RewindPreview(itemID: itemID, canRewind: body?["canRewind"]?.bool ?? false,
                                              error: body?["error"]?.string, files: files, insertions: insertions, deletions: deletions)
            } else if body?["canRewind"]?.bool == false {
                append(.notice("Could not rewind files: \(body?["error"]?.string ?? "no checkpoint for that message")", isError: true))
            } else {
                let count = files.count == 1 ? "1 file" : "\(files.count) files"
                append(.notice("Rewound \(count) (+\(insertions) −\(deletions)) to before that message. The conversation is unchanged.", isError: false))
            }
        case "apply_flag_settings" where pending.key == "sessionRules":
            return [request("list_permission_rules", key: "permissions")]
        default: break
        }
        return []
    }

    private mutating func mergeServerStatus(_ servers: [McpServer]) {
        guard var current = controls.mcp else { controls.mcp = servers; return }
        for server in servers {
            if let index = current.firstIndex(where: { $0.name == server.name }) { current[index].status = server.status }
            else { current.append(server) }
        }
        controls.mcp = current
    }

    static func commands(_ list: JSON?) -> [SlashCommand] {
        (list?.array ?? []).compactMap { c in
            guard let name = c["name"]?.string else { return nil }
            return SlashCommand(name: name, description: c["description"]?.string ?? "", argumentHint: c["argumentHint"]?.string ?? "")
        }
    }

    /// A mode the CLI reported as in effect. Every change after the first report gets a notice.
    private mutating func applyMode(_ mode: String?) {
        guard let mode, mode != permissionMode else { return }
        if permissionMode != nil { append(.notice(PermissionMode(rawValue: mode)?.notice ?? "Mode: \(mode)", isError: false)) }
        permissionMode = mode
    }

    /// `tool_result_meta` says who decided each call; a refusal by auto mode's classifier is a block.
    static func blockedByAutoMode(_ toolUseID: String, meta: JSON?) -> Bool {
        guard let entry = meta?.array?.first(where: { $0["id"]?.string == toolUseID }),
              let decision = entry["permission_decision"], decision["reason_type"]?.string == "classifier",
              let verdict = decision["decision"]?.string else { return false }
        return verdict != "accept" && verdict != "allow"
    }

    private mutating func resumeAfterPrompt() {
        if pendingPromptCount == 0, state.needsYou { state = .working }
    }

    private mutating func append(_ kind: ChatItem.Kind, id: String? = nil) {
        nextID += 1
        items.append(ChatItem(id: id ?? "i\(nextID)", kind: kind))
    }

    static func questions(_ input: JSON) -> [Question] {
        (input["questions"]?.array ?? []).map { q in
            Question(question: q["question"]?.string ?? "", header: q["header"]?.string ?? "",
                     options: (q["options"]?.array ?? []).map { ($0["label"]?.string ?? "", $0["description"]?.string ?? "") },
                     multiSelect: q["multiSelect"]?.bool ?? false)
        }
    }

    static func resultText(_ content: JSON?) -> String {
        switch content {
        case .string(let s)?: return s
        case .array(let parts)?: return parts.compactMap { $0["text"]?.string }.joined(separator: "\n")
        default: return ""
        }
    }

    static func between(_ s: String, _ open: String, _ close: String) -> String? {
        guard let a = s.range(of: open), let b = s.range(of: close, range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
