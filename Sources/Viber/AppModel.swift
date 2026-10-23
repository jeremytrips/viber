import AppKit
import Foundation
import Observation
import ViberCore

/// Sidebar selection: a Viber pane, or a session running somewhere else.
enum Target: Hashable {
    case pane(String)
    case external(String)
    /// The timeline of `//` messages between sessions.
    case messages
    /// Every project's ideas that are not planned yet.
    case ideas

    var key: String {
        switch self {
        case .messages: return "messages"
        case .ideas: return "ideas"
        case .pane(let id): return "pane:\(id)"
        case .external(let id): return "ext:\(id)"
        }
    }

    init?(key: String) {
        if key == "messages" { self = .messages }
        else if key == "ideas" { self = .ideas }
        else if key.hasPrefix("pane:") { self = .pane(String(key.dropFirst(5))) }
        else if key.hasPrefix("ext:") { self = .external(String(key.dropFirst(4))) }
        else { return nil }
    }
}

/// The settings sheet of one session, opened on a tab.
struct SettingsSheetRequest: Identifiable {
    var paneID: String
    var tab: SettingsTab
    var id: String { paneID }
}

struct NewSessionRequest {
    var folder: String
    var profile: String?
    var useWorktree: Bool
    var name: String
    var permissionMode: String
    var firstMessage: String
    /// The idea this session is started for, linked to it once it opens.
    var ideaID: String?
}

@MainActor @Observable
final class AppModel {
    var panes: [Pane] = []
    var selection: Target?
    var status: ClauthStatus?
    var statusNote: String?
    var externals: [Session] = []
    var recent: [ClauthSession] = []
    var now = Date()
    var errorMessage: String?
    var showNewSession = false
    var showSwitcher = false
    var showResume = false
    var closing: Pane?
    var settingsSheet: SettingsSheetRequest?
    var relayLog = RelayLog()
    var cacheWarning: TimeInterval { TimeInterval(max(Prefs.int(Prefs.cacheWarningMinutes), 1) * 60) }
    var ideas = IdeaList()
    /// Ideas whose session is being created, so Plan can't start two.
    var planningIdeas: Set<String> = []

    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored private let externalMonitor = ExternalMonitor()
    @ObservationIgnored private var externalStates: [String: SessionState] = [:]
    @ObservationIgnored private var cacheAlerted: Set<String> = []
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var activation: NSObjectProtocol?
    @ObservationIgnored let binDir: String?
    @ObservationIgnored let pluginDir: String?

    init() {
        let resources = Bundle.main.resourceURL
        let bundledBin = resources?.appendingPathComponent("bin").path
        let bundledPlugin = resources?.appendingPathComponent("plugin").path
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        binDir = env["VIBER_BIN_DIR"] ?? bundledBin.flatMap { fm.fileExists(atPath: $0) ? $0 : nil }
        pluginDir = env["VIBER_PLUGIN_DIR"] ?? bundledPlugin.flatMap { fm.fileExists(atPath: $0) ? $0 : nil }
        Prefs.register()
        restore()
        notifier.onOpen = { [weak self] key in
            guard let self, let target = Target(key: key) else { return }
            self.select(target)
        }
        notifier.setUp()
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.returnedToApp() }
        }
        startTimers()
        reloadStatus()
        reloadRecent()
        pollExternal()
    }

    // MARK: Lookup

    func pane(_ id: String) -> Pane? { panes.first { $0.id == id } }
    var selectedPane: Pane? { if case .pane(let id)? = selection { return pane(id) }; return nil }
    var selectedExternal: Session? {
        if case .external(let id)? = selection { return externals.first { $0.id == id } }
        return nil
    }
    var waitingCount: Int { panes.filter { $0.state.needsYou }.count + externals.filter { [.input, .plan, .permission].contains($0.state) }.count }
    var profiles: [ClauthStatus.Profile] { status?.profiles ?? [] }
    var defaultProfile: String? { status?.activeProfile }

    /// Folders seen in clauth's session list, most recent first.
    var recentFolders: [String] {
        var seen = Set<String>()
        return recent.compactMap(\.workspace).filter { seen.insert($0).inserted && FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: Selection

    func select(_ target: Target?) {
        selection = target
        guard let target else { return }
        notifier.clear(target: target.key)
        if case .pane(let id) = target, let pane = pane(id), !pane.started {
            pane.start(binDir: binDir, pluginDir: pluginDir)
        }
    }

    func select(index: Int) {
        guard panes.indices.contains(index) else { return }
        select(.pane(panes[index].id))
    }

    func selectNextWaiting() {
        let waiting: [Target] = panes.filter { $0.state.needsYou }.map { .pane($0.id) }
            + externals.filter { [.input, .plan, .permission].contains($0.state) }.map { .external($0.id) }
        guard !waiting.isEmpty else { return }
        let index = selection.flatMap { waiting.firstIndex(of: $0) }.map { ($0 + 1) % waiting.count } ?? 0
        select(waiting[index])
    }

    // MARK: Sessions

    func createSession(_ request: NewSessionRequest) {
        let title = request.name.isEmpty ? (request.firstMessage.isEmpty ? URL(fileURLWithPath: request.folder).lastPathComponent : String(request.firstMessage.prefix(50))) : request.name
        let mode = request.permissionMode == "default" ? nil : request.permissionMode
        let model = Prefs.string(Prefs.newSessionModel)
        let launchModel = model.isEmpty ? nil : model
        if request.useWorktree {
            let folder = request.folder, name = request.name.isEmpty ? title : request.name
            Task.detached {
                let result = Result { try Worktree.create(repoDir: folder, name: name) }
                await MainActor.run {
                    switch result {
                    case .success(let info):
                        self.open(title: title, spec: LaunchSpec(profile: request.profile, cwd: info.path, permissionMode: mode, model: launchModel),
                                  worktree: info, firstMessage: request.firstMessage, ideaID: request.ideaID)
                    case .failure(let error):
                        if let id = request.ideaID { self.planningIdeas.remove(id) }
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        } else {
            open(title: title, spec: LaunchSpec(profile: request.profile, cwd: request.folder, permissionMode: mode, model: launchModel),
                 worktree: nil, firstMessage: request.firstMessage, ideaID: request.ideaID)
        }
    }

    func resume(_ session: ClauthSession, profile: String?) {
        if let existing = panes.first(where: { $0.spec.resume == session.id || $0.chat.sessionID == session.id }) {
            select(.pane(existing.id)); return
        }
        guard let folder = session.workspace else { errorMessage = "This session has no recorded folder."; return }
        open(title: session.title, spec: LaunchSpec(profile: profile, cwd: folder, resume: session.id), worktree: nil, firstMessage: "")
    }

    func continueHere(_ session: Session) {
        if let existing = panes.first(where: { $0.spec.resume == session.id || $0.chat.sessionID == session.id }) {
            select(.pane(existing.id)); return
        }
        let title = recent.first(where: { $0.id == session.id })?.title ?? session.projectName
        open(title: title, spec: LaunchSpec(profile: defaultProfile, cwd: session.project, resume: session.id), worktree: nil, firstMessage: "")
    }

    private func open(title: String, spec: LaunchSpec, worktree: WorktreeInfo?, firstMessage: String, ideaID: String? = nil) {
        let pane = Pane(title: title, spec: spec, worktree: worktree)
        wire(pane)
        panes.append(pane)
        save()
        if let ideaID {
            planningIdeas.remove(ideaID)
            ideas.start(ideaID, sessionID: pane.id, sessionTitle: title)
            saveIdeas()
        }
        select(.pane(pane.id))
        let text = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { submit(text, in: pane) }
    }

    private func wire(_ pane: Pane) {
        pane.onStateChange = { [weak self] pane, previous in self?.stateChanged(pane, from: previous) }
        pane.onTurnFinished = { [weak self] pane in self?.turnFinished(pane) }
        pane.onRelayUpdate = { [weak self] pane, update in self?.relayUpdate(update, in: pane) }
        pane.onOpenURL = { NSWorkspace.shared.open($0) }
        pane.onPersist = { [weak self] in self?.save() }
    }

    /// Routes composer text: skills go to the CLI, terminal-only commands are handled here.
    /// Images go with a message to Claude; returns false when the text was not one, so the composer keeps them.
    @discardableResult
    func submit(_ text: String, images: [ImageAttachment] = [], in pane: Pane) -> Bool {
        if Relay.isRelay(text) {
            // Without a choice from the menu, use the best match.
            guard let best = Relay.rank(text, candidates: relayCandidates(excluding: pane)).first else {
                    pane.chat.note("There is no other session to send this to.", isError: true); return images.isEmpty
            }
            relay(best.message, from: pane, to: best.candidate.id)
            return images.isEmpty
        }
        switch SlashRouter.route(text, commands: pane.chat.commands) {
        case .send(let message):
            guard !message.isEmpty || !images.isEmpty else { return true }
            pane.sendUser(message, images: images, binDir: binDir, pluginDir: pluginDir)
            return true
        case .setMode(let mode, let then):
            setMode(mode, in: pane)
            if let then { pane.sendUser(then, images: images, binDir: binDir, pluginDir: pluginDir); return true }
        case .setModel(let model):
            ensureRunning(pane)
            pane.run { [$0.setModel(model)] }
            pane.chat.note("Model: \(model)")
        case .pickModel:
            let names = pane.chat.models.map(\.value).joined(separator: ", ")
            pane.chat.note(names.isEmpty ? "Use /model <name>, for example /model opus." : "Available models: \(names). Use /model <name> or the model menu.")
        case .clear:
            pane.restartFresh(binDir: binDir, pluginDir: pluginDir)
            save()
        case .resume:
            reloadRecent()
            showResume = true
        case .showCost:
            let usage = pane.chat.lastUsage
            pane.chat.note(String(format: "Session cost so far: $%.2f. Context: %@ tokens.", pane.chat.costUSD,
                                  usage.map { Self.compact($0.contextTokens) } ?? "unknown"))
        case .openSettings(let tab):
            openSettings(tab, in: pane)
        case .addDirectory(let path):
            addDirectory(path, in: pane)
        }
        return images.isEmpty
    }

    // MARK: Session settings (what /mcp, /context, /permissions … show in the terminal)

    func openSettings(_ tab: SettingsTab, in pane: Pane) {
        control(pane) { $0.refresh(tab) }
        settingsSheet = SettingsSheetRequest(paneID: pane.id, tab: tab)
    }

    /// Sends settings requests, starting the session's process first if it is not running.
    func control(_ pane: Pane, _ update: (inout ChatTranscript) -> [JSON]) {
        ensureRunning(pane)
        pane.run(update)
    }

    /// Adds a permission rule where the user chose: the session's own layer, or a project settings file.
    func addRule(_ edit: RuleEdit, scope: SettingsScope, in pane: Pane) {
        if scope == .session {
            guard !pane.sessionRules.contains(edit) else { return }
            pane.sessionRules.append(edit)
            applySessionPermissions(pane)
            return
        }
        editSettings(scope, cwd: pane.cwd, then: pane) { try SettingsFile.addRule(edit, to: $0) }
    }

    func removeRule(_ rule: PermissionRule, in pane: Pane) {
        let edit = RuleEdit(behavior: rule.behavior, rule: rule.rule)
        guard let scope = rule.scope else { return }
        if scope == .session {
            pane.sessionRules.removeAll { $0 == edit }
            applySessionPermissions(pane)
            return
        }
        editSettings(scope, cwd: pane.cwd, then: pane) { try SettingsFile.removeRule(edit, from: $0) }
    }

    /// `/add-dir`: lets Claude work in another folder for this session. `~` and paths relative to the session's folder work.
    func addDirectory(_ raw: String, in pane: Pane) {
        let expanded = (raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) as NSString).expandingTildeInPath
        let path = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: pane.cwd, isDirectory: true)).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            pane.chat.note("\(path) is not a folder.", isError: true); return
        }
        guard !pane.extraDirs.contains(path), path != pane.cwd else { return }
        pane.extraDirs.append(path)
        applySessionPermissions(pane)
        pane.chat.note("Claude can now work in \(path) too, for this session.")
    }

    func removeDirectory(_ path: String, in pane: Pane) {
        pane.extraDirs.removeAll { $0 == path }
        applySessionPermissions(pane)
    }

    /// Saves the session's own rules and folders and sends them to the CLI; the reply re-reads the rule list.
    private func applySessionPermissions(_ pane: Pane) {
        save()
        let rules = pane.sessionRules, dirs = pane.extraDirs
        control(pane) { [$0.setSessionPermissions(rules: rules, directories: dirs)] }
    }

    /// Writes a settings file off the main thread. The CLI watches its settings files and applies the change itself;
    /// the session's rule list is re-read once its watcher has had a moment.
    func editSettings(_ scope: SettingsScope, cwd: String, then pane: Pane?, done: (@MainActor () -> Void)? = nil,
                      _ change: @escaping @Sendable (URL) throws -> Void) {
        guard let url = SettingsFile.url(scope, cwd: cwd) else { return }
        Task.detached {
            let result = Result { try change(url) }
            if case .success = result, scope == .projectLocal { SettingsFile.ensureIgnored(url, cwd: cwd) }
            await MainActor.run {
                if case .failure(let error) = result { self.errorMessage = error.localizedDescription }
                done?()
            }
            guard let pane else { return }
            try? await Task.sleep(for: .milliseconds(1500))
            await MainActor.run { self.control(pane) { $0.refresh(.permissions) } }
        }
    }

    /// Back from a browser sign-in: reconnect what needs it and re-read MCP status.
    private func returnedToApp() {
        for pane in panes where pane.isRunning && (!pane.chat.controls.signingIn.isEmpty || settingsSheet?.paneID == pane.id) {
            pane.run { chat in
                var out = chat.controls.takeReturnReconnects().map { chat.mcpReconnect($0) }
                out += chat.refresh(.mcp)
                return out
            }
        }
    }

    /// While a sign-in is pending, the CLI finishes it on its own; poll so the row turns connected.
    private func pollSignIns() {
        for pane in panes where pane.isRunning && !pane.chat.controls.signingIn.isEmpty {
            pane.chat.controls.signingIn = pane.chat.controls.signingIn.filter { now.timeIntervalSince($0.value) < 120 }
            guard !pane.chat.controls.signingIn.isEmpty, !pane.chat.controls.busy.contains("mcp") else { continue }
            pane.run { $0.refresh(.mcp) }
        }
    }

    // MARK: `//` messages between sessions

    /// The other open sessions, most recently active first, with recent conversation for ranking.
    func relayCandidates(excluding source: Pane) -> [RelayCandidate] {
        panes.filter { $0.id != source.id }
            .sorted { $0.lastActivity > $1.lastActivity }
            .map { pane in
                let recentText = pane.chat.items.suffix(12).compactMap { item -> String? in
                    switch item.kind {
                    case .user(let t), .assistant(let t), .received(_, let t): return t
                    case .tool(let call): return ToolSummary.summary(name: call.name, input: call.input)
                    default: return nil
                    }
                }.joined(separator: "\n")
                return RelayCandidate(id: pane.id, title: pane.title, project: pane.projectName,
                                      branch: pane.worktree?.branch, context: String(recentText.suffix(4000)))
            }
    }

    /// Sends `text` from one session to another right away. A busy target reads it after its running tool call.
    func relay(_ text: String, from source: Pane, to targetID: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let target = pane(targetID) else { return }
        let sentID = source.chat.recordSent(to: target.title, text: message, queued: true)
        let recordID = relayLog.add(source: (source.id, source.title), target: (target.id, target.title), text: message, queued: true)
        target.deliver(IncomingRelay(recordID: recordID, sourcePaneID: source.id, sourceTitle: source.title, sentItemID: sentID, text: message),
                       binDir: binDir, pluginDir: pluginDir)
        saveRelays()
    }

    /// The target's Claude read a `//` message, or answered it.
    private func relayUpdate(_ update: RelayUpdate, in target: Pane) {
        switch update {
        case .read(let item):
            guard let relay = target.answering[item] else { return }
            markRead(relay)
        case .answered(let item, let text):
            guard let relay = target.answering.removeValue(forKey: item) else { return }
            markRead(relay)
            returnReply(relay, from: target, text: text)
        }
        saveRelays()
    }

    private func markRead(_ relay: IncomingRelay) {
        if let sent = relay.sentItemID { pane(relay.sourcePaneID)?.chat.markDelivered(itemID: sent) }
        relayLog.markDelivered(relay.recordID)
    }

    /// Posts what a session said in answer to a `//` message back to the sender, right away.
    private func returnReply(_ relay: IncomingRelay, from target: Pane, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        relayLog.recordReply(relay.recordID, text: text)
        guard !text.isEmpty, let source = pane(relay.sourcePaneID) else { return }
        source.deliver(IncomingRelay(recordID: relay.recordID, sourcePaneID: target.id, sourceTitle: target.title, sentItemID: nil,
                                     text: text, isReply: true), binDir: binDir, pluginDir: pluginDir)
        if !(NSApp.isActive && selection == .pane(source.id)) {
            notifier.post(id: "reply:\(relay.recordID)", title: "\(source.title) · reply from \(target.title)",
                          body: String(text.prefix(180)), target: Target.pane(source.id).key, sound: false)
        }
    }

    func markMessagesSeen() {
        relayLog.lastSeen = Date()
        saveRelays()
    }

    // MARK: Ideas

    /// Projects an idea can be filed under: open sessions' projects in sidebar order, then others that have ideas.
    var ideaProjects: [String] {
        var seen = Set<String>()
        let open = panes.map(\.projectPath).filter { seen.insert($0).inserted }
        let others = ideas.ideas.map(\.project).filter { seen.insert($0).inserted }
            .sorted { Self.projectName($0).localizedStandardCompare(Self.projectName($1)) == .orderedAscending }
        return open + others
    }

    static func projectName(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

    func addIdea(_ text: String, project: String, by author: String) {
        guard ideas.add(text, project: project, by: author) != nil else { return }
        saveIdeas()
    }

    func editIdea(_ id: String, text: String) {
        ideas.edit(id, text: text)
        saveIdeas()
    }

    func setIdeaStatus(_ id: String, _ status: Idea.Status) {
        ideas.setStatus(id, status)
        saveIdeas()
    }

    func removeIdea(_ id: String) {
        ideas.remove(id)
        saveIdeas()
    }

    /// Starts a plan-mode session for an idea, in a new worktree when the project is a git repo.
    /// The idea is marked started, and linked to the session, once the session opens.
    func plan(_ idea: Idea) {
        guard !planningIdeas.contains(idea.id) else { return }
        planningIdeas.insert(idea.id)
        let project = idea.project
        Task.detached {
            let isRepo = Worktree.repoRoot(project) != nil
            await MainActor.run {
                self.createSession(NewSessionRequest(folder: project, profile: AccountPicker.usableDefault(self), useWorktree: isRepo,
                                                     name: idea.title, permissionMode: PermissionMode.plan.rawValue,
                                                     firstMessage: idea.text, ideaID: idea.id))
            }
        }
    }

    private func ensureRunning(_ pane: Pane) {
        if !pane.isRunning { pane.start(binDir: binDir, pluginDir: pluginDir) }
    }

    /// The chat notes the new mode once the CLI confirms it.
    func setMode(_ mode: String, in pane: Pane) {
        ensureRunning(pane)
        pane.run { [$0.setPermissionMode(mode)] }
    }

    /// Ends a session. Worktree removal runs in the background and reports failures.
    func close(_ pane: Pane, removeWorktree: Bool = false, deleteBranch: Bool = false) {
        pane.onStateChange = nil
        pane.stop()
        pane.closePreview()
        panes.removeAll { $0.id == pane.id }
        if selection == .pane(pane.id) { selection = panes.last.map { .pane($0.id) } }
        if settingsSheet?.paneID == pane.id { settingsSheet = nil }
        notifier.clear(target: Target.pane(pane.id).key)
        save()
        guard removeWorktree, let info = pane.worktree else { return }
        Task.detached {
            do {
                try Worktree.remove(info, deleteBranch: deleteBranch)
                await MainActor.run {
                    self.notifier.post(id: UUID().uuidString, title: "Worktree removed",
                                       body: deleteBranch ? "\(info.branch) and its worktree are gone." : "Kept branch \(info.branch).",
                                       target: "", sound: false)
                }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func requestClose(_ pane: Pane) {
        if pane.worktree != nil || pane.state == .working || pane.state.needsYou { closing = pane } else { close(pane) }
    }

    func openInVSCode(_ path: String) {
        guard let url = VSCodeLink.url(for: path) else { return }
        if NSWorkspace.shared.urlForApplication(toOpen: url) == nil {
            errorMessage = "VS Code is not installed or does not handle vscode:// links."
            return
        }
        NSWorkspace.shared.open(url)
    }

    func shutdown() {
        save()
        for pane in panes { pane.stop() }
    }

    // MARK: State, notifications, polling

    private func stateChanged(_ pane: Pane, from previous: PaneState) {
        updateBadge()
        let state = pane.state
        let target = Target.pane(pane.id)
        let focused = NSApp.isActive && selection == target
        if focused || !Self.notifies(state) { return }
        let body: String
        switch state {
        case .permission:
            let prompt = pane.chat.items.reversed().compactMap { item -> PermissionPrompt? in
                if case .permission(let p) = item.kind, p.decision == nil { return p }; return nil
            }.first
            body = prompt.map { "Allow Claude to use \($0.toolName)? \(ToolSummary.summary(name: $0.toolName, input: $0.input))" } ?? "Claude needs your permission."
        case .input:
            let asking = pane.chat.items.reversed().compactMap { item -> ElicitationPrompt? in
                if case .elicitation(let e) = item.kind, e.decision == nil { return e }; return nil
            }.first
            body = asking.map { "\($0.server) needs your input." } ?? "Claude has a question for you."
        case .plan: body = "A plan is ready for review."
        case .finished:
            guard previous == .working, pane.chat.turnStartedByUser else { return }
            body = "Finished" + (pane.chat.lastTurnSeconds.map { " in \(Self.duration($0))" } ?? "") + "."
        case .failed: body = "The last turn failed."
        default: return
        }
        notifier.post(id: "\(pane.id):\(state.rawValue):\(Date().timeIntervalSince1970)",
                      title: "\(pane.title) · \(state.label)", body: body, target: target.key, sound: state != .finished)
    }

    private func turnFinished(_ pane: Pane) {
        if let request = pane.pendingClose {
            pane.pendingClose = nil
            close(pane, removeWorktree: request.removeWorktree, deleteBranch: request.deleteBranch)
            return
        }
        refreshDiff(pane)
        save()
    }

    func refreshDiff(_ pane: Pane) {
        guard let info = pane.worktree else { return }
        Task.detached {
            let stat = Worktree.diffStat(info)
            await MainActor.run { pane.diffStat = stat }
        }
    }

    private func updateBadge() {
        let count = waitingCount
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    private func startTimers() {
        timers = [
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            },
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollExternal(); self?.drainRequests(); self?.pollSignIns() }
            },
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reloadStatus() }
            }
        ]
        for pane in panes where pane.worktree != nil { refreshDiff(pane) }
    }

    private func tick() {
        now = Date()
        for pane in panes {
            guard let cache = pane.chat.cache else { continue }
            let remaining = cache.remaining(at: now)
            let key = "\(pane.id):\(cache.generation)"
            if remaining > 0, remaining <= cacheWarning, !cacheAlerted.contains(key), pane.state != .working, Prefs.bool(Prefs.notifyCache) {
                cacheAlerted.insert(key)
                // Only worth a ping if the cache was warm long enough to matter.
                if cache.ttl > cacheWarning {
                    notifier.post(id: "cache:\(key)", title: "\(pane.title) · cache expiring",
                                  body: "About \(Int(ceil(remaining / 60)))m left. Send the next message soon to keep it warm.",
                                  target: Target.pane(pane.id).key, sound: false)
                }
            }
        }
    }

    private func pollExternal() {
        externalMonitor.poll { [weak self] sessions, bootstrap in
            guard let self else { return }
            let owned = Set(self.panes.compactMap { $0.chat.sessionID } + self.panes.compactMap { $0.spec.resume })
            let visible = sessions.filter { !owned.contains($0.id) }
            for session in visible {
                let previous = self.externalStates[session.id]
                self.externalStates[session.id] = session.state
                guard !bootstrap, previous != nil, previous != session.state, session.state.alerts,
                      !(session.automatedTurn && session.state == .finished),
                      Self.notifies(PaneState(session.state)) else { continue }
                let target = Target.external(session.id)
                if NSApp.isActive && self.selection == target { continue }
                self.notifier.post(id: "\(session.id):\(session.state.rawValue):\(session.stateAt.timeIntervalSince1970)",
                                   title: "\(session.projectName) · \(session.state.rawValue)",
                                   body: "Running outside Viber. Click to see it.", target: target.key,
                                   sound: session.state != .finished)
            }
            if self.externals.map(\.id) != visible.map(\.id) || self.externals.map(\.state) != visible.map(\.state)
                || self.externals.map(\.cache) != visible.map(\.cache) {
                self.externals = visible
            }
            self.updateBadge()
        }
    }

    private func drainRequests() {
        let requests = ViberRequest.drain()
        for request in requests {
            guard let pane = pane(request.paneID) else { continue }
            switch request.command {
            case .close:
                // Let Claude finish its reply first; the close happens when the turn ends.
                if pane.state == .working { pane.pendingClose = request }
                else { close(pane, removeWorktree: request.removeWorktree, deleteBranch: request.deleteBranch) }
            case .notify:
                notifier.post(id: UUID().uuidString, title: pane.title, body: request.text ?? "", target: Target.pane(pane.id).key)
            case .rename:
                if let text = request.text, !text.isEmpty { pane.title = text; save() }
            case .idea:
                addIdea(request.text ?? "", project: pane.projectPath, by: pane.title)
            }
        }
    }

    func reloadStatus() {
        Task.detached {
            var status: ClauthStatus?
            var note: String?
            let path = ViberPaths.clauthStatus
            let fresh = (try? path.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                .map { Date().timeIntervalSince($0) < 600 } ?? false
            if fresh, let data = try? Data(contentsOf: path) { status = ClauthStatus.decode(data) }
            if status == nil {
                let result = Shell.run("clauth", ["status", "--json"])
                status = result.ok ? ClauthStatus.decode(Data(result.stdout.utf8)) : nil
                if status != nil, !fresh { note = "clauth daemon is not running, so usage may be stale. Start it with: clauth daemon" }
                if status == nil { note = result.status == 127 ? "clauth not found" : "clauth status failed" }
            }
            let loaded = status, message = note
            await MainActor.run {
                if let loaded { self.status = loaded }
                self.statusNote = message
            }
        }
    }

    func reloadRecent() {
        Task.detached {
            let result = Shell.run("clauth", ["sessions", "--json"])
            let sessions = result.ok ? ClauthSession.decodeList(Data(result.stdout.utf8)) : []
            await MainActor.run { if !sessions.isEmpty { self.recent = sessions } }
        }
    }

    // MARK: Persistence

    func save() {
        let records = panes.map(\.record)
        do {
            try FileManager.default.createDirectory(at: ViberPaths.support, withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: ViberPaths.panes, options: .atomic)
        } catch {
            errorMessage = "Could not save open sessions: \(error.localizedDescription)"
        }
    }

    func saveRelays() {
        do {
            try FileManager.default.createDirectory(at: ViberPaths.support, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try encoder.encode(relayLog).write(to: ViberPaths.relays, options: .atomic)
        } catch {
            errorMessage = "Could not save messages: \(error.localizedDescription)"
        }
    }

    func saveIdeas() {
        do {
            try ideas.save()
        } catch {
            errorMessage = "Could not save ideas: \(error.localizedDescription)"
        }
    }

    private func restore() {
        ideas = IdeaList.load()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: ViberPaths.relays), let log = try? decoder.decode(RelayLog.self, from: data) {
            relayLog = log
        }
        guard let data = try? Data(contentsOf: ViberPaths.panes),
              let records = try? JSONDecoder().decode([PaneRecord].self, from: data) else { return }
        panes = records.map(Pane.init(record:))
        panes.forEach(wire)
    }

    /// Settings → General: which state changes post a notification.
    static func notifies(_ state: PaneState) -> Bool {
        state.needsYou ? Prefs.bool(Prefs.notifyNeedsYou) : Prefs.bool(Prefs.notifyFinished)
    }

    // MARK: Formatting

    static func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    static func duration(_ seconds: Double) -> String {
        seconds >= 60 ? "\(Int(seconds) / 60)m \(Int(seconds) % 60)s" : "\(Int(seconds))s"
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return s >= 3600 ? "60:00" : String(format: "%d:%02d", s / 60, s % 60)
    }
}
