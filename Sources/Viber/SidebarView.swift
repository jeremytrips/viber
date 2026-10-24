import AppKit
import SwiftUI
import ViberCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    private struct ProjectGroup {
        let project: Project
        let panes: [Pane]
        let jobs: [WorktreeJob]
    }

    private var groups: [ProjectGroup] {
        var panesByProject: [String: [Pane]] = [:]
        var jobsByProject: [String: [WorktreeJob]] = [:]
        for pane in model.panes { panesByProject[pane.projectPath, default: []].append(pane) }
        for job in model.jobs { jobsByProject[job.project, default: []].append(job) }
        return model.sidebarProjects.map { project in
            ProjectGroup(project: project, panes: panesByProject[project.path] ?? [], jobs: jobsByProject[project.path] ?? [])
        }
    }

    var body: some View {
        let selection = Binding<Target?>(get: { model.selection }, set: { model.select($0) })
        let groups = groups
        // ⌘1…⌘9 count down the sidebar, as AppModel.orderedPanes does.
        let shortcuts = Dictionary(uniqueKeysWithValues: groups.flatMap(\.panes).enumerated().map { ($1.id, $0) })
        List(selection: selection) {
            Section {
                IdeasRow().tag(Target.ideas)
            }
            Section {
                ForEach(groups, id: \.project.path) { group in
                    DisclosureGroup(isExpanded: Binding(get: { !group.project.isCollapsed },
                                                        set: { model.setCollapsed(group.project.path, !$0) })) {
                        ForEach(group.panes) { pane in
                            PaneRow(pane: pane, index: shortcuts[pane.id] ?? 9)
                                .tag(Target.pane(pane.id))
                                .contextMenu { PaneRowMenu(pane: pane) }
                        }
                        ForEach(group.jobs) { job in
                            WorktreeJobRow(job: job)
                                .tag(Target.job(job.id))
                                .contextMenu { WorktreeJobMenu(job: job) }
                        }
                    } label: {
                        ProjectRow(project: group.project, panes: group.panes)
                            .tag(Target.project(group.project.path))
                            .contextMenu { ProjectMenu(path: group.project.path) }
                    }
                }
                if groups.isEmpty {
                    Button { model.chooseProject() } label: {
                        Label("Add a Project…", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    Button { model.chooseProject() } label: { Image(systemName: "folder.badge.plus") }
                        .buttonStyle(.borderless)
                        .help("Add a project (⇧⌘N)")
                        .accessibilityLabel("Add Project")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                if !model.externals.isEmpty {
                    ExternalsPanel()
                    Divider()
                }
                SidebarFooter()
            }
            .background(.bar)
        }
        .toolbar {
            ToolbarItem {
                Button { model.newSession(in: model.selectedProject ?? "") } label: { Label("New Session", systemImage: "plus") }
                    .help("New session (⌘N)")
            }
        }
    }
}

/// Its own view: the count reads every session's state, and the list above shouldn't redraw each time one changes.
struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings for all sessions (⌘,)")
            let waiting = model.waitingCount
            Text(waiting == 0 ? "Nothing waiting for you" : "\(waiting) waiting for you · ⌘J")
                .foregroundStyle(waiting == 0 ? .secondary : .primary)
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// A session row's right-click menu. Its own view for the same reason as the footer: it reads the session's state.
struct PaneRowMenu: View {
    @Environment(AppModel.self) private var model
    let pane: Pane

    var body: some View {
        Button("Open in VS Code") { model.openInVSCode(pane.cwd) }
        Button("Stop Claude") { pane.interrupt() }.disabled(pane.state != .working)
        Button("Restart Claude") { model.restart(pane) }
            .help("Start a new Claude process on this conversation, e.g. after logging in again")
        Divider()
        Button("Close Session…") { model.requestClose(pane) }
    }
}

/// Entry point to the Ideas panel, with how many ideas are waiting to be planned.
struct IdeasRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.ideas.ideas.filter { $0.status == .open }.count
        HStack(spacing: 6) {
            Label("Ideas", systemImage: "lightbulb")
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count) to plan").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A project in the sidebar. Selecting it shows the project's page; its sessions are listed under it.
struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let panes: [Pane]
    @State private var showingIdeas = false
    @State private var hovering = false

    var body: some View {
        let ideas = model.ideas.toPlanCount(in: project.path)
        let waiting = panes.filter { $0.state.needsYou }.count
        HStack(spacing: 6) {
            Image(systemName: panes.isEmpty ? "folder" : "folder.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(project.name).fontWeight(.semibold).lineLimit(1)
            Spacer(minLength: 4)
            if project.isCollapsed && waiting > 0 {
                Text("\(waiting) waiting").font(.caption).foregroundStyle(.orange)
            } else if project.isCollapsed && !panes.isEmpty {
                Text("\(panes.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .help("\(panes.count) open session\(panes.count == 1 ? "" : "s")")
            }
            if ideas > 0 || hovering || showingIdeas {
                Button { showingIdeas = true } label: {
                    HStack(spacing: 2) {
                        Image(systemName: ideas == 0 ? "lightbulb" : "lightbulb.fill")
                        if ideas > 0 { Text("\(ideas)").monospacedDigit() }
                    }
                    .foregroundStyle(ideas == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                }
                .buttonStyle(.borderless)
                .help(ideas == 0 ? "Ideas for later in \(project.name)" : "\(ideas) idea\(ideas == 1 ? "" : "s") to plan in \(project.name)")
                .accessibilityLabel(ideas == 0 ? "Project ideas" : "Project ideas, \(ideas) to plan")
                .popover(isPresented: $showingIdeas, arrowEdge: .trailing) {
                    ProjectIdeasPopover(name: project.name, path: project.path) { showingIdeas = false }
                }
            }
            if hovering || panes.isEmpty {
                Button { model.newSession(in: project.path) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("New session in \(project.name)")
                    .accessibilityLabel("New Session in \(project.name)")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(project.path)
    }
}

/// A project's right-click menu, in the sidebar and on its page.
struct ProjectMenu: View {
    @Environment(AppModel.self) private var model
    let path: String
    /// Shown on the project's own page, which has its own New Session button.
    var onPage = false

    var body: some View {
        if !onPage {
            Button("New Session…") { model.newSession(in: path) }
            Button("Show Project") { model.select(.project(path)) }
            Divider()
        }
        Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        Button("Open in VS Code") { model.openInVSCode(path) }
        Divider()
        Button("Rename…") { model.renamingProject = path }
        Button("Remove from Sidebar") { model.removeProject(path) }
            .disabled(!model.canRemoveProject(path))
            .help(model.canRemoveProject(path) ? "Its folder, ideas and settings stay; add it again to bring them back"
                                               : "Close its sessions first")
    }
}

struct PaneRow: View {
    @Environment(AppModel.self) private var model
    let pane: Pane
    let index: Int

    var body: some View {
        HStack(spacing: 10) {
            CacheRing(cache: pane.chat.cache, now: model.now)
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.title).lineLimit(1).fontWeight(.medium)
                HStack(spacing: 5) {
                    Chip(text: pane.profileLabel)
                    if let worktree = pane.worktree {
                        if let branch = pane.branch {
                            // The last part, so "feat/NEX-705-…" shows its ticket in the narrow chip.
                            Chip(text: "⑂ " + (branch.split(separator: "/").last.map(String.init) ?? branch))
                                .help(worktree.branch.isEmpty || branch == worktree.branch ? branch : "\(branch), created as \(worktree.branch)")
                        }
                        if let diff = pane.diffStat { Text(diff).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                    } else {
                        Text(pane.state.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 4)
            if index < 9 { Text("⌘\(index + 1)").font(.caption2).foregroundStyle(.tertiary) }
            StateDot(state: pane.state)
        }
        .padding(.vertical, 3)
        .help(pane.state.label)
    }
}

/// Sessions running outside Viber, pinned above the sidebar footer. Collapses to its header.
struct ExternalsPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sidebarExternalsExpanded") private var expanded = true

    var body: some View {
        let count = model.externals.count
        let waiting = model.externals.filter { [.input, .plan, .permission].contains($0.state) }.count
        VStack(spacing: 0) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Running elsewhere")
                    Spacer(minLength: 4)
                    if !expanded && waiting > 0 {
                        Text("\(waiting) waiting").foregroundStyle(.orange)
                    }
                    Text("\(count)").monospacedDigit()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide sessions running outside Viber" : "Show sessions running outside Viber")
            .accessibilityLabel("Running elsewhere, \(count) sessions")
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            if expanded {
                ViewThatFits(in: .vertical) {
                    rows
                    ScrollView { rows }
                }
                .frame(maxHeight: 200)
            }
        }
        .onChange(of: model.selection) { _, selection in
            if case .external? = selection { expanded = true }
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(model.externals) { session in
                Button { model.select(.external(session.id)) } label: {
                    ExternalRow(session: session)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background {
                            if model.selection == .external(session.id) {
                                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.2))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6).padding(.bottom, 6)
    }
}

struct ExternalRow: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        HStack(spacing: 10) {
            CacheRing(cache: session.cache, now: model.now)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.recent.first { $0.id == session.id }?.title ?? session.projectName).lineLimit(1)
                Text("\(session.projectName) · \(session.state.rawValue)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            StateDot(state: PaneState(session.state))
        }
        .padding(.vertical, 3)
    }
}

extension PaneState {
    init(_ state: SessionState) {
        switch state {
        case .working: self = .working
        case .input: self = .input
        case .plan: self = .plan
        case .permission: self = .permission
        case .finished: self = .finished
        case .ended: self = .exited
        case .failed: self = .failed
        }
    }

    var color: Color {
        switch self {
        case .working, .starting: return .blue
        case .permission, .plan: return .orange
        case .input: return .purple
        case .finished: return .green
        case .failed: return .red
        case .idle, .exited: return .secondary
        }
    }
}

struct StateDot: View {
    let state: PaneState

    var body: some View {
        PulsingDot(color: NSColor(state.color), pulsing: state == .working)
            .frame(width: 8, height: 8)
            .accessibilityElement()
            .accessibilityLabel(state.label)
    }
}

/// A dot whose pulse runs in Core Animation, so it costs the app nothing per frame.
/// A repeating SwiftUI animation redrew the sidebar on every frame, and kept going after the session stopped working.
private struct PulsingDot: NSViewRepresentable {
    let color: NSColor
    let pulsing: Bool

    func makeNSView(context: Context) -> DotView {
        let view = DotView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: DotView, context: Context) {
        view.color = color
        view.pulsing = pulsing
    }

    final class DotView: NSView {
        var color = NSColor.secondaryLabelColor { didSet { if color != oldValue { needsDisplay = true } } }
        var pulsing = false { didSet { if pulsing != oldValue { updatePulse() } } }

        override var wantsUpdateLayer: Bool { true }

        /// Runs with the view's appearance current, so dynamic colors resolve for light or dark mode.
        override func updateLayer() {
            layer?.backgroundColor = color.cgColor
            layer?.cornerRadius = bounds.width / 2
        }

        /// Core Animation drops animations when a layer leaves the window, as sidebar rows do when scrolled away.
        override func viewDidMoveToWindow() { updatePulse() }

        private func updatePulse() {
            guard let layer else { return }
            layer.removeAnimation(forKey: "pulse")
            guard pulsing, window != nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: "pulse")
        }
    }
}

struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
            .foregroundStyle(.secondary)
    }
}

/// Time left on the prompt cache, as a ring that drains and turns orange near the end.
struct CacheRing: View {
    let cache: CacheEstimate?
    let now: Date
    var size: CGFloat = 26

    var body: some View {
        let remaining = cache?.remaining(at: now) ?? 0
        let fraction = cache.map { remaining / max($0.ttl, 1) } ?? 0
        let low = remaining > 0 && remaining < 120
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(low ? Color.orange : Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label(remaining))
                .font(.system(size: 7.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        .help(cache.map { remaining > 0 ? "Cache: \(AppModel.countdown(remaining)) left (\($0.basis))" : "Cache expired" } ?? "No cache yet")
    }

    private func label(_ remaining: TimeInterval) -> String {
        guard remaining > 0 else { return "–" }
        return remaining >= 600 ? "\(Int(remaining / 60))m" : AppModel.countdown(remaining)
    }
}
