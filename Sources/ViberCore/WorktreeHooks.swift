import Darwin
import Foundation

/// Claude Code's two worktree hook events. A `WorktreeCreate` hook replaces `git worktree add`;
/// a `WorktreeRemove` hook removes a worktree that a `WorktreeCreate` hook made.
public enum WorktreeHookEvent: String, Sendable {
    case create = "WorktreeCreate"
    case remove = "WorktreeRemove"
}

/// One command hook from a settings file, as Claude Code would run it.
public struct HookCommand: Equatable, Sendable {
    /// Shell form: a command line for `/bin/sh -c`. Exec form (with `args`): the program to run.
    public var command: String
    public var args: [String]?
    /// Seconds, from the hook's `timeout`; nil uses Claude Code's default.
    public var timeout: Double?
    /// The settings file the hook comes from.
    public var source: String

    public init(command: String, args: [String]? = nil, timeout: Double? = nil, source: String) {
        self.command = command; self.args = args; self.timeout = timeout; self.source = source
    }

    /// Claude Code's default for command hooks: 600 seconds.
    public static let defaultTimeout: Double = 600
    public var effectiveTimeout: Double { timeout.map { max($0, 1) } ?? Self.defaultTimeout }
    public var display: String { ([command] + (args ?? [])).joined(separator: " ") }
}

public struct HookSettingsFile: Equatable, Sendable {
    public var url: URL
    /// Managed (policy) settings can't be turned off by the user's own files.
    public var managed: Bool
}

/// Finds and runs the worktree hooks Claude Code would run for a session started in a folder.
public enum WorktreeHooks {
    // MARK: Which settings files

    /// macOS's managed settings: `managed-settings.json` and the drop-in folder beside it.
    public static var managedDirectory = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode")
    /// Where `~/.claude/settings.json` is looked for. Like the rest of Viber's settings screens this is the plain
    /// home folder, also for Viber's accounts (whose folders link to it). Tests point it elsewhere.
    public static var userHome = FileManager.default.homeDirectoryForCurrentUser

    /// The settings files Claude Code reads hooks from for a session in `folder`, lowest precedence first:
    /// user, the folder's `.claude/settings.json`, then `.claude/settings.local.json` at the repository root
    /// (the main checkout's, for a worktree) and, if it differs, the older copy in the folder, then managed.
    public static func settingsFiles(folder: String, home: URL = userHome, managed: URL = managedDirectory) -> [HookSettingsFile] {
        let folderURL = URL(fileURLWithPath: folder).standardizedFileURL
        var files = [HookSettingsFile(url: home.appendingPathComponent(".claude/settings.json"), managed: false),
                     HookSettingsFile(url: folderURL.appendingPathComponent(".claude/settings.json"), managed: false)]
        let folderLocal = folderURL.appendingPathComponent(".claude/settings.local.json")
        if let root = localSettingsRoot(folder: folder, home: home), root.path != folderURL.path {
            // Where both set the same key, the root's value applies, so it comes last.
            files.append(HookSettingsFile(url: folderLocal, managed: false))
            files.append(HookSettingsFile(url: root.appendingPathComponent(".claude/settings.local.json"), managed: false))
        } else {
            files.append(HookSettingsFile(url: folderLocal, managed: false))
        }
        files.append(HookSettingsFile(url: managed.appendingPathComponent("managed-settings.json"), managed: true))
        let dropIns = (try? FileManager.default.contentsOfDirectory(at: managed.appendingPathComponent("managed-settings.d"),
                                                                     includingPropertiesForKeys: nil)) ?? []
        for url in dropIns.filter({ $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            files.append(HookSettingsFile(url: url, managed: true))
        }
        return files
    }

    /// The main checkout's root, where Claude Code keeps `.claude/settings.local.json` for every folder of a
    /// repository. Nil (the folder's own file applies) outside a repository, when the root is the home folder,
    /// or when the root, its `.git` or `.claude` isn't owned by this user.
    static func localSettingsRoot(folder: String, home: URL) -> URL? {
        guard let root = mainCheckout(folder) else { return nil }
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        if rootURL.path == home.standardizedFileURL.path { return nil }
        let me = getuid()
        func owned(_ path: String, required: Bool) -> Bool {
            var info = stat()
            guard lstat(path, &info) == 0 else { return !required }
            return info.st_uid == me
        }
        guard owned(rootURL.path, required: true), owned(rootURL.appendingPathComponent(".git").path, required: true),
              owned(rootURL.appendingPathComponent(".claude").path, required: false) else { return nil }
        return rootURL
    }

    /// The main checkout of the repository `folder` is in: its own top level, or for a linked worktree,
    /// the checkout whose `.git` directory the worktree shares.
    public static func mainCheckout(_ folder: String) -> String? {
        let common = Shell.run("git", ["-C", folder, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard common.ok, !common.output.isEmpty else { return nil }
        let dir = URL(fileURLWithPath: common.output).standardizedFileURL
        if dir.lastPathComponent == ".git" { return dir.deletingLastPathComponent().path }
        return Worktree.repoRoot(folder)
    }

    // MARK: Which hooks

    public struct Unsupported: Error, LocalizedError, Equatable {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// The command hooks for `event` in a session started in `folder`. Throws when a hook is configured that
    /// Viber can't run in Claude Code's place (an HTTP or MCP tool hook), rather than quietly doing something else.
    /// Blocking (reads files and runs git): call it off the main thread.
    public static func hooks(_ event: WorktreeHookEvent, folder: String) throws -> [HookCommand] {
        try hooks(event, files: settingsFiles(folder: folder))
    }

    public static func hooks(_ event: WorktreeHookEvent, files: [HookSettingsFile]) throws -> [HookCommand] {
        var managedOnly = false
        var userDisabled = false
        var collected: [(hook: HookCommand, managed: Bool)] = []
        var unsupported: [(what: String, managed: Bool)] = []
        for file in files {
            guard let settings = try? SettingsFile.read(file.url), !settings.isEmpty else { continue }
            if file.managed {
                if settings["disableAllHooks"] as? Bool == true { return [] }
                if settings["allowManagedHooksOnly"] as? Bool == true { managedOnly = true }
            } else if let disabled = settings["disableAllHooks"] as? Bool {
                // A scalar: the last (highest-precedence) file that sets it wins.
                userDisabled = disabled
            }
            let parsed = parse(event, hooks: settings["hooks"], source: file.url.path)
            collected += parsed.commands.map { ($0, file.managed) }
            unsupported += parsed.unsupported.map { ("\($0) in \(file.url.path)", file.managed) }
        }
        let runs = { (managed: Bool) in managed || (!managedOnly && !userDisabled) }
        let allowed = collected.filter { runs($0.managed) }
        let blocked = unsupported.filter { runs($0.managed) }.map(\.what)
        if !blocked.isEmpty {
            throw Unsupported(message: "\(event.rawValue) is configured with a hook Viber can't run: "
                              + blocked.joined(separator: ", ") + ". Viber runs command hooks only.")
        }
        // The same command configured in two files runs once.
        var seen = Set<String>()
        return allowed.map(\.hook).filter { seen.insert(([$0.command] + ($0.args ?? [])).joined(separator: "\u{0}")).inserted }
    }

    /// The `hooks` object of one settings file: event → [{matcher, hooks: [{type, command, args, timeout}]}].
    /// Worktree events have no matcher, so every group applies. Prompt and agent hooks don't run for them
    /// in Claude Code either; HTTP and MCP tool hooks do, so they are reported as unsupported.
    public static func parse(_ event: WorktreeHookEvent, hooks: Any?, source: String) -> (commands: [HookCommand], unsupported: [String]) {
        guard let events = hooks as? [String: Any], let groups = events[event.rawValue] as? [Any] else { return ([], []) }
        var commands: [HookCommand] = []
        var unsupported: [String] = []
        for group in groups.compactMap({ $0 as? [String: Any] }) {
            for hook in (group["hooks"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
                let type = hook["type"] as? String
                switch type {
                case "command":
                    guard let command = hook["command"] as? String, !command.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    if let shell = hook["shell"] as? String, shell == "powershell" { unsupported.append("a PowerShell command hook"); continue }
                    let args = (hook["args"] as? [Any])?.compactMap { $0 as? String }
                    let timeout = (hook["timeout"] as? NSNumber)?.doubleValue
                    commands.append(HookCommand(command: command, args: args, timeout: timeout, source: source))
                case "http", "mcp_tool":
                    unsupported.append("a \(type!) hook")
                default:
                    continue
                }
            }
        }
        return (commands, unsupported)
    }

    // MARK: Running

    /// The JSON a hook reads on stdin. Viber runs the hook before the session's Claude process exists,
    /// so `session_id` and `transcript_path` are empty strings.
    public static func input(_ event: WorktreeHookEvent, cwd: String, name: String? = nil, worktreePath: String? = nil,
                             permissionMode: String? = nil) -> Data {
        var object: [String: Any] = ["session_id": "", "transcript_path": "", "cwd": cwd, "hook_event_name": event.rawValue]
        if let name { object["name"] = name }
        if let worktreePath { object["worktree_path"] = worktreePath }
        if let permissionMode { object["permission_mode"] = permissionMode }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return data + Data("\n".utf8)
    }

    /// Runs one hook the way Claude Code does: shell form through `/bin/sh -c`, exec form directly, in `folder`
    /// with `CLAUDE_PROJECT_DIR` set to it, the input on stdin, and the hook's timeout.
    public static func run(_ hook: HookCommand, input: Data, folder: String, environment: [String: String] = Executables.environment(),
                           onOutput: (@Sendable (String) -> Void)? = nil) async -> SubprocessResult {
        var env = environment
        env["CLAUDE_PROJECT_DIR"] = folder
        if let args = hook.args {
            let expand = { (s: String) in s.replacingOccurrences(of: "${CLAUDE_PROJECT_DIR}", with: folder) }
            return await Subprocess.run(expand(hook.command), args.map(expand), cwd: folder, environment: env, input: input,
                                        timeout: hook.effectiveTimeout, onOutput: onOutput)
        }
        return await Subprocess.run("/bin/sh", ["-c", hook.command], cwd: folder, environment: env, input: input,
                                    timeout: hook.effectiveTimeout, onOutput: onOutput)
    }

    /// Why a hook run failed, in a sentence, with the end of its output.
    public static func failure(_ hook: HookCommand, _ result: SubprocessResult, event: WorktreeHookEvent) -> String {
        let how: String
        if result.failedToStart { how = "could not start" }
        else if result.timedOut { how = "timed out after \(Int(hook.effectiveTimeout)) seconds" }
        else if result.cancelled { how = "was stopped" }
        else { how = "exited with status \(result.status)" }
        let tail = String(result.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(1500))
        return "The \(event.rawValue) hook \(how): \(hook.display)" + (tail.isEmpty ? "" : "\n\n\(tail)")
    }

    // MARK: The worktree path a WorktreeCreate hook prints

    public struct PathError: Error, LocalizedError, Equatable {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// The last non-empty line of stdout, with terminal escape codes removed: what Claude Code reads as the path.
    public static func printedPath(_ stdout: String) -> String? {
        let plain = stripANSI(stdout)
        return plain.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }

    static func stripANSI(_ text: String) -> String {
        // CSI sequences (colours, cursor moves) and OSC sequences (titles, links).
        let pattern = "\u{1B}\\[[0-?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|\u{1B}[@-Z\\\\-_]"
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    /// Checks the path a hook printed the way Claude Code does: a relative path is resolved against the folder the
    /// hook ran in; an absolute one may not contain `.` or `..`; no part of it below the repository may be a symlink;
    /// it must be an existing directory; and it may not be (or contain) the main checkout.
    public static func validateWorktreePath(_ printed: String, cwd: String, repo: String) throws -> String {
        let path: String
        if printed.hasPrefix("/") {
            if printed.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) {
                throw PathError(message: "The WorktreeCreate hook printed a path with . or .. in it (\(printed)). It must print the normalized absolute path of the directory it made.")
            }
            path = URL(fileURLWithPath: printed).standardizedFileURL.path
        } else {
            path = URL(fileURLWithPath: printed, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL.path
        }
        let repoPath = URL(fileURLWithPath: repo).standardizedFileURL.path
        if path == repoPath || repoPath.hasPrefix(path == "/" ? "/" : path + "/") {
            throw PathError(message: "The WorktreeCreate hook printed \(path), which is the project's own checkout or contains it, not a new worktree.")
        }
        if path.hasPrefix(repoPath + "/"), let link = symlinkComponent(of: path, below: repoPath) {
            throw PathError(message: "The WorktreeCreate hook's worktree path goes through a symlink (\(link)) inside the repository, so Viber won't use it.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PathError(message: "The WorktreeCreate hook printed \(path), which is not a directory. The hook must create the worktree, then print its path as the last line of its output.")
        }
        return path
    }

    /// The first component of `path` below `root` that is a symlink.
    static func symlinkComponent(of path: String, below root: String) -> String? {
        var current = root
        for component in path.dropFirst(root.count).split(separator: "/") {
            current += "/" + component
            var info = stat()
            if lstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { return current }
        }
        return nil
    }
}
