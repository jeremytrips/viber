import Foundation

/// One-line descriptions of tool calls, for chat rows and notifications.
public enum ToolSummary {
    public static func summary(name: String, input: JSON) -> String {
        func short(_ path: String) -> String {
            let parts = path.split(separator: "/")
            return parts.suffix(2).joined(separator: "/")
        }
        switch name {
        case "TaskCreate": if let subject = input["subject"]?.string { return firstLine(subject, limit: 120) }
        case "TaskUpdate":
            if let id = input["taskId"]?.string {
                return "#\(id)" + (input["status"]?.string.map { " → \($0.replacingOccurrences(of: "_", with: " "))" } ?? "")
            }
        case "TodoWrite": if let todos = input["todos"]?.array { return "\(todos.count) items" }
        default: break
        }
        if name == DeviceToolbox.toolPrefix + "set" {
            var parts: [String] = []
            if let appearance = input["appearance"]?.string { parts.append(appearance) }
            if let latitude = input["latitude"]?.double, let longitude = input["longitude"]?.double { parts.append("\(latitude), \(longitude)") }
            for change in PermissionChange.allCases {
                guard let names = input[change.rawValue]?.array?.compactMap(\.string) ?? input[change.rawValue]?.string.map({ [$0] }), !names.isEmpty else { continue }
                parts.append((change == .grant ? "" : "\(change.rawValue) ") + names.joined(separator: ", "))
            }
            if let bar = input["status_bar"]?.string { parts.append("\(bar) status bar") }
            return parts.joined(separator: " · ")
        }
        if name.hasPrefix(DeviceToolbox.toolPrefix) {
            if let device = input["device"]?.string { return device }
            if let button = input["button"]?.string { return button.replacingOccurrences(of: "_", with: " ") }
            if let app = input["app_id"]?.string { return app }
            if let path = input["path"]?.string { return short(path) }
            if let direction = input["direction"]?.string { return direction }
            if let x = input["x"]?.double, let y = input["y"]?.double { return "(\(Int(x)),\(Int(y)))" }
            if let text = input["text"]?.string ?? input["field"]?.string { return firstLine(text, limit: 120) }
        }
        if let path = input["file_path"]?.string ?? input["notebook_path"]?.string { return short(path) }
        if let command = input["command"]?.string { return firstLine(command, limit: 120) }
        if let pattern = input["pattern"]?.string {
            let scope = input["path"]?.string.map { " in \(short($0))" } ?? ""
            return "\(pattern)\(scope)"
        }
        if let url = input["url"]?.string { return url }
        if let selector = input["selector"]?.string { return selector }
        if let text = input["text"]?.string { return firstLine(text, limit: 120) }
        if let ref = input["ref"]?.string { return ref }
        if let expression = input["expression"]?.string { return firstLine(expression, limit: 120) }
        if let query = input["query"]?.string { return firstLine(query, limit: 120) }
        if let description = input["description"]?.string { return firstLine(description, limit: 120) }
        if let prompt = input["prompt"]?.string { return firstLine(prompt, limit: 120) }
        return ""
    }

    /// How a tool is named in the chat: "Preview · click" and "Device · tap" for Viber's own tools, "server · tool" for other MCP tools.
    public static func displayName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return name }
        let tool = parts.dropFirst().joined(separator: "__")
        if parts[0] == "viber", tool.hasPrefix("preview_") { return "Preview · " + tool.dropFirst("preview_".count) }
        if parts[0] == "viber", tool.hasPrefix("device_") { return "Device · " + tool.dropFirst("device_".count).replacingOccurrences(of: "_", with: " ") }
        return "\(parts[0]) · \(tool)"
    }

    /// Diff lines for Edit/MultiEdit/Write inputs: ("-"|"+"|" ", text).
    public static func diff(name: String, input: JSON, limit: Int = 60) -> [(sign: Character, text: String)] {
        var lines: [(Character, String)] = []
        func add(_ old: String, _ new: String) {
            lines += old.split(separator: "\n", omittingEmptySubsequences: false).map { ("-", String($0)) }
            lines += new.split(separator: "\n", omittingEmptySubsequences: false).map { ("+", String($0)) }
        }
        switch name {
        case "Edit":
            add(input["old_string"]?.string ?? "", input["new_string"]?.string ?? "")
        case "MultiEdit":
            for edit in input["edits"]?.array ?? [] { add(edit["old_string"]?.string ?? "", edit["new_string"]?.string ?? "") }
        case "Write":
            lines = (input["content"]?.string ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { ("+", String($0)) }
        default:
            return []
        }
        if lines.count > limit { lines = Array(lines.prefix(limit)) + [(" ", "… \(lines.count - limit) more lines")] }
        return lines
    }

    /// "+38 −71" style counts for an edit.
    public static func counts(name: String, input: JSON) -> String? {
        let d = diff(name: name, input: input, limit: .max)
        guard !d.isEmpty else { return nil }
        return "+\(d.filter { $0.sign == "+" }.count) −\(d.filter { $0.sign == "-" }.count)"
    }

    static func firstLine(_ s: String, limit: Int) -> String {
        let line = s.split(separator: "\n").first.map(String.init) ?? s
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }
}
