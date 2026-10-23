import Foundation
import Observation
import ViberCore

/// What gets saved so open sessions come back after a relaunch.
struct PaneRecord: Codable {
    var id: String
    var title: String
    var spec: LaunchSpec
    var worktree: WorktreeInfo?
    /// Permission rules added for this session only, re-applied whenever its process starts.
    var sessionRules: [RuleEdit]?
    /// Folders added with /add-dir, re-applied the same way.
    var extraDirs: [String]?
}

/// A `//` message, or the reply to one, waiting to be delivered to a session.
struct IncomingRelay {
    var recordID: String
    var sourcePaneID: String
    var sourceTitle: String
    var sentItemID: String?
    var text: String
    var isReply = false
}

/// One Claude Code session shown in Viber.
@MainActor @Observable
final class Pane: Identifiable {
    let id: String
    var title: String
    var spec: LaunchSpec
    var worktree: WorktreeInfo?
    var chat = ChatTranscript()
    var diffStat: String?
    var lastActivity = Date()
    var pendingClose: ViberRequest?
    /// `//` messages waiting for this session's current turn to end.
    var inbox: [IncomingRelay] = []
    /// The `//` message this session is answering right now, and the chat item it arrived as.
    var answering: (recordID: String, itemID: String)?
    var sessionRules: [RuleEdit] = []
    var extraDirs: [String] = []
    /// The project's files for `@` mentions, loaded when first asked for.
    var files: [String]?
    @ObservationIgnored private var filesLoadedAt: Date?
    private(set) var started = false
    @ObservationIgnored private var process: ClaudeProcess?
    @ObservationIgnored var onStateChange: ((Pane, PaneState) -> Void)?
    @ObservationIgnored var onTurnFinished: ((Pane) -> Void)?
    /// Opens a sign-in page for an MCP server.
    @ObservationIgnored var onOpenURL: ((URL) -> Void)?
    /// The project note for the system prompt, looked up each time the process starts.
    @ObservationIgnored var notePrompt: ((Pane) -> String?)?

    init(id: String = UUID().uuidString, title: String, spec: LaunchSpec, worktree: WorktreeInfo? = nil) {
        self.id = id; self.title = title; self.spec = spec; self.worktree = worktree
    }

    convenience init(record: PaneRecord) {
        self.init(id: record.id, title: record.title, spec: record.spec, worktree: record.worktree)
        sessionRules = record.sessionRules ?? []
        extraDirs = record.extraDirs ?? []
    }

    var record: PaneRecord {
        PaneRecord(id: id, title: title, spec: spec, worktree: worktree, sessionRules: sessionRules.isEmpty ? nil : sessionRules,
                   extraDirs: extraDirs.isEmpty ? nil : extraDirs)
    }
    var state: PaneState { chat.state }
    var profileLabel: String { spec.profile ?? "Default login" }
    var cwd: String { spec.cwd }
    /// What project notes are keyed by: the repo root for worktree sessions, else the session's folder.
    var projectPath: String { worktree?.repo ?? spec.cwd }
    var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }
    var isRunning: Bool { process?.isRunning == true }

    func start(binDir: String?, pluginDir: String?) {
        guard process == nil || process?.isRunning == false else { return }
        if !started, let resume = spec.resume, chat.items.isEmpty, let data = Self.transcriptData(sessionID: resume, cwd: spec.cwd) {
            chat.loadHistory(data)
        }
        started = true
        spec.pluginDir = pluginDir
        spec.appendSystemPrompt = notePrompt?(self)
        let before = chat.state
        chat.state = .starting
        do {
            let p = try ClaudeProcess(spec: spec, paneID: id, binDir: binDir, project: projectPath)
            p.onMessage = { [weak self] message in self?.handle(message) }
            p.onExit = { [weak self] status, stderr in self?.exited(status: status, stderr: stderr) }
            process = p
            p.send(chat.request("initialize"))
            if !sessionRules.isEmpty || !extraDirs.isEmpty { p.send(chat.setSessionPermissions(rules: sessionRules, directories: extraDirs)) }
        } catch {
            chat.note(error.localizedDescription, isError: true)
            chat.state = .failed
        }
        notifyIfChanged(from: before)
    }

    private func handle(_ message: JSON) {
        let before = chat.state
        for reply in chat.apply(message) { process?.send(reply) }
        if let url = chat.controls.authURL {
            chat.controls.authURL = nil
            onOpenURL?(url)
        }
        if let session = chat.sessionID, spec.resume != session { spec.resume = session }
        lastActivity = Date()
        if message["type"]?.string == "result" { onTurnFinished?(self) }
        notifyIfChanged(from: before)
    }

    private func exited(status: Int32, stderr: String) {
        let before = chat.state
        let wasStarting = chat.state == .starting
        process = nil
        chat.processExited(status: status)
        if status != 0 || wasStarting {
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { chat.note(String(tail.suffix(600)), isError: true) }
        }
        notifyIfChanged(from: before)
    }

    private func notifyIfChanged(from before: PaneState) {
        if chat.state != before { onStateChange?(self, before) }
    }

    func send(_ message: JSON) { process?.send(message) }

    /// Sends a user message, starting the process first if needed.
    func sendUser(_ text: String, images: [ImageAttachment] = [], binDir: String?, pluginDir: String?) {
        if !isRunning { start(binDir: binDir, pluginDir: pluginDir) }
        let before = chat.state
        process?.send(chat.userMessage(text, images: images))
        lastActivity = Date()
        notifyIfChanged(from: before)
    }

    func run(_ update: (inout ChatTranscript) -> [JSON]) {
        let before = chat.state
        for message in update(&chat) { process?.send(message) }
        notifyIfChanged(from: before)
    }

    /// Whether a `//` message can go in now instead of waiting for the current turn.
    var canReceiveNow: Bool {
        !(state == .working || state == .starting || state.needsYou)
    }

    func deliver(_ relay: IncomingRelay, binDir: String?, pluginDir: String?) {
        if !isRunning { start(binDir: binDir, pluginDir: pluginDir) }
        let before = chat.state
        if relay.isReply {
            process?.send(chat.receiveReply(from: relay.sourceTitle, text: relay.text))
        } else {
            process?.send(chat.receiveRelay(from: relay.sourceTitle, text: relay.text))
            if let item = chat.lastItemID { answering = (relay.recordID, item) }
        }
        lastActivity = Date()
        notifyIfChanged(from: before)
    }

    func interrupt() {
        guard isRunning else { return }
        process?.send(chat.request("interrupt"))
    }

    func stop() {
        process?.terminate()
    }

    /// /clear: a fresh conversation in the same folder, under the same account.
    func restartFresh(binDir: String?, pluginDir: String?) {
        process?.onExit = nil
        process?.terminate()
        process = nil
        chat = ChatTranscript()
        spec.resume = nil
        started = false
        start(binDir: binDir, pluginDir: pluginDir)
    }

    /// Loads the file list for `@` mentions in the background, at most every 30 seconds.
    func loadFiles() {
        if let at = filesLoadedAt, Date().timeIntervalSince(at) < 30 { return }
        filesLoadedAt = Date()
        let cwd = spec.cwd
        Task.detached {
            let list = FileIndex.list(cwd: cwd)
            await MainActor.run { self.files = list }
        }
    }

    static func transcriptData(sessionID: String, cwd: String) -> Data? {
        let direct = ViberPaths.transcript(sessionID: sessionID, cwd: cwd)
        if let data = try? Data(contentsOf: direct) { return data }
        // The folder name encoding is the CLI's business; fall back to a search by file name.
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.projects, includingPropertiesForKeys: nil) else { return nil }
        for dir in dirs {
            let file = dir.appendingPathComponent("\(sessionID).jsonl")
            if let data = try? Data(contentsOf: file) { return data }
        }
        return nil
    }
}
