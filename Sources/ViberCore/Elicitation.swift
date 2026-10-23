import Foundation

/// One input of an MCP elicitation form. MCP limits `requested_schema` to flat properties of primitive types.
public struct ElicitationField: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case text
        case number
        case integer
        case boolean
        /// A string from a fixed list, as (value, label).
        case choice([Option])
        /// An array of strings from a fixed list.
        case multiChoice([Option])
    }

    public struct Option: Equatable, Sendable {
        public var value: String
        public var label: String
    }

    public var name: String
    public var title: String
    public var description: String
    public var kind: Kind
    public var required: Bool
    /// email, uri, date or date-time, for strings.
    public var format: String?
    public var defaultValue: JSON?
    public var id: String { name }

    /// Fields in the order the server listed them. Keys missing from `order` follow, sorted.
    public static func parse(_ schema: JSON?, order: [String] = []) -> [ElicitationField] {
        guard let properties = schema?["properties"]?.object else { return [] }
        let required = Set((schema?["required"]?.array ?? []).compactMap(\.string))
        let names = order.filter { properties[$0] != nil } + properties.keys.filter { !order.contains($0) }.sorted()
        return names.compactMap { name in
            guard let p = properties[name] else { return nil }
            return ElicitationField(name: name, title: p["title"]?.string ?? name, description: p["description"]?.string ?? "",
                                    kind: kind(p), required: required.contains(name), format: p["format"]?.string,
                                    defaultValue: p["default"])
        }
    }

    private static func kind(_ p: JSON) -> Kind {
        switch p["type"]?.string {
        case "boolean": return .boolean
        case "number": return .number
        case "integer": return .integer
        case "array": return .multiChoice(options(p["items"]))
        default:
            let list = options(p)
            return list.isEmpty ? .text : .choice(list)
        }
    }

    /// `enum` (with optional `enumNames`), or `oneOf`/`anyOf` of `{const, title}`.
    private static func options(_ p: JSON?) -> [Option] {
        if let values = p?["enum"]?.array?.compactMap(\.string) {
            let names = p?["enumNames"]?.array?.compactMap(\.string) ?? []
            return values.enumerated().map { Option(value: $1, label: names.indices.contains($0) ? names[$0] : $1) }
        }
        return (p?["oneOf"]?.array ?? p?["anyOf"]?.array ?? []).compactMap { o in
            guard let value = o["const"]?.string else { return nil }
            return Option(value: value, label: o["title"]?.string ?? value)
        }
    }

    /// The JSON value for what the user typed, or nil when it is empty or does not fit the type.
    public func value(from raw: String) -> JSON? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        switch kind {
        case .number: return Double(text).map(JSON.number)
        case .integer: return Int(text).map { .number(Double($0)) }
        case .boolean: return ["true", "yes", "1"].contains(text.lowercased()) ? true : ["false", "no", "0"].contains(text.lowercased()) ? false : nil
        default: return .string(text)
        }
    }

    /// The default as text, for prefilling a text field.
    public var defaultText: String {
        switch defaultValue {
        case .string(let s)?: return s
        case .number(let n)?: return kind == .integer ? String(Int(n)) : String(n)
        default: return ""
        }
    }
}

/// An MCP server asking the user for input (`elicitation` control request): a form, or a page to open.
public struct ElicitationPrompt: Equatable, Sendable {
    public var requestID: String
    public var server: String
    public var message: String
    public var title: String?
    /// "form" or "url".
    public var mode: String
    public var url: URL?
    public var elicitationID: String?
    public var fields: [ElicitationField]
    public var decision: PromptDecision?
    /// URL mode: the server confirmed the page flow finished.
    public var completed = false

    public var isURL: Bool { mode == "url" }
    public var heading: String { title ?? "\(server) needs input" }

    public static func parse(requestID: String, _ request: JSON) -> ElicitationPrompt {
        let server = request["display_name"]?.string ?? request["mcp_server_name"]?.string ?? "MCP server"
        return ElicitationPrompt(requestID: requestID, server: server,
                                 message: request["message"]?.string ?? request["description"]?.string ?? "",
                                 title: request["title"]?.string,
                                 mode: request["mode"]?.string ?? (request["url"]?.string == nil ? "form" : "url"),
                                 url: request["url"]?.string.flatMap(URL.init(string:)),
                                 elicitationID: request["elicitation_id"]?.string,
                                 fields: ElicitationField.parse(request["requested_schema"],
                                                                order: (request["property_order"]?.array ?? []).compactMap(\.string)))
    }

    /// Required fields that have no value yet.
    public func missing(_ values: [String: JSON]) -> [ElicitationField] {
        fields.filter { field in
            guard field.required else { return false }
            switch values[field.name] {
            case nil, .null?: return true
            case .array(let a)?: return a.isEmpty
            default: return false
            }
        }
    }
}
