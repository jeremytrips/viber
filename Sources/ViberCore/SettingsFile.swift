import Foundation

/// How long a settings change lasts, and which Claude Code settings layer it lands in.
public enum SettingsScope: String, CaseIterable, Codable, Sendable, Identifiable {
    case session, projectLocal, projectShared, user

    public var id: String { rawValue }

    public init?(source: String) {
        switch source {
        case "flagSettings": self = .session
        case "localSettings": self = .projectLocal
        case "projectSettings": self = .projectShared
        case "userSettings": self = .user
        default: return nil
        }
    }

    public var label: String {
        switch self {
        case .session: return "This session"
        case .projectLocal: return "This project, just me"
        case .projectShared: return "This project, shared"
        case .user: return "All projects"
        }
    }

    public var detail: String {
        switch self {
        case .session: return "Until the session closes"
        case .projectLocal: return ".claude/settings.local.json, not committed"
        case .projectShared: return ".claude/settings.json, committed with the repo"
        case .user: return "~/.claude/settings.json, for sessions started from now on"
        }
    }
}

/// A permission rule Viber adds or removes: `behavior` is allow, ask or deny; `rule` is like `Bash(npm test:*)`.
public struct RuleEdit: Codable, Equatable, Hashable, Sendable {
    public var behavior: String
    public var rule: String
    public init(behavior: String, rule: String) { self.behavior = behavior; self.rule = rule }

    public static let behaviors = ["allow", "ask", "deny"]
}

/// A server configured for all projects in ~/.claude.json (`claude mcp add --scope user`).
public struct ConfiguredMcpServer: Equatable, Sendable, Identifiable {
    public var name: String
    public var transport: String
    /// The command line, or the URL.
    public var target: String
    public var id: String { name }
}

public struct SettingsFileError: LocalizedError {
    public var errorDescription: String?
}

/// Reads and edits Claude Code settings files, keeping every key Viber does not touch.
public enum SettingsFile {
    public static var user: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// Claude Code's own state file, which holds user-scope MCP servers.
    public static var userConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    public static func mcpServers(in url: URL) -> [ConfiguredMcpServer] {
        guard let servers = (try? read(url))?["mcpServers"] as? [String: Any] else { return [] }
        return servers.keys.sorted().compactMap { name in
            guard let config = servers[name] as? [String: Any] else { return nil }
            let transport = config["type"] as? String ?? (config["url"] != nil ? "http" : "stdio")
            let command = ([config["command"] as? String] + ((config["args"] as? [Any]) ?? []).map { $0 as? String })
                .compactMap { $0 }.joined(separator: " ")
            return ConfiguredMcpServer(name: name, transport: transport, target: config["url"] as? String ?? command)
        }
    }

    /// `claude mcp add` for all projects. A stdio command line is split on spaces.
    public static func mcpAddArguments(name: String, transport: String, target: String) -> [String] {
        let base = ["mcp", "add", "--scope", "user"]
        if transport == "stdio" {
            return base + [name, "--"] + target.split(separator: " ").map(String.init)
        }
        return base + ["--transport", transport, name, target]
    }

    /// The environment for `claude mcp`, aimed at ~/.claude.json even when Viber was started from a clauth shell.
    public static var mcpEnvironment: [String: String] {
        var env = Executables.environment()
        env["CLAUDE_CONFIG_DIR"] = nil
        return env
    }

    public static func url(_ scope: SettingsScope, cwd: String) -> URL? {
        let project = URL(fileURLWithPath: cwd).appendingPathComponent(".claude")
        switch scope {
        case .session: return nil
        case .projectLocal: return project.appendingPathComponent("settings.local.json")
        case .projectShared: return project.appendingPathComponent("settings.json")
        case .user: return user
        }
    }

    /// The file's top-level object; a missing file is empty. Invalid JSON throws, so it is never overwritten.
    public static func read(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        if data.allSatisfy({ $0 == 32 || $0 == 10 || $0 == 13 || $0 == 9 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SettingsFileError(errorDescription: "\(url.path) is not valid JSON, so Viber left it alone.")
        }
        return object
    }

    public static func rules(in url: URL) -> [RuleEdit] {
        let permissions = ((try? read(url))?["permissions"] as? [String: Any]) ?? [:]
        return RuleEdit.behaviors.flatMap { behavior in
            ((permissions[behavior] as? [Any]) ?? []).compactMap { $0 as? String }.map { RuleEdit(behavior: behavior, rule: $0) }
        }
    }

    public static func hooks(in url: URL, source: String) -> [HookEntry] {
        guard let hooks = (try? read(url))?["hooks"] else { return [] }
        return HookEntry.parseSettings(JSON(any: hooks), source: source)
    }

    public static func addRule(_ edit: RuleEdit, to url: URL) throws {
        try update(url) { object in
            var permissions = (object["permissions"] as? [String: Any]) ?? [:]
            var list = ((permissions[edit.behavior] as? [Any]) ?? []).compactMap { $0 as? String }
            guard !list.contains(edit.rule) else { return }
            list.append(edit.rule)
            permissions[edit.behavior] = list
            object["permissions"] = permissions
        }
    }

    public static func removeRule(_ edit: RuleEdit, from url: URL) throws {
        try update(url) { object in
            guard var permissions = object["permissions"] as? [String: Any],
                  let list = permissions[edit.behavior] as? [Any] else { return }
            permissions[edit.behavior] = list.filter { ($0 as? String) != edit.rule }
            object["permissions"] = permissions
        }
    }

    /// Sets or clears (nil) one key inside a top-level object, like `modelSettings.<model>.effortLevel`.
    public static func set(_ value: String?, at path: [String], in url: URL) throws {
        guard !path.isEmpty else { return }
        try update(url) { object in object = setting(object, path[...], value) }
    }

    private static func setting(_ object: [String: Any], _ path: ArraySlice<String>, _ value: String?) -> [String: Any] {
        var object = object
        guard let key = path.first else { return object }
        if path.count == 1 {
            object[key] = value
        } else {
            let child = setting((object[key] as? [String: Any]) ?? [:], path.dropFirst(), value)
            object[key] = child.isEmpty ? nil : child
        }
        return object
    }

    /// The `permissions` value for the session layer (`apply_flag_settings`). Every list is present so removals clear.
    public static func permissionsJSON(_ edits: [RuleEdit]) -> JSON {
        .object(Dictionary(uniqueKeysWithValues: RuleEdit.behaviors.map { behavior in
            (behavior, JSON.array(edits.filter { $0.behavior == behavior }.map { .string($0.rule) }))
        }))
    }

    /// Keeps a new `.claude/settings.local.json` out of git, through the repo's own exclude file.
    public static func ensureIgnored(_ url: URL, cwd: String) {
        let check = Shell.run("git", ["check-ignore", "-q", url.path], cwd: cwd)
        guard check.status == 1 else { return } // 0: ignored already; 128: not a repo
        let exclude = Shell.run("git", ["rev-parse", "--git-path", "info/exclude"], cwd: cwd)
        guard exclude.ok, !exclude.output.isEmpty else { return }
        let path = exclude.output.hasPrefix("/") ? exclude.output : (cwd as NSString).appendingPathComponent(exclude.output)
        let line = "**/.claude/settings.local.json"
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        guard !existing.split(separator: "\n").contains(Substring(line)) else { return }
        let text = existing + (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + line + "\n"
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func update(_ url: URL, _ change: (inout [String: Any]) -> Void) throws {
        // Write through symlinks (dotfile managers link ~/.claude/settings.json) instead of replacing them.
        let target = url.resolvingSymlinksInPath()
        var object = try read(target)
        change(&object)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: target, options: .atomic)
    }
}
