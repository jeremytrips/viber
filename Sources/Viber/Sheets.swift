import AppKit
import SwiftUI
import ViberCore

// MARK: - Shared pieces

/// Account choice: nil is the plain `claude` login, otherwise a clauth profile name.
struct AccountPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?
    var label = "Account"

    var body: some View {
        Picker(label, selection: $selection) {
            Text("Default login (plain claude)").tag(String?.none)
            if !model.profiles.isEmpty { Divider() }
            ForEach(model.profiles) { profile in
                Text(Self.title(for: profile))
                    .tag(String?.some(profile.name))
                    .disabled(profile.loginProblem != nil)
            }
        }
    }

    static func title(for profile: ClauthStatus.Profile) -> String {
        var text = profile.name.capitalized
        if let tier = profile.tier, !tier.isEmpty { text += " (\(tier))" }
        if let problem = profile.loginProblem { text += " — \(problem)" }
        return text
    }
}

/// The account a project's new sessions start with. A profile with a broken login can be chosen: logging in again
/// fixes it, and Viber doesn't swap it for another account.
struct ProjectAccountPicker: View {
    @Environment(AppModel.self) private var model
    let project: String

    var body: some View {
        let account = model.account(of: project)
        Picker("Account", selection: Binding(get: { account }, set: { model.setAccount($0, for: project) })) {
            Text(model.defaultProfile.map { "clauth's default (\($0.capitalized))" } ?? "clauth's default").tag(ProjectAccount.clauthDefault)
            Text("Default login (plain claude)").tag(ProjectAccount.plain)
            if !model.profiles.isEmpty { Divider() }
            ForEach(model.profiles) { profile in
                Text(AccountPicker.title(for: profile)).tag(ProjectAccount.profile(profile.name))
            }
            if case .profile(let name) = account, !model.profiles.contains(where: { $0.name == name }) {
                Text(model.status == nil ? name : "\(name) — not in clauth").tag(account)
            }
        }
        .help("The Claude login new sessions in \(model.projectName(project)) start with")
    }
}

extension EnvironmentValues {
    /// How tall a sheet can be and still fit in the main window. Nil until the window is measured.
    @Entry var sheetRoom: CGFloat?
}

extension View {
    /// Sizes a sheet to its content, but no taller than the window: past that its Form scrolls and the buttons under
    /// it stay in view. Sized to its content alone, a long sheet ran off the screen, which cut off its top and bottom.
    func fitsWindow() -> some View { modifier(FitsWindow()) }
}

private struct FitsWindow: ViewModifier {
    @Environment(\.sheetRoom) private var room

    func body(content: Content) -> some View {
        content
            .frame(maxHeight: room)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private enum Relative {
    static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func string(_ date: Date?) -> String {
        guard let date else { return "" }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - New session

struct NewSessionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Where the session runs: a project, or a folder in one.
    @State private var folder = ""
    /// The project `folder` belongs to, once looked up.
    @State private var projectRoot: String?
    @State private var profile: String?
    /// The account was picked here, so it no longer follows the project's.
    @State private var profileChosen = false
    @State private var useWorktree = false
    @State private var repoRoot: String?
    @State private var creatingRepo = false
    @State private var repoError: String?
    @State private var name = ""
    @State private var permissionMode = "auto"
    @State private var firstMessage = ""
    @State private var didLoad = false
    @State private var maker = WorktreeMaker.git(include: false)
    /// The worktree's branch. It follows the name (the project's pattern, `viber/<slug>` by default) until it is edited.
    @State private var branch = ""
    @State private var branchEdited = false
    @State private var branchProblem: String?
    /// The project's branch pattern, and the main checkout it is saved for.
    @State private var pattern = Worktree.defaultBranchPattern
    @State private var patternProject: String?
    @State private var editingPattern = false
    /// The issue this session is started for, when planning it opened the sheet.
    @State private var issueID: String?
    @State private var issueKey: String?
    @State private var base = WorktreeBase.originDefault
    @State private var baseChoices = BaseChoices(hasOrigin: false, originDefault: nil, current: nil)

    /// What makes the worktree for this folder: git, or the project's WorktreeCreate hook.
    enum WorktreeMaker: Equatable {
        case git(include: Bool)
        case hooks([HookCommand])
        case unsupported(String)

        var note: String {
            switch self {
            case .git(let include):
                return "Creates .claude/worktrees/<name> on a new branch, so parallel sessions don't collide"
                    + (include ? ". Copies the gitignored files .worktreeinclude lists." : "")
            case .hooks:
                return "The project's WorktreeCreate hook makes it and chooses where its branch starts, as in Claude Code. Its output shows in the sidebar while it runs."
            case .unsupported(let message):
                return message
            }
        }

        var blocksWorktree: Bool { if case .unsupported = self { return true }; return false }
        var usesHook: Bool { if case .hooks = self { return true }; return false }

        /// Looks up the folder's Claude Code settings. Blocking: run it off the main thread.
        static func find(folder: String, root: String) -> WorktreeMaker {
            do {
                let hooks = try WorktreeHooks.hooks(.create, folder: folder)
                if !hooks.isEmpty { return .hooks(hooks) }
            } catch {
                return .unsupported(error.localizedDescription)
            }
            return .git(include: FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(WorktreeInclude.fileName)))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Project") {
                        HStack(spacing: 6) {
                            projectLabel
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(folder)
                            projectMenu
                            Button("Choose…", action: chooseFolder)
                                .help("A folder or git repository. A new one is added to the sidebar's projects.")
                        }
                    }
                    AccountPicker(selection: Binding(get: { profile }, set: { profile = $0; profileChosen = true }))
                }

                Section {
                    if repoRoot == nil && !folder.isEmpty {
                        LabeledContent {
                            Button("Create One", action: createRepo)
                                .disabled(creatingRepo)
                        } label: {
                            Text("Run in a new git worktree")
                            worktreeNote("This folder is not in a git repository.")
                        }
                    } else {
                        Toggle(isOn: $useWorktree) {
                            Text("Run in a new git worktree")
                            worktreeNote(maker.note)
                        }
                        .disabled(repoRoot == nil)
                        if useWorktree, case .hooks(let hooks) = maker {
                            LabeledContent("Setup") {
                                VStack(alignment: .trailing, spacing: 2) {
                                    ForEach(hooks, id: \.display) { hook in
                                        Text(hook.display).font(.callout.monospaced()).lineLimit(2).truncationMode(.middle)
                                            .textSelection(.enabled).help("From \(hook.source)")
                                    }
                                }
                            }
                        }
                    }
                    TextField("Name", text: $name, prompt: Text("Session name (used for the branch)"))
                    if useWorktree && repoRoot != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent("Branch") {
                                HStack(spacing: 6) {
                                    TextField("Branch", text: Binding(get: { branch }, set: { branch = $0; branchEdited = !$0.isEmpty && $0 != defaultBranch }),
                                              prompt: Text(defaultBranch))
                                        .labelsHidden()
                                        .font(.body.monospaced())
                                    Button("Pattern…") { editingPattern = true }
                                        .disabled(patternProject == nil)
                                        .help("The branch name new worktree sessions in this repository start with")
                                        .popover(isPresented: $editingPattern, arrowEdge: .bottom) {
                                            if let patternProject {
                                                BranchPatternEditor(project: patternProject, draft: pattern, isPresented: $editingPattern) { saved in
                                                    pattern = saved
                                                    branchEdited = false
                                                    branch = Worktree.defaultBranch(forName: sessionTitle, pattern: saved, key: issueKey)
                                                }
                                            }
                                        }
                                }
                            }
                            if let branchProblem {
                                // A part like <id> left to fill in is a step to take, not a mistake.
                                Text(branchProblem).font(.caption)
                                    .foregroundStyle(Worktree.placeholders(in: chosenBranch ?? defaultBranch).isEmpty ? .red : .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if !maker.usesHook { basePicker }
                    }
                    Picker("Mode", selection: $permissionMode) {
                        ForEach(PermissionMode.offered, id: \.self) { Text($0.label).tag($0.rawValue) }
                    }
                }

                Section("First message (optional)") {
                    TextEditor(text: $firstMessage)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(height: 72)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(folder.isEmpty || (useWorktree && repoRoot != nil && (maker.blocksWorktree || branchProblem != nil
                                                                                   || (!branchEdited && Worktree.needsInput(pattern, key: issueKey)))))
            }
            .padding(16)
        }
        .frame(width: 520)
        .fitsWindow()
        .onAppear(perform: load)
        .task(id: folder) { await checkRepo() }
        .onChange(of: defaultBranch) { if !branchEdited { branch = defaultBranch } }
        .task(id: "\(folder)|\(branch)|\(branchEdited)|\(useWorktree)|\(maker.usesHook)|\(pattern)") { await checkBranch() }
    }

    /// The project's name, then its path, or where in it the session runs.
    private var projectLabel: Text {
        guard !folder.isEmpty else { return Text("No project chosen").foregroundStyle(.secondary) }
        let root = projectRoot ?? folder
        let place = folder == root ? (root as NSString).abbreviatingWithTildeInPath
            : folder.hasPrefix(root + "/") ? "in " + folder.dropFirst(root.count + 1) : "in " + (folder as NSString).abbreviatingWithTildeInPath
        // A Form shows LabeledContent's value in the secondary color unless told otherwise.
        return Text(model.projectName(root)).fontWeight(.medium).foregroundStyle(.primary) + Text("  " + place).foregroundStyle(.secondary)
    }

    /// The sidebar's projects, then recent folders of projects it doesn't have.
    private var projectMenu: some View {
        let projects = model.sidebarProjects
        let others = model.recentFolders.filter { !model.projects.contains(model.recentRoots[$0] ?? $0) }.prefix(15)
        return Menu("Projects") {
            ForEach(projects) { project in
                Button { folder = project.path } label: {
                    if project.path == projectRoot { Label(project.name, systemImage: "checkmark") } else { Text(project.name) }
                }
            }
            if !others.isEmpty {
                if !projects.isEmpty { Divider() }
                Section("Recent Folders") {
                    ForEach(Array(others), id: \.self) { path in
                        Button((path as NSString).abbreviatingWithTildeInPath) { folder = path }
                    }
                }
            }
        }
        .disabled(projects.isEmpty && others.isEmpty)
        .fixedSize()
    }

    /// Where a git worktree's branch starts: origin's default branch (fetched first) or what is checked out here.
    /// A WorktreeCreate hook decides that itself, so this isn't shown then.
    @ViewBuilder private var basePicker: some View {
        let origin = baseChoices.originDefault ?? "origin's default branch"
        if baseChoices.hasOrigin, let current = baseChoices.current {
            Picker("Start from", selection: $base) {
                Text("\(origin) (fetched first)").tag(WorktreeBase.originDefault)
                Text("\(current) (checked out here)").tag(WorktreeBase.current)
            }
        } else if baseChoices.hasOrigin {
            LabeledContent("Start from") { Text("\(origin) (fetched first)") }
        } else if let current = baseChoices.current {
            LabeledContent("Start from") { Text(current) }
        }
    }

    /// The name the session will get, chosen as `createSession` chooses its title.
    private var sessionTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty ? trimmed
            : firstMessage.isEmpty ? URL(fileURLWithPath: folder).lastPathComponent : String(firstMessage.prefix(50))
    }

    /// The project's pattern filled in with the session's name.
    private var defaultBranch: String { Worktree.defaultBranch(forName: sessionTitle, pattern: pattern, key: issueKey) }

    private var chosenBranch: String? {
        let typed = branch.trimmingCharacters(in: .whitespaces)
        return branchEdited && !typed.isEmpty ? typed : nil
    }

    /// `git check-ref-format --branch`, that it doesn't exist yet, and what a hook can take, after a short pause in typing.
    private func checkBranch() async {
        guard useWorktree, let root = repoRoot else { branchProblem = nil; return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let name = chosenBranch ?? defaultBranch, hook = maker.usesHook
        // An untouched default is numbered if taken, so only a typed name has to be new. A default with a part
        // like <id> left still has to be filled in.
        let check = chosenBranch != nil || Worktree.needsInput(pattern, key: issueKey)
        let problem = await Task.detached { () -> String? in
            if check, case .problem(let problem) = Worktree.checkBranch(name, repo: root) { return problem }
            return hook ? Worktree.hookNameProblem(name) : nil
        }.value
        guard !Task.isCancelled else { return }
        branchProblem = problem
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        if let prefill = model.newSessionPrefill {
            model.newSessionPrefill = nil
            folder = prefill.folder
            profile = prefill.profile
            profileChosen = true
            name = prefill.name
            permissionMode = prefill.permissionMode
            firstMessage = prefill.firstMessage
            issueID = prefill.issueID
            issueKey = prefill.issueKey
            pattern = prefill.branchPattern
        } else {
            let asked = model.newSessionFolder ?? ""
            model.newSessionFolder = nil
            folder = !asked.isEmpty ? asked : model.selectedProject ?? model.sidebarProjects.first?.path ?? model.recentFolders.first ?? ""
            if !folder.isEmpty { followAccount(of: ProjectRoot.resolve(folder)) }
            permissionMode = Prefs.string(Prefs.newSessionMode)
        }
        branch = defaultBranch
    }

    /// The project's account, until one is picked here.
    private func followAccount(of project: String) {
        if !profileChosen { profile = model.launchProfile(for: project) }
    }

    /// The worktree row's subtitle, or the error from creating a repository.
    private func worktreeNote(_ text: String) -> Text {
        if let repoError { return Text(repoError).foregroundStyle(.red) }
        if case .unsupported = maker { return Text(text).foregroundStyle(.red) }
        return Text(text)
    }

    private func checkRepo() async {
        let dir = folder
        repoError = nil
        guard !dir.isEmpty else { repoRoot = nil; projectRoot = nil; useWorktree = false; return }
        let none = BaseChoices(hasOrigin: false, originDefault: nil, current: nil)
        let (root, found, project, choices, home) = await Task.detached { () -> (String?, WorktreeMaker, String?, BaseChoices, String) in
            let home = ProjectRoot.resolve(dir)
            guard let root = Worktree.repoRoot(dir) else { return (nil, .git(include: false), nil, none, home) }
            return (root, WorktreeMaker.find(folder: dir, root: root), WorktreeHooks.mainCheckout(dir) ?? root,
                    Worktree.baseChoices(root), home)
        }.value
        guard !Task.isCancelled, dir == folder else { return }
        repoRoot = root
        projectRoot = home
        followAccount(of: home)
        maker = found
        if project != patternProject {
            patternProject = project
            pattern = project.map { Prefs.branchPattern(project: $0) } ?? Worktree.defaultBranchPattern
            branchEdited = false
            branch = Worktree.defaultBranch(forName: sessionTitle, pattern: pattern, key: issueKey)
        }
        baseChoices = choices
        base = choices.available(.originDefault)
        guard let root else { useWorktree = false; return }
        // Default to a worktree when another open session already works in this repo (a chat doesn't). Planning an
        // issue always uses one.
        useWorktree = issueID != nil || model.panes.contains { pane in
            guard !pane.isChat else { return false }
            let paneRepo = pane.worktree?.repo ?? pane.spec.cwd
            return paneRepo == root || paneRepo.hasPrefix(root + "/") || paneRepo == dir
        }
    }

    /// `git init` plus a first commit (a README titled after the folder), so the worktree option works right away.
    private func createRepo() {
        let dir = folder
        creatingRepo = true
        Task {
            let result = await Task.detached { Result { try Worktree.createRepo(dir) } }.value
            await checkRepo()
            if case .failure(let error) = result, dir == folder { repoError = error.localizedDescription }
            creatingRepo = false
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if !folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: folder) }
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func start() {
        guard !folder.isEmpty else { return }
        model.createSession(NewSessionRequest(
            folder: folder,
            profile: profile,
            useWorktree: useWorktree && repoRoot != nil,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            branch: useWorktree ? chosenBranch : nil,
            base: baseChoices.available(base),
            permissionMode: permissionMode,
            firstMessage: firstMessage,
            issueID: issueID,
            issueKey: issueKey,
            branchPattern: pattern
        ))
        dismiss()
    }
}

/// Edits the branch pattern a repository's new worktree sessions start with.
struct BranchPatternEditor: View {
    let project: String
    @State var draft: String
    @Binding var isPresented: Bool
    var onSave: (String) -> Void

    private var trimmed: String { draft.trimmingCharacters(in: .whitespaces) }
    /// Without a part to fill in, every session would get the same branch.
    private var canSave: Bool { !Worktree.placeholders(in: trimmed).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Branch pattern for \(URL(fileURLWithPath: project).lastPathComponent)").font(.headline)
            TextField("Pattern", text: $draft, prompt: Text(Worktree.defaultBranchPattern))
                .labelsHidden()
                .font(.body.monospaced())
            Text(trimmed.isEmpty || canSave
                 ? "<slug> becomes the session name. Leave parts like <id> to fill in for each session. Saved in Viber, not in the repository."
                 : "Add <slug> or a part like <id>, so each session gets its own branch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Use Default") { draft = Worktree.defaultBranchPattern }
                Spacer()
                Button("Cancel", role: .cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        // The Form row it opens from right-aligns text fields.
        .multilineTextAlignment(.leading)
        .padding(14)
        .frame(width: 360)
    }

    private func save() {
        guard canSave else { return }
        Prefs.setBranchPattern(trimmed, project: project)
        onSave(trimmed)
        isPresented = false
    }
}

// MARK: - Resume

struct ResumeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selected: String?
    @State private var profile: String?

    private var sessions: [ClauthSession] {
        let sorted = model.recent.sorted { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? sorted : sorted.filter {
            $0.title.localizedCaseInsensitiveContains(q) || ($0.workspace ?? "").localizedCaseInsensitiveContains(q)
        }
        return Array(filtered.prefix(200))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Resume Session").font(.headline)
                Spacer()
            }
            .padding([.horizontal, .top], 16)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by title or folder", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
            .padding(16)

            let items = sessions
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(.secondary)
                    Text(model.recent.isEmpty ? "No sessions found. Is clauth installed?" : "No sessions match “\(query)”.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items, selection: $selected) { session in
                    ResumeRow(session: session).tag(session.id)
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { _ in
                } primaryAction: { ids in
                    if let id = ids.first { resume(id) }
                }
            }

            Divider()
            HStack {
                AccountPicker(selection: $profile)
                    .frame(maxWidth: 300)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Resume") { if let selected { resume(selected) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
            .padding(16)
        }
        .frame(width: 620, height: 520)
        .onAppear {
            model.reloadRecent()
            profile = ProjectAccount.clauthDefault.launchProfile(status: model.status)
        }
        // The chosen session's project decides, as for a new session there.
        .onChange(of: selected) {
            guard let folder = model.recent.first(where: { $0.id == selected })?.workspace else { return }
            profile = model.launchProfile(for: model.recentRoots[folder] ?? ProjectRoot.resolve(folder))
        }
    }

    private func resume(_ id: String) {
        guard let session = model.recent.first(where: { $0.id == id }) else { return }
        model.resume(session, profile: profile)
        dismiss()
    }
}

private struct ResumeRow: View {
    let session: ClauthSession

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).lineLimit(1)
                Text(session.workspace.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let profile = session.lastRanProfile, !profile.isEmpty { Chip(text: profile) }
            Text(Relative.string(session.updatedDate))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .help(session.workspace ?? "")
    }
}

// MARK: - Quick switcher

struct QuickSwitcher: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var highlight = 0
    @FocusState private var focused: Bool

    private enum Action {
        case target(Target)
        case newSession
        case addProject
        case resume
        case nextWaiting
    }

    private struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let state: PaneState?
        let icon: String?
        let action: Action
    }

    private var entries: [Entry] {
        var all: [Entry] = model.orderedPanes.map { pane in
            Entry(id: "pane:\(pane.id)", title: pane.title, subtitle: model.projectName(pane.projectPath),
                  state: pane.state, icon: nil, action: .target(.pane(pane.id)))
        }
        all += model.sidebarProjects.map { project in
            Entry(id: "project:\(project.path)", title: project.name, subtitle: "project", state: nil, icon: "folder",
                  action: .target(.project(project.path)))
        }
        all += model.externals.map { session in
            let title = model.recent.first { $0.id == session.id }?.title ?? session.projectName
            return Entry(id: "ext:\(session.id)", title: title, subtitle: "\(session.projectName) · running elsewhere",
                         state: PaneState(session.state), icon: nil, action: .target(.external(session.id)))
        }
        all += [
            Entry(id: "cmd:new", title: "New Session…", subtitle: "⌘N", state: nil, icon: "plus", action: .newSession),
            Entry(id: "cmd:project", title: "Add Project…", subtitle: "⇧⌘N", state: nil, icon: "folder.badge.plus", action: .addProject),
            Entry(id: "cmd:resume", title: "Resume Session…", subtitle: "⇧⌘R", state: nil,
                  icon: "clock.arrow.circlepath", action: .resume),
            Entry(id: "cmd:next", title: "Next session waiting for you", subtitle: "⌘J", state: nil,
                  icon: "arrow.right.circle", action: .nextWaiting)
        ]
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.subtitle.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let items = entries
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to a session or command", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { activate(items) }
                    .onKeyPress(.upArrow) { move(-1, count: items.count); return .handled }
                    .onKeyPress(.downArrow) { move(1, count: items.count); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(14)

            Divider()

            if items.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                                row(entry, highlighted: index == highlight)
                                    .id(entry.id)
                                    .onTapGesture { highlight = index; activate(items) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: highlight) { _, new in
                        if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
                    }
                }
            }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { focused = true }
        .onChange(of: query) { highlight = 0 }
    }

    private func row(_ entry: Entry, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if let state = entry.state {
                    StateDot(state: state)
                } else if let icon = entry.icon {
                    Image(systemName: icon)
                }
            }
            .frame(width: 16)
            Text(entry.title).lineLimit(1)
            Spacer(minLength: 8)
            Text(entry.subtitle)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(highlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
        }
        .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        highlight = min(max(highlight + delta, 0), count - 1)
    }

    private func activate(_ items: [Entry]) {
        guard items.indices.contains(highlight) else { return }
        let action = items[highlight].action
        dismiss()
        switch action {
        case .target(let target):
            model.select(target)
        case .nextWaiting:
            model.selectNextWaiting()
        case .newSession:
            presentLater { $0.showNewSession = true }
        case .addProject:
            presentLater { $0.chooseProject() }
        case .resume:
            presentLater { $0.reloadRecent(); $0.showResume = true }
        }
    }

    /// Sheets can't overlap, so open the next one after this one has gone.
    private func presentLater(_ change: @escaping @MainActor (AppModel) -> Void) {
        let model = model
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            change(model)
        }
    }
}

// MARK: - Close

struct CloseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pane: Pane

    @State private var hasChanges = false
    /// The project's WorktreeRemove hooks, for a worktree a WorktreeCreate hook made.
    @State private var teardown: [HookCommand] = []
    @State private var teardownProblem: String?

    private var busy: Bool { pane.state == .working || pane.state.needsYou }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Close “\(pane.title)”?").font(.headline)

            if busy {
                Label(pane.state == .working
                      ? "Claude is still working; closing stops it."
                      : "Claude is waiting for you; closing stops it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            if let worktree = pane.worktree {
                let branch = pane.branch ?? worktree.branch
                let switched = !worktree.branch.isEmpty && branch != worktree.branch
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Branch") { Text(branch).font(.callout.monospaced()).textSelection(.enabled) }
                    if switched {
                        LabeledContent("Created as") { Text(worktree.branch).font(.callout.monospaced()).textSelection(.enabled) }
                    }
                    LabeledContent("Worktree") {
                        Text((worktree.path as NSString).abbreviatingWithTildeInPath)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(worktree.path)
                    }
                    if !teardown.isEmpty {
                        LabeledContent("Teardown") {
                            VStack(alignment: .trailing, spacing: 2) {
                                ForEach(teardown, id: \.display) { hook in
                                    Text(hook.display).font(.callout.monospaced()).lineLimit(2).truncationMode(.middle)
                                        .textSelection(.enabled).help("The project's WorktreeRemove hook, from \(hook.source)")
                                }
                            }
                        }
                    }
                }
                if hasChanges {
                    Label("Has uncommitted changes", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                }
                if let teardownProblem {
                    Label(teardownProblem, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(removalNote(worktree, switchedTo: switched ? branch : nil))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Remove worktree and branch") { close(removeWorktree: true, deleteBranch: true) }
                    Button("Remove worktree") { close(removeWorktree: true) }
                    Button("Keep worktree") { close() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Close Session", role: .destructive) { close() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 580)
        .task {
            guard let worktree = pane.worktree else { return }
            model.refreshWorktree(pane)
            let (changes, hooks, problem) = await Task.detached { () -> (Bool, [HookCommand], String?) in
                let changes = Worktree.hasUncommittedChanges(worktree.path)
                guard worktree.madeByHook else { return (changes, [], nil) }
                do { return (changes, try WorktreeHooks.hooks(.remove, folder: worktree.folder ?? worktree.repo), nil) }
                catch { return (changes, [], error.localizedDescription) }
            }.value
            hasChanges = changes
            teardown = hooks
            teardownProblem = problem
        }
    }

    /// `branch` is the one the session switched to, which is never deleted.
    private func removalNote(_ worktree: WorktreeInfo, switchedTo branch: String?) -> String {
        var note = branch.map { "Removal is refused if there are uncommitted changes. Only \(worktree.branch), the branch the worktree was created on, is deleted, and only if it is merged; \($0) is kept." }
            ?? "Removal is refused if there are uncommitted changes, and the branch is only deleted if it is merged."
        if !teardown.isEmpty {
            note += " The project's WorktreeRemove hook removes the worktree; if it fails, the worktree is kept and its output shows in the sidebar."
        } else if worktree.madeByHook {
            note += " The project's WorktreeCreate hook made this worktree and there is no WorktreeRemove hook, so git removes it."
        }
        return note
    }

    private func close(removeWorktree: Bool = false, deleteBranch: Bool = false) {
        model.close(pane, removeWorktree: removeWorktree, deleteBranch: deleteBranch)
        dismiss()
    }
}
