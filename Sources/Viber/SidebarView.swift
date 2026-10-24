import SwiftUI
import ViberCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    private var groups: [(path: String, name: String, panes: [Pane], jobs: [WorktreeJob])] {
        var order: [String] = []
        var byProject: [String: [Pane]] = [:]
        var jobsByProject: [String: [WorktreeJob]] = [:]
        for pane in model.panes {
            if byProject[pane.projectPath] == nil { order.append(pane.projectPath) }
            byProject[pane.projectPath, default: []].append(pane)
        }
        for job in model.jobs {
            if byProject[job.project] == nil && jobsByProject[job.project] == nil { order.append(job.project) }
            jobsByProject[job.project, default: []].append(job)
        }
        return order.map { path in
            let panes = byProject[path] ?? []
            return (path, panes.first?.projectName ?? AppModel.projectName(path), panes, jobsByProject[path] ?? [])
        }
    }

    var body: some View {
        let selection = Binding<Target?>(get: { model.selection }, set: { model.select($0) })
        List(selection: selection) {
            Section {
                IdeasRow().tag(Target.ideas)
            }
            ForEach(groups, id: \.path) { group in
                Section {
                    ForEach(group.panes) { pane in
                        PaneRow(pane: pane, index: model.panes.firstIndex { $0.id == pane.id } ?? 0)
                            .tag(Target.pane(pane.id))
                            .contextMenu {
                                Button("Open in VS Code") { model.openInVSCode(pane.cwd) }
                                Button("Stop Claude") { pane.interrupt() }.disabled(pane.state != .working)
                                Button("Restart Claude") { model.restart(pane) }
                                    .help("Start a new Claude process on this conversation, e.g. after logging in again")
                                Divider()
                                Button("Close Session…") { model.requestClose(pane) }
                            }
                    }
                    ForEach(group.jobs) { job in
                        WorktreeJobRow(job: job)
                            .tag(Target.job(job.id))
                            .contextMenu {
                                if job.isRunning {
                                    Button(job.isRemoval ? "Stop Teardown" : "Stop Setup") { model.cancel(job) }
                                } else {
                                    Button("Try Again") { model.retry(job) }
                                    Button("Dismiss") { model.dismiss(job) }
                                }
                            }
                    }
                } header: {
                    ProjectHeader(name: group.name, path: group.path)
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
            .background(.bar)
        }
        .toolbar {
            ToolbarItem {
                Button { model.showNewSession = true } label: { Label("New Session", systemImage: "plus") }
                    .help("New session (⌘N)")
            }
        }
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

/// A project's section title, with its ideas for later.
struct ProjectHeader: View {
    @Environment(AppModel.self) private var model
    let name: String
    let path: String
    @State private var showingIdeas = false

    var body: some View {
        let count = model.ideas.toPlanCount(in: path)
        HStack(spacing: 4) {
            Text(name).help(path)
            Spacer(minLength: 4)
            Button { showingIdeas = true } label: {
                HStack(spacing: 2) {
                    Image(systemName: count == 0 ? "lightbulb" : "lightbulb.fill")
                    if count > 0 { Text("\(count)").monospacedDigit() }
                }
                .foregroundStyle(count == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
            }
            .buttonStyle(.borderless)
            .help(count == 0 ? "Ideas for later in \(name)" : "\(count) idea\(count == 1 ? "" : "s") to plan in \(name)")
            .accessibilityLabel(count == 0 ? "Project ideas" : "Project ideas, \(count) to plan")
            .popover(isPresented: $showingIdeas, arrowEdge: .trailing) {
                ProjectIdeasPopover(name: name, path: path) { showingIdeas = false }
            }
        }
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
                    if pane.worktree != nil {
                        if let branch = pane.branchName { Chip(text: "⑂ " + branch.replacingOccurrences(of: "viber/", with: "")).help(branch) }
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
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: 8, height: 8)
            .opacity(state == .working && pulse ? 0.35 : 1)
            .animation(state == .working ? .easeInOut(duration: 0.8).repeatForever() : .default, value: pulse)
            .onAppear { pulse = true }
            .accessibilityLabel(state.label)
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
