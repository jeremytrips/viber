import SwiftUI
import ViberCore

/// Starts an autopilot run on a project's ideas to plan, or on one idea.
struct AutopilotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AutopilotSheetRequest

    @State private var finish = Autopilot.Finish.pullRequest
    @State private var mode = PermissionMode.auto.rawValue
    @State private var profile: String?
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

    private var ideas: [Idea] {
        if let id = request.ideaID { return model.ideas.idea(id).flatMap { $0.status == .open ? [$0] : nil } ?? [] }
        return model.ideas.toPlan(in: request.project)
    }

    var body: some View {
        let ideas = ideas
        VStack(spacing: 0) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Autopilot for \(model.projectName(request.project))", systemImage: "airplane").font(.headline)
                        Text(ideas.count == 1
                             ? "Viber implements this idea on its own: it gets a new worktree and a session that writes it, runs the project's checks, ships it and reports back."
                             : "Viber works through these ideas on its own, one at a time. Each gets a new worktree and a session that writes it, runs the project's checks, ships it and reports back; then the next one starts. Ideas you add meanwhile join the end; ones its sessions add wait for you.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section(ideas.count == 1 ? "The idea" : "\(ideas.count) ideas, oldest first") {
                    if ideas.isEmpty {
                        Text("Nothing to plan here.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(ideas.prefix(Self.shown).enumerated()), id: \.element.id) { index, idea in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if ideas.count > 1 { Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary) }
                            Text(idea.title).lineLimit(1).help(idea.text)
                        }
                    }
                    if ideas.count > Self.shown {
                        Text("and \(ideas.count - Self.shown) more").foregroundStyle(.secondary)
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
                    LabeledContent("Branches") {
                        Text(repo.map { $0.usesHook ? "Made by the project's WorktreeCreate hook" : Autopilot.usablePattern($0.pattern) } ?? "")
                    }
                    if let repo, !repo.usesHook, Autopilot.usablePattern(repo.pattern) != repo.pattern {
                        note("The project's pattern, \(repo.pattern), can't name a branch for each idea on its own, so the autopilot uses \(Worktree.defaultBranchPattern).")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let problem = problem(ideas) {
                    Text(problem).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem(ideas) != nil)
            }
            .padding(16)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task { await load() }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var finishNote: String {
        switch finish {
        case .pullRequest:
            return "Each session pushes its branch to origin and opens a pull request (with gh on GitHub; elsewhere it gives the link). Every idea starts from origin's default branch, so each pull request stands alone."
        case .merge:
            let target = repo?.current ?? "the branch"
            return "Each session merges \(target) into its branch, checks again, then fast-forwards \(target) in the project's folder, so the next idea starts from the result. Nothing is pushed."
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
    private func problem(_ ideas: [Idea]) -> String? {
        if model.autopilots[request.project] != nil { return "The autopilot is already running here." }
        guard let repo else { return "Reading the repository…" }
        if !repo.isRepo { return "The autopilot needs a git repository: each idea gets its own worktree and branch." }
        if ideas.isEmpty { return "There is no idea to plan." }
        if finish == .pullRequest && !repo.hasOrigin { return "There is no origin remote to open pull requests on." }
        if finish == .merge && repo.current == nil { return "The project's folder has no branch checked out to merge into." }
        return nil
    }

    private func load() async {
        profile = AccountPicker.usableDefault(model)
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
        guard let repo, problem(ideas) == nil else { return }
        model.startAutopilot(Autopilot(project: request.project, ideas: ideas.map(\.id), finish: finish, target: repo.current,
                                       permissionMode: mode, profile: profile, branchPattern: repo.pattern))
        dismiss()
    }
}

/// What a project's autopilot is doing, with buttons to resume, skip or stop it, and the ideas it took with what
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
                         : pilot.paused == nil ? "Autopilot" : "Autopilot paused").fontWeight(.semibold)
                    Text(running == nil ? "· \(pilot.tally)" : counts(pilot)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer(minLength: 8)
                    if running != nil {
                        controls(pilot)
                    } else {
                        Button { model.dismissFinishedAutopilot(project) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Dismiss; the ideas keep what their sessions reported")
                            .accessibilityLabel("Dismiss")
                    }
                }
                ForEach(pilot.handled.filter { $0 != running?.current }.compactMap { model.ideas.idea($0) }) { idea in
                    handledRow(idea)
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

    /// An idea the run took: how it went, and its session.
    private func handledRow(_ idea: Idea) -> some View {
        let report = idea.report
        let pane = idea.sessionID.flatMap(model.pane)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: report.map { $0.finished ? "checkmark.seal" : "exclamationmark.triangle" } ?? "circle.dashed")
                .foregroundStyle(report.map { $0.finished ? Color.green : Color.orange } ?? Color.secondary)
            (Text(idea.title).fontWeight(.medium)
             + Text("  " + (report.map { $0.text.isEmpty ? "Done." : $0.text } ?? "Stopped before it reported.")).foregroundStyle(.secondary))
                .lineLimit(2)
                .help(report?.text ?? idea.text)
            Spacer(minLength: 4)
            if let pane {
                Button("Open") { model.select(.pane(pane.id)); onLeave?() }
                    .buttonStyle(.link)
                    .help("Show the session that worked on it")
            }
        }
        .font(.callout)
    }

    private func counts(_ pilot: Autopilot) -> String {
        let left = pilot.upcoming(in: model.ideas).count
        return "· \(pilot.tally) · \(left) to go"
    }

    @ViewBuilder
    private func status(_ pilot: Autopilot) -> some View {
        let idea = pilot.current.flatMap { model.ideas.idea($0) }
        let pane = model.autopilotPane(project)
        if let reason = pilot.paused {
            Text(reason).foregroundStyle(.secondary)
        }
        if let idea {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let pane {
                    Text(doing(pane, idea: idea)).foregroundStyle(pane.state.needsYou ? .orange : .primary)
                    Button("Open") { model.select(.pane(pane.id)); onLeave?() }
                        .buttonStyle(.link)
                        .help("Show the session working on it")
                } else {
                    Text("Making a worktree for “\(idea.title)”…")
                }
            }
        }
        if pilot.stopping {
            Text("Stops after this idea.").foregroundStyle(.secondary)
        }
    }

    private func doing(_ pane: Pane, idea: Idea) -> String {
        switch pane.state {
        case .permission, .input, .plan: return "“\(idea.title)” is waiting for you: \(pane.state.label.lowercased())."
        case .failed: return "“\(idea.title)” failed."
        case .exited: return "“\(idea.title)” stopped."
        default: return "Working on “\(idea.title)”."
        }
    }

    @ViewBuilder
    private func controls(_ pilot: Autopilot) -> some View {
        if pilot.paused != nil {
            Button("Resume") { model.resumeAutopilot(project) }
                .controlSize(.small)
                .help(pilot.current != nil ? "Tell the session to carry on with its idea" : "Start the next idea")
        }
        Menu {
            if pilot.paused == nil, pilot.current != nil {
                Button(pilot.stopping ? "Keep Going After This Idea" : "Stop After This Idea") { model.toggleStopAfterCurrent(project) }
            }
            if pilot.current != nil {
                Button("Skip to the Next Idea") { model.skipAutopilotIdea(project) }
            }
            Divider()
            Button("Stop Now") { model.stopAutopilot(project) }
        } label: {
            Text("Stop")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .help("Stop after this idea, skip it, or stop now (its session stays open)")
    }
}
