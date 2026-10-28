import Foundation

/// One running `claude -p --input-format stream-json …` process. Lines from stdout are decoded off the
/// main thread and delivered on the main queue; writes go to stdin as NDJSON.
public final class ClaudeProcess {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let writeQueue = DispatchQueue(label: "viber.claude.stdin")
    private var buffer = Data()
    public private(set) var stderrTail = ""

    public var onMessage: ((JSON) -> Void)?
    public var onExit: ((Int32, String) -> Void)?

    public var isRunning: Bool { process.isRunning }

    public init(spec: LaunchSpec, paneID: String, binDir: String?, project: String? = nil) throws {
        let command = spec.command
        guard let executable = Executables.find(command.tool) else {
            throw NSError(domain: "Viber", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Could not find \(command.tool). Install it, or check that it is in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin."])
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = command.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: spec.cwd)
        // Checkpoints let a session rewind files to before a message, as Esc Esc does in the terminal.
        var extra = ["VIBER_PANE_ID": paneID, "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING": "1"]
        if let project { extra["VIBER_PROJECT"] = project }
        if let account = spec.profile { try Accounts.prepare(account) }
        process.environment = Accounts.environment(Executables.environment(adding: binDir.map { [$0] } ?? [], extra: extra), account: spec.profile)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self.consume(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self.stderrTail = String((self.stderrTail + text).suffix(4000)) }
        }
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self else { return }
                self.onExit?(p.terminationStatus, self.stderrTail)
            }
        }
        try process.run()
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        var messages: [JSON] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let json = JSON(data: Data(line)) { messages.append(json) }
        }
        guard !messages.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            for message in messages { self?.onMessage?(message) }
        }
    }

    public func send(_ message: JSON) {
        let data = Data((message.line() + "\n").utf8)
        writeQueue.async { [stdin] in
            try? stdin.fileHandleForWriting.write(contentsOf: data)
        }
    }

    public func terminate() {
        guard process.isRunning else { return }
        try? stdin.fileHandleForWriting.close()
        process.terminate()
    }
}
