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

    /// The default profile, unless its login is broken.
    @MainActor static func usableDefault(_ model: AppModel) -> String? {
        guard let name = model.defaultProfile,
              let profile = model.profiles.first(where: { $0.name == name }),
              profile.loginProblem == nil else { return nil }
        return name
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

    @State private var folder = ""
    @State private var profile: String?
    @State private var useWorktree = false
    @State private var repoRoot: String?
    @State private var creatingRepo = false
    @State private var repoError: String?
    @State private var name = ""
    @State private var permissionMode = "auto"
    @State private var firstMessage = ""
    @State private var didLoad = false
    @State private var maker = WorktreeMaker.git(include: false)
    /// The worktree's branch. It follows the name (`viber/<slug>`) until it is edited.
    @State private var branch = ""
    @State private var branchEdited = false
    @State private var branchProblem: String?

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
                return "The project's WorktreeCreate hook makes it, as in Claude Code. Its output shows in the sidebar while it runs."
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
                    LabeledContent("Folder") {
                        HStack(spacing: 6) {
                            Text(folder.isEmpty ? "No folder chosen" : (folder as NSString).abbreviatingWithTildeInPath)
                                .foregroundStyle(folder.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(folder)
                            Menu("Recent") {
                                ForEach(model.recentFolders.prefix(20), id: \.self) { path in
                                    Button((path as NSString).abbreviatingWithTildeInPath) { folder = path }
                                }
                            }
                            .disabled(model.recentFolders.isEmpty)
                            .fixedSize()
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                    AccountPicker(selection: $profile)
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
                            TextField("Branch", text: Binding(get: { branch }, set: { branch = $0; branchEdited = !$0.isEmpty }),
                                      prompt: Text(defaultBranch))
                                .font(.body.monospaced())
                            if let branchProblem {
                                Text(branchProblem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                            }
                        }
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
                    .disabled(folder.isEmpty || (useWorktree && repoRoot != nil && (maker.blocksWorktree || branchProblem != nil)))
            }
            .padding(16)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: load)
        .task(id: folder) { await checkRepo() }
        .onChange(of: defaultBranch) { if !branchEdited { branch = defaultBranch } }
        .task(id: "\(folder)|\(branch)|\(branchEdited)|\(useWorktree)|\(maker.usesHook)") { await checkBranch() }
    }

    /// `viber/<slug>` of the name the session will get, as the session's title is chosen.
    private var defaultBranch: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = !trimmed.isEmpty ? trimmed
            : firstMessage.isEmpty ? URL(fileURLWithPath: folder).lastPathComponent : String(firstMessage.prefix(50))
        return Worktree.defaultBranch(forName: title)
    }

    private var chosenBranch: String? {
        let typed = branch.trimmingCharacters(in: .whitespaces)
        return branchEdited && !typed.isEmpty ? typed : nil
    }

    /// `git check-ref-format --branch`, that it doesn't exist yet, and what a hook can take, after a short pause in typing.
    private func checkBranch() async {
        guard useWorktree, let root = repoRoot else { branchProblem = nil; return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let name = chosenBranch ?? defaultBranch, typed = chosenBranch != nil, hook = maker.usesHook
        let problem = await Task.detached { () -> String? in
            // An untouched default is numbered if taken, so only a typed name has to be new.
            if typed, case .problem(let problem) = Worktree.checkBranch(name, repo: root) { return problem }
            return hook ? Worktree.hookNameProblem(name) : nil
        }.value
        guard !Task.isCancelled else { return }
        branchProblem = problem
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        folder = model.selectedPane?.worktree?.repo ?? model.selectedPane?.spec.cwd ?? model.recentFolders.first ?? ""
        profile = AccountPicker.usableDefault(model)
        permissionMode = Prefs.string(Prefs.newSessionMode)
        branch = defaultBranch
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
        guard !dir.isEmpty else { repoRoot = nil; useWorktree = false; return }
        let (root, found) = await Task.detached { () -> (String?, WorktreeMaker) in
            guard let root = Worktree.repoRoot(dir) else { return (nil, .git(include: false)) }
            return (root, WorktreeMaker.find(folder: dir, root: root))
        }.value
        guard !Task.isCancelled, dir == folder else { return }
        repoRoot = root
        maker = found
        guard let root else { useWorktree = false; return }
        // Default to a worktree when another open session already works in this repo.
        useWorktree = model.panes.contains { pane in
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
            permissionMode: permissionMode,
            firstMessage: firstMessage
        ))
        dismiss()
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
            profile = model.defaultProfile
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
        var all: [Entry] = model.panes.map { pane in
            Entry(id: "pane:\(pane.id)", title: pane.title, subtitle: pane.projectName,
                  state: pane.state, icon: nil, action: .target(.pane(pane.id)))
        }
        all += model.externals.map { session in
            let title = model.recent.first { $0.id == session.id }?.title ?? session.projectName
            return Entry(id: "ext:\(session.id)", title: title, subtitle: "\(session.projectName) · running elsewhere",
                         state: PaneState(session.state), icon: nil, action: .target(.external(session.id)))
        }
        all += [
            Entry(id: "cmd:new", title: "New Session…", subtitle: "⌘N", state: nil, icon: "plus", action: .newSession),
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
                let branchNote = Worktree.branchDeletionNote(recorded: worktree.branch, live: pane.liveBranch)
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Branch") { Text(pane.branchName ?? "none").font(.callout.monospaced()).textSelection(.enabled) }
                    if branchNote != nil, !worktree.branch.isEmpty {
                        LabeledContent("Created on") { Text(worktree.branch).font(.callout.monospaced()).textSelection(.enabled) }
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
                if let branchNote {
                    Label(branchNote, systemImage: "arrow.triangle.branch")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(removalNote(worktree))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Remove worktree and branch") { close(removeWorktree: true, deleteBranch: true) }
                        .disabled(worktree.branch.isEmpty)
                        .help(worktree.branch.isEmpty ? "Viber recorded no branch for this worktree"
                              : "Also delete \(worktree.branch) with git branch -d, if it is merged")
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
        .frame(width: 520)
        .task {
            guard let worktree = pane.worktree else { return }
            let (changes, head, hooks, problem) = await Task.detached { () -> (Bool, String?, [HookCommand], String?) in
                let changes = Worktree.hasUncommittedChanges(worktree.path)
                let head = Worktree.headName(worktree.path)
                guard worktree.madeByHook else { return (changes, head, [], nil) }
                do { return (changes, head, try WorktreeHooks.hooks(.remove, folder: worktree.folder ?? worktree.repo), nil) }
                catch { return (changes, head, [], error.localizedDescription) }
            }.value
            hasChanges = changes
            if let head { pane.liveBranch = head }
            teardown = hooks
            teardownProblem = problem
        }
    }

    private func removalNote(_ worktree: WorktreeInfo) -> String {
        var note = "Removal is refused if there are uncommitted changes, and the branch is only deleted if it is merged."
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
