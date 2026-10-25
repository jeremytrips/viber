import AppKit
import Foundation
import Observation
import ViberCore

/// Sidebar selection: a Viber pane, a project's page, or a session running somewhere else.
enum Target: Hashable {
    case pane(String)
    case external(String)
    /// A project's page, by its path.
    case project(String)
    /// Every project's issues that are not planned yet.
    case issues
    /// A worktree being set up for a new session.
    case job(String)

    var key: String {
        switch self {
        case .issues: return "issues"
        case .pane(let id): return "pane:\(id)"
        case .external(let id): return "ext:\(id)"
        case .job(let id): return "job:\(id)"
        case .project(let path): return "project:\(path)"
        }
    }

    init?(key: String) {
        if key == "issues" || key == "ideas" { self = .issues }
        else if key.hasPrefix("pane:") { self = .pane(String(key.dropFirst(5))) }
        else if key.hasPrefix("ext:") { self = .external(String(key.dropFirst(4))) }
        else if key.hasPrefix("job:") { self = .job(String(key.dropFirst(4))) }
        else if key.hasPrefix("project:") { self = .project(String(key.dropFirst(8))) }
        else { return nil }
    }
}

/// The Autopilot sheet, on a project's issues to plan or on one of them.
struct AutopilotSheetRequest: Identifiable {
    var project: String
    /// Just this issue; nil for every issue still to plan.
    var issueID: String?
    var id: String { project + "|" + (issueID ?? "") }
}

/// The Autopilot sheet on a Jira project: an epic's issues, or chosen ones.
struct JiraRunSheetRequest: Identifiable {
    var project: String
    var epic: JiraIssue?
    var keys: [String]
    var id: String { project + "|" + (epic?.key ?? keys.joined(separator: ",")) }
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
    /// The worktree's branch; nil for `branchPattern` filled in with the name.
    var branch: String? = nil
    /// Where a git worktree's branch starts.
    var base: WorktreeBase = .originDefault
    /// A branch to start from instead: what an autopilot issue builds on when that isn't merged yet.
    var startBranch: String? = nil
    /// The Jira issue a Jira autopilot run starts this session for, and rules the session starts with.
    var jiraRunKey: String? = nil
    var sessionRules: [RuleEdit] = []
    var permissionMode: String
    var firstMessage: String
    /// The issue this session is started for, linked to it once it opens.
    var issueID: String?
    /// Its key, such as `EST-12`, which `<key>` in the branch pattern becomes.
    var issueKey: String? = nil
    /// The project's branch pattern, such as `viber/<slug>`.
    var branchPattern = Worktree.defaultBranchPattern
}

@MainActor @Observable
final class AppModel {
    var panes: [Pane] = []
    var selection: Target?
    var status: ClauthStatus?
    var statusNote: String?
    /// clauth profiles with a browser login in flight.
    var loggingIn: Set<String> = []
    var externals: [Session] = []
    var recent: [ClauthSession] = []
    var now = Date()
    var errorMessage: String?
    var showNewSession = false
    /// Starting values for the next New Session sheet.
    var newSessionPrefill: NewSessionRequest?
    /// The folder the next New Session sheet starts in, such as the project whose + was clicked.
    var newSessionFolder: String?
    /// The projects in the sidebar, kept while none of their sessions is open.
    var projects = ProjectList()
    /// The project being renamed, by its path.
    var renamingProject: String?
    /// The project each folder in `recent` belongs to.
    var recentRoots: [String: String] = [:]
    var showSwitcher = false
    var showResume = false
    var closing: Pane?
    var settingsSheet: SettingsSheetRequest?
    var cacheWarning: TimeInterval { TimeInterval(max(Prefs.int(Prefs.cacheWarningMinutes), 1) * 60) }
    var issues = IssueList()
    /// Projects whose issues come from Jira.
    var trackers = TrackerList()
    /// What each project's sessions do once a request is done, by its path. A missing one is off.
    var requestChecks: [String: RequestCheck] = [:]
    var jiraSites: [JiraSite] = []
    /// What each Jira project's Planning tab shows, kept while the app runs.
    var jiraBoards: [String: JiraBoard] = [:]
    /// Simulators, shared by every session's device panel and device tools.
    let deviceHub = DeviceHub()
    /// Issues whose session is being created, so Plan can't start two.
    var planningIssues: Set<String> = []
    /// An issue Start was pressed on while something still blocks it; an alert asks whether to start it anyway.
    var blockedStart: Issue?
    /// Worktrees being set up for new sessions, shown in the sidebar until their session opens.
    var jobs: [WorktreeJob] = []
    /// Projects whose issues are being implemented one after another, by path.
    var autopilots: [String: Autopilot] = [:]
    /// The autopilot on Jira projects, by project; runs that ended stay in `finishedJiraRuns` until dismissed.
    var jiraRuns: [String: JiraRun] = [:]
    var finishedJiraRuns: [String: JiraRun] = [:]
    var jiraRunSheet: JiraRunSheetRequest?
    /// Runs that ended, kept on the project's page until dismissed so you can see what they did.
    var finishedAutopilots: [String: Autopilot] = [:]
    var autopilotSheet: AutopilotSheetRequest?

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
    func job(_ id: String) -> WorktreeJob? { jobs.first { $0.id == id } }
    var selectedPane: Pane? { if case .pane(let id)? = selection { return pane(id) }; return nil }
    var selectedJob: WorktreeJob? { if case .job(let id)? = selection { return job(id) }; return nil }
    var selectedExternal: Session? {
        if case .external(let id)? = selection { return externals.first { $0.id == id } }
        return nil
    }
    /// The project whose page is shown.
    var selectedProjectPage: String? { if case .project(let path)? = selection { return path }; return nil }
    /// The project of whatever is selected: its page, one of its sessions, or a worktree being set up for it.
    var selectedProject: String? { selectedProjectPage ?? selectedPane?.projectPath ?? selectedJob?.project }
    var waitingCount: Int { panes.filter { $0.state.needsYou }.count + externals.filter { [.input, .plan, .permission].contains($0.state) }.count }
    var profiles: [ClauthStatus.Profile] { status?.profiles ?? [] }
    var defaultProfile: String? { status?.activeProfile }
    /// The account the top bar shows: the selected chat's, else clauth's default. Nil means the plain `claude` login.
    var shownProfileName: String? { selectedPane.map { $0.spec.profile } ?? defaultProfile }

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
        if case .pane(let id) = target, let pane = pane(id) {
            // ⌘J or a notification can pick a session whose project is folded away.
            if projects.project(pane.projectPath)?.isCollapsed == true { setCollapsed(pane.projectPath, false) }
            if !pane.started { pane.start(binDir: binDir, pluginDir: pluginDir) }
        }
    }

    /// ⌘1…⌘9, counted down the sidebar.
    func select(index: Int) {
        let ordered = orderedPanes
        guard ordered.indices.contains(index) else { return }
        select(.pane(ordered[index].id))
    }

    func selectNextWaiting() {
        let waiting: [Target] = panes.filter { $0.state.needsYou }.map { .pane($0.id) }
            + externals.filter { [.input, .plan, .permission].contains($0.state) }.map { .external($0.id) }
        guard !waiting.isEmpty else { return }
        let index = selection.flatMap { waiting.firstIndex(of: $0) }.map { ($0 + 1) % waiting.count } ?? 0
        select(waiting[index])
    }

    // MARK: Sessions

    func createSession(_ request: NewSessionRequest, selecting: Bool = true) {
        ensureProject(ProjectRoot.resolve(request.folder))
        let title = request.name.isEmpty ? (request.firstMessage.isEmpty ? URL(fileURLWithPath: request.folder).lastPathComponent : String(request.firstMessage.prefix(50))) : request.name
        let mode = request.permissionMode == "default" ? nil : request.permissionMode
        let model = Prefs.string(Prefs.newSessionModel)
        let launchModel = model.isEmpty ? nil : model
        // Also for issues started from the sheet, so Plan can't start a second session while the worktree is made.
        if let id = request.issueID { planningIssues.insert(id) }
        if request.useWorktree {
            let job = WorktreeJob(creating: request, title: title)
            jobs.append(job)
            if selecting { select(.job(job.id)) }
            run(job)
        } else {
            open(title: title, spec: LaunchSpec(profile: request.profile, cwd: request.folder, permissionMode: mode, model: launchModel),
                 worktree: nil, firstMessage: request.firstMessage, issueID: request.issueID, jiraRunKey: request.jiraRunKey,
                 rules: request.sessionRules, selecting: selecting)
        }
    }

    func resume(_ session: ClauthSession, profile: String?) {
        if let existing = panes.first(where: { $0.spec.resume == session.id || $0.chat.sessionID == session.id }) {
            select(.pane(existing.id)); return
        }
        guard let folder = session.workspace else { errorMessage = "This session has no recorded folder."; return }
        open(title: session.title, spec: LaunchSpec(profile: profile, cwd: folder, resume: session.id), worktree: nil, firstMessage: "")
    }

    /// Restart a session's Claude process, keeping the conversation (e.g. after logging in again).
    func restart(_ pane: Pane) {
        pane.restart(binDir: binDir, pluginDir: pluginDir)
        pane.chat.note("Restarted Claude.")
    }

    func continueHere(_ session: Session) {
        if let existing = panes.first(where: { $0.spec.resume == session.id || $0.chat.sessionID == session.id }) {
            select(.pane(existing.id)); return
        }
        let title = recent.first(where: { $0.id == session.id })?.title ?? session.projectName
        open(title: title, spec: LaunchSpec(profile: defaultProfile, cwd: session.project, resume: session.id), worktree: nil, firstMessage: "")
    }

    @discardableResult
    private func open(title: String, spec: LaunchSpec, worktree: WorktreeInfo?, firstMessage: String, issueID: String? = nil,
                      jiraRunKey: String? = nil, rules: [RuleEdit] = [], selecting: Bool = true) -> Pane {
        let pane = Pane(title: title, spec: spec, worktree: worktree)
        pane.jiraRunKey = jiraRunKey
        pane.jiraServers = trackers.tracker(for: pane.projectPath)?.mcpServers ?? []
        pane.sessionRules = rules
        wire(pane)
        panes.append(pane)
        ensureProject(pane.projectPath)
        save()
        if let issueID {
            planningIssues.remove(issueID)
            issues.start(issueID, sessionID: pane.id, sessionTitle: title)
            saveIssues()
        }
        if selecting { select(.pane(pane.id)) }
        let text = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { submit(text, in: pane) }
        return pane
    }

    // MARK: Worktree setup and teardown

    /// Runs the job off the main thread (a project hook can take minutes): makes the worktree and opens its
    /// session, or removes a closed session's worktree.
    private func run(_ job: WorktreeJob) {
        job.reset()
        let report: @Sendable (WorktreeProgress) -> Void = { progress in
            // The main queue keeps the pieces in order.
            DispatchQueue.main.async { MainActor.assumeIsolated { job.apply(progress) } }
        }
        switch job.kind {
        case .create(let request):
            let worktreeRequest = WorktreeRequest(folder: request.folder, name: request.name.isEmpty ? job.title : request.name,
                                                  branch: request.branch, branchPattern: request.branchPattern, issueKey: request.issueKey,
                                                  base: request.base, startBranch: request.startBranch, permissionMode: request.permissionMode)
            job.task = Task {
                do {
                    let info = try await Worktree.create(worktreeRequest, progress: report)
                    job.flush()
                    guard jobs.contains(where: { $0.id == job.id }) else { return }
                    finish(job, request: request, info: info)
                } catch {
                    if let id = request.issueID { planningIssues.remove(id) }
                    fail(job, error, title: "worktree setup failed")
                    if let id = request.issueID { autopilotSetupFailed(id, error) }
                    if let key = request.jiraRunKey { jiraSetupFailed(key, project: job.project, error) }
                }
            }
        case .remove(let info, let deleteBranch):
            job.task = Task {
                do {
                    let summary = try await Worktree.remove(info, deleteBranch: deleteBranch, progress: report)
                    job.flush()
                    guard jobs.contains(where: { $0.id == job.id }) else { return }
                    remove(job)
                    notifier.post(id: "job:\(job.id):removed", title: "Worktree removed", body: summary, target: "", sound: false)
                } catch let kept as BranchKept {
                    // The worktree is gone; only the branch stayed, which is how `branch -d` keeps unmerged work.
                    job.flush()
                    guard jobs.contains(where: { $0.id == job.id }) else { return }
                    remove(job)
                    errorMessage = kept.message
                } catch {
                    fail(job, error, title: "worktree removal failed")
                }
            }
        }
    }

    private func finish(_ job: WorktreeJob, request: NewSessionRequest, info: WorktreeInfo) {
        let mode = request.permissionMode == "default" ? nil : request.permissionMode
        let model = Prefs.string(Prefs.newSessionModel)
        let watching = selection == .job(job.id)
        jobs.removeAll { $0.id == job.id }
        let pane = open(title: job.title, spec: LaunchSpec(profile: request.profile, cwd: info.path, permissionMode: mode,
                                                           model: model.isEmpty ? nil : model),
                        worktree: info, firstMessage: request.firstMessage, issueID: request.issueID, jiraRunKey: request.jiraRunKey,
                        rules: request.sessionRules, selecting: watching)
        // An autopilot's sessions start unwatched by design.
        if !(NSApp.isActive && watching), request.issueID.flatMap(autopilotProject(working:)) == nil, request.jiraRunKey == nil {
            notifier.post(id: "job:\(job.id):ready", title: "\(job.title) · worktree ready",
                          body: "The session has started in \((info.path as NSString).abbreviatingWithTildeInPath).",
                          target: Target.pane(pane.id).key, sound: false)
        }
    }

    /// The job stays in the sidebar with its output and the error, so it can be read and tried again.
    private func fail(_ job: WorktreeJob, _ error: Error, title: String) {
        job.flush()
        guard jobs.contains(where: { $0.id == job.id }) else { return }
        job.phase = .failed(error.localizedDescription)
        if !(NSApp.isActive && selection == .job(job.id)) {
            notifier.post(id: "job:\(job.id):failed", title: "\(job.title) · \(title)",
                          body: String(error.localizedDescription.prefix(180)), target: Target.job(job.id).key)
        }
    }

    /// Stops a running job; it stays, marked failed, so its output can still be read.
    func cancel(_ job: WorktreeJob) {
        job.task?.cancel()
    }

    func retry(_ job: WorktreeJob) {
        guard !job.isRunning else { return }
        if let id = job.issueID { planningIssues.insert(id) }
        run(job)
    }

    func dismiss(_ job: WorktreeJob) {
        job.task?.cancel()
        remove(job)
    }

    private func remove(_ job: WorktreeJob) {
        jobs.removeAll { $0.id == job.id }
        if selection == .job(job.id) { selection = .project(job.project) }
        notifier.clear(target: Target.job(job.id).key)
    }

    private func wire(_ pane: Pane) {
        pane.onStateChange = { [weak self] pane, previous in self?.stateChanged(pane, from: previous) }
        pane.onTurnFinished = { [weak self] pane in self?.turnFinished(pane) }
        pane.onRequestStarted = { [weak self] pane in self?.requestStarted(pane) }
        pane.onRelayUpdate = { [weak self] pane, update in self?.relayUpdate(update, in: pane) }
        pane.onJiraHold = { [weak self] pane, what in self?.holdJiraRun(pane, what) }
        pane.onOpenURL = { NSWorkspace.shared.open($0) }
        pane.onPersist = { [weak self] in self?.save() }
        pane.deviceHub = deviceHub
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
                                      branch: pane.branch, context: String(recentText.suffix(4000)))
            }
    }

    /// Sends `text` from one session to another right away. A busy target reads it after its running tool call.
    func relay(_ text: String, from source: Pane, to targetID: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let target = pane(targetID) else { return }
        let sentID = source.chat.recordSent(to: target.title, text: message)
        target.deliver(IncomingRelay(sourcePaneID: source.id, sourceTitle: source.title, sentItemID: sentID, text: message),
                       binDir: binDir, pluginDir: pluginDir)
    }

    /// The target's Claude read a `//` message, or answered it.
    private func relayUpdate(_ update: RelayUpdate, in target: Pane) {
        switch update {
        case .read(let item):
            guard let relay = target.answering[item], let sent = relay.sentItemID else { return }
            pane(relay.sourcePaneID)?.chat.setSentStatus(itemID: sent, .delivered)
        case .answered(let item, let text):
            guard let relay = target.answering.removeValue(forKey: item) else { return }
            returnReply(relay, from: target, text: text)
        }
    }

    /// Posts what a session said in answer to a `//` message back to the sender, right away.
    private func returnReply(_ relay: IncomingRelay, from target: Pane, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source = pane(relay.sourcePaneID) else { return }
        if let sent = relay.sentItemID { source.chat.setSentStatus(itemID: sent, text.isEmpty ? .noReply : .replied) }
        guard !text.isEmpty else { return }
        source.deliver(IncomingRelay(sourcePaneID: target.id, sourceTitle: target.title, sentItemID: nil, text: text, isReply: true),
                       binDir: binDir, pluginDir: pluginDir)
        if !(NSApp.isActive && selection == .pane(source.id)) {
            notifier.post(id: "reply:\(UUID().uuidString)", title: "\(source.title) · reply from \(target.title)",
                          body: String(text.prefix(180)), target: Target.pane(source.id).key, sound: false)
        }
    }

    // MARK: Issues

    /// Projects an issue can be filed under: the sidebar's, then others that have issues.
    var issueProjects: [String] {
        var seen = Set<String>()
        let listed = sidebarProjects.map(\.path).filter { seen.insert($0).inserted }
        let others = issues.issues.map(\.project).filter { seen.insert($0).inserted }
            .sorted { Self.projectName($0).localizedStandardCompare(Self.projectName($1)) == .orderedAscending }
        return listed + others
    }

    static func projectName(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

    /// A project's name as the sidebar shows it: the one the user gave it, else its folder's.
    func projectName(_ path: String) -> String { projects.project(path)?.name ?? Self.projectName(path) }

    // MARK: Projects

    /// The sidebar's projects, plus any that an open session or worktree job belongs to but the list lacks.
    var sidebarProjects: [Project] {
        var list = projects.projects
        for path in panes.map(\.projectPath) + jobs.map(\.project) where !list.contains(where: { $0.path == path }) {
            list.append(Project(path: path, addedAt: Date()))
        }
        return list
    }

    /// Open sessions in sidebar order: by project, then in the order they were opened.
    var orderedPanes: [Pane] {
        sidebarProjects.flatMap { project in panes.filter { $0.projectPath == project.path } }
    }

    /// Adds the project `folder` belongs to (its repository's main checkout) and returns its path.
    @discardableResult
    func addProject(_ folder: String) -> String {
        let path = ProjectRoot.resolve(folder)
        ensureProject(path)
        return path
    }

    private func ensureProject(_ path: String) {
        if projects.add(path) { saveProjects() }
    }

    /// Asks for a folder and shows its project's page.
    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Choose a folder or git repository. A folder inside a repository adds the whole repository."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        select(.project(addProject(url.path)))
    }

    /// Whether the project can leave the sidebar: not while a session or worktree job of it is open.
    func canRemoveProject(_ path: String) -> Bool {
        !panes.contains { $0.projectPath == path } && !jobs.contains { $0.project == path }
    }

    /// Takes a project out of the sidebar. Its folder, issues and settings stay; adding it again brings them back.
    func removeProject(_ path: String) {
        guard canRemoveProject(path) else { return }
        projects.remove(path)
        saveProjects()
        if selection == .project(path) { selection = nil }
    }

    func renameProject(_ path: String, to name: String) {
        projects.rename(path, to: name)
        saveProjects()
    }

    func setCollapsed(_ path: String, _ collapsed: Bool) {
        guard projects.project(path)?.isCollapsed != collapsed else { return }
        projects.setCollapsed(path, collapsed)
        saveProjects()
    }

    /// Opens the New Session sheet on a project, or on a folder in it.
    func newSession(in folder: String) {
        newSessionFolder = folder
        showNewSession = true
    }

    /// Starts a session in a worktree that already exists, such as one a session before it left behind.
    func openSession(inWorktree entry: WorktreeEntry) {
        let name = entry.branch.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? Project.folderName(entry.path)
        createSession(NewSessionRequest(folder: entry.path, profile: AccountPicker.usableDefault(self), useWorktree: false, name: name,
                                        permissionMode: Prefs.string(Prefs.newSessionMode), firstMessage: "", issueID: nil))
    }

    @discardableResult
    func addIssue(_ text: String, project: String, by author: String, parent: String? = nil, blockedBy: [String] = []) -> Issue? {
        guard let issue = issues.add(text, project: project, by: author, parent: parent, blockedBy: blockedBy) else { return nil }
        saveIssues()
        // Issues you write while the project's autopilot runs join its queue. Ones its sessions add wait for you,
        // so a run can't keep feeding itself.
        if author == "you" { autopilots[project]?.enqueue(issue.id) }
        return issue
    }

    func setIssueLinks(_ id: String, parent: String?, blockedBy: [String]) {
        issues.setLinks(id, parent: parent, blockedBy: blockedBy)
        saveIssues()
    }

    func commentIssue(_ id: String, _ text: String) {
        issues.comment(id, text, by: "you")
        saveIssues()
    }

    func setIssuePrefix(_ prefix: String, project: String) {
        issues.setPrefix(prefix, project: project)
        saveIssues()
    }

    /// The issue a session works on: the one it was started for, else the one its branch is named after.
    func issue(for pane: Pane) -> Issue? {
        issues.issue(startedIn: pane.id) ?? pane.branch.flatMap { issues.issue(forBranch: $0, in: pane.projectPath) }
    }

    /// `viber issue shipped`, which /ship runs: the session's issue is in review, with a note on what landed.
    private func shipped(from pane: Pane, text: String) {
        guard let issue = issue(for: pane), issue.status != .done else { return }
        if issue.status == .open { issues.start(issue.id, sessionID: pane.id, sessionTitle: pane.title) }
        issues.setStatus(issue.id, .review)
        issues.comment(issue.id, text.isEmpty ? "Shipped: the branch is ready to merge." : text, by: pane.title)
        saveIssues()
    }

    func editIssue(_ id: String, text: String) {
        issues.edit(id, text: text)
        saveIssues()
    }

    func setIssueStatus(_ id: String, _ status: Issue.Status) {
        issues.setStatus(id, status)
        saveIssues()
        releaseFromAutopilot(id, finished: status == .done)
    }

    func removeIssue(_ id: String) {
        issues.remove(id)
        saveIssues()
        releaseFromAutopilot(id, finished: false)
    }

    /// Start on an issue: a plan-mode session for it, unless something still blocks it, in which case an alert asks.
    func startIssue(_ issue: Issue) {
        if issues.blockers(of: issue).isEmpty { plan(issue) } else { blockedStart = issue }
    }

    /// Starts a plan-mode session for an issue, in a new worktree when the project is a git repo.
    /// The issue is marked started, and linked to the session, once the session opens.
    func plan(_ issue: Issue) {
        guard !planningIssues.contains(issue.id) else { return }
        planningIssues.insert(issue.id)
        let project = issue.project
        Task.detached {
            let root = Worktree.repoRoot(project)
            let key = root.map { WorktreeHooks.mainCheckout($0) ?? $0 }
            await MainActor.run {
                let pattern = key.map { Prefs.branchPattern(project: $0) } ?? Worktree.defaultBranchPattern
                let request = NewSessionRequest(folder: project, profile: AccountPicker.usableDefault(self), useWorktree: root != nil,
                                                name: issue.title, permissionMode: PermissionMode.plan.rawValue,
                                                firstMessage: self.firstMessage(for: issue), issueID: issue.id, issueKey: issue.key,
                                                branchPattern: pattern)
                guard root != nil, Worktree.needsInput(pattern, key: issue.key) else { self.createSession(request); return }
                // The branch needs a part only the user knows, such as a ticket number: ask in the sheet.
                self.planningIssues.remove(issue.id)
                self.newSessionPrefill = request
                Task {
                    // The issues popover closes in the same click.
                    try? await Task.sleep(for: .milliseconds(200))
                    self.showNewSession = true
                }
            }
        }
    }

    /// What a session started for an issue reads first: the issue with its key, what it is part of or waits for,
    /// and the notes on it.
    func firstMessage(for issue: Issue) -> String {
        var lines = ["\(issue.key): \(issue.text)"]
        if let parent = issue.parentID.flatMap({ issues.issue($0) }) { lines.append("\nPart of \(parent.key): \(parent.title)") }
        let blockers = issues.blockers(of: issue)
        if !blockers.isEmpty { lines.append("\nStill blocked by " + blockers.map { "\($0.key) (\($0.status.label.lowercased()))" }.joined(separator: ", ") + ".") }
        if !issue.comments.isEmpty {
            lines.append("\nNotes on it:")
            lines += issue.comments.map { "- \($0.by == "you" ? "the user" : $0.by): \($0.text)" }
        }
        lines.append("\n(`viber issue show \(issue.key)` prints this again; `viber issue` prints which issue this session is on.)")
        return lines.joined(separator: "\n")
    }

    // MARK: Usage limits

    /// A turn that stopped at the account's usage limit: carry on once the limit resets, unless that's turned off
    /// or the limit kept outlasting its reset time.
    private func waitOutLimit(_ pane: Pane) {
        guard let limit = pane.chat.usageLimit, Prefs.bool(Prefs.continueAfterLimit) else { pane.continueAt = nil; return }
        pane.continueAt = limit.continueAt(now: Date())
    }

    /// Sends on the sessions whose limit has reset. A message sent meanwhile takes the wait's place.
    private func continueLimitedSessions() {
        for pane in panes {
            guard let at = pane.continueAt else { continue }
            if pane.chat.usageLimit == nil { pane.continueAt = nil; continue }
            guard at <= now, [.failed, .finished, .idle, .exited].contains(pane.state) else { continue }
            continueAfterLimit(pane)
        }
    }

    /// Tells a session the limit stopped to carry on. An autopilot session resumes its run, which tells it.
    func continueAfterLimit(_ pane: Pane) {
        pane.continueAt = nil
        if let project = issues.issue(startedIn: pane.id).flatMap({ autopilotProject(working: $0.id) }), autopilots[project]?.paused != nil {
            resumeAutopilot(project)
        } else {
            pane.sendUser(UsageLimit.continueMessage, binDir: binDir, pluginDir: pluginDir, continuing: true)
        }
    }

    /// Leaves the session where the limit stopped it.
    func cancelContinue(_ pane: Pane) {
        pane.continueAt = nil
    }

    /// "Hit the session limit. Viber carries on at 23:31."
    func limitNotice(_ limit: UsageLimit, continueAt: Date?) -> String {
        let hit = "Hit the \(limit.name)."
        if let continueAt { return hit + " Viber carries on at \(Self.clock(continueAt, now: now))." }
        if let reset = limit.resetsAt, reset > now { return hit + " It resets at \(Self.clock(reset, now: now))." }
        return hit
    }

    // MARK: Jira

    func addJiraSite(_ site: JiraSite, token: String) {
        JiraKeychain.set(token, for: site.host)
        jiraSites.removeAll { $0.host == site.host }
        jiraSites.append(site)
        saveJiraSites()
    }

    func updateJiraSite(_ site: JiraSite, displayName: String) {
        guard let index = jiraSites.firstIndex(where: { $0.host == site.host }) else { return }
        jiraSites[index].displayName = displayName
        saveJiraSites()
    }

    func removeJiraSite(_ site: JiraSite) {
        JiraKeychain.remove(for: site.host)
        jiraSites.removeAll { $0.host == site.host }
        saveJiraSites()
        for (project, board) in jiraBoards where board.site?.host == site.host { board.update(tracker: board.tracker, site: nil); _ = project }
    }

    private func saveJiraSites() {
        UserDefaults.standard.set(try? JSONEncoder().encode(jiraSites), forKey: Prefs.jiraSites)
    }

    func setTracker(_ tracker: ProjectTracker?, for project: String) {
        trackers.set(tracker, for: project)
        do { try trackers.save() } catch { errorMessage = "Could not save the project's tracker: \(error.localizedDescription)" }
        if let tracker {
            if let board = jiraBoards[project] { board.update(tracker: tracker, site: jiraSites.first { $0.host == tracker.site }) }
        } else {
            jiraBoards[project] = nil
        }
    }

    /// The Jira board of a project that reads its issues from Jira, loading it the first time.
    func jiraBoard(for project: String) -> JiraBoard? {
        guard let tracker = trackers.tracker(for: project) else { return nil }
        if let board = jiraBoards[project] { return board }
        let board = JiraBoard(project: project, tracker: tracker, site: jiraSites.first { $0.host == tracker.site })
        jiraBoards[project] = board
        board.load()
        return board
    }

    /// The Jira key a session's branch names, in a project that uses Jira.
    func jiraKey(for pane: Pane) -> String? {
        guard trackers.tracker(for: pane.projectPath) != nil, let branch = pane.branch else { return nil }
        return JiraIssue.key(inBranch: branch)
    }

    /// The Jira issue a session is on, as far as its project's board knows it; the board fetches it if needed.
    func jiraIssue(for pane: Pane) -> (key: String, issue: JiraIssue?)? {
        guard let key = jiraKey(for: pane), let board = jiraBoard(for: pane.projectPath) else { return nil }
        board.ensure(key)
        return (key, board.known[key])
    }

    /// Start on a Jira issue: a session in a new worktree whose first message is the tracker's, such as
    /// `/work-issue NEX-233`, so the repository's own skill takes it from there (and moves the issue in Jira).
    func startJiraIssue(_ issue: JiraIssue, project: String) {
        guard let tracker = trackers.tracker(for: project) else { return }
        Task.detached {
            let root = Worktree.repoRoot(project)
            let key = root.map { WorktreeHooks.mainCheckout($0) ?? $0 }
            await MainActor.run {
                let pattern = key.map { Prefs.branchPattern(project: $0) } ?? Worktree.defaultBranchPattern
                let profile = tracker.profile.flatMap { name in self.profiles.contains { $0.name == name && $0.loginProblem == nil } ? name : nil }
                    ?? AccountPicker.usableDefault(self)
                let request = NewSessionRequest(folder: project, profile: profile, useWorktree: root != nil,
                                                name: "\(issue.key) \(issue.summary)", permissionMode: Prefs.string(Prefs.newSessionMode),
                                                firstMessage: tracker.firstMessage(for: issue), issueID: nil, issueKey: issue.key,
                                                branchPattern: pattern)
                guard root != nil, Worktree.needsInput(pattern, key: issue.key) else { self.createSession(request); return }
                self.newSessionPrefill = request
                self.showNewSession = true
            }
        }
    }

    /// Ask Claude: a session in the project with the action's prompt. On Jira every call to the Jira servers asks.
    func askClaude(_ action: AskClaude, project: String) {
        let tracker = trackers.tracker(for: project)
        let profile = tracker?.profile.flatMap { name in profiles.contains { $0.name == name && $0.loginProblem == nil } ? name : nil }
            ?? AccountPicker.usableDefault(self)
        createSession(NewSessionRequest(folder: project, profile: profile, useWorktree: false, name: action.title,
                                        sessionRules: tracker.map { JiraRun.askRules(servers: $0.mcpServers) } ?? [],
                                        permissionMode: PermissionMode.auto.rawValue,
                                        firstMessage: action.prompt(project: project, tracker: tracker), issueID: nil))
    }

    /// Draft…: a session that writes `text` up as a Jira issue and creates it. It runs in the default permission mode,
    /// so every Jira call asks, and the create call shows as a ticket card to edit and approve.
    func draftJiraIssue(_ text: String, project: String) {
        guard let tracker = trackers.tracker(for: project) else { return }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        let profile = tracker.profile.flatMap { name in profiles.contains { $0.name == name && $0.loginProblem == nil } ? name : nil }
            ?? AccountPicker.usableDefault(self)
        createSession(NewSessionRequest(folder: project, profile: profile, useWorktree: false, name: "Draft: " + String(line.prefix(40)),
                                        permissionMode: PermissionMode.default.rawValue,
                                        firstMessage: ProjectTracker.draftPrompt(line, site: tracker.site), issueID: nil))
    }

    // MARK: The autopilot on Jira

    /// Opens the Autopilot sheet on an epic's issues, or on chosen keys.
    func offerJiraRun(project: String, epic: JiraIssue? = nil, keys: [String] = []) {
        if let epic, let board = jiraBoard(for: project), board.epicChildren[epic.key] == nil, !board.openEpics.contains(epic.key) {
            board.toggleEpic(epic.key)
        }
        jiraRunSheet = JiraRunSheetRequest(project: project, epic: epic, keys: keys)
    }

    func startJiraRun(_ run: JiraRun) {
        guard jiraRuns[run.project] == nil else { return }
        jiraRuns[run.project] = run
        finishedJiraRuns[run.project] = nil
        advanceJiraRun(run.project)
    }

    /// Adds keys to the project's running Jira autopilot; ones it can't take are left alone, with a note.
    func addToJiraRun(_ keys: [String], project: String) {
        guard let board = jiraBoard(for: project) else { return }
        for key in keys {
            guard let issue = board.known[key], JiraRun.ineligible(issue, mine: board.isMine(issue)) == nil else { continue }
            jiraRuns[project]?.enqueue(key)
        }
        advanceJiraRun(project)
    }

    func jiraRunPanes(_ project: String) -> [Pane] {
        let active = jiraRuns[project]?.active ?? []
        return panes.filter { $0.projectPath == project && $0.jiraRunKey.map(active.contains) == true }
    }

    func isJiraRunSession(_ pane: Pane) -> Bool {
        guard let key = pane.jiraRunKey else { return false }
        return jiraRuns[pane.projectPath]?.active.contains(key) == true
    }

    /// Why the run isn't starting another issue although some are queued.
    func jiraRunWait(_ project: String) -> String? {
        guard let run = jiraRuns[project], run.paused == nil, !run.stopping, !run.queue.isEmpty, run.active.count < run.sessionsAtOnce else { return nil }
        let open = openWorktrees(in: project)
        if open >= run.worktreesAtMost {
            return "\(open) worktrees are open, the most this run allows. Shipped issues keep theirs until they are merged and cleaned up; the run continues when one is closed."
        }
        return nil
    }

    private func advanceJiraRun(_ project: String) {
        guard var run = jiraRuns[project], run.paused == nil, let board = jiraBoard(for: project), let tracker = trackers.tracker(for: project) else { return }
        if run.stuckInARow >= JiraRun.maxStuckInARow {
            pauseJiraRun(project, "\(run.stuckInARow) issues in a row got stuck, so something may be wrong with the project. Look at their sessions, then resume.")
            return
        }
        var starting: [JiraIssue] = []
        if !run.stopping {
            while let key = run.takeNext(known: board.known, openWorktrees: openWorktrees(in: project) + starting.count) {
                if let issue = board.known[key] { starting.append(issue) }
                else { run.finish(key, stuck: true, report: "Viber hadn't loaded \(key); open a view that lists it, then add it to the run again.") }
            }
        }
        if starting.isEmpty, run.active.isEmpty, run.stopping || run.queue.isEmpty {
            jiraRuns[project] = nil
            finishedJiraRuns[project] = run
            notifier.post(id: "jirarun:\(project):\(Date().timeIntervalSince1970)", title: "Autopilot · \(projectName(project))",
                          body: (run.stopping ? "Stopped as you asked: " : "Nothing left in \(run.label): ") + run.tally + ". Nothing was pushed or merged.",
                          target: Target.project(project).key)
            return
        }
        jiraRuns[project] = run
        for issue in starting {
            createSession(NewSessionRequest(folder: project, profile: run.profile, useWorktree: true, name: "\(issue.key) \(issue.summary)",
                                            jiraRunKey: issue.key, sessionRules: JiraRun.askRules(servers: tracker.mcpServers),
                                            permissionMode: run.permissionMode, firstMessage: JiraRun.prompt(for: issue, tracker: tracker, check: requestCheck(for: project)),
                                            issueID: nil, issueKey: issue.key, branchPattern: run.branchPattern),
                          selecting: false)
        }
    }

    private func reportJira(from pane: Pane, text: String, finished: Bool) {
        guard let key = pane.jiraRunKey, jiraRuns[pane.projectPath]?.active.contains(key) == true else { return }
        let project = pane.projectPath
        jiraRuns[project]?.finish(key, stuck: !finished, report: text.isEmpty ? (finished ? "Landed; in review." : "Stuck.") : text)
        if !finished {
            notifier.post(id: "jirarun:\(key):stuck", title: "\(key) · stuck", body: String(text.prefix(180)), target: Target.pane(pane.id).key)
        }
        jiraBoards[project]?.reload()
        advanceJiraRun(project)
    }

    private func jiraTurnEnded(_ pane: Pane, stalled: Bool = false) {
        guard let key = pane.jiraRunKey, let run = jiraRuns[pane.projectPath], run.active.contains(key), run.paused == nil else { return }
        let project = pane.projectPath
        if let stopped = pane.interruptedAt, Date().timeIntervalSince(stopped) < 120 {
            pane.interruptedAt = nil
            pauseJiraRun(project, "You stopped “\(pane.title)”. Resume to let it carry on, or skip it.")
            return
        }
        if pane.state == .failed, let limit = pane.chat.usageLimit {
            pauseJiraRun(project, "The \(limit.name) was reached.", notify: pane.continueAt == nil)
            return
        }
        switch pane.state {
        case .failed, .exited:
            pauseJiraRun(project, "“\(pane.title)” stopped with an error. Look at it, then resume.")
        case .finished, .idle:
            let background = !pane.chat.controls.runningTasks.isEmpty || !pane.chat.runningAgents.isEmpty
            switch run.afterTurn(for: key, backgroundWork: background && !stalled) {
            case .wait: break
            case .nudge:
                jiraRuns[project]?.nudged(key)
                submit(run.nudge(for: key), in: pane)
            case .giveUp:
                giveUpJira(on: key, project: project, why: "Its session kept stopping without saying whether it finished.")
            }
        default: break
        }
    }

    private func giveUpJira(on key: String, project: String, why: String) {
        jiraRuns[project]?.finish(key, stuck: true, report: why)
        notifier.post(id: "jirarun:\(key):stuck", title: "\(key) · stuck", body: why, target: Target.project(project).key)
        advanceJiraRun(project)
    }

    private func jiraSetupFailed(_ key: String, project: String, _ error: Error) {
        guard jiraRuns[project]?.active.contains(key) == true else { return }
        jiraRuns[project]?.finish(key, stuck: true, report: "The autopilot couldn't make its worktree: \(error.localizedDescription)")
        pauseJiraRun(project, "The worktree for \(key) couldn't be made. Its setup's output is in the sidebar.")
    }

    /// A session asked for a Jira change the run doesn't make on its own: the prompt waits in the session, and the
    /// run starts nothing more until it is answered.
    private func holdJiraRun(_ pane: Pane, _ what: String) {
        guard let key = pane.jiraRunKey, jiraRuns[pane.projectPath]?.active.contains(key) == true,
              jiraRuns[pane.projectPath]?.paused == nil else { return }
        jiraRuns[pane.projectPath]?.heldBy = pane.id
        pauseJiraRun(pane.projectPath, "\(key)'s session wants \(what). That isn't one of the run's own changes, so it waits for you in the session.")
    }

    private func pauseJiraRun(_ project: String, _ reason: String, notify: Bool = true) {
        guard jiraRuns[project] != nil else { return }
        jiraRuns[project]?.paused = reason
        guard notify else { return }
        notifier.post(id: "jirarun:\(project):paused:\(Date().timeIntervalSince1970)", title: "Autopilot paused · \(projectName(project))",
                      body: reason, target: Target.project(project).key)
    }

    func resumeJiraRun(_ project: String) {
        guard jiraRuns[project]?.paused != nil else { return }
        jiraRuns[project]?.resume()
        for pane in jiraRunPanes(project) where pane.state != .working && !pane.state.needsYou {
            submit(JiraRun.resumeMessage, in: pane)
        }
        advanceJiraRun(project)
    }

    func toggleStopJiraRunAfterCurrent(_ project: String) {
        guard let run = jiraRuns[project] else { return }
        if run.active.isEmpty { stopJiraRun(project); return }
        jiraRuns[project]?.stopping.toggle()
    }

    func skipJiraIssue(_ key: String, project: String) {
        guard jiraRuns[project]?.active.contains(key) == true else { return }
        for pane in jiraRunPanes(project) where pane.jiraRunKey == key {
            pane.interrupt()
            pane.interruptedAt = nil
            pane.continueAt = nil
        }
        if let job = jobs.first(where: { $0.project == project && $0.jiraRunKey == key }) { dismiss(job) }
        jiraRuns[project]?.finish(key, stuck: true, report: "You skipped it. Its session stays open; move \(key) back in Jira if the skill left it In Progress.")
        jiraRuns[project]?.resume()
        advanceJiraRun(project)
    }

    func stopJiraRun(_ project: String) {
        guard var run = jiraRuns[project] else { return }
        jiraRuns[project] = nil
        run.stopping = true
        finishedJiraRuns[project] = run
        for job in jobs where job.project == project && job.jiraRunKey != nil { dismiss(job) }
        for pane in panes where pane.projectPath == project && pane.jiraRunKey.map(run.active.contains) == true {
            pane.interrupt()
            pane.interruptedAt = nil
            pane.continueAt = nil
        }
    }

    func dismissFinishedJiraRun(_ project: String) {
        finishedJiraRuns[project] = nil
    }

    // MARK: Autopilot

    /// Opens the Autopilot sheet on a project's issues to plan, or on one issue.
    func offerAutopilot(project: String, issueID: String? = nil, fromPopover: Bool = false) {
        let request = AutopilotSheetRequest(project: project, issueID: issueID)
        guard fromPopover else { autopilotSheet = request; return }
        Task {
            // The issues popover closes in the same click.
            try? await Task.sleep(for: .milliseconds(200))
            self.autopilotSheet = request
        }
    }

    func startAutopilot(_ pilot: Autopilot) {
        guard autopilots[pilot.project] == nil else { return }
        autopilots[pilot.project] = pilot
        finishedAutopilots[pilot.project] = nil
        advanceAutopilot(pilot.project)
    }

    /// Adds an issue to the project's running autopilot.
    func addToAutopilot(_ issue: Issue) {
        autopilots[issue.project]?.enqueue(issue.id)
    }

    /// The project whose autopilot is on this issue now.
    func autopilotProject(working issueID: String) -> String? {
        autopilots.first { $0.value.active.contains(issueID) }?.key
    }

    /// The sessions of the issues the project's autopilot is on, once their worktrees are made.
    func autopilotPanes(_ project: String) -> [Pane] {
        (autopilots[project]?.active ?? []).compactMap { id in
            guard let issue = issues.issue(id), issue.status == .started, let session = issue.sessionID else { return nil }
            return pane(session)
        }
    }

    func isAutopilotSession(_ pane: Pane) -> Bool {
        issues.issue(startedIn: pane.id).flatMap { autopilotProject(working: $0.id) } != nil
    }

    /// Worktrees the project has open through Viber: sessions in one, and ones being made.
    func openWorktrees(in project: String) -> Int {
        panes.filter { $0.projectPath == project && $0.worktree != nil }.count
            + jobs.filter { $0.project == project && $0.isRunning && !$0.isRemoval }.count
    }

    /// Why the run isn't starting another issue although some are left, if that is so.
    func autopilotWait(_ project: String) -> String? {
        guard let pilot = autopilots[project], pilot.paused == nil, !pilot.stopping, !pilot.upcoming(in: issues).isEmpty else { return nil }
        if pilot.active.count >= pilot.sessionsAtOnce { return nil }
        let open = openWorktrees(in: project)
        if open >= pilot.worktreesAtMost {
            return "\(open) worktrees are open, the most this run allows. It continues when one is closed, such as after /cleanup."
        }
        let waiting = pilot.waiting(in: issues)
        if !waiting.isEmpty, waiting.count == pilot.upcoming(in: issues).count {
            let keys = Set(waiting.flatMap { $0.for.map(\.key) }).sorted()
            return "The rest wait for \(keys.joined(separator: ", ")) to ship."
        }
        return nil
    }

    /// Starts sessions for the next issues, as many as the run has room for, or ends the run when nothing is left.
    private func advanceAutopilot(_ project: String) {
        guard var pilot = autopilots[project], pilot.paused == nil else { return }
        if pilot.stuckInARow >= Autopilot.maxStuckInARow {
            pauseAutopilot(project, "\(pilot.stuckInARow) issues in a row got stuck, so something may be wrong with the project. "
                           + "Look at their sessions, then resume.")
            return
        }
        var starting: [(Issue, String?)] = []
        if !pilot.stopping {
            while let issue = pilot.takeNext(from: issues, openWorktrees: openWorktrees(in: project) + starting.count) {
                starting.append((issue, startBranch(for: issue, pilot: pilot)))
            }
        }
        if starting.isEmpty, pilot.active.isEmpty, pilot.stopping || pilot.takeNext(from: issues, openWorktrees: 0) == nil {
            autopilots[project] = nil
            finishedAutopilots[project] = pilot
            let left = pilot.upcoming(in: issues).count
            notifier.post(id: "autopilot:\(project):\(Date().timeIntervalSince1970)", title: "Autopilot · \(projectName(project))",
                          body: (pilot.stopping ? "Stopped as you asked: " : left > 0 ? "\(left) left that wait for each other: " : "No issues left to plan: ")
                          + pilot.tally + ".", target: Target.project(project).key)
            return
        }
        autopilots[project] = pilot
        for (issue, branch) in starting {
            createSession(NewSessionRequest(folder: project, profile: pilot.profile, useWorktree: true, name: issue.title,
                                            // Merged issues build on each other; pull requests each start from origin.
                                            base: pilot.finish == .merge ? .current : .originDefault, startBranch: branch,
                                            permissionMode: pilot.permissionMode,
                                            firstMessage: pilot.prompt(for: issue, in: issues, startBranch: branch, check: requestCheck(for: project)),
                                            issueID: issue.id, issueKey: issue.key, branchPattern: pilot.branchPattern),
                          selecting: false)
        }
    }

    /// The branch an issue's worktree starts from when it builds on one the run shipped without merging: the branch
    /// of the last blocker that is done. With `merge`, the target branch already has that work.
    private func startBranch(for issue: Issue, pilot: Autopilot) -> String? {
        guard pilot.finish != .merge else { return nil }
        return issue.blockedBy.compactMap { id -> String? in
            guard let blocker = issues.issue(id), blocker.status == .done, pilot.handled.contains(id),
                  let session = blocker.sessionID, let pane = pane(session) else { return nil }
            return pane.branch
        }.last
    }

    /// `viber issue done` or `failed`: records how the session's issue went, and moves its autopilot on.
    private func reportIssue(from pane: Pane, text: String, finished: Bool) {
        guard let issue = issues.issue(startedIn: pane.id) else { return }
        issues.report(issue.id, text, finished: finished)
        saveIssues()
        guard let project = autopilotProject(working: issue.id) else { return }
        autopilots[project]?.finish(issue.id, stuck: !finished)
        if !finished {
            notifier.post(id: "autopilot:\(issue.id):stuck", title: "\(issue.title) · stuck", body: String(text.prefix(180)),
                          target: Target.pane(pane.id).key)
        }
        advanceAutopilot(project)
    }

    /// An active issue's session ended a turn without a report: wait for its background work to wake it, remind it,
    /// or give up on the issue. A failed turn (an API error, a dead login) or your Stop pauses the run; a usage limit
    /// pauses it until the limit resets.
    private func autopilotTurnEnded(_ pane: Pane, stalled: Bool = false) {
        guard let issue = issues.issue(startedIn: pane.id), let project = autopilotProject(working: issue.id),
              let pilot = autopilots[project], pilot.paused == nil else { return }
        if let stopped = pane.interruptedAt, Date().timeIntervalSince(stopped) < 120 {
            pane.interruptedAt = nil
            pauseAutopilot(project, "You stopped “\(pane.title)”. Resume to let it carry on, or skip it.")
            return
        }
        if pane.state == .failed, let limit = pane.chat.usageLimit {
            // The session carries on once the limit resets and resumes the run. Its own notification says when.
            pauseAutopilot(project, "The \(limit.name) was reached.", notify: pane.continueAt == nil)
            return
        }
        switch pane.state {
        case .failed, .exited:
            pauseAutopilot(project, "“\(pane.title)” stopped with an error. Look at it, then resume.")
        case .finished, .idle:
            let background = !pane.chat.controls.runningTasks.isEmpty || !pane.chat.runningAgents.isEmpty
            switch pilot.afterTurn(for: issue.id, backgroundWork: background && !stalled) {
            case .wait: break
            case .nudge:
                autopilots[project]?.nudged(issue.id)
                submit(pilot.nudge(for: issue.id), in: pane)
            case .giveUp:
                giveUp(on: issue.id, project: project, why: "Its session kept stopping without saying whether it finished.")
            }
        default:
            // Still working, or waiting for you: answering it lets it carry on.
            break
        }
    }

    /// A session that sat idle a long time without a report is reminded, even while a background command
    /// (which may never end, like a dev server) still runs. One whose process died mid-turn never ends that turn.
    private func checkStalledAutopilots() {
        for project in autopilots.keys {
            for pane in autopilotPanes(project) {
                if pane.state == .exited { autopilotTurnEnded(pane); continue }
                guard [.finished, .idle].contains(pane.state), now.timeIntervalSince(pane.lastActivity) > Autopilot.stallInterval else { continue }
                autopilotTurnEnded(pane, stalled: true)
            }
        }
        for project in jiraRuns.keys {
            for pane in jiraRunPanes(project) {
                if pane.state == .exited { jiraTurnEnded(pane); continue }
                guard [.finished, .idle].contains(pane.state), now.timeIntervalSince(pane.lastActivity) > Autopilot.stallInterval else { continue }
                jiraTurnEnded(pane, stalled: true)
            }
        }
    }

    private func giveUp(on issueID: String, project: String, why: String) {
        let title = issues.issue(issueID)?.title ?? "An issue"
        issues.report(issueID, why, finished: false)
        saveIssues()
        autopilots[project]?.finish(issueID, stuck: true)
        notifier.post(id: "autopilot:\(issueID):stuck", title: "\(title) · stuck", body: why, target: Target.project(project).key)
        advanceAutopilot(project)
    }

    /// An issue's worktree couldn't be made. That is usually the project's setup, which would stop the next one too.
    private func autopilotSetupFailed(_ issueID: String, _ error: Error) {
        guard let project = autopilotProject(working: issueID) else { return }
        let title = issues.issue(issueID)?.title ?? "the issue"
        issues.report(issueID, "The autopilot couldn't make its worktree: \(error.localizedDescription)", finished: false)
        saveIssues()
        autopilots[project]?.finish(issueID, stuck: true)
        pauseAutopilot(project, "The worktree for “\(title)” couldn't be made. Its setup's output is in the sidebar.")
    }

    private func pauseAutopilot(_ project: String, _ reason: String, notify: Bool = true) {
        guard autopilots[project] != nil else { return }
        autopilots[project]?.paused = reason
        guard notify else { return }
        notifier.post(id: "autopilot:\(project):paused:\(Date().timeIntervalSince1970)", title: "Autopilot paused · \(projectName(project))",
                      body: reason, target: Target.project(project).key)
    }

    /// Picks a paused run up again: idle sessions are told to carry on, and the next issues start.
    func resumeAutopilot(_ project: String) {
        guard autopilots[project]?.paused != nil else { return }
        autopilots[project]?.resume()
        for pane in autopilotPanes(project) where pane.state != .working && !pane.state.needsYou {
            submit(Autopilot.resumeMessage, in: pane)
        }
        advanceAutopilot(project)
    }

    /// Lets the active issues finish, then ends the run. Asked again, it keeps going after all.
    func toggleStopAfterCurrent(_ project: String) {
        guard let pilot = autopilots[project] else { return }
        if pilot.active.isEmpty { stopAutopilot(project); return }
        autopilots[project]?.stopping.toggle()
    }

    /// Gives up on an active issue so the next one can start. Its session is stopped and stays open.
    func skipAutopilotIssue(_ id: String, project: String) {
        guard autopilots[project]?.active.contains(id) == true else { return }
        if let pane = issues.issue(id)?.sessionID.flatMap(pane) {
            pane.interrupt()
            pane.interruptedAt = nil
            pane.continueAt = nil
        }
        if let job = jobs.first(where: { $0.issueID == id }) { dismiss(job) }
        issues.report(id, "You skipped it.", finished: false)
        saveIssues()
        autopilots[project]?.finish(id, stuck: true)
        autopilots[project]?.resume()
        advanceAutopilot(project)
    }

    /// Ends the run now. The active issues' sessions are stopped and stay open; worktrees still being made are dropped.
    func stopAutopilot(_ project: String) {
        guard var pilot = autopilots[project] else { return }
        autopilots[project] = nil
        pilot.stopping = true
        finishedAutopilots[project] = pilot
        for id in pilot.active {
            if let job = jobs.first(where: { $0.issueID == id }) { dismiss(job) }
            if let pane = issues.issue(id)?.sessionID.flatMap(pane) {
                pane.interrupt()
                pane.interruptedAt = nil
                pane.continueAt = nil
            }
        }
    }

    func dismissFinishedAutopilot(_ project: String) {
        finishedAutopilots[project] = nil
    }

    /// You changed or deleted an issue the autopilot is on, so it moves on. Its session carries on as an ordinary one.
    private func releaseFromAutopilot(_ id: String, finished: Bool) {
        guard let project = autopilotProject(working: id) else { return }
        autopilots[project]?.finish(id, stuck: !finished)
        advanceAutopilot(project)
    }

    private func ensureRunning(_ pane: Pane) {
        if !pane.isRunning { pane.start(binDir: binDir, pluginDir: pluginDir) }
    }

    /// The chat notes the new mode once the CLI confirms it.
    func setMode(_ mode: String, in pane: Pane) {
        ensureRunning(pane)
        pane.run { [$0.setPermissionMode(mode)] }
    }

    /// Ends a session. Worktree removal runs in the background, in the sidebar while it runs (a project's
    /// WorktreeRemove hook can take a while), and stays there with its output if it fails.
    func close(_ pane: Pane, removeWorktree: Bool = false, deleteBranch: Bool = false) {
        let wasSelected = selection == .pane(pane.id)
        pane.onStateChange = nil
        pane.stop()
        pane.closePreview()
        panes.removeAll { $0.id == pane.id }
        // Another session in the same project, else the project's page.
        if wasSelected { selection = panes.last { $0.projectPath == pane.projectPath }.map { .pane($0.id) } ?? .project(pane.projectPath) }
        if settingsSheet?.paneID == pane.id { settingsSheet = nil }
        notifier.clear(target: Target.pane(pane.id).key)
        save()
        if let issue = issues.issue(startedIn: pane.id), let project = autopilotProject(working: issue.id) {
            giveUp(on: issue.id, project: project, why: "Its session was closed before it said how it went.")
        } else if let key = pane.jiraRunKey, jiraRuns[pane.projectPath]?.active.contains(key) == true {
            giveUpJira(on: key, project: pane.projectPath, why: "Its session was closed before it said how it went.")
        } else if removeWorktree, let issue = issue(for: pane), issue.status == .started || issue.status == .review {
            // /cleanup only removes a worktree whose branch is merged, so the issue it was for is done.
            issues.setStatus(issue.id, .done)
            issues.comment(issue.id, "Merged: its worktree was cleaned up.", by: pane.title)
            saveIssues()
        }
        // One worktree fewer may let the project's autopilot start its next issue.
        if pane.worktree != nil { advanceAutopilot(pane.projectPath) }
        guard removeWorktree, let info = pane.worktree else { return }
        let job = WorktreeJob(removing: info, deleteBranch: deleteBranch, title: pane.title, project: pane.projectPath)
        jobs.append(job)
        // A hook's teardown is worth watching; git's takes a moment.
        if wasSelected && info.madeByHook { select(.job(job.id)) }
        run(job)
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
        // Stops any setup hook still running; its process group would otherwise outlive the app.
        for job in jobs { job.task?.cancel() }
    }

    // MARK: State, notifications, polling

    private func stateChanged(_ pane: Pane, from previous: PaneState) {
        updateBadge()
        // The held Jira change was answered: the run goes on.
        if pane.jiraRunKey != nil, previous == .permission, pane.state != .permission,
           let run = jiraRuns[pane.projectPath], run.heldBy == pane.id { resumeJiraRun(pane.projectPath) }
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
            // Held while Viber finds out whether the request needs its check.
            guard previous == .working, pane.chat.turnStartedByUser, !pane.checks.comparing else { return }
            body = "Finished" + (pane.chat.lastTurnSeconds.map { " in \(Self.duration($0))" } ?? "") + "."
        case .failed: body = pane.chat.usageLimit.map { limitNotice($0, continueAt: pane.continueAt) } ?? "The last turn failed."
        default: return
        }
        notifier.post(id: "\(pane.id):\(state.rawValue):\(Date().timeIntervalSince1970)",
                      title: "\(pane.title) · \(state.label)", body: body, target: target.key, sound: state != .finished)
    }

    private func turnFinished(_ pane: Pane) {
        // A `viber issue done` from the turn that just ended decides what the autopilot does next: read it now,
        // not on the next poll.
        if isAutopilotSession(pane) || isJiraRunSession(pane) {
            drainRequests()
            guard panes.contains(where: { $0 === pane }) else { return }
        }
        if let request = pane.pendingClose {
            pane.pendingClose = nil
            close(pane, removeWorktree: request.removeWorktree, deleteBranch: request.deleteBranch)
            return
        }
        refreshWorktree(pane)
        waitOutLimit(pane)
        save()
        autopilotTurnEnded(pane)
        jiraTurnEnded(pane)
        checkAfterRequest(pane)
    }

    /// Turns a project's check after each request on or off, or changes its test command.
    func setRequestCheck(_ check: RequestCheck, for project: String) {
        requestChecks[project] = check.enabled || !check.testCommand.isEmpty ? check : nil
        UserDefaults.standard.set(try? JSONEncoder().encode(requestChecks), forKey: Prefs.requestChecks)
    }

    /// The project's check after each request, when it is on. Autopilot sessions run it before they ship.
    func requestCheck(for project: String) -> RequestCheck? {
        requestChecks[project].flatMap { $0.enabled ? $0 : nil }
    }

    /// The check a session gets after each request: the project's, except in autopilot sessions, whose first
    /// message already has it before they ship.
    private func checksRequests(_ pane: Pane) -> RequestCheck? {
        guard pane.jiraRunKey == nil, !startedByAutopilot(pane) else { return nil }
        return requestCheck(for: pane.projectPath)
    }

    /// A request started in a project that checks each one: read the work tree, to tell at its end whether it changed.
    private func requestStarted(_ pane: Pane) {
        guard checksRequests(pane) != nil, let request = pane.checks.requestStartedAt else { return }
        let cwd = pane.cwd
        Task.detached {
            let state = Worktree.fingerprint(cwd)
            await MainActor.run { pane.checks.setBaseline(state, for: request) }
        }
    }

    /// Once a request that changed files is done, a project that asks for it has the session run the tests and a
    /// code review and fix what they find. The message keeps the session working, so "Finished" is only posted
    /// after the check.
    private func checkAfterRequest(_ pane: Pane) {
        guard let check = checksRequests(pane) else { return }
        switch pane.checks.turnEnded(state: pane.state, lastEdit: pane.chat.lastFileEditAt,
                                     agentsRunning: !pane.chat.runningAgents.isEmpty, interruptedAt: pane.interruptedAt) {
        case .nothing: break
        case .check: sendCheck(check, to: pane)
        case .compare(let baseline):
            pane.checks.comparing = true
            let cwd = pane.cwd, request = pane.checks.requestStartedAt
            Task.detached {
                let state = Worktree.fingerprint(cwd)
                await MainActor.run {
                    // A message sent meanwhile started another request.
                    guard pane.checks.comparing, pane.checks.requestStartedAt == request else { return }
                    pane.checks.comparing = false
                    guard self.panes.contains(where: { $0 === pane }), pane.state == .finished else { return }
                    if let state, state != baseline { self.sendCheck(check, to: pane) }
                    else { self.stateChanged(pane, from: .working) }  // posts the "Finished" it held
                }
            }
        }
    }

    private func sendCheck(_ check: RequestCheck, to pane: Pane) {
        pane.sendUser(check.message, binDir: binDir, pluginDir: pluginDir, continuing: true)
        pane.checks.checkSent(at: Date())
    }

    /// A session an autopilot run started, while it runs or until its card is dismissed. Its issue has left the run
    /// by the time its last turn ends, so the run's list of issues it took says.
    private func startedByAutopilot(_ pane: Pane) -> Bool {
        guard let issue = issues.issue(startedIn: pane.id) else { return false }
        return [autopilots[issue.project], finishedAutopilots[issue.project]].contains { $0?.handled.contains(issue.id) == true }
    }

    /// Reads the worktree's diff stat and the branch checked out in it.
    func refreshWorktree(_ pane: Pane) {
        guard let info = pane.worktree else { return }
        Task.detached {
            let stat = Worktree.diffStat(info)
            let branch = Worktree.currentBranch(info.path)
            await MainActor.run { pane.diffStat = stat; pane.liveBranch = branch }
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
                Task { @MainActor in self?.reloadStatus(); self?.deviceHub.reap(); self?.checkStalledAutopilots(); self?.refreshJira() }
            }
        ]
        for pane in panes where pane.worktree != nil { refreshWorktree(pane) }
    }

    /// Reads the shown Jira view again when it is stale: the selected project's, and those with sessions open.
    private func refreshJira() {
        var projects = Set(panes.map(\.projectPath))
        if let selected = selectedProjectPage { projects.insert(selected) }
        for project in projects { jiraBoards[project]?.refreshIfStale(now: now) }
    }

    private func tick() {
        now = Date()
        continueLimitedSessions()
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
            case .issueAdd:
                addIssue(request.text ?? "", project: pane.projectPath, by: pane.title, parent: request.parent, blockedBy: request.blockedBy ?? [])
            case .issueDone, .issueFailed:
                if pane.jiraRunKey != nil { reportJira(from: pane, text: request.text ?? "", finished: request.command == .issueDone) }
                else { reportIssue(from: pane, text: request.text ?? "", finished: request.command == .issueDone) }
            case .issueShipped:
                // On a Jira project the repository's skill moves the issue; Viber only reads.
                if trackers.tracker(for: pane.projectPath) == nil { shipped(from: pane, text: request.text ?? "") }
            case .issueUpdate:
                guard let key = request.key, let issue = issues.issue(key, in: pane.projectPath) else { continue }
                if let status = request.status.flatMap(Issue.Status.init(rawValue:)) { setIssueStatus(issue.id, status) }
                if request.parent != nil || request.blockedBy != nil {
                    let parent = request.parent ?? issue.parentID
                    issues.setLinks(issue.id, parent: parent == "" ? nil : parent, blockedBy: request.blockedBy ?? issue.blockedBy)
                    saveIssues()
                }
            case .issueComment:
                guard let key = request.key, let issue = issues.issue(key, in: pane.projectPath) else { continue }
                issues.comment(issue.id, request.text ?? "", by: pane.title)
                saveIssues()
            }
        }
    }

    /// Usage comes from `clauth daemon`, the only clauth process that fetches it; `clauth status`
    /// just reads the daemon's cache. So when the daemon's snapshot goes stale, start the daemon.
    func reloadStatus() {
        let path = ViberPaths.clauthStatus
        // The daemon rewrites its snapshot every refresh (90s by default).
        let fresh = (try? path.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            .map { Date().timeIntervalSince($0) < 300 } ?? false
        let starting = !fresh && startDaemon()
        Task.detached {
            var status: ClauthStatus?
            var note: String?
            if fresh, let data = try? Data(contentsOf: path) { status = ClauthStatus.decode(data) }
            if status == nil {
                let result = Shell.run("clauth", ["status", "--json"])
                status = result.ok ? ClauthStatus.decode(Data(result.stdout.utf8)) : nil
                if status == nil { note = result.status == 127 ? "clauth not found" : "clauth status failed" }
                else if !starting { note = "The clauth daemon is not running, so usage and login states are out of date. Check ~/.clauth/daemon.log." }
            }
            let loaded = status, message = note
            await MainActor.run {
                if let loaded { self.status = loaded }
                self.statusNote = message
            }
        }
        // The daemon writes its first snapshot within a second or two.
        if starting { reloadStatus(after: 3) }
    }

    private func reloadStatus(after seconds: Double) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            self.reloadStatus()
        }
    }

    @ObservationIgnored private var daemonStartedAt: Date?

    /// Launch `clauth daemon` in the background; it exits at once if one is already running, and keeps
    /// running after Viber quits. Returns false when it was tried too recently or could not start.
    private func startDaemon() -> Bool {
        if let last = daemonStartedAt, Date().timeIntervalSince(last) < 120 { return false }
        daemonStartedAt = Date()
        guard let tool = Executables.find("clauth") else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["daemon"]
        process.environment = Executables.environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        // clauth caps daemon.log's size only when stderr is opened for appending.
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clauth/daemon.log").path
        let fd = Darwin.open(log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        process.standardError = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : FileHandle.nullDevice
        return (try? process.run()) != nil
    }

    /// Re-authenticate a clauth profile. clauth opens the browser itself and waits for the redirect,
    /// so this finishes once the user completes (or abandons) the sign-in there.
    func login(_ profile: String) {
        guard loggingIn.insert(profile).inserted else { return }
        Task.detached {
            let result = Shell.run("clauth", ["login", profile])
            await MainActor.run {
                self.loggingIn.remove(profile)
                if !result.ok {
                    let detail = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                    self.errorMessage = "Login for \(profile) failed." + (detail.isEmpty ? "" : "\n\n\(detail)")
                }
                // Chats that hit the dead login pick up the new one on a fresh process.
                if result.ok {
                    for pane in self.panes where pane.authFailed && pane.spec.profile == profile { self.restart(pane) }
                }
                // The daemon picks up the new login on its next pass; check back a few times.
                self.reloadStatus()
                for delay in [5.0, 15, 45] { self.reloadStatus(after: delay) }
            }
        }
    }

    func reloadRecent() {
        Task.detached {
            let result = Shell.run("clauth", ["sessions", "--json"])
            let sessions = result.ok ? ClauthSession.decodeList(Data(result.stdout.utf8)) : []
            var roots: [String: String] = [:]
            for folder in Set(sessions.compactMap(\.workspace)) { roots[folder] = ProjectRoot.resolve(folder) }
            let found = roots
            await MainActor.run {
                if !sessions.isEmpty { self.recent = sessions; self.recentRoots = found }
            }
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

    func saveIssues() {
        do {
            try issues.save()
        } catch {
            errorMessage = "Could not save issues: \(error.localizedDescription)"
        }
    }

    func saveProjects() {
        do {
            try projects.save()
        } catch {
            errorMessage = "Could not save projects: \(error.localizedDescription)"
        }
    }

    private func restore() {
        issues = IssueList.load()
        trackers = TrackerList.load()
        if let data = UserDefaults.standard.data(forKey: Prefs.jiraSites), let sites = try? JSONDecoder().decode([JiraSite].self, from: data) {
            jiraSites = sites
        }
        if let data = UserDefaults.standard.data(forKey: Prefs.requestChecks),
           let checks = try? JSONDecoder().decode([String: RequestCheck].self, from: data) {
            requestChecks = checks
        }
        // Issues were filed under a session's folder; a subfolder's or worktree's now belong to its repository.
        if issues.moveProjects(ProjectRoot.resolve) { saveIssues() }
        if let data = try? Data(contentsOf: ViberPaths.panes),
           let records = try? JSONDecoder().decode([PaneRecord].self, from: data) {
            panes = records.map(Pane.init(record:))
            panes.forEach(wire)
        }
        // The first launch with projects starts the list from the open sessions and the folders that have issues.
        let saved = ProjectList.load()
        projects = saved ?? ProjectList()
        var changed = saved == nil
        let withIdeas = saved == nil ? issues.issues.map(\.project).filter { FileManager.default.fileExists(atPath: $0) } : []
        for path in panes.map(\.projectPath) + withIdeas {
            if projects.add(path) { changed = true }
        }
        if changed { saveProjects() }
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

    /// "23:31" today, "Tue 09:01" on another day, as the user's locale writes them.
    nonisolated static func clock(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDate(date, inSameDayAs: now) { formatter.timeStyle = .short }
        else { formatter.setLocalizedDateFormatFromTemplate("EEEjmm") }
        return formatter.string(from: date)
    }

    /// "2d 3h", "1h 12m", "4m"; "<1m" for less.
    nonisolated static func span(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        let hours = Int(seconds / 3600), minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return minutes > 0 ? "\(minutes)m" : "<1m"
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return s >= 3600 ? "60:00" : String(format: "%d:%02d", s / 60, s % 60)
    }
}
