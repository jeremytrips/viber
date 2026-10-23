import Foundation

/// A subagent's run behind an `Agent` call (`Task` in older CLIs): what it is doing, what it did, and its report.
public struct AgentRun: Equatable, Sendable {
    public static let toolNames: Set<String> = ["Agent", "Task"]

    /// The subagent type, like Explore or general-purpose.
    public var type: String?
    /// The CLI's ID for the run, which `stop_task` takes.
    public var taskID: String?
    public var background = false
    /// running, completed, failed, stopped or killed; unknown when history ends before the agent did.
    public var status = "running"
    public var tokens: Int?
    public var toolUses: Int?
    public var durationMs: Int?
    /// The subagent's own tool calls and messages, in order.
    public var steps: [ChatItem] = []
    /// What the agent handed back to Claude.
    public var report: String?

    public init(type: String? = nil, background: Bool = false) {
        self.type = type; self.background = background
    }

    public var isRunning: Bool { status == "running" || status == "pending" }

    /// Steps before the report. An agent's last message is its report, which shows on its own.
    public var activity: ArraySlice<ChatItem> { report == nil ? steps[...] : steps[..<lastMessageStart] }

    /// Where the messages after the agent's last tool call begin.
    private var lastMessageStart: Int {
        var start = steps.endIndex
        while start > steps.startIndex, case .assistant = steps[start - 1].kind { start -= 1 }
        return start
    }

    /// The agent's last message so far: its report, when the CLI sends nothing better.
    var lastMessage: String? {
        let texts = steps[lastMessageStart...].compactMap { item -> String? in
            if case .assistant(let text) = item.kind { return text }
            return nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }

    /// The Agent call's own result: a foreground agent's report, or word that a background one started.
    mutating func applyResult(_ meta: JSON?, text: String, isError: Bool) {
        if let id = meta?["agentId"]?.string { taskID = id }
        if meta?["status"]?.string == "async_launched" || meta?["isAsync"]?.bool == true || text.hasPrefix("Async agent launched") {
            background = true
            return
        }
        let content = ChatTranscript.resultText(meta?["content"])
        report = isError ? text : content.isEmpty ? Self.handBack(text) : content
        status = isError ? "failed" : "completed"
        tokens = meta?["totalTokens"]?.int ?? tokens
        toolUses = meta?["totalToolUseCount"]?.int ?? toolUses
        durationMs = meta?["totalDurationMs"]?.int ?? durationMs
    }

    /// The live end of a run, from `task_notification`.
    mutating func finish(status: String, summary: String?) {
        self.status = status
        report = report ?? lastMessage ?? summary.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The end of a run as a transcript records it.
    mutating func finish(_ note: TaskNotification) {
        status = note.status
        report = note.result ?? report
        tokens = note.tokens ?? tokens
        toolUses = note.toolUses ?? toolUses
        durationMs = note.durationMs ?? durationMs
    }

    /// A foreground agent's result as Claude receives it: a framing note, the report indented, then its ID and usage.
    static func handBack(_ text: String) -> String {
        guard let start = text.range(of: "The report follows:\n") else { return text }
        var body = String(text[start.upperBound...])
        if let end = body.range(of: "\nagentId: ", options: .backwards) { body = String(body[..<end.lowerBound]) }
        return body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : String($0) }
            .joined(separator: "\n")
    }
}

/// The note the CLI queues for Claude when a background task ends. Transcripts store it as a user message.
public struct TaskNotification: Equatable, Sendable {
    public var taskID: String
    public var toolUseID: String?
    public var status: String
    public var result: String?
    public var tokens: Int?
    public var toolUses: Int?
    public var durationMs: Int?

    public static func parse(_ text: String) -> TaskNotification? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("<task-notification>"), let id = ChatTranscript.between(text, "<task-id>", "</task-id>") else { return nil }
        func number(_ tag: String) -> Int? { ChatTranscript.between(text, "<\(tag)>", "</\(tag)>").flatMap { Int($0) } }
        return TaskNotification(taskID: id, toolUseID: ChatTranscript.between(text, "<tool-use-id>", "</tool-use-id>"),
                                status: ChatTranscript.between(text, "<status>", "</status>") ?? "completed",
                                result: ChatTranscript.between(text, "<result>", "</result>").map(unescaped),
                                tokens: number("subagent_tokens"), toolUses: number("tool_uses"), durationMs: number("duration_ms"))
    }

    /// The report inside is XML-escaped.
    static func unescaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }
}
