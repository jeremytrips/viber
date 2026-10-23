import Foundation

/// MCP servers hosted by Viber itself, reached over the CLI's stdio control channel (what the Agent SDK
/// calls "sdk" servers). Checked against claude 2.1.309:
/// - `initialize` names them in `sdkMcpServers` and may carry `sdkMcpServerConfigs` (timeout, disableAutoBackground,
///   alwaysLoad, and an ask/deny tool policy; allow is not honoured for sdk servers, so Viber answers `can_use_tool`).
/// - The CLI sends `control_request {subtype: "mcp_message", server_name, message: <JSON-RPC>}` for every MCP message,
///   notifications included, and expects `control_response` success with `{mcp_response: <JSON-RPC>}`.
/// - Tools appear as `mcp__<server>__<tool>` and are deferred behind ToolSearch unless `alwaysLoad` is set.
public enum SdkMcp {
    public struct Incoming: Equatable {
        public var requestID: String
        public var server: String
        public var message: JSON

        public init?(_ controlRequest: JSON) {
            guard controlRequest["type"]?.string == "control_request",
                  let request = controlRequest["request"], request["subtype"]?.string == "mcp_message",
                  let requestID = controlRequest["request_id"]?.string,
                  let server = request["server_name"]?.string, let message = request["message"] else { return nil }
            self.requestID = requestID; self.server = server; self.message = message
        }
    }

    public static func reply(requestID: String, response: JSON) -> JSON {
        ChatTranscript.controlSuccess(requestID, ["mcp_response": response])
    }

    /// Fields to merge into the `initialize` control request.
    public static func initializeFields(_ servers: [String: JSON]) -> [String: JSON] {
        ["sdkMcpServers": .array(servers.keys.sorted().map { .string($0) }), "sdkMcpServerConfigs": .object(servers)]
    }
}

public struct McpTool: Equatable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSON
    public var readOnly: Bool

    public init(name: String, description: String, inputSchema: JSON, readOnly: Bool = false) {
        self.name = name; self.description = description; self.inputSchema = inputSchema; self.readOnly = readOnly
    }

    var json: JSON {
        ["name": .string(name), "description": .string(description), "inputSchema": inputSchema,
         "annotations": ["readOnlyHint": .bool(readOnly)]]
    }
}

public enum McpContent: Equatable, Sendable {
    case text(String)
    case image(Data, mimeType: String)

    var json: JSON {
        switch self {
        case .text(let text): return ["type": "text", "text": .string(text)]
        case .image(let data, let mime): return ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mime)]
        }
    }
}

public struct McpToolResult: Equatable, Sendable {
    public var content: [McpContent]
    public var isError: Bool

    public init(_ content: [McpContent], isError: Bool = false) { self.content = content; self.isError = isError }
    public static func error(_ text: String) -> McpToolResult { McpToolResult([.text(text)], isError: true) }

    public var text: String {
        content.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined(separator: "\n")
    }
}

/// The JSON-RPC side of one in-process MCP server. Tool calls are handed to `call`.
public struct SdkMcpServer: Sendable {
    public var name: String
    public var version: String
    public var instructions: String?
    public var tools: [McpTool]

    public init(name: String, version: String = "1.0", instructions: String? = nil, tools: [McpTool]) {
        self.name = name; self.version = version; self.instructions = instructions; self.tools = tools
    }

    /// The JSON-RPC reply for `message`. Notifications get an empty result, which is what the CLI expects back.
    @MainActor
    public func handle(_ message: JSON, call: (String, JSON) async -> McpToolResult) async -> JSON {
        let id = message["id"]
        func result(_ value: JSON) -> JSON { ["jsonrpc": "2.0", "id": id ?? 0, "result": value] }
        guard let id, id != .null else { return ["jsonrpc": "2.0", "id": 0, "result": [:]] }
        switch message["method"]?.string {
        case "initialize":
            var body: [String: JSON] = [
                "protocolVersion": message["params"]?["protocolVersion"] ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": .string(name), "version": .string(version)],
            ]
            if let instructions { body["instructions"] = .string(instructions) }
            return result(.object(body))
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": .array(tools.map(\.json))])
        case "tools/call":
            let toolName = message["params"]?["name"]?.string ?? ""
            let outcome: McpToolResult
            if tools.contains(where: { $0.name == toolName }) {
                outcome = await call(toolName, message["params"]?["arguments"] ?? [:])
            } else {
                outcome = .error("Unknown tool \(toolName).")
            }
            var body: [String: JSON] = ["content": .array(outcome.content.map(\.json))]
            if outcome.isError { body["isError"] = true }
            return result(.object(body))
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("Method not found: \(message["method"]?.string ?? "")")]]
        }
    }
}
