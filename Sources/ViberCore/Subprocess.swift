import Darwin
import Foundation

public struct SubprocessResult: Sendable, Equatable {
    /// The exit code, or 128 + the signal that ended it.
    public var status: Int32
    public var stdout: String
    public var stderr: String
    /// Both streams in the order they arrived, for showing to the user.
    public var output: String
    public var timedOut = false
    public var cancelled = false
    /// The command could not be started at all; `stderr` says why.
    public var failedToStart = false
    public var ok: Bool { status == 0 && !timedOut && !cancelled && !failedToStart }
}

/// Long-running commands (project setup scripts) that must never block the caller's thread.
/// Each runs in its own process group, so a timeout or a cancel stops everything it started.
public enum Subprocess {
    /// Runs `executable` (a path, or a name looked up on the environment's PATH) and returns when it exits.
    /// `onOutput` gets the combined output as it arrives, on a background queue.
    public static func run(_ executable: String, _ arguments: [String], cwd: String? = nil,
                           environment: [String: String] = Executables.environment(), input: Data? = nil,
                           timeout: TimeInterval? = nil, onOutput: (@Sendable (String) -> Void)? = nil) async -> SubprocessResult {
        let state = RunState(onOutput: onOutput)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SubprocessResult, Never>) in
                state.start(executable, arguments, cwd: cwd, environment: environment, input: input, timeout: timeout) {
                    continuation.resume(returning: $0)
                }
            }
        } onCancel: {
            state.stop(cancelled: true)
        }
    }

    /// Finds `name` on `path` (colon-separated), or returns it unchanged when it is a path already.
    static func resolve(_ name: String, path: String) -> String? {
        if name.contains("/") { return name }
        for dir in path.split(separator: ":") {
            let candidate = (String(dir) as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// Everything one run shares between its reader, waiter and timer threads.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private let onOutput: (@Sendable (String) -> Void)?
    private var pid: pid_t = 0
    private var exited = false
    private var timedOut = false
    private var cancelled = false
    private var stdoutData = Data()
    private var stderrData = Data()
    private var combined = Data()
    /// Bytes of a UTF-8 character split across reads, held until the rest arrives.
    private var pending = Data()

    init(onOutput: (@Sendable (String) -> Void)?) { self.onOutput = onOutput }

    func start(_ executable: String, _ arguments: [String], cwd: String?, environment: [String: String], input: Data?,
               timeout: TimeInterval?, done: @escaping @Sendable (SubprocessResult) -> Void) {
        guard let path = Subprocess.resolve(executable, path: environment["PATH"] ?? "") else {
            done(Self.notStarted("\(executable) not found"))
            return
        }
        if lock.withLock({ cancelled }) {
            var result = Self.notStarted("Cancelled before it started.")
            result.cancelled = true
            done(result)
            return
        }
        var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            for fd in inPipe + outPipe + errPipe where fd >= 0 { close(fd) }
            done(Self.notStarted("Could not create pipes: \(String(cString: strerror(errno)))"))
            return
        }
        for fd in [inPipe[1], outPipe[0], errPipe[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group, so the whole tree can be stopped; only the three pipes are inherited.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                     | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t(), defaults = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD, SIGALRM, SIGUSR1, SIGUSR2] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var child: pid_t = 0
        let spawned = posix_spawn(&child, path, &actions, &attributes, argv, envp)
        close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
        guard spawned == 0 else {
            close(inPipe[1]); close(outPipe[0]); close(errPipe[0])
            done(Self.notStarted("Could not run \(path): \(String(cString: strerror(spawned)))"))
            return
        }
        // A cancel that came in while it was being spawned found no process to stop; stop it now.
        if lock.withLock({ pid = child; return cancelled }) { stop(cancelled: true) }

        let writer = inPipe[1]
        DispatchQueue.global().async {
            if let input, !input.isEmpty {
                input.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let n = write(writer, buffer.baseAddress! + offset, buffer.count - offset)
                        if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { break }
                    }
                }
            }
            close(writer)
        }

        let readers = DispatchGroup()
        for (fd, isError) in [(outPipe[0], false), (errPipe[0], true)] {
            readers.enter()
            DispatchQueue.global().async {
                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                while true {
                    let n = read(fd, &buffer, buffer.count)
                    if n > 0 { self.received(Data(buffer[0..<n]), isError: isError) }
                    else if n < 0 && errno == EINTR { continue }
                    else { break }
                }
                close(fd)
                readers.leave()
            }
        }

        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.stop(timedOut: true) }
        }

        DispatchQueue.global().async {
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            self.lock.withLock { self.exited = true }
            // Something it started in the background may hold the pipes open; don't wait on that for long.
            _ = readers.wait(timeout: .now() + 2)
            done(self.result(status: status))
        }
    }

    /// Stops the process group: SIGTERM, then SIGKILL if it is still there a few seconds later.
    func stop(timedOut: Bool = false, cancelled: Bool = false) {
        let target: pid_t? = lock.withLock {
            guard pid > 0, !exited else {
                if cancelled { self.cancelled = true }
                return nil
            }
            if timedOut { self.timedOut = true }
            if cancelled { self.cancelled = true }
            return pid
        }
        guard let target else { return }
        kill(-target, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { kill(-target, SIGKILL) }
    }

    private func received(_ data: Data, isError: Bool) {
        let text: String? = lock.withLock {
            if isError { stderrData.append(data) } else { stdoutData.append(data) }
            combined.append(data)
            guard onOutput != nil else { return nil }
            pending.append(data)
            let cut = Subprocess.completeUTF8Prefix(pending)
            let chunk = pending.prefix(cut)
            pending = Data(pending.dropFirst(cut))
            return chunk.isEmpty ? nil : String(decoding: chunk, as: UTF8.self)
        }
        if let text { onOutput?(text) }
    }

    private func result(status: Int32) -> SubprocessResult {
        lock.withLock {
            // waitpid's status: low 7 bits are the signal, or 0 when it exited normally with code in bits 8–15.
            let signal = status & 0x7f
            let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
            return SubprocessResult(status: code, stdout: String(decoding: stdoutData, as: UTF8.self),
                                    stderr: String(decoding: stderrData, as: UTF8.self),
                                    output: String(decoding: combined, as: UTF8.self), timedOut: timedOut, cancelled: cancelled)
        }
    }

    private static func notStarted(_ message: String) -> SubprocessResult {
        SubprocessResult(status: 127, stdout: "", stderr: message, output: message, failedToStart: true)
    }
}

extension Subprocess {
    /// How many leading bytes form whole UTF-8 characters, so a character split across reads isn't garbled.
    static func completeUTF8Prefix(_ data: Data) -> Int {
        let bytes = [UInt8](data)
        var back = 1
        while back <= min(4, bytes.count) {
            let byte = bytes[bytes.count - back]
            if byte & 0x80 == 0 { return bytes.count }            // ASCII: nothing is split
            if byte & 0xC0 == 0xC0 {                               // a lead byte: is its sequence all here?
                let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
                return back >= length ? bytes.count : bytes.count - back
            }
            back += 1                                              // a continuation byte: look further back
        }
        return bytes.count
    }
}
