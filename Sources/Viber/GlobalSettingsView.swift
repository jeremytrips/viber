import SwiftUI
import ViberCore

/// Settings that are not about one conversation: Viber's own preferences, and Claude Code settings for all
/// projects (~/.claude/settings.json, ~/.claude.json). Per-conversation settings are in the session's sheet.
struct GlobalSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            UserPermissionsSettings().tabItem { Label("Permissions", systemImage: "lock.shield") }
            UserHooksSettings().tabItem { Label("Hooks", systemImage: "point.3.connected.trianglepath.dotted") }
            UserMcpSettings().tabItem { Label("MCP", systemImage: "server.rack") }
            ModelDefaultsSettings().tabItem { Label("Model", systemImage: "cpu") }
        }
        .frame(width: 640, height: 480)
    }
}

private struct SettingsNote: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(Prefs.notifyFinished) private var notifyFinished = true
    @AppStorage(Prefs.notifyNeedsYou) private var notifyNeedsYou = true
    @AppStorage(Prefs.notifyCache) private var notifyCache = true
    @AppStorage(Prefs.cacheWarningMinutes) private var cacheWarningMinutes = 2
    @AppStorage(Prefs.newSessionMode) private var newSessionMode = "auto"
    @AppStorage(Prefs.previewTools) private var previewTools = true
    @AppStorage(Prefs.previewLocalActions) private var previewLocalActions = true
    @AppStorage(Prefs.deviceTools) private var deviceTools = true
    @AppStorage(Prefs.deviceActions) private var deviceActions = true

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("When a session finishes or fails", isOn: $notifyFinished)
                Toggle("When Claude needs you: a permission, a question or a plan", isOn: $notifyNeedsYou)
                Toggle("Before a session's prompt cache expires", isOn: $notifyCache)
                Stepper("Warn \(cacheWarningMinutes) min before it expires", value: $cacheWarningMinutes, in: 1...10)
                    .disabled(!notifyCache)
            }
            Section("New sessions") {
                Picker("Permission mode", selection: $newSessionMode) {
                    ForEach(PermissionMode.offered, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
            }
            Section {
                Toggle("Give Claude tools to see and use the preview", isOn: $previewTools)
                Toggle("Let Claude click, type and run scripts on local pages without asking", isOn: $previewLocalActions)
                    .disabled(!previewTools)
            } header: {
                Text("Browser preview")
            } footer: {
                Text("Screenshots, the console and page outlines never ask. The first setting applies to sessions started afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Give Claude tools to see and use devices", isOn: $deviceTools)
                Toggle("Let Claude tap, type, install and launch apps on simulators without asking", isOn: $deviceActions)
                    .disabled(!deviceTools)
            } header: {
                Text("Simulators")
            } footer: {
                Text("Screenshots, screen outlines and logs never ask. The first setting applies to sessions started afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Permissions (all projects)

private struct UserPermissionsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var rules: [RuleEdit] = []
    @State private var behavior = "allow"
    @State private var rule = ""

    var body: some View {
        VStack(spacing: 0) {
            List {
                if rules.isEmpty { Text("No rules for all projects yet.").foregroundStyle(.secondary) }
                ForEach(RuleEdit.behaviors, id: \.self) { behavior in
                    let group = rules.filter { $0.behavior == behavior }
                    if !group.isEmpty {
                        Section(["allow": "Allow", "ask": "Ask first", "deny": "Deny"][behavior] ?? behavior) {
                            ForEach(group, id: \.self) { edit in
                                HStack {
                                    Text(edit.rule).font(.callout.monospaced()).textSelection(.enabled)
                                    Spacer()
                                    Button { change { try SettingsFile.removeRule(edit, from: $0) } } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless).help("Remove this rule")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            VStack(spacing: 6) {
                HStack {
                    Picker("Behavior", selection: $behavior) {
                        Text("Allow").tag("allow"); Text("Ask first").tag("ask"); Text("Deny").tag("deny")
                    }
                    .labelsHidden().fixedSize()
                    TextField("Rule, like Bash(git status) or Read(~/notes/**)", text: $rule)
                        .textFieldStyle(.roundedBorder).font(.callout.monospaced())
                        .onSubmit(add)
                    Button("Add", action: add).disabled(rule.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                SettingsNote(text: "Saved in ~/.claude/settings.json for every project. Sessions started from now on use them; rules for one project or one session are in that session's settings.")
            }
            .padding(12)
        }
        .onAppear(perform: reload)
    }

    private func add() {
        let edit = RuleEdit(behavior: behavior, rule: rule.trimmingCharacters(in: .whitespaces))
        guard !edit.rule.isEmpty else { return }
        rule = ""
        change { try SettingsFile.addRule(edit, to: $0) }
    }

    private func change(_ edit: @escaping @Sendable (URL) throws -> Void) {
        model.editSettings(.user, cwd: "", then: nil, done: { reload() }, edit)
    }

    private func reload() { rules = SettingsFile.rules(in: SettingsFile.user) }
}

// MARK: - Hooks (all projects)

private struct UserHooksSettings: View {
    @State private var hooks: [HookEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            if hooks.isEmpty {
                Text("No hooks in ~/.claude/settings.json.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HookList(hooks: hooks)
            }
            Divider()
            HStack {
                SettingsNote(text: "Hooks run shell commands, so Viber only shows them. Plugin hooks and project hooks are listed in each session's settings.")
                SettingsFileButton(title: "Open settings.json", url: SettingsFile.user)
                Button("Reload") { reload() }
            }
            .padding(12)
        }
        .onAppear(perform: reload)
    }

    private func reload() { hooks = SettingsFile.hooks(in: SettingsFile.user, source: "All projects") }
}

// MARK: - MCP (all projects)

private struct UserMcpSettings: View {
    @State private var servers: [ConfiguredMcpServer] = []
    @State private var name = ""
    @State private var transport = "http"
    @State private var target = ""
    @State private var running = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            List {
                if servers.isEmpty { Text("No MCP servers for all projects yet.").foregroundStyle(.secondary) }
                ForEach(servers) { server in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).fontWeight(.medium)
                            Text(server.target).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Chip(text: server.transport)
                        Button { run(["mcp", "remove", "--scope", "user", server.name]) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove this server").disabled(running)
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            VStack(spacing: 6) {
                HStack {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 130)
                    Picker("Transport", selection: $transport) {
                        Text("HTTP").tag("http"); Text("SSE").tag("sse"); Text("Command").tag("stdio")
                    }
                    .labelsHidden().fixedSize()
                    TextField(transport == "stdio" ? "Command, like npx -y @modelcontextprotocol/server-memory" : "https://…",
                              text: $target)
                        .textFieldStyle(.roundedBorder).font(.callout.monospaced())
                        .onSubmit(add)
                    if running { ProgressView().controlSize(.small) }
                    Button("Add", action: add).disabled(running || name.isEmpty || target.isEmpty)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    SettingsNote(text: "Saved in ~/.claude.json through `claude mcp`, for every project. Sessions started from now on connect to them. Turn servers on or off per project in a session's settings.")
                    Link("claude.ai connectors…", destination: URL(string: "https://claude.ai/settings/connectors")!)
                        .font(.caption)
                }
            }
            .padding(12)
        }
        .onAppear(perform: reload)
    }

    private func add() {
        guard !name.isEmpty, !target.isEmpty else { return }
        run(SettingsFile.mcpAddArguments(name: name.trimmingCharacters(in: .whitespaces), transport: transport,
                                         target: target.trimmingCharacters(in: .whitespaces))) {
            name = ""; target = ""
        }
    }

    private func run(_ arguments: [String], onSuccess: @escaping @MainActor () -> Void = {}) {
        running = true
        error = nil
        Task {
            let result = await Task.detached { Shell.run("claude", arguments, environment: SettingsFile.mcpEnvironment) }.value
            running = false
            if result.ok { onSuccess() } else {
                let message = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                error = message.isEmpty ? "claude mcp failed with status \(result.status)." : message
            }
            reload()
        }
    }

    private func reload() { servers = SettingsFile.mcpServers(in: SettingsFile.userConfig) }
}

// MARK: - Model defaults

private struct ModelDefaultsSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.newSessionModel) private var newSessionModel = ""
    @State private var efforts: [String: String] = [:]

    private static let levels = ["low", "medium", "high", "xhigh"]

    /// Model choices from open sessions, or the usual aliases before any has started.
    private var modelOptions: [ModelOption] {
        var seen = Set<String>()
        var options = model.panes.flatMap(\.chat.models).filter { $0.value != "default" && seen.insert($0.value).inserted }
        if options.isEmpty {
            options = [ModelOption(value: "opus", displayName: "Opus"), ModelOption(value: "sonnet", displayName: "Sonnet"),
                       ModelOption(value: "haiku", displayName: "Haiku")]
        }
        if !newSessionModel.isEmpty, !options.contains(where: { $0.value == newSessionModel }) {
            options.append(ModelOption(value: newSessionModel, displayName: newSessionModel))
        }
        return options
    }

    /// Full model ids that have a saved default, plus the ones open sessions run on.
    private var modelIDs: [String] {
        let running = model.panes.compactMap { $0.chat.controls.appliedModel ?? $0.chat.model }.filter { $0.hasPrefix("claude-") }
        return Array(Set(efforts.keys).union(running)).sorted()
    }

    var body: some View {
        Form {
            Section {
                Picker("Model for new sessions", selection: $newSessionModel) {
                    Text("Claude Code default").tag("")
                    ForEach(modelOptions, id: \.value) { Text($0.displayName).tag($0.value) }
                }
            } footer: {
                SettingsNote(text: "Viber starts new sessions with this model. Switch a running session with /model.")
            }
            Section {
                if modelIDs.isEmpty {
                    Text("Open a session to set a default effort for its model.").foregroundStyle(.secondary)
                }
                ForEach(modelIDs, id: \.self) { id in
                    Picker(id, selection: Binding(get: { efforts[id] ?? "" }, set: { setEffort($0, for: id) })) {
                        Text("Not set").tag("")
                        ForEach(Self.levels, id: \.self) { Text($0).tag($0) }
                    }
                }
            } header: {
                Text("Default effort")
            } footer: {
                SettingsNote(text: "Saved in ~/.claude/settings.json, where /effort saves its default. Sessions started from now on use it; change one session's effort in its settings.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
    }

    private func setEffort(_ level: String, for id: String) {
        efforts[id] = level.isEmpty ? nil : level
        let value: String? = level.isEmpty ? nil : level
        model.editSettings(.user, cwd: "", then: nil, done: { reload() }) {
            try SettingsFile.set(value, at: ["modelSettings", id, "effortLevel"], in: $0)
        }
    }

    private func reload() {
        let settings = (try? SettingsFile.read(SettingsFile.user)) ?? [:]
        let models = settings["modelSettings"] as? [String: Any] ?? [:]
        efforts = models.compactMapValues { ($0 as? [String: Any])?["effortLevel"] as? String }
    }
}
