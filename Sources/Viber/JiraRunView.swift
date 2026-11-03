import SwiftUI
import ViberCore

/// Starts the autopilot on a Jira project: an epic's issues, or chosen ones, with what is left out and why.
struct JiraRunSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: JiraRunSheetRequest

    @State private var mode = PermissionMode.auto.rawValue
    @State private var profile: String?
    /// The account was picked here; until then each session starts on the least-used one when it starts.
    @State private var profileChosen = false
    @State private var sessions = Prefs.int(Prefs.autopilotSessions)
    @State private var worktrees = Prefs.int(Prefs.autopilotWorktrees)
    @State private var removed: Set<String> = []
    @State private var pattern = Worktree.defaultBranchPattern

    private static let modes: [PermissionMode] = [.auto, .acceptEdits, .default]

    private var board: JiraBoard? { model.jiraBoard(for: request.project) }

    /// The issues the sheet was opened on: the epic's, as far as they are loaded, or the chosen keys.
    private var candidates: [JiraIssue]? {
        guard let board else { return [] }
        if let epic = request.epic { return board.epicChildren[epic.key] }
        return request.keys.compactMap { board.known[$0] }
    }

    private var split: (queue: [JiraIssue], left: [(JiraIssue, String)]) {
        guard let board, let candidates else { return ([], []) }
        var queue: [JiraIssue] = [], left: [(JiraIssue, String)] = []
        for issue in candidates {
            if let why = JiraRun.ineligible(issue, mine: board.isMine(issue)) { left.append((issue, why)) }
            else if !removed.contains(issue.key) { queue.append(issue) }
        }
        return (queue, left)
    }

    var body: some View {
        let (queue, left) = split
        VStack(spacing: 0) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(request.epic.map { "Autopilot for \($0.key) \($0.summary)" } ?? "Autopilot for \(model.projectName(request.project))",
                              systemImage: "airplane").font(.headline)
                        Text("Takes these issues, several at a time, each in a new worktree with a session that runs the project's own skill (\(model.trackers.tracker(for: request.project)?.startMessage ?? "/work-issue <key>")). Each commits on its branch and stops at In Review; nothing is pushed or merged. You ship each branch, and the skill moves the issue to Done.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section(candidates == nil ? "Loading the epic's issues…" : "\(queue.count) to take, in Jira's order") {
                    if candidates == nil { ProgressView().controlSize(.small) }
                    ForEach(queue) { issue in
                        HStack(spacing: 8) {
                            Text(issue.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(issue.summary).lineLimit(1)
                            Spacer()
                            Button { removed.insert(issue.key) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Leave it out")
                        }
                    }
                    if candidates != nil, queue.isEmpty { Text("Nothing it can take.").foregroundStyle(.secondary) }
                }
                if !left.isEmpty {
                    Section("Left out") {
                        ForEach(left, id: \.0.key) { issue, why in
                            HStack(spacing: 8) {
                                Text(issue.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(issue.summary).lineLimit(1)
                                Spacer()
                                Text(why).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    LabeledContent("Jira changes it makes without asking") {
                        Text("Reading anything; moving the issue it is on, and commenting on it, as the project's skill does. Any other change (a new issue, another issue, Done, Wontfix) waits for you in the session and pauses the run.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Picker("Mode", selection: $mode) {
                        ForEach(Self.modes, id: \.self) { Text($0.label).tag($0.rawValue) }
                    }
                    AccountPicker(selection: Binding(get: { profile }, set: { profile = $0; profileChosen = true }),
                                  best: model.bestAccount(for: request.project))
                        .help(profileChosen ? "Every session runs on this account"
                              : "Each session starts on the least-used account when it starts, and moves to another when that runs low")
                    Stepper("Sessions at once: \(sessions)", value: $sessions, in: 1...JiraRun.maxSessions)
                    Stepper("Worktrees at most: \(worktrees)", value: $worktrees, in: max(sessions, 1)...32)
                    Text("A shipped issue keeps its worktree until it is merged and cleaned up, so the run can't get further ahead of you than this.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    CheckBeforeShipping(project: request.project, commits: true)
                    LabeledContent("Branches") { Text(Autopilot.usablePattern(pattern)) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let problem = problem(queue) { Text(problem).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start", action: start).keyboardShortcut(.defaultAction).disabled(problem(queue) != nil)
            }
            .padding(16)
        }
        .frame(width: 560)
        .fitsWindow()
        .task {
            profile = model.bestAccount(for: request.project)
            let project = request.project
            let key = await Task.detached { Worktree.repoRoot(project).map { WorktreeHooks.mainCheckout($0) ?? $0 } }.value
            if let key { pattern = Prefs.branchPattern(project: key) }
        }
    }

    private func problem(_ queue: [JiraIssue]) -> String? {
        if model.jiraRuns[request.project] != nil { return "The autopilot is already running here." }
        if candidates == nil { return "Loading…" }
        if queue.isEmpty { return "There is nothing to take." }
        return nil
    }

    private func start() {
        let queue = split.queue
        UserDefaults.standard.set(sessions, forKey: Prefs.autopilotSessions)
        UserDefaults.standard.set(worktrees, forKey: Prefs.autopilotWorktrees)
        var run = JiraRun(project: request.project, keys: queue.map(\.key), epicKey: request.epic?.key,
                          label: request.epic.map { "\($0.key) \($0.summary)" } ?? "issues you picked",
                          sessionsAtOnce: sessions, worktreesAtMost: worktrees, permissionMode: mode, profile: profile, branchPattern: pattern)
        run.leftOut = split.left.map { ($0.0.key, $0.1) }
        run.autoAccount = !profileChosen
        model.startJiraRun(run)
        dismiss()
    }
}

/// What a Jira project's autopilot is doing, and the issues it took with how each went.
struct JiraRunCard: View {
    @Environment(AppModel.self) private var model
    let project: String

    var body: some View {
        let running = model.jiraRuns[project]
        if let run = running ?? model.finishedJiraRuns[project] {
            let tint = run.paused == nil ? Color.accentColor : Color.orange
            let board = model.jiraBoard(for: project)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "airplane").foregroundStyle(tint)
                    Text(running == nil ? (run.stopping ? "Autopilot stopped" : "Autopilot finished") : run.paused == nil ? "Autopilot" : "Autopilot paused")
                        .fontWeight(.semibold)
                    Text("· \(run.label) · \(run.tally)" + (running == nil ? "" : " · \(run.queue.count) to go")).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    if running != nil {
                        if run.paused != nil {
                            Button("Resume") { model.resumeJiraRun(project) }.controlSize(.small)
                        }
                        Menu {
                            if run.paused == nil, !run.active.isEmpty {
                                Button(run.stopping ? "Keep Going After These Issues" : "Stop After These Issues") { model.toggleStopJiraRunAfterCurrent(project) }
                            }
                            Divider()
                            Button("Stop Now") { model.stopJiraRun(project) }
                        } label: { Text("Stop") }
                        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                    } else {
                        Button { model.dismissFinishedJiraRun(project) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).accessibilityLabel("Dismiss")
                    }
                }
                ForEach(run.handled.filter { !run.active.contains($0) }, id: \.self) { key in
                    let report = run.reports[key]
                    let pane = model.panes.first { $0.projectPath == project && $0.jiraRunKey == key }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: report?.finished == true ? "checkmark.seal" : "exclamationmark.triangle")
                            .foregroundStyle(report?.finished == true ? Color.green : Color.orange)
                        (Text("\(key) \(board?.known[key]?.summary ?? "")").fontWeight(.medium)
                         + Text("  " + (report?.text ?? "Stopped before it reported.")).foregroundStyle(.secondary))
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        if let pane { Button("Open") { model.select(.pane(pane.id)) }.buttonStyle(.link) }
                    }
                    .font(.callout)
                }
                if running != nil {
                    if let reason = run.paused { Text(reason).foregroundStyle(.secondary).font(.callout) }
                    ForEach(run.active, id: \.self) { key in
                        let pane = model.panes.first { $0.projectPath == project && $0.jiraRunKey == key }
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let pane {
                                Text(doing(pane, key: key)).foregroundStyle(pane.state.needsYou ? .orange : .primary)
                                Button("Open") { model.select(.pane(pane.id)) }.buttonStyle(.link)
                            } else {
                                Text("Making a worktree for \(key)…")
                            }
                            Spacer(minLength: 4)
                            Button("Skip") { model.skipJiraIssue(key, project: project) }.buttonStyle(.link).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    if let wait = model.jiraRunWait(project) { Text(wait).foregroundStyle(.secondary).font(.callout) }
                    if run.stopping { Text("Stops after these issues.").foregroundStyle(.secondary).font(.callout) }
                } else {
                    Text("Nothing was pushed or merged. Review each branch, then say ship in its session; the project's skill moves the issue to Done.")
                        .foregroundStyle(.secondary).font(.callout)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.35)))
        }
    }

    private func doing(_ pane: Pane, key: String) -> String {
        switch pane.state {
        case .permission where pane.chat.items.last.map({ if case .permission = $0.kind { return true }; return false }) == true:
            return "\(key) waits for you: a Jira change the run doesn't make on its own."
        case .permission, .input, .plan: return "\(key) is waiting for you: \(pane.state.label.lowercased())."
        case .failed: return "\(key) failed."
        case .exited: return "\(key) stopped."
        default: return "Working on \(key)."
        }
    }
}
