import Foundation

/// How Viber starts one Claude Code session. A nil profile means plain `claude` with its default login.
public struct LaunchSpec: Codable, Equatable {
    public var profile: String?
    public var cwd: String
    public var resume: String?
    public var permissionMode: String?
    public var model: String?
    public var pluginDir: String?
    /// The project note. The CLI records it on a conversation's first request and keeps that version on resume.
    public var appendSystemPrompt: String?

    public init(profile: String?, cwd: String, resume: String? = nil, permissionMode: String? = nil,
                model: String? = nil, pluginDir: String? = nil, appendSystemPrompt: String? = nil) {
        self.profile = profile; self.cwd = cwd; self.resume = resume
        self.permissionMode = permissionMode; self.model = model; self.pluginDir = pluginDir
        self.appendSystemPrompt = appendSystemPrompt
    }

    /// The `claude` arguments for a headless session that speaks the Agent SDK protocol on stdio.
    /// Replayed user messages carry the IDs that rewinding files needs.
    public var claudeArguments: [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--permission-prompt-tool", "stdio", "--replay-user-messages"]
        if let resume { args += ["--resume", resume] }
        if let permissionMode { args += ["--permission-mode", permissionMode] }
        if let model { args += ["--model", model] }
        if let pluginDir { args += ["--plugin-dir", pluginDir] }
        if let appendSystemPrompt { args += ["--append-system-prompt", appendSystemPrompt] }
        return args
    }

    /// Executable name and full argument list. clauth forwards everything after `--` to claude untouched.
    public var command: (tool: String, arguments: [String]) {
        if let profile { return ("clauth", ["start", profile, "--"] + claudeArguments) }
        return ("claude", claudeArguments)
    }
}

public enum Executables {
    /// GUI apps start with a minimal PATH, so look where CLI installers usually put things.
    public static var searchPath: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin",
                "\(home)/.npm-global/bin", "\(home)/.claude/local", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }

    public static func find(_ name: String, extra: [String] = []) -> String? {
        let fm = FileManager.default
        let fromEnv = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in extra + searchPath + fromEnv {
            let path = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Environment for child processes: the user's environment plus the search path, so clauth can find claude.
    public static func environment(adding extraPath: [String] = [], extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        env["PATH"] = (extraPath + searchPath + existing).filter { seen.insert($0).inserted }.joined(separator: ":")
        for (key, value) in extra { env[key] = value }
        return env
    }
}

public struct ShellResult {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var ok: Bool { status == 0 }
    public var output: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public enum Shell {
    /// Run a command to completion. Blocking: call it off the main thread.
    @discardableResult
    public static func run(_ tool: String, _ arguments: [String], cwd: String? = nil, environment: [String: String]? = nil) -> ShellResult {
        guard let path = tool.hasPrefix("/") ? tool : Executables.find(tool) else {
            return ShellResult(status: 127, stdout: "", stderr: "\(tool) not found")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment ?? Executables.environment()
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return ShellResult(status: 126, stdout: "", stderr: error.localizedDescription)
        }
        // Read both pipes before waiting so a full pipe buffer cannot deadlock the child.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return ShellResult(status: process.terminationStatus,
                           stdout: String(decoding: outData, as: UTF8.self),
                           stderr: String(decoding: errData, as: UTF8.self))
    }
}

public enum ViberPaths {
    public static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Viber")
    }
    public static var requests: URL { support.appendingPathComponent("requests") }
    public static var panes: URL { support.appendingPathComponent("panes.json") }
    public static var relays: URL { support.appendingPathComponent("messages.json") }
    public static var notes: URL { support.appendingPathComponent("notes.json") }
    public static var clauthStatus: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clauth/status.json")
    }
    /// Where the CLI stores a session's transcript.
    public static func transcript(sessionID: String, cwd: String) -> URL {
        let slug = cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return Paths.projects.appendingPathComponent(String(slug)).appendingPathComponent("\(sessionID).jsonl")
    }
}
