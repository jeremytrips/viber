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

    public init(id: String, name: String, input: JSON, result: String? = nil, isError: Bool = false, done: Bool = false) {
        self.id = id; self.name = name; self.input = input; self.result = result; self.isError = isError; self.done = done
    }
}

public enum PromptDecision: Equatable, Sendable {
    case allowed, alwaysAllowed, denied, answered, keepPlanning, cancelled
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
        case assistant(String)
        case tool(ToolCall)
        case permission(PermissionPrompt)
        case question(QuestionPrompt)
        case plan(PlanPrompt)
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
}

public struct TurnUsage: Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheCreation = 0
    public var contextTokens: Int { input + cacheRead + cacheCreation }
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
    public var cache: CacheEstimate?
    public var lastUsage: TurnUsage?
    public var costUSD: Double = 0
    public var lastTurnSeconds: Double?
    public var commands: [SlashCommand] = []
    public var models: [ModelOption] = []
    public var turnStartedByUser = true

    private var toolIndex: [String: Int] = [:]
    private var pendingRequests: [String: String] = [:]
    private var blockCounts: [String: Int] = [:]
    private var seenRows: Set<String> = []
    private var nextID = 0

    public init() {}

    public var pendingPromptCount: Int {
        items.reduce(0) { count, item in
            switch item.kind {
            case .permission(let p) where p.decision == nil: return count + 1
            case .question(let q) where q.decision == nil && q.requestID != nil: return count + 1
            case .plan(let p) where p.decision == nil && p.requestID != nil: return count + 1
            default: return count
            }
        }
    }

    // MARK: Outgoing

    public mutating func userMessage(_ text: String) -> JSON {
        append(.user(text))
        state = .working
        turnStartedByUser = true
        return ["type": "user", "message": ["role": "user", "content": .string(text)]]
    }

    public mutating func request(_ subtype: String, _ extra: [String: JSON] = [:]) -> JSON {
        nextID += 1
        let id = "viber-\(nextID)-\(subtype)"
        pendingRequests[id] = subtype
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

    /// `permissionMode` changes once the CLI confirms; it refuses auto mode on some models.
    public mutating func setPermissionMode(_ mode: String) -> JSON {
        request("set_permission_mode", ["mode": .string(mode)])
    }

    public mutating func setModel(_ value: String?) -> JSON {
        model = value ?? model
        return request("set_model", value.map { ["model": .string($0)] } ?? [:])
    }

    public mutating func note(_ text: String, isError: Bool = false) { append(.notice(text, isError: isError)) }

    /// Delivers a `//` message from another session as a user turn, keeping who sent it.
    public mutating func receiveRelay(from source: String, text: String) -> JSON {
        append(.received(from: source, text: text))
        state = .working
        turnStartedByUser = true
        return ["type": "user", "message": ["role": "user", "content": .string(Relay.envelope(from: source, text: text))]]
    }

    /// Posts the answer to an earlier `//` message back into the sender's conversation.
    public mutating func receiveReply(from source: String, text: String) -> JSON {
        append(.reply(from: source, text: text))
        state = .working
        turnStartedByUser = true
        return ["type": "user", "message": ["role": "user", "content": .string(Relay.replyEnvelope(from: source, text: text))]]
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
        items.removeAll(); toolIndex.removeAll(); streamingText = ""
    }

    public mutating func processExited(status: Int32) {
        streamingText = ""
        for index in items.indices {
            switch items[index].kind {
            case .permission(var p) where p.decision == nil: p.decision = .cancelled; items[index].kind = .permission(p)
            case .question(var q) where q.decision == nil && q.requestID != nil: q.decision = .cancelled; items[index].kind = .question(q)
            case .plan(var p) where p.decision == nil && p.requestID != nil: p.decision = .cancelled; items[index].kind = .plan(p)
            default: break
            }
        }
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
        case "user": applyUser(message, history: history)
        case "stream_event": applyStreamEvent(message)
        case "result": applyResult(message)
        case "control_request": return applyControlRequest(message)
        case "control_cancel_request": cancelPrompt(requestID: message["request_id"]?.string ?? "")
        case "control_response": applyControlResponse(message)
        default: break
        }
        return []
    }

    /// Rebuild the chat from a transcript file so resumed sessions show their history.
    public mutating func loadHistory(_ data: Data) {
        for line in data.split(separator: 10) {
            guard let row = JSON(data: Data(line)) else { continue }
            if row["isSidechain"]?.bool == true || row["isMeta"]?.bool == true { continue }
            apply(row, history: true)
        }
        for index in items.indices {
            if case .tool(var call) = items[index].kind, !call.done { call.done = true; items[index].kind = .tool(call) }
        }
        streamingText = ""
        state = .idle
    }

    private mutating func applySystem(_ message: JSON) {
        switch message["subtype"]?.string {
        case "init":
            sessionID = message["session_id"]?.string ?? sessionID
            cwd = message["cwd"]?.string ?? cwd
            model = message["model"]?.string ?? model
            applyMode(message["permissionMode"]?.string)
            if state == .starting { state = .idle }
        case "status":
            // The CLI announces every mode change here, including ones it makes itself,
            // like leaving auto mode when the model switches to one without it.
            applyMode(message["permissionMode"]?.string)
        case "compact_boundary":
            append(.notice("Conversation compacted", isError: false))
        default: break
        }
    }

    private mutating func applyAssistant(_ message: JSON, now: Date) {
        guard let body = message["message"] else { return }
        let messageID = body["id"]?.string ?? UUID().uuidString
        if message["parent_tool_use_id"]?.string != nil { return } // subagent traffic stays inside its Task row
        for block in body["content"]?.array ?? [] {
            let n = blockCounts[messageID, default: 0]
            blockCounts[messageID] = n + 1
            switch block["type"]?.string {
            case "text":
                let text = block["text"]?.string ?? ""
                streamingText = ""
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    append(.assistant(text), id: "a:\(messageID):\(n)")
                }
            case "tool_use":
                let id = block["id"]?.string ?? "\(messageID):\(n)"
                let call = ToolCall(id: id, name: block["name"]?.string ?? "Tool", input: block["input"] ?? .null)
                streamingText = ""
                if let existing = toolIndex[id] {
                    if case .tool = items[existing].kind { items[existing].kind = .tool(call) }
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
                if !state.needsYou { state = .working }
            default: break
            }
        }
        if let usage = body["usage"], body["model"]?.string != "<synthetic>" {
            applyUsage(usage, messageID: messageID, now: now)
        }
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

    private mutating func applyUser(_ message: JSON, history: Bool) {
        guard let body = message["message"] else { return }
        if message["parent_tool_use_id"]?.string != nil { return }
        if let text = body["content"]?.string {
            if history { appendUserText(text) }
            return
        }
        for block in body["content"]?.array ?? [] {
            switch block["type"]?.string {
            case "tool_result":
                guard let id = block["tool_use_id"]?.string, let index = toolIndex[id] else { continue }
                if case .tool(var call) = items[index].kind {
                    call.result = Self.resultText(block["content"])
                    call.isError = block["is_error"]?.bool ?? false
                    call.done = true
                    call.blockedByAutoMode = Self.blockedByAutoMode(id, meta: message["tool_result_meta"])
                    items[index].kind = .tool(call)
                }
            case "text":
                if history, let text = block["text"]?.string { appendUserText(text) }
            default: break
            }
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
        case "content_block_delta":
            if event["delta"]?["type"]?.string == "text_delta" { streamingText += event["delta"]?["text"]?.string ?? "" }
        default: break
        }
    }

    private mutating func applyResult(_ message: JSON) {
        streamingText = ""
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
        guard let request = message["request"], request["subtype"]?.string == "can_use_tool" else {
            return [Self.controlError(requestID, "Viber does not handle \(message["request"]?["subtype"]?.string ?? "this request").")]
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
            let prompt = PermissionPrompt(requestID: requestID, toolName: toolName, input: input, toolUseID: toolUseID,
                                          description: request["description"]?.string ?? request["decision_reason"]?.string,
                                          suggestions: request["permission_suggestions"]?.array ?? [])
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
            default: continue
            }
        }
        resumeAfterPrompt()
    }

    private mutating func applyControlResponse(_ message: JSON) {
        guard let response = message["response"], let id = response["request_id"]?.string,
              let subtype = pendingRequests.removeValue(forKey: id) else { return }
        if response["subtype"]?.string == "error" {
            append(.notice("\(subtype) failed: \(response["error"]?.string ?? "unknown error")", isError: true))
            return
        }
        if subtype == "set_permission_mode" { applyMode(response["response"]?["mode"]?.string) }
        guard subtype == "initialize", let body = response["response"] else { return }
        commands = (body["commands"]?.array ?? []).compactMap { c in
            guard let name = c["name"]?.string else { return nil }
            return SlashCommand(name: name, description: c["description"]?.string ?? "", argumentHint: c["argumentHint"]?.string ?? "")
        }
        models = (body["models"]?.array ?? []).compactMap { m in
            guard let value = m["value"]?.string else { return nil }
            return ModelOption(value: value, displayName: m["displayName"]?.string ?? value)
        }
        applyMode(body["current_permission_mode"]?.string)
        if state == .starting { state = .idle }
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
