import Foundation

/// An element the user picked in the preview, attached to their next message.
public struct ElementReference: Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var url: String
    public var selector: String
    public var tag: String
    public var text: String
    public var html: String
    public var rect: (x: Int, y: Int, width: Int, height: Int)
    public var styles: [(String, String)]
    /// Innermost first, e.g. ["Counter", "App"].
    public var components: [String]
    /// Source location as the framework reported it, made relative to the project when possible.
    public var file: String?
    public var line: Int?

    public static func == (a: ElementReference, b: ElementReference) -> Bool { a.id == b.id }

    /// Decodes what the picker script posts. Paths are made relative to `cwd`.
    public init?(payload: JSON, cwd: String) {
        guard let selector = payload["selector"]?.string, !selector.isEmpty else { return nil }
        self.selector = selector
        url = payload["url"]?.string ?? ""
        tag = payload["tag"]?.string ?? "element"
        text = Self.squash(payload["text"]?.string ?? "", limit: 120)
        html = payload["html"]?.string ?? ""
        if html.count > 600 { html = String(html.prefix(600)) + "…" }
        let r = payload["rect"]
        rect = (r?["x"]?.int ?? 0, r?["y"]?.int ?? 0, r?["width"]?.int ?? 0, r?["height"]?.int ?? 0)
        styles = (payload["styles"]?.object ?? [:]).compactMap { key, value in value.string.map { (key, $0) } }.sorted { $0.0 < $1.0 }
        components = (payload["components"]?.array ?? []).compactMap(\.string)
        file = payload["file"]?.string.flatMap { Self.relativePath($0, cwd: cwd) }
        line = payload["line"]?.int
    }

    /// "src/App.tsx" from "/Users/me/app/src/App.tsx", "http://localhost:5173/src/App.tsx?t=1", or "/@fs/Users/me/app/src/App.tsx".
    public static func relativePath(_ raw: String, cwd: String) -> String? {
        var path = raw
        if let url = URL(string: raw), let scheme = url.scheme, ["http", "https", "webpack", "file"].contains(scheme) {
            path = scheme == "webpack" ? raw.replacingOccurrences(of: #"^webpack://[^/]*/"#, with: "", options: .regularExpression) : url.path
        }
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        if path.hasPrefix("/@fs/") { path = String(path.dropFirst(4)) }
        if path.hasPrefix("./") { path.removeFirst(2) }
        guard !path.isEmpty else { return nil }
        let root = cwd.hasSuffix("/") ? cwd : cwd + "/"
        if path.hasPrefix(root) { return String(path.dropFirst(root.count)) }
        // A path served from the dev server root, like /src/App.tsx, is relative to the project.
        if path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) { return String(path.dropFirst()) }
        return path
    }

    /// Short text for the composer chip: `button "Save" · SaveButton · App.tsx:24`.
    public var label: String {
        var parts = [text.isEmpty ? tag : "\(tag) \"\(Self.squash(text, limit: 32))\""]
        if let component = components.first { parts.append(component) }
        if let file { parts.append(line.map { "\((file as NSString).lastPathComponent):\($0)" } ?? (file as NSString).lastPathComponent) }
        return parts.joined(separator: " · ")
    }

    /// What goes into the message so Claude can find the element in the page and in the code.
    public var block: String {
        var lines = ["<preview-element url=\"\(url)\" selector=\"\(selector.replacingOccurrences(of: "\"", with: "'"))\">", html]
        let location = file.map { file in line.map { "\(file):\($0)" } ?? file }
        if !components.isEmpty {
            lines.append("component: \(components.joined(separator: " < "))" + (location.map { " (\($0))" } ?? ""))
        } else if let location {
            lines.append("source: \(location)")
        }
        var box = "box: \(rect.width)×\(rect.height) at \(rect.x),\(rect.y)"
        if !styles.isEmpty { box += " · " + styles.map { "\($0.0): \($0.1)" }.joined(separator: "; ") }
        lines.append(box)
        lines.append("</preview-element>")
        return lines.joined(separator: "\n")
    }

    /// The message to send: the user's words, then the blocks for the elements they picked.
    public static func compose(_ text: String, with references: [ElementReference]) -> String {
        guard !references.isEmpty else { return text }
        return ((text.isEmpty ? [] : [text]) + references.map(\.block)).joined(separator: "\n\n")
    }

    /// A sent message as the chat shows it: each element block shrinks to one line.
    public static func displayText(_ message: String) -> String {
        guard message.contains("<preview-element") else { return message }
        return message.replacingOccurrences(of: #"<preview-element url="[^"]*" selector="([^"]*)">[\s\S]*?</preview-element>"#,
                                            with: "◎ $1", options: .regularExpression)
    }

    static func squash(_ s: String, limit: Int) -> String {
        let one = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return one.count > limit ? String(one.prefix(limit)) + "…" : one
    }
}
