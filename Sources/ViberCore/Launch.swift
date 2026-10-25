import Foundation

/// How Viber starts one Claude Code session. A nil profile means plain `claude` with its default login.
public struct LaunchSpec: Codable, Equatable {
    public var profile: String?
    public var cwd: String
    public var resume: String?
    public var permissionMode: String?
    public var model: String?
    public var pluginDir: String?

    public init(profile: String?, cwd: String, resume: String? = nil, permissionMode: String? = nil,
                model: String? = nil, pluginDir: String? = nil) {
        self.profile = profile; self.cwd = cwd; self.resume = resume
        self.permissionMode = permissionMode; self.model = model; self.pluginDir = pluginDir
    }

    /// The `claude` arguments for a headless session that speaks the Agent SDK protocol on stdio.
    /// Replayed user messages carry the IDs that rewinding files needs; summarized thinking gives thinking blocks text to show.
    public var claudeArguments: [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--permission-prompt-tool", "stdio", "--replay-user-messages",
                    "--thinking-display", "summarized"]
        if let resume { args += ["--resume", resume] }
        if let permissionMode { args += ["--permission-mode", permissionMode] }
        if let model { args += ["--model", model] }
        if let pluginDir { args += ["--plugin-dir", pluginDir] }
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
    /// Standard output as bytes, for commands that print binary data such as images.
    public var stdoutData = Data()
    public var ok: Bool { status == 0 }
    public var output: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public enum Shell {
    /// Run a command to completion. Blocking: call it off the main thread. `input` is written to its standard input.
    /// With a `timeout` (seconds), the command is stopped when it runs longer and the result has status 124.
    @discardableResult
    public static func run(_ tool: String, _ arguments: [String], cwd: String? = nil, environment: [String: String]? = nil,
                           input: Data? = nil, timeout: TimeInterval? = nil) -> ShellResult {
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
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        do { try process.run() } catch {
            return ShellResult(status: 126, stdout: "", stderr: error.localizedDescription)
        }
        if let stdin, let input {
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        let timedOut = Flag()
        let stopper = timeout.map { seconds in
            let item = DispatchWorkItem {
                guard process.isRunning else { return }
                timedOut.set()
                process.terminate()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
            return item
        }
        // Read both pipes before waiting so a full pipe buffer cannot deadlock the child.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        stopper?.cancel()
        if timedOut.isSet, let timeout {
            return ShellResult(status: 124, stdout: String(decoding: outData, as: UTF8.self),
                               stderr: "\(tool) did not finish within \(Int(timeout)) s", stdoutData: outData)
        }
        return ShellResult(status: process.terminationStatus,
                           stdout: String(decoding: outData, as: UTF8.self),
                           stderr: String(decoding: errData, as: UTF8.self), stdoutData: outData)
    }

    /// `run` on a global queue, so slow commands don't hold a thread of Swift's cooperative pool.
    public static func runAsync(_ tool: String, _ arguments: [String], environment: [String: String]? = nil,
                                input: Data? = nil, timeout: TimeInterval? = nil) async -> ShellResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: run(tool, arguments, environment: environment, input: input, timeout: timeout))
            }
        }
    }

    /// Starts a long-running command without waiting for it. Its output goes to `output`, a file rather than a pipe,
    /// so it never blocks on a full pipe or dies of SIGPIPE when Viber quits.
    public static func spawn(_ tool: String, _ arguments: [String], environment: [String: String]? = nil, output: URL) throws -> Process {
        guard let path = tool.hasPrefix("/") ? tool : Executables.find(tool) else { throw ShellError.notFound(tool) }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment ?? Executables.environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        try? handle.close()
        return process
    }

    /// The end of a log file, for error messages.
    public static func tail(_ file: URL, lines: Int = 15) -> String {
        guard let data = try? Data(contentsOf: file) else { return "" }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}

public enum ShellError: Error, LocalizedError {
    case notFound(String)
    public var errorDescription: String? {
        switch self { case .notFound(let tool): return "\(tool) was not found." }
    }
}

public enum ViberPaths {
    public static var support: URL {
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Viber")
    }
    public static var requests: URL { support.appendingPathComponent("requests") }
    public static var panes: URL { support.appendingPathComponent("panes.json") }
    public static var issues: URL { support.appendingPathComponent("issues.json") }
    /// Issues were ideas; read once to turn them into issues.
    public static var ideas: URL { support.appendingPathComponent("ideas.json") }
    public static var projects: URL { support.appendingPathComponent("projects.json") }
    /// Which projects read their issues from Jira, and how.
    public static var trackers: URL { support.appendingPathComponent("trackers.json") }
    /// Project notes from before ideas, read once to turn them into ideas.
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
