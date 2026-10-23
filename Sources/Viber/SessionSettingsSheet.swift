import AppKit
import SwiftUI
import ViberCore

/// Settings that belong to one conversation: what `/mcp`, `/context`, `/permissions`, `/hooks` and `/config`
/// open in the terminal, drawn from the CLI's control requests.
struct SessionSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pane: Pane
    @State var tab: SettingsTab

    private var busy: Bool {
        let keys: [String] = switch tab {
        case .mcp: ["mcp"]
        case .context: ["context", "cost"]
        case .permissions: ["permissions", "sessionRules"]
        case .hooks: ["hooks"]
        case .tasks: pane.chat.controls.busy.filter { $0.hasPrefix("task:") || $0.hasPrefix("output:") }.sorted()
        case .model: ["settings"]
        }
        return keys.contains { pane.chat.controls.busy.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session Settings").font(.headline)
                    Text(pane.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Picker("Section", selection: $tab) {
                    ForEach(SettingsTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding([.horizontal, .top], 16).padding(.bottom, 12)
            Divider()

            Group {
                switch tab {
                case .mcp: McpTab(pane: pane)
                case .context: ContextTab(pane: pane, close: { dismiss() })
                case .permissions: PermissionsTab(pane: pane)
                case .hooks: HooksTab(pane: pane)
                case .tasks: TasksTab(pane: pane)
                case .model: ModelTab(pane: pane)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                Text("For this conversation. Settings for every session are under the gear at the bottom left of the sidebar.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Refresh") { model.control(pane) { $0.refresh(tab) } }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 700, height: 560)
        .onChange(of: tab) { model.control(pane) { $0.refresh(tab) } }
    }
}

/// Placeholder while a tab's data loads, or when it failed.
private struct TabStatus: View {
    let loading: Bool
    let error: String?
    var empty = "Nothing to show."

    var body: some View {
        VStack(spacing: 8) {
            if let error {
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.red)
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
            } else if loading {
                ProgressView()
            } else {
                Text(empty).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - MCP

private struct McpTab: View {
    let pane: Pane

    var body: some View {
        let controls = pane.chat.controls
        VStack(spacing: 0) {
            if let servers = controls.mcp, !servers.isEmpty {
                List {
                    ForEach(servers) { McpRow(server: $0, pane: pane) }
                }
                .listStyle(.inset)
                Text("Turning a server off or on is saved for this project, as /mcp does in the terminal. Add servers in Settings → MCP or with `claude mcp add`.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            } else {
                TabStatus(loading: controls.mcp == nil, error: controls.errors["mcp"],
                          empty: "No MCP servers in this session.\nAdd one in Settings → MCP, or with `claude mcp add`.")
            }
        }
    }
}

private struct McpRow: View {
    @Environment(AppModel.self) private var model
    let server: McpServer
    let pane: Pane
    @State private var open = false

    private var color: Color {
        switch server.status {
        case .connected: return .green
        case .pending: return .blue
        case .needsAuth: return .orange
        case .failed: return .red
        case .disabled, .other: return .secondary
        }
    }

    private var subtitle: String {
        var parts = [server.status.label]
        if server.transport == "claudeai-proxy" {
            parts.append("claude.ai connector")
        } else {
            if let source = server.source { parts.append(Self.sourceLabel(source)) }
            if let transport = server.transport { parts.append(transport) }
        }
        if !server.tools.isEmpty { parts.append("\(server.tools.count) tool\(server.tools.count == 1 ? "" : "s")") }
        if let version = server.version { parts.append("v\(version)") }
        return parts.joined(separator: " · ")
    }

    static func sourceLabel(_ source: String) -> String {
        ["plugin": "plugin", "claudeai": "claude.ai", "user": "all projects", "project": "project .mcp.json",
         "local": "this project", "dynamic": "added by the session"][source] ?? source
    }

    var body: some View {
        let controls = pane.chat.controls
        let key = "mcp:\(server.name)"
        let busy = controls.busy.contains(key)
        let signingIn = controls.signingIn[server.name] != nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(server.name).fontWeight(.medium)
                        if !server.tools.isEmpty {
                            Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let error = server.error, server.status == .failed {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                if busy || signingIn { ProgressView().controlSize(.small) }
                if signingIn { Text("Waiting for browser sign-in").font(.caption).foregroundStyle(.secondary) }
                switch server.status {
                case .needsAuth:
                    Button("Sign In") { model.control(pane) { [$0.mcpAuthenticate(server.name)] } }.disabled(busy)
                case .failed:
                    Button("Retry") { model.control(pane) { [$0.mcpReconnect(server.name)] } }.disabled(busy)
                default:
                    EmptyView()
                }
                Toggle("Enabled", isOn: Binding(
                    get: { server.status != .disabled },
                    set: { on in model.control(pane) { [$0.mcpToggle(server.name, enabled: on)] } }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .disabled(busy)
                    .help(server.status == .disabled ? "Turn on for this project" : "Turn off for this project")
            }
            if let error = controls.errors[key] {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.leading, 18)
            }
            if open {
                Text(server.tools.joined(separator: "  "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(.leading, 18)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { if !server.tools.isEmpty { open.toggle() } }
        .contextMenu {
            Button("Reconnect") { model.control(pane) { [$0.mcpReconnect(server.name)] } }
            if server.canSignOut { Button("Sign Out") { model.control(pane) { [$0.mcpClearAuth(server.name)] } } }
        }
    }
}

// MARK: - Context

private struct ContextTab: View {
    @Environment(AppModel.self) private var model
    let pane: Pane
    let close: () -> Void
    @State private var instructions = ""

    private static let palette: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo, .yellow, .mint, .brown]

    var body: some View {
        let controls = pane.chat.controls
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let usage = controls.context {
                    usageView(usage)
                } else {
                    TabStatus(loading: controls.busy.contains("context"), error: controls.errors["context"]).frame(height: 160)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Compact").font(.headline)
                    Text("Summarize the conversation so far to free up context. The summary replaces the messages above it.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        TextField("Optional: what the summary should keep", text: $instructions)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(compact)
                        Button("Compact Now", action: compact).disabled(pane.state == .working)
                    }
                }
                if let cost = controls.costText {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This session").font(.headline)
                        Text(cost).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .padding(16)
        }
    }

    private func usageView(_ usage: ContextUsage) -> some View {
        let counted = usage.categories.filter { $0.kind != "deferred" }
        let colors = Dictionary(uniqueKeysWithValues: counted.enumerated().map { ($1.name, color(for: $1, index: $0)) })
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(AppModel.compact(usage.totalTokens)) of \(AppModel.compact(usage.maxTokens)) tokens").font(.title3.weight(.semibold))
                Text(String(format: "%.0f%%", usage.fraction * 100)).foregroundStyle(.secondary)
                Spacer()
                if let name = usage.model { Text(name).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(counted) { category in
                        Rectangle().fill(colors[category.name] ?? .gray)
                            .frame(width: max(geo.size.width * Double(category.tokens) / Double(max(usage.maxTokens, 1)) - 1, 0))
                    }
                }
            }
            .frame(height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(usage.categories) { category in
                    GridRow {
                        RoundedRectangle(cornerRadius: 2).fill(colors[category.name] ?? Color.clear)
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.separator))
                            .frame(width: 10, height: 10)
                        Text(category.kind == "deferred"
                             ? category.name.replacingOccurrences(of: " (deferred)", with: "") + " (loaded when used)"
                             : category.name)
                        Text(AppModel.compact(category.tokens)).monospacedDigit().gridColumnAlignment(.trailing)
                        Text(String(format: "%.1f%%", Double(category.tokens) / Double(max(usage.maxTokens, 1)) * 100))
                            .monospacedDigit().foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    }
                    .font(.callout)
                    .foregroundStyle(category.kind == "deferred" ? .secondary : .primary)
                }
            }
            if !usage.autoCompactEnabled {
                Label("Auto-compact is off", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func color(for category: ContextUsage.Category, index: Int) -> Color {
        switch category.kind {
        case "free": return Color(nsColor: .quaternaryLabelColor).opacity(0.5)
        case "buffer": return Color.gray.opacity(0.45)
        default: return Self.palette[index % Self.palette.count]
        }
    }

    private func compact() {
        let note = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        model.submit(note.isEmpty ? "/compact" : "/compact \(note)", in: pane)
        close()
    }
}

// MARK: - Permissions

private struct PermissionsTab: View {
    @Environment(AppModel.self) private var model
    let pane: Pane
    @State private var behavior = "allow"
    @State private var rule = ""
    @State private var scope: SettingsScope = .session

    static func title(_ behavior: String) -> String {
        ["allow": "Allow", "ask": "Ask first", "deny": "Deny"][behavior] ?? behavior
    }

    var body: some View {
        let controls = pane.chat.controls
        VStack(spacing: 0) {
            if let rules = controls.rules {
                List {
                    if rules.isEmpty {
                        Text("No permission rules yet. Claude asks before each tool use that needs one.").foregroundStyle(.secondary)
                    }
                    ForEach(RuleEdit.behaviors, id: \.self) { behavior in
                        let group = rules.filter { $0.behavior == behavior }
                        if !group.isEmpty {
                            Section(Self.title(behavior)) {
                                ForEach(group) { RuleRow(rule: $0, pane: pane) }
                            }
                        }
                    }
                    if !controls.directories.isEmpty {
                        Section("Folders Claude can work in") {
                            ForEach(controls.directories, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                TabStatus(loading: true, error: controls.errors["permissions"])
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("Behavior", selection: $behavior) {
                        ForEach(RuleEdit.behaviors, id: \.self) { Text(Self.title($0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    TextField("Rule, like Bash(npm test:*)", text: $rule)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .onSubmit(add)
                    Picker("Scope", selection: $scope) {
                        ForEach([SettingsScope.session, .projectLocal, .projectShared]) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Button("Add", action: add).disabled(rule.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(scope.detail + (scope == .session ? "" : ". Claude Code picks the change up right away."))
                    .font(.caption).foregroundStyle(.secondary)
                if let error = controls.errors["sessionRules"] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(12)
        }
    }

    private func add() {
        let text = rule.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        model.addRule(RuleEdit(behavior: behavior, rule: text), scope: scope, in: pane)
        rule = ""
    }
}

private struct RuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: PermissionRule
    let pane: Pane

    var body: some View {
        HStack(spacing: 8) {
            Text(rule.rule).font(.callout.monospaced()).textSelection(.enabled)
            Spacer(minLength: 8)
            Chip(text: rule.sourceLabel)
            switch rule.scope {
            case .user?:
                Text("Edit in Settings").font(.caption).foregroundStyle(.tertiary)
            case .some:
                Button { model.removeRule(rule, in: pane) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Remove this rule")
            case nil:
                EmptyView()
            }
        }
    }
}

// MARK: - Hooks

private struct HooksTab: View {
    let pane: Pane

    var body: some View {
        let controls = pane.chat.controls
        VStack(spacing: 0) {
            if let hooks = controls.hooks, !hooks.isEmpty {
                HookList(hooks: hooks)
            } else {
                TabStatus(loading: controls.hooks == nil, error: controls.errors["hooks"], empty: "No hooks run in this session.")
            }
            Divider()
            HStack {
                Text("Hooks run shell commands, so Viber only shows them. Edit them in the settings files.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                SettingsFileButton(title: "Open Project Settings", url: SettingsFile.url(.projectShared, cwd: pane.cwd))
                SettingsFileButton(title: "Open Local Settings", url: SettingsFile.url(.projectLocal, cwd: pane.cwd))
            }
            .padding(12)
        }
    }
}

// MARK: - Tasks

private struct TasksTab: View {
    let pane: Pane

    var body: some View {
        let tasks = pane.chat.controls.tasks
        VStack(spacing: 0) {
            if tasks.isEmpty {
                TabStatus(loading: false, error: nil,
                          empty: "No background tasks in this session.\nShell commands Claude runs in the background and subagents show up here.")
            } else {
                List {
                    let running = tasks.filter(\.isRunning), ended = tasks.filter { !$0.isRunning }.reversed()
                    if !running.isEmpty { Section("Running") { ForEach(running) { TaskRow(entry: $0, pane: pane) } } }
                    if !ended.isEmpty { Section("Finished") { ForEach(Array(ended)) { TaskRow(entry: $0, pane: pane) } } }
                }
                .listStyle(.inset)
            }
            Divider()
            Text("Like /tasks in the terminal. Stopping a task ends its process; Claude is told it was stopped.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }
}

private struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let entry: SessionTask
    let pane: Pane
    @State private var showOutput = false

    private var statusColor: Color {
        switch entry.status {
        case "completed": return .green
        case "failed": return .red
        case "stopped": return .secondary
        default: return .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Chip(text: entry.kindLabel)
                Text(entry.description.isEmpty ? entry.id : entry.description).fontWeight(.medium).lineLimit(1)
                Spacer()
                if pane.chat.controls.busy.contains("task:\(entry.id)") || pane.chat.controls.busy.contains("output:\(entry.id)") {
                    ProgressView().controlSize(.small)
                }
                if entry.hasOutput {
                    Button(showOutput ? "Hide Output" : "Output") {
                        showOutput.toggle()
                        if showOutput { model.control(pane) { [$0.taskOutput(entry.id)] } }
                    }
                }
                if entry.isRunning {
                    Button("Stop") { model.control(pane) { [$0.stopTask(entry.id)] } }
                }
            }
            let detail = [entry.isRunning ? entry.lastTool : nil, entry.summary].compactMap { $0 }.joined(separator: " · ")
            let usage = [entry.toolUses.map { "\($0) tool uses" }, entry.tokens.map { "\(AppModel.compact($0)) tokens" }].compactMap { $0 }
            if !detail.isEmpty || !usage.isEmpty || !entry.isRunning {
                HStack(spacing: 6) {
                    if !entry.isRunning { Text(entry.status.capitalized).foregroundStyle(statusColor) }
                    if !detail.isEmpty { Text(detail).lineLimit(2) }
                    if !usage.isEmpty { Text(usage.joined(separator: " · ")).foregroundStyle(.tertiary) }
                }
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 16)
            }
            if showOutput {
                let output = pane.chat.controls.taskOutput[entry.id]
                ScrollView {
                    Text(output.map { $0.text.isEmpty ? "No output yet." : ($0.truncated ? "…" : "") + $0.text } ?? "Loading…")
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(maxHeight: 180)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 3)
        // While the output is open and the shell is still running, keep it current.
        .task(id: showOutput && entry.isRunning) {
            guard showOutput && entry.isRunning else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, !pane.chat.controls.busy.contains("output:\(entry.id)") else { continue }
                model.control(pane) { [$0.taskOutput(entry.id)] }
            }
        }
    }
}

/// Hooks grouped by event. Shared with Settings → Hooks.
struct HookList: View {
    let hooks: [HookEntry]

    var body: some View {
        let events = hooks.reduce(into: [String]()) { if !$0.contains($1.event) { $0.append($1.event) } }
        List {
            ForEach(events, id: \.self) { event in
                Section(event) {
                    ForEach(hooks.filter { $0.event == event }) { hook in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hook.command).font(.callout.monospaced()).lineLimit(3).textSelection(.enabled)
                            HStack(spacing: 6) {
                                if !hook.matcher.isEmpty { Chip(text: "matches \(hook.matcher)") }
                                Text(hook.source).font(.caption).foregroundStyle(.secondary)
                                if let timeout = hook.timeout { Text("· \(timeout)s timeout").font(.caption).foregroundStyle(.tertiary) }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

/// Opens a settings file in its default editor; disabled until the file exists.
struct SettingsFileButton: View {
    let title: String
    let url: URL?

    var body: some View {
        let exists = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        Button(title) { if let url { NSWorkspace.shared.open(url) } }
            .disabled(!exists)
            .help(exists ? (url?.path ?? "") : "\(url?.path ?? "The file") does not exist yet")
    }
}

// MARK: - Model

private struct ModelTab: View {
    @Environment(AppModel.self) private var model
    let pane: Pane

    private static let efforts = ["low", "medium", "high", "xhigh", "max"]

    var body: some View {
        let controls = pane.chat.controls
        Form {
            Section {
                LabeledContent("Model") {
                    Menu(modelLabel) {
                        if pane.chat.models.isEmpty { Text("Start the session to load models") }
                        ForEach(pane.chat.models, id: \.value) { option in
                            Button(option.displayName) { model.submit("/model \(option.value)", in: pane) }
                        }
                    }
                    .fixedSize()
                }
                LabeledContent("Effort") {
                    Picker("Effort", selection: Binding(
                        get: { controls.effort ?? "" },
                        set: { level in model.control(pane) { [$0.setEffort(level)] } })) {
                        if controls.effort == nil { Text("Model default").tag("") }
                        ForEach(Self.efforts + (controls.effort.map { Self.efforts.contains($0) ? [] : [$0] } ?? []), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                LabeledContent("Permission mode") {
                    Menu(PermissionMode.label(for: pane.chat.permissionMode ?? pane.spec.permissionMode)) {
                        ForEach(PermissionMode.offered, id: \.self) { mode in
                            Button(mode.label) { model.setMode(mode.rawValue, in: pane) }.help(mode.summary ?? "")
                        }
                    }
                    .fixedSize()
                }
            } footer: {
                Text("This session only. Set the model and effort new sessions start with in Settings → Model.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Output style") {
                    Picker("Output style", selection: Binding(
                        get: { controls.outputStyle ?? "default" },
                        set: { style in model.control(pane) { [$0.setOutputStyle(style)] } })) {
                        ForEach(controls.outputStyles.isEmpty ? ["default"] : controls.outputStyles, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            } footer: {
                Text("Saved for this project, just you (.claude/settings.local.json), as /output-style does.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = controls.errors["effort"] ?? controls.errors["outputStyle"] ?? controls.errors["settings"] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    private var modelLabel: String {
        guard let current = pane.chat.model ?? pane.chat.controls.appliedModel else { return "Default" }
        return pane.chat.models.first { $0.value == current }?.displayName ?? current
    }
}
