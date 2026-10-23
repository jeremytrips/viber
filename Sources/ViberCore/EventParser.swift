// Copied from claude-cache/Sources/CompanionCore/EventParser.swift. Keep in sync by hand.
import Foundation

public enum EventParser {
    /// The transcript is an undocumented, version-dependent format. Unknown rows are ignored.
    public static func transcript(_ data: Data, path: String, fallbackTTL: TimeInterval = 300) -> Event? {
        guard let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var type = row["type"] as? String,
              let time = Dates.parse(row["timestamp"]) else { return nil }
        // Subagent files often reuse the parent's sessionId; never merge them into its state.
        guard !path.contains("/subagents/"), row["isSidechain"] as? Bool != true else { return nil }
        let attachment = row["attachment"] as? [String: Any] ?? [:]
        // Agent reports queued while busy arrive as attachments rather than user rows.
        if type == "attachment", attachment["type"] as? String == "queued_command" { type = "queued" }
        guard ["user", "assistant", "queued"].contains(type) else { return nil }
        let session = row["sessionId"] as? String ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let message = row["message"] as? [String: Any] ?? [:]
        let content = message["content"] as? [[String: Any]] ?? []
        let messageID = message["id"] as? String
        let id = row["uuid"] as? String ?? "\(path):\(time.timeIntervalSince1970):\(type):\(messageID ?? "")"
        var event = Event(id: id, sessionID: session,
                          project: row["cwd"] as? String ?? URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent,
                          time: time, state: .working, estimated: true, transcriptPath: path)
        if type != "assistant" {
            // A tool result resumes execution; ordinary user messages begin a new turn. Turns started by
            // background-task results or agent messages are not ones the user is waiting on.
            let origin = (type == "queued" ? attachment["origin"] : row["origin"]) as? [String: Any]
            if let kind = origin?["kind"] as? String { event.automatedTurn = kind != "human" }
            if type == "queued" { event.state = nil }
            return event
        }
        let tools = content.filter { $0["type"] as? String == "tool_use" }
        event.state = tools.isEmpty ? nil : .working
        if let tool = tools.first(where: { ["AskUserQuestion", "ExitPlanMode"].contains($0["name"] as? String ?? "") }) {
            event.state = tool["name"] as? String == "AskUserQuestion" ? .input : .plan
            if let toolID = tool["id"] as? String { event.id = "tool:\(toolID)" }
        } else if message["stop_reason"] as? String == "end_turn", tools.isEmpty {
            event.state = .finished
        }
        if let usage = message["usage"] as? [String: Any] {
            let creation = usage["cache_creation"] as? [String: Any] ?? [:]
            let five = (creation["ephemeral_5m_input_tokens"] as? Int ?? 0) > 0
            let hour = (creation["ephemeral_1h_input_tokens"] as? Int ?? 0) > 0
            let used = (usage["cache_read_input_tokens"] as? Int ?? 0) > 0
                || (usage["cache_creation_input_tokens"] as? Int ?? 0) > 0 || five || hour
            if used {
                // Never infer the TTL of cache reads from creation buckets in a different request.
                event.cacheTTL = five ? 300 : hour ? 3600 : fallbackTTL
                event.cacheBasis = five && hour ? "Mixed TTL writes; earliest 5m expiry estimate"
                    : five ? "5m cache write observed" : hour ? "1h cache write observed"
                    : "TTL unavailable; assumed \(Int(fallbackTTL / 60))m"
                event.messageID = messageID ?? id
            }
        }
        return event
    }

    public static func hook(_ data: Data) -> Event? {
        guard let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = row["hook_event_name"] as? String,
              let session = row["session_id"] as? String, !session.isEmpty,
              let time = Dates.parse(row["observed_at"]),
              let id = row["event_id"] as? String else { return nil }
        // Subagent hooks carry the parent's session_id; agent_id marks them so they never alter its state.
        guard (row["agent_id"] as? String ?? "").isEmpty else { return nil }
        let tool = row["tool_name"] as? String ?? ""
        var state: SessionState?
        var estimated = false
        switch name {
        case "SessionStart", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure": state = .working
        case "PreToolUse":
            state = tool == "AskUserQuestion" ? .input : tool == "ExitPlanMode" ? .plan : .working
            // Invocation can be auto-approved, so it is a request rather than a confirmed dialog.
            estimated = state == .input || state == .plan
        case "PermissionRequest":
            state = tool == "ExitPlanMode" ? .plan : tool == "AskUserQuestion" ? .input : .permission
        case "Stop": state = .finished
        case "StopFailure": state = .failed
        case "SessionEnd": state = .ended
        case "Notification":
            switch row["notification_type"] as? String {
            case "permission_prompt": state = .permission
            case "elicitation_dialog", "elicitation_url_dialog": state = .input
            // idle_prompt means idle after a response, not necessarily an unanswered question.
            default: return nil
            }
        default: return nil
        }
        var event = Event(id: (row["tool_use_id"] as? String).map { "tool:\($0)" } ?? id,
                     sessionID: session, project: row["cwd"] as? String ?? "Unknown project",
                     time: time, state: state, estimated: estimated)
        event.genericPermissionNotice = name == "Notification" && state == .permission
        return event
    }
}
