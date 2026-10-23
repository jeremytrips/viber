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
    var preview: PreviewRecord?
}

struct PreviewRecord: Codable {
    var url: String?
    var open: Bool
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
    /// Whether the browser preview shows beside the chat.
    var showPreview = false { didSet { if showPreview != oldValue { onPersist?() } } }
    /// The page the preview shows, kept across relaunches.
    var previewURL: URL?
    /// Created the first time the preview is shown or Claude uses a preview tool.
    private(set) var preview: PreviewController?
    /// Elements picked in the preview, attached to the next message.
    var pickedElements: [ElementReference] = []
    var extraDirs: [String] = []
    /// The project's files for `@` mentions, loaded when first asked for.
    var files: [String]?
    @ObservationIgnored private var filesLoadedAt: Date?
    private(set) var started = false
    @ObservationIgnored private var process: ClaudeProcess?
    /// Preview tool calls in flight, by control request ID.
    @ObservationIgnored private var mcpTasks: [String: Task<Void, Never>] = [:]
    /// Something worth saving in panes.json changed.
    @ObservationIgnored var onPersist: (() -> Void)?
    @ObservationIgnored var onStateChange: ((Pane, PaneState) -> Void)?
    @ObservationIgnored var onTurnFinished: ((Pane) -> Void)?
    /// Opens a sign-in page for an MCP server.
    @ObservationIgnored var onOpenURL: ((URL) -> Void)?

    init(id: String = UUID().uuidString, title: String, spec: LaunchSpec, worktree: WorktreeInfo? = nil) {
        self.id = id; self.title = title; self.spec = spec; self.worktree = worktree
    }

    convenience init(record: PaneRecord) {
        self.init(id: record.id, title: record.title, spec: record.spec, worktree: record.worktree)
        sessionRules = record.sessionRules ?? []
        extraDirs = record.extraDirs ?? []
        previewURL = record.preview?.url.flatMap(URL.init(string:))
        showPreview = record.preview?.open ?? false
    }

    var record: PaneRecord {
        let preview = previewURL != nil || showPreview ? PreviewRecord(url: previewURL?.absoluteString, open: showPreview) : nil
        return PaneRecord(id: id, title: title, spec: spec, worktree: worktree, sessionRules: sessionRules.isEmpty ? nil : sessionRules,
                          extraDirs: extraDirs.isEmpty ? nil : extraDirs, preview: preview)
    }
    var state: PaneState { chat.state }
    var profileLabel: String { spec.profile ?? "Default login" }
    var cwd: String { spec.cwd }
    /// What ideas are filed under: the repo root for worktree sessions, else the session's folder.
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
        let before = chat.state
        chat.state = .starting
        do {
            let p = try ClaudeProcess(spec: spec, paneID: id, binDir: binDir, project: projectPath)
            p.onMessage = { [weak self] message in self?.handle(message) }
            p.onExit = { [weak self] status, stderr in self?.exited(status: status, stderr: stderr) }
            process = p
            // The browser preview's tools, served from this app over the same stdio channel.
            let mcp = Prefs.bool(Prefs.previewTools)
                ? SdkMcp.initializeFields([PreviewToolbox.serverName: ["disableAutoBackground": true, "timeout": 60000]]) : [:]
            p.send(chat.request("initialize", mcp))
            if !sessionRules.isEmpty || !extraDirs.isEmpty { p.send(chat.setSessionPermissions(rules: sessionRules, directories: extraDirs)) }
        } catch {
            chat.note(error.localizedDescription, isError: true)
            chat.state = .failed
        }
        notifyIfChanged(from: before)
    }

    private func handle(_ message: JSON) {
        if let call = SdkMcp.Incoming(message) { answer(call); return }
        if let reply = previewPermission(message) { process?.send(reply); return }
        if message["type"]?.string == "control_cancel_request", let id = message["request_id"]?.string,
           let task = mcpTasks.removeValue(forKey: id) {
            task.cancel()
            return
        }
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
        cancelToolCalls()
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
        cancelToolCalls()
        process?.terminate()
    }

    /// /clear: a fresh conversation in the same folder, under the same account.
    func restartFresh(binDir: String?, pluginDir: String?) {
        cancelToolCalls()
        process?.onExit = nil
        process?.terminate()
        process = nil
        chat = ChatTranscript()
        spec.resume = nil
        started = false
        start(binDir: binDir, pluginDir: pluginDir)
    }

    // MARK: Browser preview

    func ensurePreview() -> PreviewController {
        if let preview { return preview }
        let controller = PreviewController(url: previewURL, readAccess: cwd)
        controller.onReveal = { [weak self] in self?.showPreview = true }
        controller.onURLChange = { [weak self] url in
            guard let self, url != self.previewURL else { return }
            self.previewURL = url
            self.onPersist?()
        }
        controller.onPick = { [weak self] payload in
            guard let self, let reference = ElementReference(payload: payload, cwd: self.cwd) else { return }
            self.pickedElements.append(reference)
        }
        preview = controller
        return controller
    }

    func togglePreview() {
        showPreview.toggle()
        if showPreview { _ = ensurePreview() }
    }

    func openPreview(_ url: URL) {
        showPreview = true
        ensurePreview().navigate(url)
    }

    func closePreview() {
        cancelToolCalls()
        preview?.tearDown()
        preview = nil
    }

    /// Local URLs printed by recent tool calls, newest first: usually the dev server Claude started.
    var recentLocalURLs: [URL] {
        var urls: [URL] = []
        for item in chat.items.suffix(40).reversed() {
            guard case .tool(let call) = item.kind, let result = call.result, !call.name.hasPrefix(PreviewToolbox.toolPrefix) else { continue }
            for url in PreviewURL.detect(in: String(result.prefix(4000))) where !urls.contains(url) { urls.append(url) }
        }
        return urls
    }

    /// Answers a preview tool call. Replies only to the process that asked, in case it restarted meanwhile.
    private func answer(_ call: SdkMcp.Incoming) {
        guard call.server == PreviewToolbox.serverName else {
            process?.send(ChatTranscript.controlError(call.requestID, "Viber has no MCP server named \(call.server)."))
            return
        }
        let asker = process
        mcpTasks[call.requestID] = Task { [weak self] in
            guard let self else { return }
            let reply = await PreviewToolbox.server.handle(call.message) { name, args in
                let preview = self.ensurePreview()
                preview.activity = PreviewToolbox.activity(name)
                defer { preview.activity = nil }
                return await PreviewToolbox.call(name, args, driver: preview, lastEdit: self.chat.lastFileEditAt)
            }
            self.mcpTasks[call.requestID] = nil
            guard !Task.isCancelled, let asker, asker === self.process else { return }
            asker.send(SdkMcp.reply(requestID: call.requestID, response: reply))
        }
    }

    /// Viber approves its own preview tools: looking always, acting on local pages when the setting allows.
    private func previewPermission(_ message: JSON) -> JSON? {
        guard message["type"]?.string == "control_request", let request = message["request"],
              request["subtype"]?.string == "can_use_tool", let requestID = message["request_id"]?.string,
              let tool = request["tool_name"]?.string, tool.hasPrefix(PreviewToolbox.toolPrefix),
              PreviewPolicy.autoAllow(tool: tool, pageURL: preview?.pageURL ?? previewURL,
                                      actionsOnLocalPages: Prefs.bool(Prefs.previewLocalActions)) else { return nil }
        var response: [String: JSON] = ["behavior": "allow", "updatedInput": request["input"] ?? [:]]
        if let toolUseID = request["tool_use_id"]?.string { response["toolUseID"] = .string(toolUseID) }
        return ChatTranscript.controlSuccess(requestID, .object(response))
    }

    private func cancelToolCalls() {
        for task in mcpTasks.values { task.cancel() }
        mcpTasks = [:]
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
