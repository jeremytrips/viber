import AppKit
import Foundation
import Observation
import ViberCore

/// Sidebar selection: a Viber pane, or a session running somewhere else.
enum Target: Hashable {
    case pane(String)
    case external(String)

    var key: String {
        switch self {
        case .pane(let id): return "pane:\(id)"
        case .external(let id): return "ext:\(id)"
        }
    }

    init?(key: String) {
        if key.hasPrefix("pane:") { self = .pane(String(key.dropFirst(5))) }
        else if key.hasPrefix("ext:") { self = .external(String(key.dropFirst(4))) }
        else { return nil }
    }
}

struct NewSessionRequest {
    var folder: String
    var profile: String?
    var useWorktree: Bool
    var name: String
    var permissionMode: String
    var firstMessage: String
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
    var cacheWarning: TimeInterval = 120

    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored private let externalMonitor = ExternalMonitor()
    @ObservationIgnored private var externalStates: [String: SessionState] = [:]
    @ObservationIgnored private var cacheAlerted: Set<String> = []
    @ObservationIgnored private var timers: [Timer] = []
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
        restore()
        notifier.onOpen = { [weak self] key in
            guard let self, let target = Target(key: key) else { return }
            self.select(target)
        }
        notifier.setUp()
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
        if request.useWorktree {
            let folder = request.folder, name = request.name.isEmpty ? title : request.name
            Task.detached {
                let result = Result { try Worktree.create(repoDir: folder, name: name) }
                await MainActor.run {
                    switch result {
                    case .success(let info):
                        self.open(title: title, spec: LaunchSpec(profile: request.profile, cwd: info.path, permissionMode: mode),
                                  worktree: info, firstMessage: request.firstMessage)
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        } else {
            open(title: title, spec: LaunchSpec(profile: request.profile, cwd: request.folder, permissionMode: mode),
                 worktree: nil, firstMessage: request.firstMessage)
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

    private func open(title: String, spec: LaunchSpec, worktree: WorktreeInfo?, firstMessage: String) {
        let pane = Pane(title: title, spec: spec, worktree: worktree)
        wire(pane)
        panes.append(pane)
        save()
        select(.pane(pane.id))
        let text = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { submit(text, in: pane) }
    }

    private func wire(_ pane: Pane) {
        pane.onStateChange = { [weak self] pane, previous in self?.stateChanged(pane, from: previous) }
        pane.onTurnFinished = { [weak self] pane in self?.turnFinished(pane) }
    }

    /// Routes composer text: skills go to the CLI, terminal-only commands are handled here.
    func submit(_ text: String, in pane: Pane) {
        switch SlashRouter.route(text, commands: pane.chat.commands) {
        case .send(let message):
            guard !message.isEmpty else { return }
            pane.sendUser(message, binDir: binDir, pluginDir: pluginDir)
        case .setMode(let mode, let then):
            ensureRunning(pane)
            pane.run { [$0.setPermissionMode(mode)] }
            pane.chat.note(mode == "plan" ? "Plan mode is on. Claude plans first and edits only after you approve." : "Mode: \(Self.modeLabel(mode))")
            if let then { pane.sendUser(then, binDir: binDir, pluginDir: pluginDir) }
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
        }
    }

    private func ensureRunning(_ pane: Pane) {
        if !pane.isRunning { pane.start(binDir: binDir, pluginDir: pluginDir) }
    }

    /// Ends a session. Worktree removal runs in the background and reports failures.
    func close(_ pane: Pane, removeWorktree: Bool = false, deleteBranch: Bool = false) {
        pane.onStateChange = nil
        pane.stop()
        panes.removeAll { $0.id == pane.id }
        if selection == .pane(pane.id) { selection = panes.last.map { .pane($0.id) } }
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
        if focused { return }
        let body: String
        switch state {
        case .permission:
            let prompt = pane.chat.items.reversed().compactMap { item -> PermissionPrompt? in
                if case .permission(let p) = item.kind, p.decision == nil { return p }; return nil
            }.first
            body = prompt.map { "Allow Claude to use \($0.toolName)? \(ToolSummary.summary(name: $0.toolName, input: $0.input))" } ?? "Claude needs your permission."
        case .input: body = "Claude has a question for you."
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
                Task { @MainActor in self?.pollExternal(); self?.drainRequests() }
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
            if remaining > 0, remaining <= cacheWarning, !cacheAlerted.contains(key), pane.state != .working {
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
                      !(session.automatedTurn && session.state == .finished) else { continue }
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

    private func restore() {
        guard let data = try? Data(contentsOf: ViberPaths.panes),
              let records = try? JSONDecoder().decode([PaneRecord].self, from: data) else { return }
        panes = records.map(Pane.init(record:))
        panes.forEach(wire)
    }

    // MARK: Formatting

    static func modeLabel(_ mode: String?) -> String {
        switch mode {
        case "acceptEdits": return "Edit automatically"
        case "plan": return "Plan mode"
        case "bypassPermissions": return "Bypass permissions"
        case "auto": return "Auto"
        default: return "Ask before edits"
        }
    }

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
