import Foundation

/// One-line descriptions of tool calls, for chat rows and notifications.
public enum ToolSummary {
    public static func summary(name: String, input: JSON) -> String {
        func short(_ path: String) -> String {
            let parts = path.split(separator: "/")
            return parts.suffix(2).joined(separator: "/")
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
        if name == "TodoWrite", let todos = input["todos"]?.array { return "\(todos.count) items" }
        return ""
    }

    /// How a tool is named in the chat: "Preview · click" for Viber's preview, "server · tool" for other MCP tools.
    public static func displayName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return name }
        let tool = parts.dropFirst().joined(separator: "__")
        if parts[0] == "viber", tool.hasPrefix("preview_") { return "Preview · " + tool.dropFirst("preview_".count) }
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
