import AppKit
import SwiftUI
import ViberCore

extension JiraCategory {
    var color: Color {
        switch self {
        case .todo: return .secondary
        case .progress: return .blue
        case .done: return .green
        }
    }
}

/// Jira's status lozenge: the status name, coloured by its category.
struct JiraStatusChip: View {
    let issue: JiraIssue
    var body: some View {
        Text(issue.status.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(issue.category.color.opacity(0.18)))
            .foregroundStyle(issue.category == .todo ? Color.primary.opacity(0.7) : issue.category.color)
            .lineLimit(1)
    }
}

/// A Jira project's issues on the Planning tab: the tracker's views, one at a time, by status or by epic.
struct JiraIssuesSection: View {
    @Environment(AppModel.self) private var model
    let project: String
    let board: JiraBoard
    @State private var query = ""
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TextField("New issue… for example: invite emails bounce for Gmail users", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(startDraft)
                Button { startDraft() } label: { Label("Draft…", systemImage: "sparkles") }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("A session writes it up (following the project's Jira rules, after searching for duplicates) and shows you the ticket to edit before it is created")
            }
            Text("Claude writes it up for Jira, checks for duplicates, and shows the ticket to you before anything is created.")
                .font(.caption).foregroundStyle(.secondary)
            viewBar
            if let error = board.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if board.issues.isEmpty && !board.loading && board.error == nil {
                Text(query.isEmpty ? "Nothing in this view." : "Nothing matches.").foregroundStyle(.secondary)
            } else if board.byEpic {
                epicTree
            } else {
                groups
            }
            footer
        }
    }

    private func startDraft() {
        model.draftJiraIssue(draft, project: project)
        draft = ""
    }

    private var viewBar: some View {
        HStack(spacing: 8) {
            Picker("View", selection: Binding(get: { board.viewID }, set: { board.show($0); query = "" })) {
                ForEach(board.tracker.views) { view in Text(view.name).tag(view.id) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            TextField(board.view?.byEpic == true ? "Search the view, then press Return" : "Search, then press Return", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { board.search = query; board.load() }
            if !board.search.isEmpty {
                Button { query = ""; board.search = ""; board.load() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Clear the search")
            }
            if model.jiraRuns[project] == nil, !board.byEpic, board.issues.contains(where: { JiraRun.ineligible($0, mine: board.isMine($0)) == nil }) {
                Button { model.offerJiraRun(project: project, keys: board.issues.map(\.key)) } label: { Image(systemName: "airplane") }
                    .buttonStyle(.borderless)
                    .help("Autopilot: implement the issues in this view that are to do and yours or unassigned, several at a time")
            }
            Button { board.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(board.loading)
                .help(board.loadedAt.map { "Loaded \(IssueRow.relative($0, now: model.now)); refreshes every \(board.tracker.refreshSeconds) s" } ?? "Load")
            if board.loading { ProgressView().controlSize(.small) }
        }
    }

    private var groups: some View {
        let order: [JiraCategory] = [.progress, .todo, .done]
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(order, id: \.self) { category in
                let issues = board.issues.filter { $0.category == category }
                if !issues.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Circle().fill(category.color).frame(width: 8, height: 8)
                            Text(category == .todo ? "To do" : category == .progress ? "In progress" : "Done").font(.subheadline.weight(.semibold))
                            Text("\(issues.count)").foregroundStyle(.secondary)
                        }
                        card(issues)
                    }
                }
            }
        }
    }

    private func card(_ issues: [JiraIssue], indent: Bool = false) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(issues.enumerated()), id: \.element.key) { index, issue in
                if index > 0 { Divider().padding(.leading, indent ? 36 : 0) }
                JiraIssueRow(issue: issue, project: project, board: board, indent: indent)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    /// Epics with their issues folded in, then the issues outside any epic.
    private var epicTree: some View {
        let epics = board.issues.filter(\.isEpic)
        let loose = board.issues.filter { !$0.isEpic }
        return VStack(alignment: .leading, spacing: 10) {
            if !epics.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill").foregroundStyle(.purple).font(.caption)
                        Text("Epics").font(.subheadline.weight(.semibold))
                        Text("\(epics.count)").foregroundStyle(.secondary)
                        Spacer()
                        Text("parent is EMPTY").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(epics.enumerated()), id: \.element.key) { index, epic in
                            if index > 0 { Divider() }
                            epicRow(epic)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                }
            }
            if !loose.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("Not in an epic").font(.subheadline.weight(.semibold))
                        Text("\(loose.count)").foregroundStyle(.secondary)
                    }
                    card(loose)
                }
            }
        }
    }

    @ViewBuilder
    private func epicRow(_ epic: JiraIssue) -> some View {
        let open = board.openEpics.contains(epic.key)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary).frame(width: 10)
                Image(systemName: "bolt.fill").foregroundStyle(.purple).font(.caption)
                Text(epic.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(epic.summary).lineLimit(1)
                Spacer(minLength: 8)
                if let kids = board.epicChildren[epic.key] { Text("\(kids.count) open").font(.caption).foregroundStyle(.secondary) }
                JiraStatusChip(issue: epic)
                if model.jiraRuns[project] == nil {
                    Button { model.offerJiraRun(project: project, epic: epic) } label: { Label("Autopilot…", systemImage: "airplane") }
                        .buttonStyle(.link).font(.caption)
                        .help("Implement the epic's issues that are to do and yours or unassigned, several at a time")
                } else if let kids = board.epicChildren[epic.key] {
                    Button("Add to Autopilot") { model.addToJiraRun(kids.map(\.key), project: project) }
                        .buttonStyle(.link).font(.caption)
                }
                Link(destination: board.site?.browseURL(epic.key) ?? URL(fileURLWithPath: "/")) { Image(systemName: "arrow.up.right.square") }
                    .foregroundStyle(.secondary).help("Open in Jira")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { board.toggleEpic(epic.key) }
            if open {
                Divider().padding(.leading, 36)
                if let kids = board.epicChildren[epic.key] {
                    if kids.isEmpty {
                        Text("Nothing open in it.").font(.caption).foregroundStyle(.secondary).padding(.leading, 36).padding(.vertical, 6)
                    }
                    ForEach(Array(kids.enumerated()), id: \.element.key) { index, issue in
                        if index > 0 { Divider().padding(.leading, 36) }
                        JiraIssueRow(issue: issue, project: project, board: board, indent: true)
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading its issues · parent = \(epic.key)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 36).padding(.vertical, 6)
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if let total = board.total {
                Text(board.byEpic ? "\(board.issues.count) loaded of about \(total) at the top level"
                     : "\(board.issues.count) loaded of about \(total)").font(.caption).foregroundStyle(.secondary)
            }
            if board.nextPageToken != nil {
                Button("Load \(JiraClient.pageSize) More") { board.loadMore() }.buttonStyle(.link).font(.caption).disabled(board.loading)
            }
            Spacer()
            if let site = board.site, let view = board.view, let url = site.searchURL(jql: board.jql()) {
                Link("Open \(view.name) in Jira", destination: url).font(.caption)
            }
        }
    }
}

/// One Jira issue: type, key, summary, labels, priority, status, assignee, and Start or its session.
struct JiraIssueRow: View {
    @Environment(AppModel.self) private var model
    let issue: JiraIssue
    let project: String
    let board: JiraBoard
    var indent = false
    @State private var expanded = false

    var body: some View {
        let pane = model.panes.first { $0.projectPath == project && model.jiraKey(for: $0) == issue.key }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                typeIcon
                Text(issue.key).font(.caption.monospaced()).foregroundStyle(.secondary).frame(minWidth: 56, alignment: .leading)
                Text(issue.summary).lineLimit(1)
                ForEach(issue.labels, id: \.self) { Chip(text: $0) }
                Spacer(minLength: 8)
                if let priority = issue.priority, priority != "Medium" {
                    Text(priority).font(.caption2).foregroundStyle(priority.hasPrefix("High") ? .red : .secondary)
                }
                JiraStatusChip(issue: issue)
                if let assignee = issue.assignee, !board.isMine(issue) {
                    Text(assignee.split(separator: " ").compactMap { $0.first.map(String.init) }.joined().prefix(2))
                        .font(.caption2.weight(.bold)).frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(0.1))).help("Assigned to \(assignee)")
                }
                if let pane {
                    Button { model.select(.pane(pane.id)) } label: {
                        HStack(spacing: 4) { StateDot(state: pane.state); Text(pane.title).lineLimit(1) }
                    }
                    .buttonStyle(.borderless).controlSize(.small).frame(maxWidth: 160).help("Open \(pane.title)")
                } else if issue.category != .done, !issue.isEpic {
                    Button("Start") { model.startJiraIssue(issue, project: project) }
                        .controlSize(.small)
                        .help("A new session in a worktree, started with “\(board.tracker.startMessage.replacingOccurrences(of: "<key>", with: issue.key))”")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.description.isEmpty ? "No description." : issue.description)
                        .font(.callout).foregroundStyle(issue.description.isEmpty ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).lineLimit(20)
                    HStack(spacing: 10) {
                        Text("\(issue.type) · \(issue.assignee ?? "unassigned")" + (issue.updated.map { " · updated \(IssueRow.relative($0, now: model.now))" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                        if let url = board.site?.browseURL(issue.key) { Link("Open in Jira", destination: url).font(.caption) }
                    }
                }
                .padding(.leading, 30)
            }
        }
        .padding(.leading, indent ? 36 : 12).padding(.trailing, 12).padding(.vertical, 7)
        .contextMenu {
            if let url = board.site?.browseURL(issue.key) { Link("Open in Jira", destination: url) }
            Button("Copy Key") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(issue.key, forType: .string) }
            if !issue.isEpic { Button("Break Down with Claude") { model.askClaude(.breakDown(key: issue.key), project: project) } }
            if !issue.isEpic, JiraRun.ineligible(issue, mine: board.isMine(issue)) == nil {
                if let run = model.jiraRuns[project] {
                    if !run.queue.contains(issue.key), !run.active.contains(issue.key) {
                        Button("Add to Autopilot") { model.addToJiraRun([issue.key], project: project) }
                    }
                } else {
                    Button("Implement on Autopilot…") { model.offerJiraRun(project: project, keys: [issue.key]) }
                }
            }
            if issue.category != .done, !issue.isEpic, pane == nil { Button("Start in a New Session") { model.startJiraIssue(issue, project: project) } }
        }
    }

    private var typeIcon: some View {
        let (name, color): (String, Color) = {
            switch issue.type.lowercased() {
            case "bug": return ("circle.fill", .red)
            case "story": return ("bookmark.fill", .green)
            case "epic": return ("bolt.fill", .purple)
            case "subtask", "sub-task": return ("square.on.square", .cyan)
            default: return ("checkmark.square.fill", .cyan)
            }
        }()
        return Image(systemName: name).foregroundStyle(color).font(.caption).frame(width: 14).help(issue.type)
    }
}

/// The Tracker rows of a project's Settings tab: Viber's own list, or a Jira site with its views.
struct TrackerSettingsRows: View {
    @Environment(AppModel.self) private var model
    let project: String
    @State private var draft: ProjectTracker?
    @State private var keysDraft = ""

    var body: some View {
        let tracker = model.trackers.tracker(for: project)
        SettingRowView(label: "Tracker", note: tracker == nil ? "Issues live in Viber, not in the repository. Sessions move them along as they ship."
                       : "Issues come from Jira. Viber reads them; every change goes through Claude and the repository's skills.") {
            Picker("Tracker", selection: Binding(get: { tracker == nil ? "viber" : "jira" }, set: { choose($0) })) {
                Text("Viber").tag("viber")
                Text("Jira").tag("jira").disabled(model.jiraSites.isEmpty)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help(model.jiraSites.isEmpty ? "Add a Jira site in Settings → Jira first" : "")
        }
        if let tracker {
            Divider()
            SettingRowView(label: "Site", note: "Added in Settings → Jira (⌘,).") {
                Picker("Site", selection: Binding(get: { tracker.site }, set: { host in save { $0.site = host } })) {
                    ForEach(model.jiraSites) { Text($0.host).tag($0.host) }
                }
                .labelsHidden().fixedSize()
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Views")
                        Text("JQL queries Planning can show, one at a time. By epic loads the epics and the issues outside them first, and an epic's issues when you open it.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Add View") { save { $0.views.append(JiraView(name: "New view", jql: "assignee = currentUser() ORDER BY updated DESC")) } }
                        .controlSize(.small)
                }
                ForEach(tracker.views) { view in
                    HStack(alignment: .top, spacing: 8) {
                        TextField("Name", text: Binding(get: { view.name }, set: { name in save { $0.views[idx($0, view)].name = name } }))
                            .textFieldStyle(.roundedBorder).frame(width: 130)
                        TextField("JQL", text: Binding(get: { view.jql }, set: { jql in save { $0.views[idx($0, view)].jql = jql } }), axis: .vertical)
                            .textFieldStyle(.roundedBorder).font(.callout.monospaced()).lineLimit(1...3)
                        Toggle("By epic", isOn: Binding(get: { view.byEpic }, set: { on in save { $0.views[idx($0, view)].byEpic = on } }))
                            .toggleStyle(.checkbox).fixedSize()
                        Button { save { $0.views.removeAll { $0.id == view.id } } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).disabled(tracker.views.count == 1).help("Remove the view")
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            SettingRowView(label: "On Start", note: "The first message of a session started from an issue; <key> becomes the issue's key. The issue's summary and description follow it.") {
                TextField("First message", text: Binding(get: { tracker.startMessage }, set: { text in save { $0.startMessage = text } }))
                    .textFieldStyle(.roundedBorder).font(.callout.monospaced()).frame(width: 220)
            }
            Divider()
            SettingRowView(label: "Account", note: "The login those sessions use; it needs the Atlassian connector for the skills that change Jira.") {
                AccountPicker(selection: Binding(get: { tracker.profile }, set: { name in save { $0.profile = name } }), label: "Account").labelsHidden().fixedSize()
            }
            Divider()
            SettingRowView(label: "Jira in sessions", note: "The MCP servers that reach Jira, by name, separated by commas. An autopilot run makes their calls ask, allows the skill's own changes and holds the rest for you.") {
                TextField("Servers", text: Binding(get: { tracker.mcpServers.joined(separator: ", ") },
                                                   set: { text in save { $0.mcpServers = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } }))
                    .textFieldStyle(.roundedBorder).font(.callout.monospaced()).frame(width: 220)
            }
            Divider()
            SettingRowView(label: "Refresh", note: "How often the shown view is read again.") {
                Picker("Refresh", selection: Binding(get: { tracker.refreshSeconds }, set: { seconds in save { $0.refreshSeconds = seconds } })) {
                    Text("Every 30 s").tag(30); Text("Every minute").tag(60); Text("Every 5 minutes").tag(300)
                }
                .labelsHidden().fixedSize()
            }
        }
    }

    private func idx(_ tracker: ProjectTracker, _ view: JiraView) -> Int { tracker.views.firstIndex { $0.id == view.id } ?? 0 }

    private func save(_ change: (inout ProjectTracker) -> Void) {
        guard var tracker = model.trackers.tracker(for: project) else { return }
        change(&tracker)
        model.setTracker(tracker, for: project)
    }

    private func choose(_ which: String) {
        if which == "viber" {
            model.setTracker(nil, for: project)
        } else if let site = model.jiraSites.first {
            model.setTracker(ProjectTracker(site: site.host, views: ProjectTracker.defaultViews(projectKeys: []),
                                            profile: AccountPicker.usableDefault(model)), for: project)
        }
    }
}

/// A labelled settings row, as the project page draws them.
struct SettingRowView<Controls: View>: View {
    let label: String
    let note: String
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { controls }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}
