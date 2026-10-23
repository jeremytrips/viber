import SwiftUI
import ViberCore

struct PaneView: View {
    @Environment(AppModel.self) private var model
    let pane: Pane

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: pane)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    ChatList(pane: pane, readOnly: false)
                    ChecklistPanel(pane: pane)
                    ComposerView(pane: pane)
                }
                .frame(minWidth: 320, maxWidth: .infinity)
                if pane.showPreview, let preview = pane.preview {
                    PreviewView(pane: pane, preview: preview)
                        .frame(minWidth: 300, idealWidth: 640, maxWidth: .infinity)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { if pane.showPreview { _ = pane.ensurePreview() } }
        .onChange(of: pane.showPreview) { if pane.showPreview { _ = pane.ensurePreview() } }
        .alert(rewindTitle, isPresented: Binding(get: { pane.chat.rewindPreview != nil }, set: { if !$0 { pane.chat.rewindPreview = nil } }),
               presenting: pane.chat.rewindPreview) { preview in
            if preview.canRewind && !preview.files.isEmpty {
                Button("Rewind files", role: .destructive) { pane.run { $0.rewind(itemID: preview.itemID, dryRun: false).map { [$0] } ?? [] } }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { preview in
            Text(rewindMessage(preview))
        }
    }

    private var rewindTitle: String {
        guard let preview = pane.chat.rewindPreview else { return "" }
        if !preview.canRewind { return "Can't rewind files" }
        return preview.files.isEmpty ? "Nothing to rewind" : "Rewind \(preview.files.count == 1 ? "1 file" : "\(preview.files.count) files")?"
    }

    private func rewindMessage(_ preview: RewindPreview) -> String {
        if !preview.canRewind { return preview.error ?? "There is no checkpoint for that message." }
        if preview.files.isEmpty { return "No files changed after that message." }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shown = preview.files.prefix(8).map { $0.replacingOccurrences(of: pane.cwd + "/", with: "").replacingOccurrences(of: home, with: "~") }
        let more = preview.files.count > 8 ? "\n…and \(preview.files.count - 8) more" : ""
        return "Files go back to how they were before that message (+\(preview.insertions) −\(preview.deletions) undone). "
            + "The conversation stays as it is, so tell Claude if it should know.\n\n" + shown.joined(separator: "\n") + more
    }
}

struct PaneHeader: View {
    @Environment(AppModel.self) private var model
    let pane: Pane

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Stat(label: "Account", value: pane.profileLabel)
            Stat(label: "Cache", value: cacheText, warn: cacheLow)
            if let usage = pane.chat.lastUsage {
                Stat(label: "Context", value: "\(AppModel.compact(usage.contextTokens)) · \(AppModel.compact(usage.cacheRead)) cached")
            }
            if pane.chat.costUSD > 0 { Stat(label: "Cost", value: String(format: "$%.2f", pane.chat.costUSD)) }
            let running = pane.chat.controls.runningTasks.count
            if running > 0 {
                Button { model.openSettings(.tasks, in: pane) } label: { Stat(label: "Tasks", value: "\(running) running") }
                    .buttonStyle(.plain)
                    .help("Background shells and agents. Click to see their output or stop them.")
            }
            if let mcp = pane.chat.controls.mcpSummary {
                Button { model.openSettings(.mcp, in: pane) } label: {
                    Stat(label: "MCP", value: "\(mcp.connected)/\(mcp.total)", warn: mcp.attention)
                }
                .buttonStyle(.plain)
                .help(mcp.attention ? "Some MCP servers need sign-in or failed. Click to see them." : "MCP servers connected")
            }
            Button { pane.togglePreview() } label: {
                Image(systemName: "safari")
                    .foregroundStyle(pane.showPreview ? Color.accentColor : Color.primary)
                    .overlay(alignment: .topTrailing) {
                        if (pane.preview?.console.errorsThisPage ?? 0) > 0 {
                            Circle().fill(Color.red).frame(width: 6, height: 6).offset(x: 3, y: -2)
                        }
                    }
            }
            .help(pane.showPreview ? "Hide the browser preview (⇧⌘B)" : "Show the browser preview (⇧⌘B)")
            Button { model.openSettings(.model, in: pane) } label: { Image(systemName: "slider.horizontal.3") }
                .help("Session settings: MCP, context, permissions, hooks, model (⌥⌘,)")
            Button("Open in VS Code") { model.openInVSCode(pane.cwd) }
            if pane.authFailed {
                Button("Restart Claude") { model.restart(pane) }.help("Restart with the new login, keeping this conversation")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private var subtitle: String {
        var parts = [pane.cwd.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")]
        if let worktree = pane.worktree { parts.append("branch \(worktree.branch)") }
        return parts.joined(separator: "  ·  ")
    }

    private var cacheText: String {
        guard let cache = pane.chat.cache else { return "—" }
        let remaining = cache.remaining(at: model.now)
        return remaining > 0 ? "\(AppModel.countdown(remaining)) of \(cache.ttl >= 3600 ? "60:00" : AppModel.countdown(cache.ttl))" : "expired"
    }

    private var cacheLow: Bool {
        guard let cache = pane.chat.cache else { return false }
        let remaining = cache.remaining(at: model.now)
        return remaining > 0 && remaining < 120
    }
}

struct Stat: View {
    let label: String
    let value: String
    var warn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.medium)).foregroundStyle(warn ? Color.orange : Color.primary)
        }
    }
}

/// The conversation. Read-only mode is used for sessions running outside Viber.
struct ChatList: View {
    let pane: Pane?
    var readOnlyChat: ChatTranscript?
    let readOnly: Bool

    init(pane: Pane, readOnly: Bool) { self.pane = pane; self.readOnly = readOnly }
    init(chat: ChatTranscript) { self.pane = nil; self.readOnlyChat = chat; self.readOnly = true }

    private var chat: ChatTranscript { pane?.chat ?? readOnlyChat ?? ChatTranscript() }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(chat.items) { item in
                        ChatItemView(item: item, pane: readOnly ? nil : pane)
                            .id(item.id)
                    }
                    if !chat.streamingText.isEmpty {
                        MarkdownText(text: chat.streamingText, streaming: true).id("streaming")
                    }
                    if !readOnly, chat.state == .working || chat.state == .starting {
                        WorkingRow(pane: pane, starting: chat.state == .starting).id("working")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 24).padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.items.count) { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: chat.streamingText) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.state) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

struct WorkingRow: View {
    let pane: Pane?
    let starting: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(starting ? "Starting Claude…" : pane?.chat.isThinking == true ? "Thinking…" : "Working…").foregroundStyle(.secondary)
            Spacer()
            if !starting, let pane {
                Button("Stop") { pane.interrupt() }.help("Interrupt Claude (⌘.)")
            }
        }
        .font(.callout)
    }
}

struct ChatItemView: View {
    @Environment(AppModel.self) private var model
    let item: ChatItem
    let pane: Pane?
    @State private var hovering = false

    /// Not mid-turn: files are still changing then.
    private var rewindable: Bool {
        guard let pane, pane.state != .working, pane.state != .starting else { return false }
        return pane.chat.canRewind(itemID: item.id)
    }

    /// A dry run first: the alert shows what would change.
    private func rewind() {
        guard let pane else { return }
        model.control(pane) { $0.rewind(itemID: item.id, dryRun: true).map { [$0] } ?? [] }
    }

    var body: some View {
        switch item.kind {
        case .user(let text):
            HStack(alignment: .center, spacing: 6) {
                Spacer(minLength: 60)
                if rewindable {
                    Button(action: rewind) { Image(systemName: "arrow.uturn.backward.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0)
                        .help("Rewind files to before this message")
                }
                Text(ElementReference.displayText(text))
                    .textSelection(.enabled)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.6)))
            }
            .onHover { hovering = $0 }
            .contextMenu {
                if rewindable { Button("Rewind Files to Before This Message…", action: rewind) }
            }
        case .attachments(let labels):
            HStack(spacing: 6) {
                Spacer(minLength: 60)
                ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                    Label(label, systemImage: "photo").font(.caption).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.6)))
                }
            }
        case .assistant(let text):
            MarkdownText(text: text)
        case .thinking(let text):
            FoldedText(title: "Thinking", icon: "brain", text: text)
        case .tool(let call):
            if let run = call.agent { AgentCard(call: call, run: run, pane: pane) } else { ToolRow(call: call, pane: pane) }
        case .permission(let prompt):
            PermissionCard(itemID: item.id, prompt: prompt, pane: pane)
        case .question(let prompt):
            QuestionCard(itemID: item.id, prompt: prompt, pane: pane)
        case .plan(let prompt):
            PlanCard(itemID: item.id, prompt: prompt, pane: pane)
        case .elicitation(let prompt):
            ElicitationCard(itemID: item.id, prompt: prompt, pane: pane)
        case .received(let from, let text):
            VStack(alignment: .trailing, spacing: 4) {
                Label("From \(from)", systemImage: "arrow.down.left").font(.caption).foregroundStyle(.secondary)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.35)))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 60)
        case .reply(let from, let text):
            VStack(alignment: .leading, spacing: 4) {
                Label("Reply from \(from)", systemImage: "arrowshape.turn.up.left").font(.caption).foregroundStyle(.secondary)
                MarkdownText(text: text)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.3)))
            }
            .padding(.trailing, 60)
        case .sent(let to, let text, let queued):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.up.right").foregroundStyle(Color.accentColor)
                Text(queued ? "Queued for \(to)" : "Sent to \(to)").fontWeight(.medium)
                Text(text).foregroundStyle(.secondary).lineLimit(2)
                if queued { Text("· delivered when its reply ends").foregroundStyle(.tertiary) }
            }
            .font(.callout)
            .textSelection(.enabled)
        case .notice(let text, let isError):
            Label(text, systemImage: isError ? "exclamationmark.triangle" : "info.circle")
                .font(.callout)
                .foregroundStyle(isError ? Color.red : Color.secondary)
                .textSelection(.enabled)
        }
    }
}

/// Text folded away until opened: Claude's thinking, or the prompt it gave an agent.
struct FoldedText: View {
    let title: String
    let icon: String
    let text: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.12)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.caption)
                    Text(title).font(.callout)
                    if !open { Text(text.replacingOccurrences(of: "\n", with: " ")).font(.callout).lineLimit(1).foregroundStyle(.tertiary) }
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                MarkdownText(text: text)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 2) }
            }
        }
    }
}

struct ToolRow: View {
    let call: ToolCall
    var pane: Pane?
    @State private var open = false

    /// A dev server's address in the output of a shell command, offered for the preview.
    private var localURL: URL? {
        guard pane != nil, call.name == "Bash" || call.name.hasSuffix("Output") || call.name == "Monitor",
              let result = call.result else { return nil }
        return PreviewURL.detect(in: String(result.prefix(4000))).first
    }

    private var detail: Bool { !ToolSummary.diff(name: call.name, input: call.input).isEmpty || !(call.result ?? "").isEmpty || call.name == "Bash" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                row
                if let url = localURL, let pane {
                    Button { pane.openPreview(url) } label: { Label("Open in preview", systemImage: "safari") }
                        .buttonStyle(.borderless).font(.caption)
                        .help("Open \(PreviewURL.short(url)) in the browser preview beside the chat")
                }
            }
            if !call.done, let progress = call.progress, !progress.isEmpty {
                Text(progress).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 15)
            }
            if open { ToolDetail(call: call).padding(.leading, 15) }
        }
    }

    private var row: some View {
        Button { if detail { open.toggle() } } label: {
            HStack(spacing: 8) {
                Circle().fill(call.isError ? Color.red : call.done ? Color.green : Color.blue).frame(width: 7, height: 7)
                Text(ToolSummary.displayName(call.name)).fontWeight(.semibold)
                Text(ToolSummary.summary(name: call.name, input: call.input))
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if call.blockedByAutoMode {
                    Label("Blocked by auto mode", systemImage: "hand.raised").font(.caption).foregroundStyle(.orange)
                }
                if let counts = ToolSummary.counts(name: call.name, input: call.input) {
                    Text(counts).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if detail { Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.callout)
    }
}

/// A subagent's run: what it is doing while it works, then its report. Its prompt and steps fold open below.
struct AgentCard: View {
    @Environment(AppModel.self) private var model
    let call: ToolCall
    let run: AgentRun
    let pane: Pane?
    @State private var showSteps = false
    @State private var showFullReport = false
    @State private var reportHeight: CGFloat = 0

    private static let reportPreview: CGFloat = 160

    private var color: Color {
        switch run.status {
        case "running", "pending": return .blue
        case "completed": return .green
        case "failed": return .red
        default: return .secondary
        }
    }

    private var statusText: String? {
        switch run.status {
        case "running", "pending": return run.background ? "In background" : nil
        case "completed": return nil
        case "failed": return "Failed"
        case "unknown": return "No report yet"
        default: return "Stopped"
        }
    }

    private var stats: String {
        [run.toolUses.map { $0 == 1 ? "1 tool" : "\($0) tools" },
         run.tokens.map { "\(AppModel.compact($0)) tokens" },
         run.durationMs.map { AppModel.duration(Double($0) / 1000) }].compactMap { $0 }.joined(separator: " · ")
    }

    /// What the agent did last, while it runs.
    private var latest: String? {
        switch run.steps.last?.kind {
        case .tool(let step)?: return "\(step.name) \(ToolSummary.summary(name: step.name, input: step.input))"
        case .assistant(let text)?: return text.split(separator: "\n").first.map(String.init)
        default: return call.progress
        }
    }

    private var stepsLabel: String {
        let count = run.activity.count
        return count == 0 ? "Prompt" : "Prompt and \(count == 1 ? "1 step" : "\(count) steps")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if run.isRunning { ProgressView().controlSize(.mini) } else { Circle().fill(color).frame(width: 7, height: 7) }
                Text(run.type ?? "Agent").fontWeight(.semibold)
                Text(call.input["description"]?.string ?? "").foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                if let statusText { Text(statusText).font(.caption).foregroundStyle(color) }
                if !stats.isEmpty { Text(stats).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                if run.isRunning, let id = run.taskID, let pane {
                    Button("Stop") { model.control(pane) { [$0.stopTask(id)] } }
                        .controlSize(.small)
                        .disabled(pane.chat.controls.busy.contains("task:\(id)"))
                        .help("Stop this agent. Claude is told it was stopped.")
                }
            }
            .font(.callout)
            if run.isRunning, let latest {
                Text(latest).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let report = run.report, !report.isEmpty {
                let cut = !showFullReport && reportHeight > Self.reportPreview
                MarkdownText(text: report)
                    .foregroundStyle(run.status == "failed" ? Color.red : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { reportHeight = $0 }
                    .frame(maxHeight: showFullReport ? nil : Self.reportPreview, alignment: .top)
                    .clipped()
                    // A cut-off report fades out rather than ending mid-line.
                    .mask {
                        VStack(spacing: 0) {
                            Rectangle()
                            if cut { LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 32) }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                if reportHeight > Self.reportPreview { ExpandButton(expanded: $showFullReport) }
            }
            Button { withAnimation(.easeOut(duration: 0.12)) { showSteps.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(stepsLabel)
                    Image(systemName: showSteps ? "chevron.down" : "chevron.right").font(.caption2)
                }
                .font(.caption).foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showSteps {
                VStack(alignment: .leading, spacing: 6) {
                    if let prompt = call.input["prompt"]?.string { FoldedText(title: "Prompt", icon: "text.bubble", text: prompt) }
                    ForEach(run.activity) { step in AgentStep(item: step, pane: pane) }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 2) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.35)))
    }
}

/// One thing a subagent did: a tool call (an agent of its own gets its own card) or a message.
struct AgentStep: View {
    let item: ChatItem
    let pane: Pane?

    var body: some View {
        switch item.kind {
        case .tool(let call):
            // AnyView: a card inside a card would otherwise make the view type contain itself.
            if let run = call.agent { AnyView(AgentCard(call: call, run: run, pane: pane)) } else { ToolRow(call: call, pane: pane) }
        case .assistant(let text):
            Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
        default:
            EmptyView()
        }
    }
}

struct ToolDetail: View {
    let call: ToolCall

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let diff = ToolSummary.diff(name: call.name, input: call.input)
            if !diff.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diff.enumerated()), id: \.offset) { _, line in
                            Text("\(String(line.sign)) \(line.text)")
                                .font(.system(size: 11.5, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .background(line.sign == "+" ? Color.green.opacity(0.14) : line.sign == "-" ? Color.red.opacity(0.12) : .clear)
                        }
                    }
                    .padding(.vertical, 6)
                }
            } else if let command = call.input["command"]?.string {
                Text(command).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).padding(10)
            }
            if call.name == "TodoWrite" {
                ChecklistRows(items: ChatTranscript.todoList(call.input)).padding(10)
            } else if let result = call.result, !result.isEmpty {
                Divider()
                ScrollView {
                    Text(result.count > 6000 ? String(result.prefix(6000)) + "\n…" : result)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(call.isError ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 220)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

/// Claude's checklist, pinned above the message box while something on it is still open.
struct ChecklistPanel: View {
    let pane: Pane
    @State private var open = true

    var body: some View {
        let todos = pane.chat.todos
        if todos.contains(where: { !$0.isDone }) {
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.12)) { open.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checklist")
                        Text("Checklist").fontWeight(.semibold)
                        Text("\(todos.filter(\.isDone).count) of \(todos.count) done").foregroundStyle(.secondary)
                        if !open, let active = todos.first(where: \.isActive) {
                            Text("· \(active.activeForm ?? active.content)").foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: open ? "chevron.down" : "chevron.up").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open { ChecklistRows(items: todos) }
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: 760, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .padding(.horizontal, 24).padding(.top, 6)
            .frame(maxWidth: .infinity)
        }
    }
}

struct ChecklistRows: View {
    let items: [TodoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.isDone ? "checkmark.circle.fill" : item.isActive ? "circle.dotted.circle" : "circle")
                        .foregroundStyle(item.isDone ? Color.green : item.isActive ? Color.accentColor : Color.secondary)
                    Text(item.isActive ? (item.activeForm ?? item.content) : item.content)
                        .strikethrough(item.isDone)
                        .foregroundStyle(item.isDone ? Color.secondary : Color.primary)
                        .fontWeight(item.isActive ? .medium : .regular)
                }
                .font(.callout)
            }
        }
    }
}

/// Shared look for permission, question and plan cards.
struct Card<Content: View>: View {
    let title: String
    let color: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).fontWeight(.semibold)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.45)))
    }
}

struct DecisionLabel: View {
    let decision: PromptDecision
    var body: some View {
        let (text, icon, color): (String, String, Color) = {
            switch decision {
            case .allowed: return ("Allowed", "checkmark.circle", .green)
            case .alwaysAllowed: return ("Allowed for this session", "checkmark.circle", .green)
            case .denied: return ("Denied", "xmark.circle", .red)
            case .answered: return ("Answered", "checkmark.circle", .green)
            case .declined: return ("Declined", "xmark.circle", .secondary)
            case .approved(let mode): return ("Approved · \(mode.label.lowercased())", "checkmark.circle", .green)
            case .keepPlanning: return ("Kept planning", "arrow.uturn.backward.circle", .secondary)
            case .cancelled: return ("No longer needed", "minus.circle", .secondary)
            }
        }()
        Label(text, systemImage: icon).font(.callout).foregroundStyle(color)
    }
}

struct PermissionCard: View {
    let itemID: String
    let prompt: PermissionPrompt
    let pane: Pane?

    var body: some View {
        if let decision = prompt.decision {
            HStack(spacing: 8) {
                DecisionLabel(decision: decision)
                Text("\(prompt.toolName) \(ToolSummary.summary(name: prompt.toolName, input: prompt.input))")
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            Card(title: "Allow \(prompt.agent ?? "Claude") to use \(prompt.toolName)?", color: .orange) {
                if let task = prompt.agentTask {
                    Label(task, systemImage: "person.2").font(.caption).foregroundStyle(.secondary)
                }
                if let description = prompt.description, !description.isEmpty {
                    Text(description).foregroundStyle(.secondary).font(.callout)
                }
                let summary = prompt.input["command"]?.string ?? ToolSummary.summary(name: prompt.toolName, input: prompt.input)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                }
                let diff = ToolSummary.diff(name: prompt.toolName, input: prompt.input)
                if !diff.isEmpty { ToolDetail(call: ToolCall(id: itemID, name: prompt.toolName, input: prompt.input)) }
                if let pane {
                    HStack {
                        Button("Allow") { pane.run { $0.decidePermission(itemID: itemID, allow: true).map { [$0] } ?? [] } }
                            .keyboardShortcut(.defaultAction)
                        if !prompt.suggestions.isEmpty {
                            Button("Always allow") { pane.run { $0.decidePermission(itemID: itemID, allow: true, always: true).map { [$0] } ?? [] } }
                                .help("Allow this for the rest of the session, using Claude Code's suggested rule")
                        }
                        Button("Deny") { pane.run { $0.decidePermission(itemID: itemID, allow: false).map { [$0] } ?? [] } }
                    }
                }
            }
        }
    }
}

struct QuestionCard: View {
    let itemID: String
    let prompt: QuestionPrompt
    let pane: Pane?
    @State private var choices: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    var body: some View {
        if prompt.requestID == nil || prompt.decision != nil {
            // History, or already answered: show the questions and what was chosen.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(prompt.questions, id: \.question) { q in
                    Text(q.question).fontWeight(.medium)
                    if let answer = prompt.answers?[q.question] { Text("→ \(answer)").foregroundStyle(.secondary) }
                }
                if let decision = prompt.decision { DecisionLabel(decision: decision) }
            }
            .font(.callout)
        } else {
            Card(title: prompt.questions.count == 1 ? prompt.questions[0].question : "Claude has \(prompt.questions.count) questions", color: .purple) {
                ForEach(prompt.questions, id: \.question) { q in
                    VStack(alignment: .leading, spacing: 6) {
                        if prompt.questions.count > 1 { Text(q.question).fontWeight(.medium) }
                        ForEach(q.options, id: \.label) { option in
                            OptionRow(label: option.label, description: option.description, multi: q.multiSelect,
                                      selected: choices[q.question, default: []].contains(option.label)) {
                                toggle(q, option.label)
                            }
                        }
                        TextField("Other answer", text: Binding(get: { other[q.question, default: ""] }, set: { other[q.question] = $0 }))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if let pane {
                    Button("Answer") {
                        pane.run { $0.answerQuestion(itemID: itemID, answers: answers()).map { [$0] } ?? [] }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(answers().count < prompt.questions.count)
                }
            }
        }
    }

    private func toggle(_ q: Question, _ label: String) {
        var set = choices[q.question, default: []]
        if q.multiSelect { if set.contains(label) { set.remove(label) } else { set.insert(label) } } else { set = [label] }
        choices[q.question] = set
    }

    private func answers() -> [String: String] {
        var result: [String: String] = [:]
        for q in prompt.questions {
            let typed = other[q.question, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            let picked = q.options.map(\.label).filter { choices[q.question, default: []].contains($0) }
            let all = picked + (typed.isEmpty ? [] : [typed])
            if !all.isEmpty { result[q.question] = all.joined(separator: ", ") }
        }
        return result
    }
}

struct OptionRow: View {
    let label: String
    let description: String
    let multi: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: multi ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                    if !description.isEmpty { Text(description).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor)))
        }
        .buttonStyle(.plain)
    }
}

struct PlanCard: View {
    let itemID: String
    let prompt: PlanPrompt
    let pane: Pane?
    @State private var feedback = ""
    @State private var expanded = false
    @State private var planHeight: CGFloat = 360

    var body: some View {
        Card(title: prompt.decision == nil && prompt.requestID != nil ? "Plan ready for review" : "Plan", color: .orange) {
            let plan = MarkdownText(text: prompt.plan).padding(12)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { planHeight = $0 }
            Group {
                // Inside the chat's own ScrollView an unbounded one would swallow its scrolling, so the expanded plan drops it.
                if expanded { plan } else { ScrollView { plan }.frame(height: min(planHeight, 360)) }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            if planHeight > 360 { ExpandButton(expanded: $expanded) }
            if let decision = prompt.decision {
                DecisionLabel(decision: decision)
            } else if let pane, prompt.requestID != nil {
                TextField("Optional: tell Claude what to change", text: $feedback, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                HStack {
                    ForEach([PermissionMode.acceptEdits, .auto, .default], id: \.self) { mode in
                        Button("Approve, \(mode.label.lowercased())") { pane.run { $0.decidePlan(itemID: itemID, decision: .approved(mode)) } }
                            .keyboardShortcut(mode == .acceptEdits ? .defaultAction : nil)
                            .help(mode.summary ?? "")
                    }
                    Button("Keep planning") { pane.run { $0.decidePlan(itemID: itemID, decision: .keepPlanning, feedback: feedback) } }
                }
            }
        }
    }
}

/// An MCP server asking for input: a small form built from its schema, or a page to open in the browser.
struct ElicitationCard: View {
    let itemID: String
    let prompt: ElicitationPrompt
    let pane: Pane?
    @State private var text: [String: String] = [:]
    @State private var picks: [String: Set<String>] = [:]
    @State private var toggles: [String: Bool] = [:]

    var body: some View {
        if let decision = prompt.decision {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(prompt.heading): \(prompt.message)").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if prompt.isURL, decision == .answered {
                    Label(prompt.completed ? "Completed" : "Opened in your browser. Waiting for \(prompt.server)…",
                          systemImage: prompt.completed ? "checkmark.circle" : "globe")
                        .font(.callout).foregroundStyle(prompt.completed ? Color.green : Color.secondary)
                } else {
                    DecisionLabel(decision: decision)
                }
            }
        } else {
            Card(title: prompt.heading, color: .purple) {
                if !prompt.message.isEmpty { MarkdownText(text: prompt.message) }
                if prompt.isURL {
                    if let url = prompt.url {
                        Text(url.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                } else {
                    ForEach(prompt.fields) { field($0) }
                }
                if let pane { buttons(pane) }
            }
        }
    }

    @ViewBuilder private func field(_ f: ElicitationField) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                Text(f.title).fontWeight(.medium)
                if f.required { Text("*").foregroundStyle(.red) }
            }
            if !f.description.isEmpty { Text(f.description).font(.caption).foregroundStyle(.secondary) }
            switch f.kind {
            case .boolean:
                Toggle(f.title, isOn: Binding(get: { toggles[f.name] ?? (f.defaultValue?.bool ?? false) }, set: { toggles[f.name] = $0 }))
                    .labelsHidden()
            case .choice(let options), .multiChoice(let options):
                let multi = { if case .multiChoice = f.kind { return true }; return false }()
                ForEach(options, id: \.value) { option in
                    OptionRow(label: option.label, description: "", multi: multi, selected: picks[f.name, default: []].contains(option.value)) {
                        var set = picks[f.name, default: []]
                        if multi { if set.contains(option.value) { set.remove(option.value) } else { set.insert(option.value) } } else { set = [option.value] }
                        picks[f.name] = set
                    }
                }
            case .text, .number, .integer:
                TextField(f.format ?? (f.kind == .text ? "" : "Number"),
                          text: Binding(get: { text[f.name] ?? f.defaultText }, set: { text[f.name] = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder private func buttons(_ pane: Pane) -> some View {
        HStack {
            if prompt.isURL {
                Button("Open page") {
                    pane.run { $0.answerElicitation(itemID: itemID, action: "accept").map { [$0] } ?? [] }
                    if let url = prompt.url { pane.onOpenURL?(url) }
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Submit") { pane.run { $0.answerElicitation(itemID: itemID, action: "accept", content: values).map { [$0] } ?? [] } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!prompt.missing(values).isEmpty)
            }
            Button("Decline") { pane.run { $0.answerElicitation(itemID: itemID, action: "decline").map { [$0] } ?? [] } }
        }
    }

    /// What the form holds, typed per the schema. Untouched fields fall back to their defaults.
    private var values: [String: JSON] {
        var out: [String: JSON] = [:]
        for f in prompt.fields {
            switch f.kind {
            case .boolean:
                out[f.name] = .bool(toggles[f.name] ?? (f.defaultValue?.bool ?? false))
            case .choice:
                if let pick = picks[f.name]?.first { out[f.name] = .string(pick) } else if let d = f.defaultValue { out[f.name] = d }
            case .multiChoice(let options):
                let chosen = options.map(\.value).filter { picks[f.name, default: []].contains($0) }
                if !chosen.isEmpty { out[f.name] = .array(chosen.map(JSON.string)) } else if let d = f.defaultValue { out[f.name] = d }
            case .text, .number, .integer:
                if let v = f.value(from: text[f.name] ?? f.defaultText) { out[f.name] = v }
            }
        }
        return out
    }
}

/// A session running outside Viber: its state, cache and history, with a way to take it over.
struct ExternalView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var history: ChatTranscript?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.recent.first { $0.id == session.id }?.title ?? session.projectName).font(.headline).lineLimit(1)
                    Text(session.project.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Stat(label: "State", value: session.state.rawValue)
                Stat(label: "Cache", value: session.cache.map { $0.remaining(at: model.now) > 0 ? AppModel.countdown($0.remaining(at: model.now)) : "expired" } ?? "—")
                Button("Open in VS Code") { model.openInVSCode(session.project) }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("This session is running outside Viber. Viber shows its state and cache and notifies you, but you chat with it where it runs.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Continue it here") { model.continueHere(session) }
                    .help("Resume this conversation in Viber. Close it elsewhere first so two processes don't write to it.")
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            if let history { ChatList(chat: history) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: session.lastActivity) {
            let path = session.transcriptPath
            let loaded: ChatTranscript = await Task.detached {
                var chat = ChatTranscript()
                if let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    chat.loadHistory(data, transcript: URL(fileURLWithPath: path))
                }
                return chat
            }.value
            history = loaded
        }
    }
}
