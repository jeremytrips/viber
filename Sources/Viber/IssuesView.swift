import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ViberCore

/// Every project's issues: work to do, in progress, in review and done.
struct IssuesView: View {
    @Environment(AppModel.self) private var model

    enum Filter: String, CaseIterable, Identifiable {
        case toDo = "To do", inProgress = "In progress", inReview = "In review", done = "Done", all = "All"
        var id: Self { self }

        func matches(_ issue: Issue) -> Bool {
            switch self {
            case .toDo: return issue.status == .open
            case .inProgress: return issue.status == .started
            case .inReview: return issue.status == .review
            case .done: return issue.status == .done
            case .all: return true
            }
        }

        var empty: String {
            switch self {
            case .toDo: return "Nothing left to do."
            case .inProgress: return "No issue has a session yet."
            case .inReview: return "Nothing is waiting to be merged."
            case .done: return "No issues done yet."
            case .all: return "No issues yet."
            }
        }
    }

    @State private var filter: Filter = .toDo
    @State private var search = ""

    /// Matching issues by project, in sidebar order, newest first within each.
    private var groups: [(project: String, issues: [Issue])] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = model.issues.issues.reversed().filter { issue in
            filter.matches(issue) && (query.isEmpty || issue.text.localizedCaseInsensitiveContains(query) || issue.key.localizedCaseInsensitiveContains(query))
        }
        return model.issueProjects.compactMap { project in
            let issues = matching.filter { $0.project == project }
            return issues.isEmpty ? nil : (project, issues)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                IssueComposer()
                if model.issues.issues.isEmpty {
                    emptyState
                } else {
                    controls
                    let groups = groups
                    if groups.isEmpty {
                        Text(search.trimmingCharacters(in: .whitespaces).isEmpty ? filter.empty : "No issues match.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(groups, id: \.project) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text(model.projectName(group.project))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .help(group.project)
                                Button { model.select(.project(group.project)) } label: { Image(systemName: "arrow.right.circle") }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                                    .help("Show the project")
                            }
                            .padding(.top, 4)
                            ForEach(group.issues) { issue in
                                IssueRow(issue: issue)
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
        .navigationTitle("Issues")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Issues").font(.title2.weight(.semibold))
            Text("Work in every project. Start one to open a session for it in plan mode; sessions move issues along as they ship.")
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
            TextField("Search issues", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checklist")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No issues yet").font(.title3.weight(.semibold))
            Text("Write down what you'd like to do in a project. Sessions can add issues too, with /issue, when they notice work outside their task.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

/// Adds an issue to one of the open sessions' projects, or to any folder.
struct IssueComposer: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var project: String?
    @FocusState private var focused: Bool

    /// The project of the session used last.
    private var defaultProject: String? {
        model.panes.max { $0.lastActivity < $1.lastActivity }?.projectPath ?? model.issueProjects.first
    }

    var body: some View {
        let target = project ?? defaultProject
        VStack(alignment: .leading, spacing: 8) {
            TextField("New issue… the first line is its title", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit(add)
            HStack(spacing: 8) {
                Menu {
                    ForEach(model.issueProjects, id: \.self) { path in
                        Button { project = path } label: {
                            if path == target { Label(model.projectName(path), systemImage: "checkmark") } else { Text(model.projectName(path)) }
                        }
                    }
                    if !model.issueProjects.isEmpty { Divider() }
                    Button("Other Folder…", action: chooseFolder)
                } label: {
                    Label(target.map(model.projectName) ?? "Choose a project", systemImage: "folder")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(target ?? "Choose the project this issue is for")
                Spacer()
                Button("Add Issue", action: add)
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
        model.addIssue(text, project: target, by: "you")
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

/// A project's issues that are not done, from the list button next to its name in the sidebar.
struct ProjectIssuesPopover: View {
    @Environment(AppModel.self) private var model
    let name: String
    let path: String
    let close: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let issues = model.issues.pending(in: path)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Issues for \(name)").font(.headline)
                Spacer()
                if model.autopilots[path] == nil, issues.contains(where: { $0.status == .open }) {
                    Button { model.offerAutopilot(project: path, fromPopover: true); close() } label: { Image(systemName: "airplane") }
                        .buttonStyle(.borderless)
                        .help("Autopilot: implement the issues to do one after another on their own")
                        .accessibilityLabel("Autopilot")
                }
                Button("Show Project") { model.select(.project(path)); close() }
                    .buttonStyle(.borderless)
                    .help("The project's page, with its board")
            }
            AutopilotCard(project: path, onLeave: close)
            HStack(alignment: .top, spacing: 6) {
                TextField("New issue…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if issues.isEmpty {
                Text("Nothing to do here. Write down what you'd like done; Start opens a session for it in plan mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ViewThatFits(in: .vertical) {
                    rows(issues)
                    ScrollView { rows(issues) }
                }
                .frame(maxHeight: 380)
            }
            Text("Sessions can add issues too, with /issue.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 400)
        .onAppear { focused = true }
    }

    private func rows(_ issues: [Issue]) -> some View {
        VStack(spacing: 6) {
            ForEach(issues) { issue in
                IssueRow(issue: issue, compact: true, onLeave: close)
            }
        }
    }

    private func add() {
        model.addIssue(draft, project: path, by: "you")
        draft = ""
        focused = true
    }
}

// MARK: - Status

extension Issue.Status {
    var color: Color {
        switch self {
        case .open: return .secondary
        case .started: return .blue
        case .review: return .purple
        case .done: return .green
        }
    }

    var symbol: String {
        switch self {
        case .open: return "circle"
        case .started: return "circle.lefthalf.filled"
        case .review: return "circle.righthalf.filled"
        case .done: return "checkmark.circle.fill"
        }
    }
}

struct StatusIcon: View {
    let status: Issue.Status
    var body: some View {
        Image(systemName: status.symbol)
            .foregroundStyle(status.color)
            .help(status.label)
            .accessibilityLabel(status.label)
    }
}

// MARK: - Rows

/// One issue, as a card in the Issues panel or a compact row in a project's popover.
struct IssueRow: View {
    @Environment(AppModel.self) private var model
    let issue: Issue
    var compact = false
    /// Called when a button here selects a session, so a popover can close.
    var onLeave: (() -> Void)?

    @State private var expanded = false
    @State private var editing = false

    private var lineLimit: Int { compact ? 3 : 6 }

    /// Whether the text likely runs past the line limit.
    private var isLong: Bool {
        issue.text.split(separator: "\n", omittingEmptySubsequences: false).count > lineLimit
            || issue.text.count > lineLimit * (compact ? 45 : 80)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { model.setIssueStatus(issue.id, issue.status == .done ? .open : .done) } label: {
                StatusIcon(status: issue.status)
            }
            .buttonStyle(.borderless)
            .help(issue.status == .done ? "Mark as to do" : "Mark as done")

            VStack(alignment: .leading, spacing: 4) {
                content
                IssueChips(issue: issue, onLeave: onLeave)
                if let report = issue.report { reportLine(report) }
                if expanded && !compact { IssueComments(issue: issue) }
                meta
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            IssueActions(issue: issue, onLeave: onLeave)
        }
        .padding(compact ? 8 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: compact ? 8 : 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: compact ? 8 : 10).strokeBorder(.separator))
        .contextMenu { IssueMenu(issue: issue, onLeave: onLeave) { editing = true } }
        .popover(isPresented: $editing, arrowEdge: .bottom) { IssueEditor(issue: issue, isPresented: $editing) }
    }

    @ViewBuilder
    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(issue.key).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(issue.text)
                .strikethrough(issue.status == .done)
                .foregroundStyle(issue.status == .done ? .secondary : .primary)
                .lineLimit(expanded ? nil : lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        if isLong || (!compact && !issue.comments.isEmpty) {
            ExpandButton(expanded: $expanded)
        }
    }

    private var meta: some View {
        HStack(spacing: 4) {
            Text(issue.createdBy == "you" ? "You" : issue.createdBy)
                .help(issue.createdBy == "you" ? "Added by you" : "Added by the session “\(issue.createdBy)”")
            Text("· \(Self.relative(issue.createdAt, now: model.now))")
            if issue.status != .open, let id = issue.sessionID {
                let pane = model.pane(id)
                let title = pane?.title ?? issue.sessionTitle ?? "a session"
                Text("·")
                Button(issue.status == .review ? "Shipped by \(title)" : issue.status == .done ? "Done in \(title)" : "Started in \(title)") {
                    model.select(.pane(id)); onLeave?()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(pane != nil ? Color.accentColor : Color.secondary)
                .disabled(pane == nil)
                .help(pane != nil ? "Open \(title)" : "\(title) is no longer open")
            } else if issue.status == .done {
                Text("· done \(Self.relative(issue.updatedAt, now: model.now))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// What the issue's session said at the end, or why the autopilot couldn't start one.
    private func reportLine(_ report: Issue.Report) -> some View {
        Label(report.text.isEmpty ? "Done." : report.text,
              systemImage: report.finished ? "checkmark.seal" : "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(report.finished ? Color.secondary : Color.orange)
            .lineLimit(expanded ? nil : 3)
            .fixedSize(horizontal: false, vertical: true)
            .help(report.finished ? "What its session said it shipped" : "Why it got stuck")
    }

    static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
    }
}

/// What an issue is part of, what blocks it, how many sub-issues it has, and where the autopilot has it.
struct IssueChips: View {
    @Environment(AppModel.self) private var model
    let issue: Issue
    var onLeave: (() -> Void)?

    var body: some View {
        let parent = issue.parentID.flatMap { model.issues.issue($0) }
        let blockers = model.issues.blockers(of: issue)
        let children = model.issues.children(of: issue.id)
        let place = autopilotPlace
        if parent != nil || !blockers.isEmpty || !children.isEmpty || place != nil {
            HStack(spacing: 5) {
                if let parent { Chip(text: "part of \(parent.key)").help(parent.title) }
                if !blockers.isEmpty {
                    Chip(text: "blocked by " + blockers.map(\.key).joined(separator: ", "))
                        .foregroundStyle(.orange)
                        .help(blockers.map { "\($0.key): \($0.title) (\($0.status.label.lowercased()))" }.joined(separator: "\n"))
                }
                if !children.isEmpty {
                    let done = children.filter { $0.status == .done }.count
                    Chip(text: "\(done)/\(children.count) sub-issues").help(children.map { "\($0.key): \($0.title)" }.joined(separator: "\n"))
                }
                if let place {
                    Label(place, systemImage: "airplane").labelStyle(.titleAndIcon)
                        .font(.caption2).foregroundStyle(Color.accentColor)
                }
            }
            .lineLimit(1)
        }
    }

    /// Where the project's autopilot has this issue: on it now, or in line.
    private var autopilotPlace: String? {
        guard let pilot = model.autopilots[issue.project] else { return nil }
        if pilot.active.contains(issue.id) { return "on autopilot" }
        guard let index = pilot.upcoming(in: model.issues).firstIndex(where: { $0.id == issue.id }) else { return nil }
        return index == 0 ? "next on autopilot" : "#\(index + 1) on autopilot"
    }
}

/// Start, or the session an issue is in.
struct IssueActions: View {
    @Environment(AppModel.self) private var model
    let issue: Issue
    var onLeave: (() -> Void)?

    var body: some View {
        if issue.status == .open {
            Button("Start") { model.startIssue(issue); onLeave?() }
                .controlSize(.small)
                .disabled(model.planningIssues.contains(issue.id))
                .help(model.issues.blockers(of: issue).isEmpty ? "Start a session in plan mode for this issue"
                      : "Blocked; Start asks first")
        } else if let id = issue.sessionID, let pane = model.pane(id) {
            Button { model.select(.pane(id)); onLeave?() } label: {
                HStack(spacing: 4) { StateDot(state: pane.state); Text(pane.title).lineLimit(1) }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .frame(maxWidth: 160)
            .help("Open \(pane.title)")
        }
    }
}

/// The right-click menu of an issue, wherever it shows.
struct IssueMenu: View {
    @Environment(AppModel.self) private var model
    let issue: Issue
    var onLeave: (() -> Void)?
    var edit: () -> Void

    var body: some View {
        if issue.status == .open {
            Button("Start in a New Session") { model.startIssue(issue); onLeave?() }
                .disabled(model.planningIssues.contains(issue.id))
            if model.autopilots[issue.project] == nil {
                Button("Implement on Autopilot…") {
                    model.offerAutopilot(project: issue.project, issueID: issue.id, fromPopover: onLeave != nil)
                    onLeave?()
                }
            } else if !(model.autopilots[issue.project]?.queue.contains(issue.id) ?? false) {
                Button("Add to Autopilot") { model.addToAutopilot(issue) }
            }
        }
        if let id = issue.sessionID, model.pane(id) != nil {
            Button("Open Session") { model.select(.pane(id)); onLeave?() }
        }
        Button("Edit…", action: edit)
        Button("Copy Key") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(issue.key, forType: .string)
        }
        Button("Break Down with Claude") { model.askClaude(.breakDown(key: issue.key), project: issue.project) }
        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(issue.text, forType: .string)
        }
        Divider()
        Menu("Move to") {
            ForEach(Issue.Status.allCases, id: \.self) { status in
                Button(status.label) { model.setIssueStatus(issue.id, status) }.disabled(status == issue.status)
            }
        }
        Divider()
        Button("Delete", role: .destructive) { model.removeIssue(issue.id) }
    }
}

/// An issue's comments, with a field to add one.
struct IssueComments: View {
    @Environment(AppModel.self) private var model
    let issue: Issue
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(issue.comments) { comment in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(comment.by == "you" ? "You" : comment.by).fontWeight(.medium)
                    Text("· \(IssueRow.relative(comment.at, now: model.now))").foregroundStyle(.secondary)
                    Text(comment.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                .font(.caption)
            }
            HStack(spacing: 6) {
                TextField("Add a note…", text: $draft).textFieldStyle(.roundedBorder).controlSize(.small).onSubmit(add)
                Button("Add", action: add).controlSize(.small).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.top, 2)
    }

    private func add() {
        model.commentIssue(issue.id, draft)
        draft = ""
    }
}

/// Edits an issue's text, what it is part of, and what blocks it.
struct IssueEditor: View {
    @Environment(AppModel.self) private var model
    let issue: Issue
    @Binding var isPresented: Bool
    @State private var text = ""
    @State private var parent = ""
    @State private var blockedBy = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit \(issue.key)").font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 100, maxHeight: 240)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            LabeledContent("Part of") {
                TextField("Key, such as \(model.issues.prefix(for: issue.project))-1", text: $parent).textFieldStyle(.roundedBorder)
            }
            LabeledContent("Blocked by") {
                TextField("Keys, separated by commas", text: $blockedBy).textFieldStyle(.roundedBorder)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || problem != nil)
            }
        }
        .padding(14)
        .frame(width: 440)
        .onAppear {
            text = issue.text
            parent = issue.parentID.flatMap { model.issues.issue($0)?.key } ?? ""
            blockedBy = issue.blockedBy.compactMap { model.issues.issue($0)?.key }.joined(separator: ", ")
        }
    }

    private var keys: [String] { blockedBy.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    /// A key that names no issue in the project, or the issue itself.
    private var problem: String? {
        let unknown = ([parent.trimmingCharacters(in: .whitespaces)] + keys).filter { !$0.isEmpty }
            .filter { model.issues.issue($0, in: issue.project) == nil }
        if let first = unknown.first { return "There is no issue \(first.uppercased()) in this project." }
        if parent.trimmingCharacters(in: .whitespaces).uppercased() == issue.key || keys.contains(where: { $0.uppercased() == issue.key }) {
            return "An issue can't be part of, or blocked by, itself."
        }
        return nil
    }

    private func save() {
        guard problem == nil else { return }
        model.editIssue(issue.id, text: text)
        let parentKey = parent.trimmingCharacters(in: .whitespaces)
        model.setIssueLinks(issue.id, parent: parentKey.isEmpty ? nil : parentKey, blockedBy: keys)
        isPresented = false
    }
}

// MARK: - The project page's list and board

/// A project's issues grouped by status, in progress first and done folded away.
struct IssueGroups: View {
    @Environment(AppModel.self) private var model
    let project: String
    @State private var showDone = false

    private static let order: [Issue.Status] = [.started, .review, .open, .done]

    var body: some View {
        let mine = model.issues.issues(in: project)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.order, id: \.self) { status in
                let issues = Array(mine.filter { $0.status == status }.reversed())
                if !issues.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            if status == .done {
                                Button { showDone.toggle() } label: {
                                    Image(systemName: showDone ? "chevron.down" : "chevron.right").font(.caption2.weight(.bold)).frame(width: 10)
                                }
                                .buttonStyle(.borderless).foregroundStyle(.tertiary)
                            }
                            StatusIcon(status: status).font(.caption)
                            Text(status.label).font(.subheadline.weight(.semibold))
                            Text("\(issues.count)").foregroundStyle(.secondary)
                        }
                        if status != .done || showDone {
                            VStack(spacing: 0) {
                                ForEach(Array(issues.enumerated()), id: \.element.id) { index, issue in
                                    if index > 0 { Divider() }
                                    IssueLine(issue: issue)
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                        }
                    }
                }
            }
        }
    }
}

/// One line of the project page's list; click to open it.
struct IssueLine: View {
    @Environment(AppModel.self) private var model
    let issue: Issue
    @State private var expanded = false
    @State private var editing = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusIcon(status: issue.status)
                Text(issue.key).font(.caption.monospaced()).foregroundStyle(.secondary).frame(minWidth: 44, alignment: .leading)
                Text(issue.title).lineLimit(1).strikethrough(issue.status == .done)
                IssueChips(issue: issue)
                Spacer(minLength: 8)
                if let report = issue.report, !report.finished {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption).help(report.text)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                IssueActions(issue: issue)
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !issue.body.isEmpty {
                        Text(issue.body).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if let report = issue.report {
                        Label(report.text.isEmpty ? "Done." : report.text, systemImage: report.finished ? "checkmark.seal" : "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(report.finished ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    IssueComments(issue: issue)
                    HStack {
                        Button("Edit…") { editing = true }.controlSize(.small)
                        Spacer()
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(hovering ? Color.primary.opacity(0.03) : .clear)
        .onHover { hovering = $0 }
        .contextMenu { IssueMenu(issue: issue) { editing = true } }
        .popover(isPresented: $editing, arrowEdge: .bottom) { IssueEditor(issue: issue, isPresented: $editing) }
    }

    private var subtitle: String {
        let who = issue.createdBy == "you" ? "you" : issue.createdBy
        switch issue.status {
        case .open: return "\(who) · \(IssueRow.relative(issue.createdAt, now: model.now))"
        case .done: return "done \(IssueRow.relative(issue.updatedAt, now: model.now))"
        default: return issue.sessionID.flatMap(model.pane) == nil ? "\(issue.status.label.lowercased()) \(IssueRow.relative(issue.updatedAt, now: model.now))" : ""
        }
    }
}

/// A project's issues in four columns; drag a card to change its status.
struct IssueBoard: View {
    @Environment(AppModel.self) private var model
    let project: String

    private static let columns: [Issue.Status] = [.open, .started, .review, .done]

    var body: some View {
        let mine = model.issues.issues(in: project)
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Self.columns, id: \.self) { status in
                    let issues = Array(mine.filter { $0.status == status }.reversed())
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            StatusIcon(status: status).font(.caption)
                            Text(status.label).font(.subheadline.weight(.semibold))
                            Text("\(issues.count)").foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                        ForEach(issues) { issue in
                            IssueCard(issue: issue).draggable(issue.id)
                        }
                        if issues.isEmpty {
                            Text("Drop an issue here").font(.caption).foregroundStyle(.tertiary).padding(6)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .frame(width: 210, alignment: .top)
                    .frame(minHeight: 180)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                    .dropDestination(for: String.self) { ids, _ in
                        guard let id = ids.first, let issue = model.issues.issue(id), issue.project == project, issue.status != status else { return false }
                        model.setIssueStatus(id, status)
                        return true
                    }
                }
            }
        }
        Text("Drag a card to change its status. Sessions move cards too: Start → in progress, /ship → in review, /cleanup after the merge → done.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct IssueCard: View {
    @Environment(AppModel.self) private var model
    let issue: Issue
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(issue.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if model.autopilots[issue.project].map({ $0.active.contains(issue.id) || $0.queue.contains(issue.id) }) == true {
                    Image(systemName: "airplane").font(.caption2).foregroundStyle(Color.accentColor)
                }
                if let report = issue.report, !report.finished {
                    Image(systemName: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange).help(report.text)
                }
            }
            Text(issue.title).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            IssueChips(issue: issue)
            if issue.status != .open, let id = issue.sessionID, let pane = model.pane(id) {
                Button { model.select(.pane(id)) } label: {
                    HStack(spacing: 4) { StateDot(state: pane.state); Text(pane.title).lineLimit(1) }.font(.caption)
                }
                .buttonStyle(.borderless)
            } else if issue.status == .open {
                Button("Start") { model.startIssue(issue) }.controlSize(.mini).disabled(model.planningIssues.contains(issue.id))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .contextMenu { IssueMenu(issue: issue) { editing = true } }
        .popover(isPresented: $editing, arrowEdge: .bottom) { IssueEditor(issue: issue, isPresented: $editing) }
    }
}
