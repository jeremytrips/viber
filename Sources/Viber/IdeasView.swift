import AppKit
import SwiftUI
import ViberCore

/// Every project's ideas: things to do later that nobody has planned yet.
struct IdeasView: View {
    @Environment(AppModel.self) private var model

    enum Filter: String, CaseIterable, Identifiable {
        case toPlan = "To plan", started = "Started", done = "Done", all = "All"
        var id: Self { self }

        func matches(_ idea: Idea) -> Bool {
            switch self {
            case .toPlan: return idea.status == .open
            case .started: return idea.status == .started
            case .done: return idea.status == .done
            case .all: return true
            }
        }

        var empty: String {
            switch self {
            case .toPlan: return "Nothing left to plan."
            case .started: return "No idea has a session yet."
            case .done: return "No ideas done yet."
            case .all: return "No ideas yet."
            }
        }
    }

    @State private var filter: Filter = .toPlan
    @State private var search = ""

    /// Matching ideas by project, in sidebar order, newest first within each.
    private var groups: [(project: String, ideas: [Idea])] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = model.ideas.ideas.reversed().filter { idea in
            filter.matches(idea) && (query.isEmpty || idea.text.localizedCaseInsensitiveContains(query))
        }
        return model.ideaProjects.compactMap { project in
            let ideas = matching.filter { $0.project == project }
            return ideas.isEmpty ? nil : (project, ideas)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                IdeaComposer()
                if model.ideas.ideas.isEmpty {
                    emptyState
                } else {
                    controls
                    let groups = groups
                    if groups.isEmpty {
                        Text(search.trimmingCharacters(in: .whitespaces).isEmpty ? filter.empty : "No ideas match.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(groups, id: \.project) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(AppModel.projectName(group.project))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .help(group.project)
                                .padding(.top, 4)
                            ForEach(group.ideas) { idea in
                                IdeaRow(idea: idea)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("Ideas")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ideas").font(.title2.weight(.semibold))
            Text("Things to do later that nobody has planned yet. Plan one to start a session for it in plan mode.")
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
            TextField("Search ideas", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "lightbulb")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No ideas yet").font(.title3.weight(.semibold))
            Text("Write down what you'd like to do in a project later. Sessions can add ideas too, with /idea, when they notice something outside their task.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

/// Adds an idea to one of the open sessions' projects, or to any folder.
struct IdeaComposer: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var project: String?
    @FocusState private var focused: Bool

    /// The project of the session used last.
    private var defaultProject: String? {
        model.panes.max { $0.lastActivity < $1.lastActivity }?.projectPath ?? model.ideaProjects.first
    }

    var body: some View {
        let target = project ?? defaultProject
        VStack(alignment: .leading, spacing: 8) {
            TextField("Something to do later…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit(add)
            HStack(spacing: 8) {
                Menu {
                    ForEach(model.ideaProjects, id: \.self) { path in
                        Button { project = path } label: {
                            if path == target { Label(AppModel.projectName(path), systemImage: "checkmark") } else { Text(AppModel.projectName(path)) }
                        }
                    }
                    if !model.ideaProjects.isEmpty { Divider() }
                    Button("Other Folder…", action: chooseFolder)
                } label: {
                    Label(target.map(AppModel.projectName) ?? "Choose a project", systemImage: "folder")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(target ?? "Choose the project this idea is for")
                Spacer()
                Button("Add Idea", action: add)
                    .disabled(target == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor)))
        .onAppear { if project == nil { project = defaultProject } }
    }

    private func add() {
        guard let target = project ?? defaultProject else { return }
        model.addIdea(text, project: target, by: "you")
        text = ""
        focused = true
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { project = url.path }
    }
}

/// A project's ideas, from the lightbulb next to its name in the sidebar.
struct ProjectIdeasPopover: View {
    @Environment(AppModel.self) private var model
    let name: String
    let path: String
    let close: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let ideas = model.ideas.pending(in: path)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ideas for \(name)").font(.headline)
                Spacer()
                Button("Show All") { model.select(.ideas); close() }
                    .buttonStyle(.borderless)
                    .help("Every project's ideas (⇧⌘I)")
            }
            HStack(alignment: .top, spacing: 6) {
                TextField("Something to do later…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if ideas.isEmpty {
                Text("Nothing yet. Note what you'd like to do here later; Plan starts a session for it in plan mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ViewThatFits(in: .vertical) {
                    rows(ideas)
                    ScrollView { rows(ideas) }
                }
                .frame(maxHeight: 380)
            }
            Text("Sessions can add ideas too, with /idea.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func rows(_ ideas: [Idea]) -> some View {
        VStack(spacing: 6) {
            ForEach(ideas) { idea in
                IdeaRow(idea: idea, compact: true, onLeave: close)
            }
        }
    }

    private func add() {
        model.addIdea(draft, project: path, by: "you")
        draft = ""
        focused = true
    }
}

/// One idea, as a card in the Ideas panel or a compact row in a project's popover.
struct IdeaRow: View {
    @Environment(AppModel.self) private var model
    let idea: Idea
    var compact = false
    /// Called when a button here selects a session, so a popover can close.
    var onLeave: (() -> Void)?

    @State private var expanded = false
    @State private var editing = false
    @State private var draft = ""

    private var lineLimit: Int { compact ? 3 : 6 }

    /// Whether the text likely runs past the line limit.
    private var isLong: Bool {
        idea.text.split(separator: "\n", omittingEmptySubsequences: false).count > lineLimit
            || idea.text.count > lineLimit * (compact ? 45 : 80)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { model.setIdeaStatus(idea.id, idea.status == .done ? .open : .done) } label: {
                Image(systemName: idea.status == .done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(idea.status == .done ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(idea.status == .done ? "Mark as not done" : "Mark as done")
            .accessibilityLabel(idea.status == .done ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 4) {
                if editing { editor } else { content }
                meta
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if idea.status == .open && !editing {
                Button("Plan", action: plan)
                    .controlSize(.small)
                    .disabled(model.planningIdeas.contains(idea.id))
                    .help("Start a session in plan mode for this idea")
            }
        }
        .padding(compact ? 8 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: compact ? 8 : 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: compact ? 8 : 10).strokeBorder(.separator))
        .contextMenu { menu }
    }

    @ViewBuilder
    private var content: some View {
        Text(idea.text)
            .strikethrough(idea.status == .done)
            .foregroundStyle(idea.status == .done ? .secondary : .primary)
            .lineLimit(expanded ? nil : lineLimit)
            .fixedSize(horizontal: false, vertical: true)
        if isLong {
            ExpandButton(expanded: $expanded)
        }
    }

    @ViewBuilder
    private var editor: some View {
        TextField("Idea", text: $draft, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...12)
            .onSubmit(save)
        HStack {
            Spacer()
            Button("Cancel") { editing = false }
            Button("Save", action: save)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .controlSize(.small)
    }

    private var meta: some View {
        HStack(spacing: 4) {
            Text(idea.createdBy == "you" ? "You" : idea.createdBy)
                .help(idea.createdBy == "you" ? "Added by you" : "Added by the session “\(idea.createdBy)”")
            Text("· \(RelayRow.relative(idea.createdAt, now: model.now))")
            if idea.status == .started, let id = idea.sessionID {
                let pane = model.pane(id)
                let title = pane?.title ?? idea.sessionTitle ?? "a session"
                Text("·")
                Button("Started in \(title)") { model.select(.pane(id)); onLeave?() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(pane != nil ? Color.accentColor : Color.secondary)
                    .disabled(pane == nil)
                    .help(pane != nil ? "Open \(title)" : "\(title) is no longer open")
            } else if idea.status == .done {
                Text("· done \(RelayRow.relative(idea.updatedAt, now: model.now))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private var menu: some View {
        if idea.status == .open {
            Button("Plan in a New Session", action: plan)
                .disabled(model.planningIdeas.contains(idea.id))
        }
        if idea.status == .started, let id = idea.sessionID, model.pane(id) != nil {
            Button("Open Session") { model.select(.pane(id)); onLeave?() }
        }
        Button("Edit") { draft = idea.text; editing = true }
        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(idea.text, forType: .string)
        }
        Divider()
        switch idea.status {
        case .open:
            Button("Mark as Done") { model.setIdeaStatus(idea.id, .done) }
        case .started:
            Button("Mark as Done") { model.setIdeaStatus(idea.id, .done) }
            Button("Move Back to To Plan") { model.setIdeaStatus(idea.id, .open) }
        case .done:
            Button("Mark as Not Done") { model.setIdeaStatus(idea.id, .open) }
        }
        Divider()
        Button("Delete", role: .destructive) { model.removeIdea(idea.id) }
    }

    private func plan() {
        model.plan(idea)
        onLeave?()
    }

    private func save() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.editIdea(idea.id, text: draft)
        editing = false
    }
}
