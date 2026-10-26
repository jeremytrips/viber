import Foundation

/// The tabs of a session's settings sheet. Terminal-only commands (`/mcp`, `/context`, …) open these.
public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case mcp, context, permissions, hooks, tasks, model

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .mcp: return "MCP"
        case .context: return "Context"
        case .permissions: return "Permissions"
        case .hooks: return "Hooks"
        case .tasks: return "Tasks"
        case .model: return "Model"
        }
    }
}

/// One MCP server as `mcp_status` (or the `init` message) reports it.
public struct McpServer: Equatable, Sendable, Identifiable {
    public enum Status: Equatable, Sendable {
        case connected, pending, needsAuth, failed, disabled, other(String)

        init(_ raw: String) {
            switch raw {
            case "connected": self = .connected
            case "pending": self = .pending
            case "needs-auth": self = .needsAuth
            case "failed": self = .failed
            case "disabled": self = .disabled
            default: self = .other(raw)
            }
        }

        public var label: String {
            switch self {
            case .connected: return "Connected"
            case .pending: return "Connecting"
            case .needsAuth: return "Needs sign-in"
            case .failed: return "Failed"
            case .disabled: return "Disabled"
            case .other(let raw): return raw
            }
        }
    }

    public var name: String
    public var status: Status
    public var source: String?
    public var transport: String?
    public var tools: [String]
    public var error: String?
    public var version: String?
    public var id: String { name }

    public init(name: String, status: Status, source: String? = nil, transport: String? = nil, tools: [String] = [],
                error: String? = nil, version: String? = nil) {
        self.name = name; self.status = status; self.source = source; self.transport = transport
        self.tools = tools; self.error = error; self.version = version
    }

    /// OAuth tokens the CLI holds itself; claude.ai connectors are signed out on claude.ai.
    public var canSignOut: Bool { transport == "http" || transport == "sse" }
    /// clauth gives each session its own config folder and Keychain item, which is where the CLI keeps a server's
    /// OAuth login, so a sign-in there is gone once Claude restarts. claude.ai connectors sign in with the account.
    public func signInLastsOneSession(underClauth: Bool) -> Bool { underClauth && transport != "claudeai-proxy" }
    public var needsAttention: Bool { status == .needsAuth || status == .failed }

    public static func parse(_ list: JSON?) -> [McpServer] {
        (list?.array ?? []).compactMap { s in
            guard let name = s["name"]?.string else { return nil }
            return McpServer(name: name, status: Status(s["status"]?.string ?? ""),
                             source: s["source"]?.string ?? s["scope"]?.string,
                             transport: s["transport"]?.string ?? s["config"]?["type"]?.string,
                             tools: (s["tools"]?.array ?? []).compactMap { $0["name"]?.string },
                             error: s["error"]?.string, version: s["serverInfo"]?["version"]?.string)
        }
    }
}

/// `get_context_usage`: where the context window goes.
public struct ContextUsage: Equatable, Sendable {
    public struct Category: Equatable, Sendable, Identifiable {
        public var name: String
        public var tokens: Int
        /// "used", "deferred" (loaded on demand, not counted), "buffer" (autocompact reserve) or "free".
        public var kind: String
        public var id: String { name }
    }

    public var categories: [Category]
    public var totalTokens: Int
    public var maxTokens: Int
    public var model: String?
    public var autoCompactEnabled: Bool

    public var fraction: Double { maxTokens > 0 ? Double(totalTokens) / Double(maxTokens) : 0 }

    public static func parse(_ json: JSON?) -> ContextUsage? {
        guard let json, let max = json["maxTokens"]?.int else { return nil }
        let categories = (json["categories"]?.array ?? []).compactMap { c -> Category? in
            guard let name = c["name"]?.string else { return nil }
            return Category(name: name, tokens: c["tokens"]?.int ?? 0, kind: c["kind"]?.string ?? "used")
        }
        return ContextUsage(categories: categories, totalTokens: json["totalTokens"]?.int ?? 0, maxTokens: max,
                            model: json["model"]?.string, autoCompactEnabled: json["isAutoCompactEnabled"]?.bool ?? true)
    }
}

/// A permission rule with the settings layer it comes from (`list_permission_rules`).
public struct PermissionRule: Equatable, Sendable, Identifiable {
    public var behavior: String
    public var rule: String
    /// userSettings, projectSettings, localSettings, flagSettings (Viber's session rules), policySettings, cliArg, …
    public var source: String
    public var id: String { "\(source)|\(behavior)|\(rule)" }

    public init(behavior: String, rule: String, source: String) {
        self.behavior = behavior; self.rule = rule; self.source = source
    }

    public var scope: SettingsScope? { SettingsScope(source: source) }

    public var sourceLabel: String {
        scope?.label ?? [
            "policySettings": "Managed policy", "cliArg": "Command line", "command": "Command", "session": "This session"
        ][source] ?? source
    }

    public static func parse(_ json: JSON?) -> (rules: [PermissionRule], directories: [String]) {
        let state = json?["state"]
        let rules = (state?["rules"]?.array ?? []).compactMap { r -> PermissionRule? in
            guard let behavior = r["behavior"]?.string, let rule = r["rule"]?.string else { return nil }
            return PermissionRule(behavior: behavior, rule: rule, source: r["source"]?.string ?? "")
        }
        return (rules, (state?["workspaceDirectories"]?.array ?? []).compactMap { $0["path"]?.string })
    }
}

/// One configured hook (`get_hooks_listing`, or a settings file's `hooks` block).
public struct HookEntry: Equatable, Sendable, Identifiable {
    public var event: String
    public var matcher: String
    public var command: String
    public var source: String
    public var timeout: Int?
    public var id: String { "\(source)|\(event)|\(matcher)|\(command)" }

    public init(event: String, matcher: String, command: String, source: String, timeout: Int? = nil) {
        self.event = event; self.matcher = matcher; self.command = command; self.source = source; self.timeout = timeout
    }

    public static func parseListing(_ json: JSON?) -> [HookEntry] {
        (json?["hooks"]?.array ?? []).compactMap { h in
            guard let event = h["event"]?.string else { return nil }
            let source = h["pluginName"]?.string.map { "Plugin \($0)" } ?? h["sourceLabel"]?.string ?? h["source"]?.string ?? ""
            return HookEntry(event: event, matcher: h["matcher"]?.string ?? "",
                             command: h["displayText"]?.string ?? h["commandText"]?.string ?? h["type"]?.string ?? "",
                             source: source, timeout: h["timeout"]?.int)
        }
    }

    /// The `hooks` block of a settings file: event → [{matcher, hooks: [{type, command, timeout}]}].
    public static func parseSettings(_ hooks: JSON?, source: String) -> [HookEntry] {
        guard let events = hooks?.object else { return [] }
        return events.keys.sorted().flatMap { event in
            (events[event]?.array ?? []).flatMap { group in
                (group["hooks"]?.array ?? []).map { hook in
                    HookEntry(event: event, matcher: group["matcher"]?.string ?? "",
                              command: hook["command"]?.string ?? hook["prompt"]?.string ?? hook["type"]?.string ?? "",
                              source: source, timeout: hook["timeout"]?.int)
                }
            }
        }
    }
}

/// A shell command, subagent or monitor the CLI runs alongside the conversation (`task_*` system messages).
public struct SessionTask: Equatable, Sendable, Identifiable {
    public var id: String
    /// local_bash, local_agent, monitor, …
    public var type: String
    public var description: String
    /// running, completed, failed or stopped.
    public var status = "running"
    public var summary: String?
    public var lastTool: String?
    public var toolUseID: String?
    public var subagentType: String?
    public var backgrounded = false
    public var tokens: Int?
    public var toolUses: Int?

    public init(id: String, type: String, description: String) {
        self.id = id; self.type = type; self.description = description
    }

    public var isRunning: Bool { status == "running" || status == "pending" }
    /// Shells and monitors write output the CLI can show (`get_task_output`).
    public var hasOutput: Bool { type == "local_bash" || type == "monitor" }
    public var kindLabel: String {
        switch type {
        case "local_bash": return "Shell"
        case "local_agent": return subagentType.map { "Agent · \($0)" } ?? "Agent"
        case "monitor": return "Monitor"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// The end of a shell task's output (`get_task_output`).
public struct TaskOutput: Equatable, Sendable {
    public var text: String
    public var totalBytes: Int
    public var truncated: Bool
}

/// What the settings sheet shows for one session. Filled by control-request replies.
public struct SessionControls: Equatable, Sendable {
    public var mcp: [McpServer]?
    public var context: ContextUsage?
    public var costText: String?
    public var rules: [PermissionRule]?
    public var directories: [String] = []
    public var hooks: [HookEntry]?
    /// Every task seen this session, in start order; finished ones are trimmed to the last few.
    public var tasks: [SessionTask] = []
    public var taskOutput: [String: TaskOutput] = [:]
    /// Model and effort in effect, as `get_settings` reports them.
    public var appliedModel: String?
    public var effort: String?
    public var outputStyle: String?
    public var outputStyles: [String] = []
    /// Requests in flight, by key ("mcp", "mcp:<server>", "context", …).
    public var busy: Set<String> = []
    public var errors: [String: String] = [:]
    /// Servers waiting for a browser sign-in, and when it started.
    public var signingIn: [String: Date] = [:]
    /// Sign-ins that ran out of time without the server connecting, until it connects or a new sign-in starts.
    /// The browser can say it worked when Claude then failed to use the login, and nothing else would tell.
    public var signInsUnfinished: Set<String> = []
    public static let signInTimeout: TimeInterval = 120
    /// Signed in on a web page that does not call the CLI back: reconnect when the user returns.
    public var reconnectOnReturn: Set<String> = []
    /// A sign-in page the app should open, then clear.
    public var authURL: URL?

    public init() {}

    /// When the user comes back from a browser sign-in: reconnect the servers that need it, then re-read status.
    public mutating func takeReturnReconnects() -> [String] {
        defer { reconnectOnReturn.removeAll() }
        return reconnectOnReturn.sorted()
    }

    /// Stops waiting on sign-ins older than `signInTimeout` and marks them unfinished.
    public mutating func expireSignIns(now: Date) {
        for (server, started) in signingIn where now.timeIntervalSince(started) >= Self.signInTimeout {
            signingIn[server] = nil
            signInsUnfinished.insert(server)
        }
    }

    public var runningTasks: [SessionTask] { tasks.filter(\.isRunning) }

    public var mcpSummary: (connected: Int, total: Int, attention: Bool)? {
        guard let mcp, !mcp.isEmpty else { return nil }
        return (mcp.filter { $0.status == .connected }.count, mcp.count, mcp.contains(where: \.needsAttention))
    }
}
