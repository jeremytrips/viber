import SwiftUI
import ViberCore

/// Starts an autopilot run on a project's issues to plan, or on one issue.
struct AutopilotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AutopilotSheetRequest

    @State private var finish = Autopilot.Finish.pullRequest
    @State private var mode = PermissionMode.auto.rawValue
    @State private var profile: String?
    @State private var sessions = Prefs.int(Prefs.autopilotSessions)
    @State private var worktrees = Prefs.int(Prefs.autopilotWorktrees)
    /// Nil while it is read.
    @State private var repo: Repo?

    /// What the sheet needs to know about the project's repository.
    struct Repo {
        var isRepo = false
        var hasOrigin = false
        /// The branch checked out in the project's folder; nil when HEAD is detached.
        var current: String?
        var pattern = Worktree.defaultBranchPattern
        var usesHook = false
    }

    private static let shown = 8
    /// The modes that make sense without someone watching.
    private static let modes: [PermissionMode] = [.auto, .acceptEdits, .default]

    private var issues: [Issue] {
        if let id = request.issueID { return model.issues.issue(id).flatMap { $0.status == .open ? [$0] : nil } ?? [] }
        return model.issues.toPlan(in: request.project)
    }

    var body: some View {
        let issues = issues
        VStack(spacing: 0) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Autopilot for \(model.projectName(request.project))", systemImage: "airplane").font(.headline)
                        Text(issues.count == 1
                             ? "Viber implements this issue on its own: it gets a new worktree and a session that writes it, runs the project's checks, ships it and reports back."
                             : "Viber works through these issues on its own, several at a time. Each gets a new worktree and a session that writes it, runs the project's checks, ships it and reports back; then the next one takes its place. An issue blocked by another in the run waits for it. Issues you add meanwhile join the end; ones its sessions add wait for you.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section(issues.count == 1 ? "The issue" : "\(issues.count) issues, oldest first") {
                    if issues.isEmpty {
                        Text("Nothing to plan here.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(issues.prefix(Self.shown).enumerated()), id: \.element.id) { index, issue in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if issues.count > 1 { Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary) }
                            Text(issue.title).lineLimit(1).help(issue.text)
                        }
                    }
                    if issues.count > Self.shown {
                        Text("and \(issues.count - Self.shown) more").foregroundStyle(.secondary)
                    }
                }

                Section {
                    Picker("When one works", selection: $finish) {
                        Text("Open a pull request").tag(Autopilot.Finish.pullRequest)
                            .disabled(repo?.hasOrigin != true)
                        Text(repo?.current.map { "Merge it into \($0)" } ?? "Merge it").tag(Autopilot.Finish.merge)
                            .disabled(repo?.current == nil)
                        Text("Commit it on its branch").tag(Autopilot.Finish.commit)
                    }
                    note(finishNote)
                    Picker("Mode", selection: $mode) {
                        ForEach(Self.modes, id: \.self) { Text($0.label).tag($0.rawValue) }
                    }
                    note(modeNote)
                    AccountPicker(selection: $profile)
                    Stepper("Sessions at once: \(sessions)", value: $sessions, in: 1...Autopilot.maxSessions)
                    note(sessions == 1 ? "One issue at a time." : "\(sessions) issues at a time, each in its own session and worktree. Each costs usage, and each runs the project's checks.")
                    Stepper("Worktrees at most: \(worktrees)", value: $worktrees, in: max(sessions, 1)...32)
                    note(finish == .merge ? "Counts the project's open worktree sessions. Merged issues close theirs, so this rarely matters."
                         : "Counts the project's open worktree sessions, including issues waiting for review: a shipped issue keeps its worktree until it is merged and cleaned up, so the run can't get further ahead of you than this.")
                    CheckBeforeShipping(project: request.project)
                    LabeledContent("Branches") {
                        Text(repo.map { $0.usesHook ? "Made by the project's WorktreeCreate hook" : Autopilot.usablePattern($0.pattern) } ?? "")
                    }
                    if let repo, !repo.usesHook, Autopilot.usablePattern(repo.pattern) != repo.pattern {
                        note("The project's pattern, \(repo.pattern), can't name a branch for each issue on its own, so the autopilot uses \(Worktree.defaultBranchPattern).")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let problem = problem(issues) {
                    Text(problem).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem(issues) != nil)
            }
            .padding(16)
        }
        .frame(width: 520)
        .fitsWindow()
        .task { await load() }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }


    private var finishNote: String {
        switch finish {
        case .pullRequest:
            return "Each session pushes its branch to origin and opens a pull request (with gh on GitHub; elsewhere it gives the link). Every issue starts from origin's default branch, so each pull request stands alone."
        case .merge:
            let target = repo?.current ?? "the branch"
            return "Each session merges \(target) into its branch, checks again, then fast-forwards \(target) in the project's folder, so the next issue starts from the result. Nothing is pushed."
        case .commit:
            return "Each session commits on its own branch and stops there, for you to review. Nothing is pushed or merged."
        }
    }

    private var modeNote: String {
        switch PermissionMode(rawValue: mode) {
        case .auto: return "Claude edits and runs commands without asking; a classifier blocks risky actions. A session that still needs you waits, and the run with it."
        case .acceptEdits: return "Claude edits without asking but asks before commands, so the run waits for you often."
        default: return "Claude asks before every edit and command, so the run waits for you at each step."
        }
    }

    /// Why Start is off, if it is.
    private func problem(_ issues: [Issue]) -> String? {
        if model.autopilots[request.project] != nil { return "The autopilot is already running here." }
        guard let repo else { return "Reading the repository…" }
        if !repo.isRepo { return "The autopilot needs a git repository: each issue gets its own worktree and branch." }
        if issues.isEmpty { return "There is no issue to plan." }
        if finish == .pullRequest && !repo.hasOrigin { return "There is no origin remote to open pull requests on." }
        if finish == .merge && repo.current == nil { return "The project's folder has no branch checked out to merge into." }
        return nil
    }

    private func load() async {
        profile = model.launchProfile(for: request.project)
        let project = request.project
        let (found, key) = await Task.detached { () -> (Repo, String?) in
            guard let root = Worktree.repoRoot(project) else { return (Repo(), nil) }
            let hooks = (try? WorktreeHooks.hooks(.create, folder: project)) ?? []
            return (Repo(isRepo: true, hasOrigin: Worktree.hasOrigin(root), current: Worktree.currentBranch(root), usesHook: !hooks.isEmpty),
                    WorktreeHooks.mainCheckout(root) ?? root)
        }.value
        var repo = found
        if let key { repo.pattern = Prefs.branchPattern(project: key) }
        self.repo = repo
        finish = repo.hasOrigin ? .pullRequest : repo.current != nil ? .merge : .commit
    }

    private func start() {
        guard let repo, problem(issues) == nil else { return }
        UserDefaults.standard.set(sessions, forKey: Prefs.autopilotSessions)
        UserDefaults.standard.set(worktrees, forKey: Prefs.autopilotWorktrees)
        model.startAutopilot(Autopilot(project: request.project, issues: issues.map(\.id), finish: finish, target: repo.current,
                                       permissionMode: mode, profile: profile, branchPattern: repo.pattern,
                                       sessionsAtOnce: sessions, worktreesAtMost: worktrees))
        dismiss()
    }
}

/// What a project's autopilot is doing, with buttons to resume, skip or stop it, and the issues it took with what
/// their sessions reported. A run that ended stays until dismissed. Shows nothing when there is neither.
struct AutopilotCard: View {
    @Environment(AppModel.self) private var model
    let project: String
    /// Called when a button here selects a session, so a popover can close.
    var onLeave: (() -> Void)?

    var body: some View {
        let running = model.autopilots[project]
        if let pilot = running ?? model.finishedAutopilots[project] {
            let tint = pilot.paused == nil ? Color.accentColor : Color.orange
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "airplane").foregroundStyle(tint)
                    Text(running == nil ? (pilot.stopping ? "Autopilot stopped" : "Autopilot finished")
                         : pilot.paused == nil ? "Autopilot" : waitingAt != nil ? "Autopilot waiting" : "Autopilot paused").fontWeight(.semibold)
                    Text(running == nil ? "· \(pilot.tally)" : counts(pilot)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer(minLength: 8)
                    if running != nil {
                        controls(pilot)
                    } else {
                        Button { model.dismissFinishedAutopilot(project) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Dismiss; the issues keep what their sessions reported")
                            .accessibilityLabel("Dismiss")
                    }
                }
                ForEach(pilot.handled.filter { !pilot.active.contains($0) }.compactMap { model.issues.issue($0) }) { issue in
                    handledRow(issue)
                }
                if running != nil {
                    status(pilot)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.35)))
        }
    }

    /// An issue the run took: how it went, and its session.
    private func handledRow(_ issue: Issue) -> some View {
        let report = issue.report
        let pane = issue.sessionID.flatMap(model.pane)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: report.map { $0.finished ? "checkmark.seal" : "exclamationmark.triangle" } ?? "circle.dashed")
                .foregroundStyle(report.map { $0.finished ? Color.green : Color.orange } ?? Color.secondary)
            (Text(issue.title).fontWeight(.medium)
             + Text("  " + (report.map { $0.text.isEmpty ? "Done." : $0.text } ?? "Stopped before it reported.")).foregroundStyle(.secondary))
                .lineLimit(2)
                .help(report?.text ?? issue.text)
            Spacer(minLength: 4)
            if let pane {
                Button("Open") { model.select(.pane(pane.id)); onLeave?() }
                    .buttonStyle(.link)
                    .help("Show the session that worked on it")
            }
        }
        .font(.callout)
    }

    /// When a session carries on by itself, once the usage limit that stopped it resets.
    private var waitingAt: Date? { model.autopilotPanes(project).compactMap(\.continueAt).min() }

    private func counts(_ pilot: Autopilot) -> String {
        let left = pilot.upcoming(in: model.issues).count
        let at = pilot.sessionsAtOnce > 1 && !pilot.active.isEmpty ? " · \(pilot.active.count) at once" : ""
        return "· \(pilot.tally) · \(left) to go\(at)"
    }

    @ViewBuilder
    private func status(_ pilot: Autopilot) -> some View {
        if let reason = pilot.paused {
            Text(reason).foregroundStyle(.secondary)
        }
        ForEach(pilot.active.compactMap { model.issues.issue($0) }) { issue in
            let pane = issue.sessionID.flatMap(model.pane)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let pane {
                    Text(doing(pane, issue: issue)).foregroundStyle(pane.state.needsYou ? .orange : .primary)
                    Button("Open") { model.select(.pane(pane.id)); onLeave?() }
                        .buttonStyle(.link)
                        .help("Show the session working on it")
                } else {
                    Text("Making a worktree for “\(issue.title)”…")
                }
                Spacer(minLength: 4)
                Button("Skip") { model.skipAutopilotIssue(issue.id, project: project) }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
                    .help("Give up on this issue; its session stays open")
            }
        }
        if let wait = model.autopilotWait(project) {
            Text(wait).foregroundStyle(.secondary)
        }
        if pilot.stopping {
            Text(pilot.active.count == 1 ? "Stops after this issue." : "Stops after these issues.").foregroundStyle(.secondary)
        }
    }

    private func doing(_ pane: Pane, issue: Issue) -> String {
        switch pane.state {
        case .permission, .input, .plan: return "“\(issue.title)” is waiting for you: \(pane.state.label.lowercased())."
        case .failed where pane.chat.usageLimit != nil:
            guard let at = pane.continueAt else { return "“\(issue.title)” stopped at the limit. Resume once it resets." }
            return "Carries on with “\(issue.title)” at \(AppModel.clock(at, now: model.now)), when the limit resets."
        case .failed: return "“\(issue.title)” failed."
        case .exited: return "“\(issue.title)” stopped."
        default: return "Working on “\(issue.title)”."
        }
    }

    @ViewBuilder
    private func controls(_ pilot: Autopilot) -> some View {
        if pilot.paused != nil {
            Button("Resume") { model.resumeAutopilot(project) }
                .controlSize(.small)
                .help(waitingAt != nil ? "Carry on now instead of when the limit resets"
                      : !pilot.active.isEmpty ? "Tell the sessions to carry on with their issues" : "Start the next issue")
        }
        Menu {
            if pilot.paused == nil, !pilot.active.isEmpty {
                let these = pilot.active.count == 1 ? "This Issue" : "These Issues"
                Button(pilot.stopping ? "Keep Going After \(these)" : "Stop After \(these)") { model.toggleStopAfterCurrent(project) }
            }
            Divider()
            Button("Stop Now") { model.stopAutopilot(project) }
        } label: {
            Text("Stop")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .help("Stop after the issues it is on, or stop now (their sessions stay open)")
    }
}


/// An autopilot sheet's row on the project's check after each request, which its sessions run before they ship
/// (or, on Jira, commit).
struct CheckBeforeShipping: View {
    @Environment(AppModel.self) private var model
    let project: String
    var commits = false

    var body: some View {
        let on = model.requestCheck(for: project) != nil
        let ships = commits ? "commits" : "ships"
        LabeledContent(commits ? "Before committing" : "Before shipping") {
            Text(on ? "Tests and /code-review" : "The project's checks")
        }
        Text(on ? "After each request is on in the project's Settings tab, so each session also runs /code-review and fixes what it finds before it \(ships)."
             : "Turn on After each request in the project's Settings tab to have each session also run /code-review before it \(ships).")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
