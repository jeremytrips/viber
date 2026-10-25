import AppKit
import SwiftUI
import ViberCore

/// A project's page: Planning (its open sessions, issues, earlier sessions, worktrees and branches) and Settings.
struct ProjectView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case planning = "Planning", settings = "Settings"
        var id: Self { self }
    }

    @Environment(AppModel.self) private var model
    let path: String

    @State private var summary: RepoSummary?
    @State private var loading = false
    @State private var showAllEarlier = false
    @State private var showAllBranches = false
    @State private var editingPattern = false
    @State private var pattern = Worktree.defaultBranchPattern
    @State private var draft = ""
    @AppStorage("projectTab") private var tab: Tab = .planning
    @AppStorage("issuesAsBoard") private var board = false
    @State private var editingPrefix = false
    @State private var creatingRepo = false
    @State private var repoError: String?
    @FocusState private var issueFocused: Bool

    private static let earlierShown = 6
    private static let branchesShown = 8

    private var project: Project { model.projects.project(path) ?? Project(path: path, addedAt: Date()) }
    private var panes: [Pane] { model.panes.filter { $0.projectPath == path } }
    private var jobs: [WorktreeJob] { model.jobs.filter { $0.project == path } }

    /// Sessions clauth knows of in this project that are not open, newest first.
    private var earlier: [ClauthSession] {
        let open = Set(model.panes.compactMap(\.chat.sessionID) + model.panes.compactMap(\.spec.resume))
        return model.recent.filter { session in
            guard let folder = session.workspace, !open.contains(session.id) else { return false }
            return (model.recentRoots[folder] ?? folder) == path
        }
        .sorted { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                Picker("Tab", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity)
                .padding(.vertical, -8)
                if tab == .planning {
                    openSessions
                    issues
                    earlierSessions
                    if summary?.isRepo == true {
                        worktrees
                        branches
                    }
                } else {
                    settings
                }
            }
            .padding(24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(project.name)
        .task(id: path) { await reload() }
        // A worktree was made or removed, or a session opened or closed.
        .onChange(of: model.jobs.count) { Task { await reload() } }
        .onChange(of: model.panes.count) { Task { await reload() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.title2.weight(.semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(path)
                    if let branch = summary?.currentBranch {
                        Chip(text: "⑂ " + branch).help("Checked out in the project's folder")
                    }
                    if summary?.isRepo == false { Chip(text: "not a git repository") }
                }
            }
            Spacer(minLength: 12)
            Menu { ProjectMenu(path: path, onPage: true) } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Show in Finder, open in VS Code, rename or remove from the sidebar")
            Button { model.newSession(in: path) } label: { Label("New Session", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .help("Start a session in \(project.name) (⌘N)")
        }
    }

    // MARK: Sessions

    private var openSessions: some View {
        let panes = panes, jobs = jobs
        return PageSection(title: "Open Sessions", detail: panes.isEmpty ? nil : "\(panes.count)") {
            if panes.isEmpty && jobs.isEmpty {
                Text("No session is open here. Start one, or resume an earlier one below.")
                    .foregroundStyle(.secondary)
            } else {
                PageCard {
                    ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                        if index > 0 { Divider() }
                        ProjectSessionRow(pane: pane, project: path)
                    }
                    ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                        if index > 0 || !panes.isEmpty { Divider() }
                        ProjectJobRow(job: job)
                    }
                }
            }
        }
    }

    private var earlierSessions: some View {
        let all = earlier
        let shown = showAllEarlier ? all : Array(all.prefix(Self.earlierShown))
        return PageSection(title: "Earlier Sessions", detail: all.isEmpty ? nil : "\(all.count)") {
            if all.count > Self.earlierShown {
                Button(showAllEarlier ? "Show Fewer" : "Show All") { showAllEarlier.toggle() }.buttonStyle(.link)
            }
        } content: {
            if all.isEmpty {
                Text(model.recent.isEmpty ? "Earlier sessions come from clauth's session list, which is empty or unavailable."
                                          : "No earlier sessions in this project.")
                    .foregroundStyle(.secondary)
            } else {
                PageCard {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Divider() }
                        EarlierSessionRow(session: session, project: path)
                    }
                }
            }
        }
    }

    // MARK: Issues

    @ViewBuilder
    private var issues: some View {
        if let board = model.jiraBoard(for: path) {
            jiraIssues(board)
        } else {
            ownIssues
        }
    }

    private func jiraIssues(_ board: JiraBoard) -> some View {
        PageSection(title: "Issues", detail: board.view.map { "\($0.name) · \(board.site?.host ?? board.tracker.site)" }) {
            HStack(spacing: 14) {
                Button("All Issues") { model.select(.issues) }
                    .buttonStyle(.link)
                    .help("Every project's own issues (⇧⌘I)")
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                JiraRunCard(project: path)
                JiraIssuesSection(project: path, board: board)
            }
        }
    }

    private var ownIssues: some View {
        let mine = model.issues.issues(in: path)
        let toDo = mine.filter { $0.status == .open }.count
        let counts = [(toDo, "to do"), (mine.filter { $0.status == .started }.count, "in progress"),
                      (mine.filter { $0.status == .review }.count, "in review")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return PageSection(title: "Issues", detail: counts.isEmpty ? nil : counts.joined(separator: " · ")) {
            HStack(spacing: 14) {
                if model.autopilots[path] == nil, toDo > 0, summary?.isRepo != false {
                    Button { model.offerAutopilot(project: path) } label: { Label("Autopilot…", systemImage: "airplane") }
                        .buttonStyle(.link)
                        .help("Implement the issues to do one after another on their own, each in a new worktree, shipped once it works")
                }
                Button("All Issues") { model.select(.issues) }
                    .buttonStyle(.link)
                    .help("Every project's issues (⇧⌘I)")
                Picker("Layout", selection: $board) {
                    Image(systemName: "list.bullet").tag(false).help("List")
                    Image(systemName: "rectangle.split.3x1").tag(true).help("Board")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                AutopilotCard(project: path)
                HStack(alignment: .top, spacing: 6) {
                    TextField("New issue… the first line is its title", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .focused($issueFocused)
                        .onSubmit(addIssue)
                    Button("Add", action: addIssue)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if mine.isEmpty {
                    Text("No issues yet. Start opens a session for one in plan mode; sessions move it along as they ship, and can add issues with /issue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if board {
                    IssueBoard(project: path)
                } else {
                    IssueGroups(project: path)
                }
            }
        }
    }

    private func addIssue() {
        model.addIssue(draft, project: path, by: "you")
        draft = ""
        issueFocused = true
    }

    // MARK: Repository

    private var worktrees: some View {
        let linked = summary?.worktrees.filter { !$0.isMain } ?? []
        return PageSection(title: "Worktrees", detail: linked.isEmpty ? nil : "\(linked.count)") {
            Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(loading)
                .help("Read the worktrees and branches again")
        } content: {
            if linked.isEmpty {
                Text("None yet. A session started with “Run in a new git worktree” gets its own, so parallel sessions don't collide.")
                    .foregroundStyle(.secondary)
            } else {
                PageCard {
                    ForEach(Array(linked.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        WorktreeEntryRow(entry: entry, project: path)
                    }
                }
            }
        }
    }

    private var branches: some View {
        let all = summary?.branches ?? []
        let shown = showAllBranches ? all : Array(all.prefix(Self.branchesShown))
        let worktrees = summary?.worktrees ?? []
        return PageSection(title: "Branches", detail: all.isEmpty ? nil : "\(all.count)") {
            if all.count > Self.branchesShown {
                Button(showAllBranches ? "Show Fewer" : "Show All") { showAllBranches.toggle() }.buttonStyle(.link)
            }
        } content: {
            if all.isEmpty {
                Text("No branches yet.").foregroundStyle(.secondary)
            } else {
                PageCard {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, branch in
                        if index > 0 { Divider() }
                        BranchRow(branch: branch, checkout: worktrees.first { $0.branch == branch.name })
                    }
                }
            }
        }
    }

    // MARK: Settings

    private var settings: some View {
        let prefix = model.issues.prefix(for: path)
        let jira = model.trackers.tracker(for: path) != nil
        return PageSection(title: "Settings") {
            PageCard {
                TrackerSettingsRows(project: path)
                if !jira {
                    Divider()
                    SettingRow(label: "Issue keys",
                               note: "\(prefix)-1, \(prefix)-2… Branch names carry them, and sessions and commits refer to issues by them.") {
                        Text(prefix).font(.callout.monospaced()).textSelection(.enabled)
                        Button("Edit…") { editingPrefix = true }
                            .popover(isPresented: $editingPrefix, arrowEdge: .bottom) {
                                IssuePrefixEditor(project: path, isPresented: $editingPrefix)
                            }
                    }
                }
                Divider()
                if summary?.isRepo == true {
                    SettingRow(label: "Branch pattern",
                               note: "The branch new worktree sessions start on. <slug> is the session name and <key> the issue's key; a pattern with neither puts the key in front of the slug. Saved in Viber, not in the repository.") {
                        Text(pattern).font(.callout.monospaced()).textSelection(.enabled)
                        Button("Edit…") { editingPattern = true }
                            .popover(isPresented: $editingPattern, arrowEdge: .bottom) {
                                BranchPatternEditor(project: path, draft: pattern, isPresented: $editingPattern) { pattern = $0 }
                            }
                    }
                    Divider()
                } else if summary?.isRepo == false {
                    SettingRow(label: "Git", note: repoError ?? "Worktrees, branches and branch patterns need a git repository.",
                               noteIsError: repoError != nil) {
                        Button("Create Repository", action: createRepo).disabled(creatingRepo)
                            .help("git init, then a first commit of a README, so worktrees have a branch to start from")
                    }
                    Divider()
                }
                SettingRow(label: "Claude Code settings",
                           note: "Permissions, hooks and MCP servers for every session here. Viber keeps the personal file out of git.") {
                    SettingsFileButton(title: "Shared", url: SettingsFile.url(.projectShared, cwd: path))
                    SettingsFileButton(title: "Just Me", url: SettingsFile.url(.projectLocal, cwd: path))
                }
                Divider()
                SettingRow(label: "Instructions", note: "CLAUDE.md, which every session here reads.") {
                    SettingsFileButton(title: "Open CLAUDE.md", url: URL(fileURLWithPath: path).appendingPathComponent("CLAUDE.md"))
                }
                if let pane = panes.first {
                    Divider()
                    SettingRow(label: "As a session sees them",
                               note: "MCP servers, rules and output style in effect, from every settings file. Changes there can be saved for the project.") {
                        Button("Session Settings…") { model.openSettings(.permissions, in: pane) }
                    }
                }
            }
        }
    }

    private func createRepo() {
        creatingRepo = true
        repoError = nil
        let dir = path
        Task {
            let result = await Task.detached { Result { try Worktree.createRepo(dir) } }.value
            if case .failure(let error) = result { repoError = error.localizedDescription }
            await reload()
            creatingRepo = false
        }
    }

    private func reload() async {
        loading = true
        let dir = path
        let loaded = await Task.detached { RepoSummary.load(dir) }.value
        guard dir == path else { return }
        summary = loaded
        pattern = Prefs.branchPattern(project: dir)
        loading = false
    }
}

// MARK: - Layout

/// A titled block of the project page, with an optional control on the right of its title.
private struct PageSection<Accessory: View, Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.headline)
                if let detail { Text(detail).foregroundStyle(.secondary) }
                Spacer()
                accessory
            }
            content
        }
    }
}

extension PageSection where Accessory == EmptyView {
    init(title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, detail: detail, accessory: { EmptyView() }, content: content)
    }
}

private struct PageCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

private struct SettingRow<Controls: View>: View {
    let label: String
    let note: String
    var noteIsError = false
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(note)
                    .font(.caption)
                    .foregroundStyle(noteIsError ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { controls }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

/// Where a session or worktree is, relative to its project.
private func place(_ folder: String, in project: String) -> String {
    if folder == project { return "project folder" }
    if folder.hasPrefix(project + "/") { return String(folder.dropFirst(project.count + 1)) }
    return (folder as NSString).abbreviatingWithTildeInPath
}

// MARK: - Rows

private struct ProjectSessionRow: View {
    @Environment(AppModel.self) private var model
    let pane: Pane
    let project: String

    var body: some View {
        Button { model.select(.pane(pane.id)) } label: {
            HStack(spacing: 10) {
                StateDot(state: pane.state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.title).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let diff = pane.diffStat { Text(diff).font(.caption.monospaced()).foregroundStyle(.secondary) }
                Text(pane.state.label).font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { PaneRowMenu(pane: pane) }
        .help("Open \(pane.title)")
    }

    private var subtitle: String {
        var parts = [pane.branch.map { "⑂ " + $0 } ?? place(pane.cwd, in: project)]
        parts.append(pane.profileLabel)
        return parts.joined(separator: " · ")
    }
}

private struct ProjectJobRow: View {
    @Environment(AppModel.self) private var model
    let job: WorktreeJob

    var body: some View {
        Button { model.select(.job(job.id)) } label: {
            HStack(spacing: 10) {
                if job.isRunning {
                    ProgressView().controlSize(.small).frame(width: 8, height: 8)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
                }
                Text(job.title).lineLimit(1)
                Spacer(minLength: 8)
                Text(job.statusText).font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct EarlierSessionRow: View {
    @Environment(AppModel.self) private var model
    let session: ClauthSession
    let project: String

    var body: some View {
        let folder = session.workspace ?? project
        let exists = FileManager.default.fileExists(atPath: folder)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).lineLimit(1)
                Text(place(folder, in: project) + (session.updatedDate.map { " · " + IssueRow.relative($0, now: model.now) } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder)
            }
            Spacer(minLength: 8)
            if let profile = session.lastRanProfile, !profile.isEmpty { Chip(text: profile) }
            Button("Resume") { model.resume(session, profile: profile) }
                .controlSize(.small)
                .disabled(!exists)
                .help(exists ? "Open this conversation again" : "Its folder is gone, probably a removed worktree")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// The account it last ran on, if that login still works, else the default one.
    private var profile: String? {
        if let name = session.lastRanProfile, model.profiles.contains(where: { $0.name == name && $0.loginProblem == nil }) { return name }
        return AccountPicker.usableDefault(model)
    }
}

private struct WorktreeEntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: WorktreeEntry
    let project: String

    var body: some View {
        let session = model.panes.first { $0.worktree?.path == entry.path || $0.cwd == entry.path || $0.cwd.hasPrefix(entry.path + "/") }
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.branch ?? "detached at \(entry.head.prefix(7))").font(.callout.monospaced()).lineLimit(1)
                Text(place(entry.path, in: project))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.path)
            }
            Spacer(minLength: 8)
            if let session {
                Button("Open “\(session.title)”") { model.select(.pane(session.id)) }
                    .buttonStyle(.link)
                    .lineLimit(1)
            } else if entry.isPrunable {
                Text("folder is gone").font(.caption).foregroundStyle(.orange)
                    .help("git still lists it; `git worktree prune` forgets it")
            } else {
                Button("Start Session") { model.openSession(inWorktree: entry) }
                    .controlSize(.small)
                    .help("Open a session in this worktree, on the branch it has checked out")
            }
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .disabled(entry.isPrunable)
                .help("Show in Finder")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private struct BranchRow: View {
    @Environment(AppModel.self) private var model
    let branch: BranchEntry
    /// Where it is checked out, if anywhere.
    let checkout: WorktreeEntry?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(branch.name).font(.callout.monospaced()).lineLimit(1).textSelection(.enabled)
                    if let checkout { Chip(text: checkout.isMain ? "checked out" : "in a worktree").help(checkout.path) }
                }
                if !branch.subject.isEmpty {
                    Text(branch.subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let date = branch.date {
                Text(IssueRow.relative(date, now: model.now)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .contextMenu {
            Button("Copy Branch Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(branch.name, forType: .string)
            }
        }
    }
}

/// Changes a project's issue key prefix; its issues are renumbered with it (the numbers stay).
private struct IssuePrefixEditor: View {
    @Environment(AppModel.self) private var model
    let project: String
    @Binding var isPresented: Bool
    @State private var draft = ""

    var body: some View {
        let cleaned = IssueList.cleanPrefix(draft)
        let fallback = IssueList.defaultPrefix(forProject: project)
        VStack(alignment: .leading, spacing: 10) {
            Text("Issue keys").font(.headline)
            TextField("Prefix", text: $draft, prompt: Text(fallback))
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Text(cleaned.isEmpty ? "Letters and digits, such as \(fallback). Keys become \(fallback)-1, \(fallback)-2…"
                 : "Keys become \(cleaned)-1, \(cleaned)-2… Existing issues keep their numbers.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Use Default") { draft = "" }
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { draft = model.issues.prefixes[project] ?? "" }
    }

    private func save() {
        model.setIssuePrefix(draft, project: project)
        isPresented = false
    }
}
