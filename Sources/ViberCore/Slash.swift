import Foundation

/// Where a message typed in the composer goes. Skills and custom commands go to the CLI as text;
/// commands that only exist in the interactive terminal UI are handled by Viber.
public enum SlashAction: Equatable {
    case send(String)
    case setMode(String, then: String?)
    case setModel(String)
    case pickModel
    case clear
    case resume
    case showCost
    /// Terminal panels (`/mcp`, `/context`, …) open the session's settings sheet on a tab.
    case openSettings(SettingsTab)
}

public enum SlashRouter {
    /// Commands Viber adds on top of the CLI's own list.
    public static let builtins: [SlashCommand] = [
        SlashCommand(name: "plan", description: "Plan first; edit only after you approve"),
        SlashCommand(name: "model", description: "Switch model", argumentHint: "<model>"),
        SlashCommand(name: "clear", description: "Start a fresh conversation"),
        SlashCommand(name: "resume", description: "Resume a past session"),
        SlashCommand(name: "cost", description: "Show tokens and cost for this session"),
        SlashCommand(name: "mcp", description: "MCP servers: status, sign in, enable or disable", argumentHint: "[reconnect|enable|disable <server>]"),
        SlashCommand(name: "context", description: "Context window usage, and compact"),
        SlashCommand(name: "permissions", description: "Permission rules for this session and project"),
        SlashCommand(name: "hooks", description: "Hooks that run in this session"),
        SlashCommand(name: "settings", description: "Session settings: model, effort, output style")
    ]

    public static func route(_ raw: String, commands: [SlashCommand]) -> SlashAction {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/"), text.count > 1 else { return .send(text) }
        let parts = text.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let name = String(parts.first ?? "")
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        switch name {
        case "plan": return .setMode("plan", then: rest.isEmpty ? nil : rest)
        case "model": return rest.isEmpty ? .pickModel : .setModel(rest)
        case "clear": return .clear
        case "resume": return .resume
        case "cost": return .showCost
        case "context", "usage": return .openSettings(.context)
        case "permissions", "allowed-tools": return .openSettings(.permissions)
        case "hooks": return .openSettings(.hooks)
        case "settings": return .openSettings(.model)
        // With arguments these run headless in the CLI (`/mcp reconnect all`, `/effort high`, `/config key=value`).
        case "mcp" where rest.isEmpty: return .openSettings(.mcp)
        case "config", "effort", "output-style":
            if rest.isEmpty { return .openSettings(.model) }
        default: break
        }
        if commands.contains(where: { $0.name == name }) { return .send(text) }
        // Plugin skills are namespaced ("viber:cleanup"); let the short name work too.
        if let match = commands.first(where: { $0.name.hasSuffix(":\(name)") }) {
            return .send("/\(match.name)" + (rest.isEmpty ? "" : " \(rest)"))
        }
        return .send(text)
    }

    /// Suggestions for the "/" menu, short names first, without duplicates.
    public static func suggestions(for raw: String, commands: [SlashCommand]) -> [SlashCommand] {
        guard raw.hasPrefix("/"), !raw.contains(" ") else { return [] }
        let query = raw.dropFirst().lowercased()
        var seen = Set<String>()
        var all: [SlashCommand] = []
        for command in builtins + commands {
            let short = command.name.split(separator: ":").last.map(String.init) ?? command.name
            let display = command.name.hasPrefix("viber:") ? short : command.name
            guard seen.insert(display).inserted else { continue }
            all.append(SlashCommand(name: display, description: command.description, argumentHint: command.argumentHint))
        }
        let prefix = all.filter { $0.name.lowercased().hasPrefix(query) }
        let contains = all.filter { !$0.name.lowercased().hasPrefix(query) && $0.name.lowercased().contains(query) }
        return prefix + contains
    }
}
