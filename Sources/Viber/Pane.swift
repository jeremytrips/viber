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
    var device: DeviceRecord?
}

struct PreviewRecord: Codable {
    var url: String?
    var open: Bool
}

struct DeviceRecord: Codable {
    var id: String?
    var open: Bool
    /// The user picked this device in the panel (rather than Claude opening it).
    var chosen: Bool?
}

/// A `//` message, or the reply to one, on its way to a session.
struct IncomingRelay {
    var sourcePaneID: String
    var sourceTitle: String
    /// The "Sent to" line in the sender's chat, which shows how far the message got.
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
    /// The branch checked out in the worktree, read with the diff stat. Claude may have switched away from `worktree.branch`.
    var liveBranch: String?
    var lastActivity = Date()
    var pendingClose: ViberRequest?
    /// When Stop was last pressed, so an autopilot run can tell your stop from Claude ending its turn.
    @ObservationIgnored var interruptedAt: Date?
    /// `//` messages this session has yet to answer, by the chat item each arrived as.
    var answering: [String: IncomingRelay] = [:]
    var sessionRules: [RuleEdit] = []
    /// Whether the browser preview shows beside the chat.
    var showPreview = false { didSet { if showPreview != oldValue { onPersist?() } } }
    /// The page the preview shows, kept across relaunches.
    var previewURL: URL?
    /// Created the first time the preview is shown or Claude uses a preview tool.
    private(set) var preview: PreviewController?
    /// Elements picked in the preview or on the device, attached to the next message.
    var pickedElements: [ElementReference] = []
    /// Whether the device panel shows beside the chat.
    var showDevice = false { didSet { if showDevice != oldValue { onPersist?() } } }
    /// The simulator or emulator this session shows and its device tools drive, kept across relaunches.
    var deviceID: String? { didSet { if deviceID != oldValue { onPersist?() } } }
    /// The user picked the session's device in the panel. Looking at a USB phone needs this, else Claude's tools ask.
    var userChoseDevice = false { didSet { if userChoseDevice != oldValue { onPersist?() } } }
    /// The device tool Claude is running, for the device panel.
    var deviceActivity: String?
    /// Images the device panel attached, picked up by the composer.
    var pendingAttachments: [ImageAttachment] = []
    var extraDirs: [String] = []
    /// The project's files for `@` mentions, loaded when first asked for.
    var files: [String]?
    @ObservationIgnored private var filesLoadedAt: Date?
    private(set) var started = false
    /// The CLI reported a dead login. It keeps its credentials in memory, so only a new process
    /// sees a re-login; the next message restarts it.
    private(set) var authFailed = false
    @ObservationIgnored private var process: ClaudeProcess?
    /// Preview and device tool calls in flight, by control request ID.
    @ObservationIgnored private var mcpTasks: [String: Task<Void, Never>] = [:]
    /// Viber's MCP server as this process was told about it.
    @ObservationIgnored private var mcpServer: SdkMcpServer?
    @ObservationIgnored weak var deviceHub: DeviceHub?
    /// The device a tool call of this session is using.
    @ObservationIgnored private weak var busyController: (any DeviceController)?
    /// Something worth saving in panes.json changed.
    @ObservationIgnored var onPersist: (() -> Void)?
    @ObservationIgnored var onStateChange: ((Pane, PaneState) -> Void)?
    @ObservationIgnored var onTurnFinished: ((Pane) -> Void)?
    @ObservationIgnored var onRelayUpdate: ((Pane, RelayUpdate) -> Void)?
    /// Opens a sign-in page for an MCP server.
    @ObservationIgnored var onOpenURL: ((URL) -> Void)?

    init(id: String = UUID().uuidString, title: String, spec: LaunchSpec, worktree: WorktreeInfo? = nil) {
        self.id = id; self.title = title; self.spec = spec; self.worktree = worktree
        projectPath = ProjectRoot.resolve(worktree?.repo ?? spec.cwd)
    }

    convenience init(record: PaneRecord) {
        self.init(id: record.id, title: record.title, spec: record.spec, worktree: record.worktree)
        sessionRules = record.sessionRules ?? []
        extraDirs = record.extraDirs ?? []
        previewURL = record.preview?.url.flatMap(URL.init(string:))
        showPreview = record.preview?.open ?? false
        deviceID = record.device?.id
        showDevice = record.device?.open ?? false
        userChoseDevice = record.device?.chosen ?? false
    }

    var record: PaneRecord {
        let preview = previewURL != nil || showPreview ? PreviewRecord(url: previewURL?.absoluteString, open: showPreview) : nil
        let device = deviceID != nil || showDevice ? DeviceRecord(id: deviceID, open: showDevice, chosen: userChoseDevice ? true : nil) : nil
        return PaneRecord(id: id, title: title, spec: spec, worktree: worktree, sessionRules: sessionRules.isEmpty ? nil : sessionRules,
                          extraDirs: extraDirs.isEmpty ? nil : extraDirs, preview: preview, device: device)
    }
    var state: PaneState { chat.state }
    var profileLabel: String { spec.profile ?? "Default login" }
    var cwd: String { spec.cwd }
    /// The project it belongs to: its repository's main checkout (also for subfolders and worktrees), else its folder.
    /// Ideas are filed under it.
    @ObservationIgnored let projectPath: String
    var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }
    /// The worktree's branch as it is now, or the one it was created on until it is read (and while HEAD is detached).
    /// Nil when there is neither: a hook can make a worktree on a detached HEAD.
    var branch: String? {
        guard let worktree else { return nil }
        let branch = liveBranch ?? worktree.branch
        return branch.isEmpty ? nil : branch
    }
    var isRunning: Bool { process?.isRunning == true }

    func start(binDir: String?, pluginDir: String?) {
        guard process == nil || process?.isRunning == false else { return }
        if !started, let resume = spec.resume, chat.items.isEmpty, let url = Self.transcriptURL(sessionID: resume, cwd: spec.cwd),
           let data = try? Data(contentsOf: url) {
            chat.loadHistory(data, transcript: url)
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
            // The browser preview's and device panel's tools, served from this app over the same stdio channel.
            // Booting a simulator for the first time can take a minute or two, hence the long timeout.
            let preview = Prefs.bool(Prefs.previewTools), device = Prefs.bool(Prefs.deviceTools)
            mcpServer = preview || device ? ViberMcp.server(preview: preview, device: device) : nil
            let mcp = mcpServer != nil
                ? SdkMcp.initializeFields([PreviewToolbox.serverName: ["disableAutoBackground": true, "timeout": 180000]]) : [:]
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
        reportRelayUpdates()
        if let url = chat.controls.authURL {
            chat.controls.authURL = nil
            onOpenURL?(url)
        }
        if let session = chat.sessionID, spec.resume != session { spec.resume = session }
        lastActivity = Date()
        if message["type"]?.string == "result" {
            if message["is_error"]?.bool == true, Self.isAuthError(message["result"]?.string ?? ""), !authFailed {
                authFailed = true
                chat.note("Log in to \(profileLabel) again (click its chip in the top bar), then send your message again. Viber will restart Claude with the new login and keep this conversation.", isError: true)
            }
            onTurnFinished?(self)
        }
        notifyIfChanged(from: before)
    }

    private func exited(status: Int32, stderr: String) {
        cancelToolCalls()
        let before = chat.state
        let wasStarting = chat.state == .starting
        process = nil
        chat.processExited(status: status)
        reportRelayUpdates()
        if status != 0 || wasStarting {
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { chat.note(String(tail.suffix(600)), isError: true) }
        }
        notifyIfChanged(from: before)
    }

    private func reportRelayUpdates() {
        for update in chat.takeRelayUpdates() { onRelayUpdate?(self, update) }
    }

    private func notifyIfChanged(from before: PaneState) {
        if chat.state != before { onStateChange?(self, before) }
    }

    func send(_ message: JSON) { process?.send(message) }

    /// Sends a user message, starting the process first if needed.
    func sendUser(_ text: String, images: [ImageAttachment] = [], binDir: String?, pluginDir: String?) {
        if authFailed { restart(binDir: binDir, pluginDir: pluginDir) }
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

    /// Sends a `//` message or reply right away. A busy Claude gets it after its running tool call, as Claude Code does.
    func deliver(_ relay: IncomingRelay, binDir: String?, pluginDir: String?) {
        if authFailed { restart(binDir: binDir, pluginDir: pluginDir) }
        if !isRunning { start(binDir: binDir, pluginDir: pluginDir) }
        let before = chat.state
        if relay.isReply {
            process?.send(chat.receiveReply(from: relay.sourceTitle, text: relay.text))
        } else {
            process?.send(chat.receiveRelay(from: relay.sourceTitle, text: relay.text))
            if let item = chat.lastItemID { answering[item] = relay }
        }
        lastActivity = Date()
        notifyIfChanged(from: before)
    }

    func interrupt() {
        guard isRunning else { return }
        interruptedAt = Date()
        process?.send(chat.request("interrupt"))
    }

    func stop() {
        cancelToolCalls()
        process?.terminate()
    }

    /// A new CLI process on the same conversation, so it re-reads the login and settings.
    func restart(binDir: String?, pluginDir: String?) {
        cancelToolCalls()
        process?.onExit = nil
        process?.terminate()
        process = nil
        authFailed = false
        chat.processExited(status: 0)
        reportRelayUpdates()
        start(binDir: binDir, pluginDir: pluginDir)
    }

    static func isAuthError(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("failed to authenticate") || lower.contains("oauth") || lower.contains("/login")
    }

    /// /clear: a fresh conversation in the same folder, under the same account.
    func restartFresh(binDir: String?, pluginDir: String?) {
        // The new conversation won't answer what the old one was sent.
        for item in answering.keys { onRelayUpdate?(self, .answered(itemID: item, text: "")) }
        cancelToolCalls()
        process?.onExit = nil
        process?.terminate()
        process = nil
        chat = ChatTranscript()
        spec.resume = nil
        started = false
        authFailed = false
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

    // MARK: Device

    var deviceController: (any DeviceController)? { deviceID.flatMap { deviceHub?.controllers[$0] } }

    func toggleDevice() {
        showDevice.toggle()
    }

    /// Shows `device` in this session's panel (booting it if asked) and makes it the one Claude's device tools use.
    func chooseDevice(_ device: DeviceInfo, boot: Bool) {
        guard let hub = deviceHub else { return }
        deviceID = device.id
        userChoseDevice = true
        showDevice = true
        let controller = hub.controller(for: device)
        if boot, !device.isBooted {
            Task {
                try? await controller.boot()
                _ = try? await hub.refresh()
            }
        }
    }

    func toggleDevicePicking() {
        guard let controller = deviceController else { return }
        if controller.picking { controller.picking = false; return }
        // The controller is shared between sessions: picks go to the session that started picking.
        controller.onPick = { [weak self] element, app in
            guard let self, let controller = self.deviceController else { return }
            self.pickedElements.append(ElementReference(device: controller.device.label, app: app, element: element))
        }
        controller.picking = true
        controller.screenView.window?.makeFirstResponder(controller.screenView)
    }

    /// Runs a build or an Expo URL on this session's device when it can, else on a running (else the newest) simulator
    /// or emulator of the build's platform.
    /// A development build's link fails if the build isn't installed there; the error says so in the chat.
    func runOnDevice(_ artifact: DeviceArtifact) {
        guard let hub = deviceHub else { return }
        Task {
            do {
                let devices = try await hub.refresh(maxAge: 2)
                let fits = { (d: DeviceInfo) -> Bool in
                    // A simulator build can't run on a physical iPhone.
                    if case .app = artifact, !d.isVirtual { return false }
                    return artifact.platform.map { d.platform == $0 } ?? true
                }
                let mine = deviceID.flatMap { id in devices.first { $0.id == id } }.flatMap { fits($0) ? $0 : nil }
                guard let device = mine ?? DeviceCatalog.preferred(devices.filter(fits)) else {
                    throw DeviceError.failed(artifact.platform == .android
                        ? "No Android emulators found. Create one in Android Studio's Device Manager."
                        : "No simulators found. Install an iOS simulator runtime in Xcode → Settings → Components.")
                }
                let driver = try use(device, reveal: true)
                try await driver.boot()
                switch artifact {
                case .app(let path), .apk(let path):
                    let id = try await driver.install(path)
                    try await driver.launch(id, arguments: [], terminateRunning: true)
                case .expo(let url), .devClient(let url):
                    try await driver.openURL(url)
                }
            } catch {
                chat.note(error.localizedDescription, isError: true)
            }
        }
    }

    func attachDeviceScreenshot() {
        guard let controller = deviceController, let png = controller.screenshotPNG(),
              let image = ImageAttachment(data: png, label: "\(controller.device.name) screenshot") else { return }
        pendingAttachments.append(image)
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

    /// Answers a preview or device tool call. Replies only to the process that asked, in case it restarted meanwhile.
    private func answer(_ call: SdkMcp.Incoming) {
        guard call.server == PreviewToolbox.serverName, let server = mcpServer else {
            process?.send(ChatTranscript.controlError(call.requestID, "Viber has no MCP server named \(call.server)."))
            return
        }
        let asker = process
        mcpTasks[call.requestID] = Task { [weak self] in
            guard let self else { return }
            let reply = await server.handle(call.message) { name, args in
                if name.hasPrefix("device_") {
                    self.deviceActivity = DeviceToolbox.activity(name)
                    defer {
                        self.deviceActivity = nil
                        self.busyController?.activity = nil
                        self.busyController = nil
                    }
                    return await DeviceToolbox.call(name, args, host: self)
                }
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

    /// Viber approves its own tools: looking always, acting on local pages and on simulators when the settings allow.
    private func previewPermission(_ message: JSON) -> JSON? {
        guard message["type"]?.string == "control_request", let request = message["request"],
              request["subtype"]?.string == "can_use_tool", let requestID = message["request_id"]?.string,
              let tool = request["tool_name"]?.string, tool.hasPrefix(PreviewToolbox.toolPrefix) else { return nil }
        let allowed = tool.hasPrefix(DeviceToolbox.toolPrefix)
            ? devicePermission(tool: tool, input: request["input"] ?? [:])
            : PreviewPolicy.autoAllow(tool: tool, pageURL: preview?.pageURL ?? previewURL,
                                      actionsOnLocalPages: Prefs.bool(Prefs.previewLocalActions))
        guard allowed else { return nil }
        var response: [String: JSON] = ["behavior": "allow", "updatedInput": request["input"] ?? [:]]
        if let toolUseID = request["tool_use_id"]?.string { response["toolUseID"] = .string(toolUseID) }
        return ChatTranscript.controlSuccess(requestID, .object(response))
    }

    private func devicePermission(tool: String, input: JSON) -> Bool {
        let target = DeviceToolbox.target(tool: tool, input: input, devices: deviceHub?.devices ?? [], sessionDeviceID: deviceID)
        return DevicePolicy.autoAllow(tool: tool, target: target, userChose: userChoseDevice && target?.id == deviceID,
                                      actionsOnVirtualDevices: Prefs.bool(Prefs.deviceActions))
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

    static func transcriptURL(sessionID: String, cwd: String) -> URL? {
        let fm = FileManager.default
        let direct = ViberPaths.transcript(sessionID: sessionID, cwd: cwd)
        if fm.fileExists(atPath: direct.path) { return direct }
        // The folder name encoding is the CLI's business; fall back to a search by file name.
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.projects, includingPropertiesForKeys: nil) else { return nil }
        return dirs.map { $0.appendingPathComponent("\(sessionID).jsonl") }.first { fm.fileExists(atPath: $0.path) }
    }
}

extension Pane: DeviceHost {
    func listDevices() async throws -> [DeviceInfo] {
        guard let deviceHub else { throw DeviceError.failed("Devices are not available.") }
        return try await deviceHub.refresh(maxAge: 2)
    }

    var sessionDeviceID: String? { deviceID }

    func use(_ device: DeviceInfo, reveal: Bool) throws -> DeviceDriver {
        guard let deviceHub else { throw DeviceError.failed("Devices are not available.") }
        if deviceID != device.id { userChoseDevice = false }
        deviceID = device.id
        if reveal { showDevice = true }
        let controller = deviceHub.controller(for: device)
        // Marks the stream as in use for the whole call, which can outlast the hub's idle limit (booting, waiting).
        if let activity = deviceActivity {
            if busyController !== controller { busyController?.activity = nil }
            controller.activity = activity
            busyController = controller
        }
        return controller
    }
}
