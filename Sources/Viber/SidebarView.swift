import SwiftUI
import ViberCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    private var groups: [(name: String, panes: [Pane])] {
        var order: [String] = []
        var byProject: [String: [Pane]] = [:]
        for pane in model.panes {
            if byProject[pane.projectName] == nil { order.append(pane.projectName) }
            byProject[pane.projectName, default: []].append(pane)
        }
        return order.map { ($0, byProject[$0] ?? []) }
    }

    var body: some View {
        let selection = Binding<Target?>(get: { model.selection }, set: { model.select($0) })
        List(selection: selection) {
            Section {
                MessagesRow().tag(Target.messages)
            }
            ForEach(groups, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.panes) { pane in
                        PaneRow(pane: pane, index: model.panes.firstIndex { $0.id == pane.id } ?? 0)
                            .tag(Target.pane(pane.id))
                            .contextMenu {
                                Button("Open in VS Code") { model.openInVSCode(pane.cwd) }
                                Button("Stop Claude") { pane.interrupt() }.disabled(pane.state != .working)
                                Divider()
                                Button("Close Session…") { model.requestClose(pane) }
                            }
                    }
                }
            }
            if !model.externals.isEmpty {
                Section("Running elsewhere") {
                    ForEach(model.externals) { session in
                        ExternalRow(session: session).tag(Target.external(session.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
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

/// Entry point to the Messages panel, with unread and in-flight counts.
struct MessagesRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let unread = model.selection == .messages ? 0 : model.relayLog.unreadCount
        let waiting = model.relayLog.records.filter { $0.status == .queued || $0.status == .delivered }.count
        HStack(spacing: 6) {
            Label("Messages", systemImage: "bubble.left.and.bubble.right")
            Spacer(minLength: 4)
            if waiting > 0 {
                Text("\(waiting) waiting").font(.caption).foregroundStyle(.secondary)
            }
            if unread > 0 {
                Text("\(unread)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor))
                    .accessibilityLabel("\(unread) unread")
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
                    if let worktree = pane.worktree {
                        Chip(text: "⑂ " + worktree.branch.replacingOccurrences(of: "viber/", with: ""))
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
