import SwiftUI
import ViberCore

/// The message box: multi-line input, a "/" menu of skills and commands, and mode/model menus.
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let pane: Pane
    @State private var draft = ""
    @State private var highlighted = 0
    @State private var menuDismissed = false
    @FocusState private var focused: Bool

    private var suggestions: [SlashCommand] {
        menuDismissed ? [] : Array(SlashRouter.suggestions(for: draft, commands: pane.chat.commands).prefix(8))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if !suggestions.isEmpty { slashMenu }
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...10)
                    .focused($focused)
                    .padding(.horizontal, 13).padding(.top, 11).padding(.bottom, 6)
                    .onSubmit(submitOrComplete)
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.tab) { complete() }
                    .onKeyPress(.escape) {
                        if !suggestions.isEmpty { menuDismissed = true; return .handled }
                        if pane.state == .working { pane.interrupt(); return .handled }
                        return .ignored
                    }
                    .onChange(of: draft) { highlighted = 0; if !draft.hasPrefix("/") { menuDismissed = false } }
                bottomBar
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor)))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
            .frame(maxWidth: 760)
        }
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .onAppear { focused = true }
    }

    private var placeholder: String {
        switch pane.state {
        case .permission, .input, .plan: return "Answer the card above, or type to send a message"
        case .working: return "Claude is working. Messages you send now are queued."
        default: return "Message Claude. Type / for skills and commands"
        }
    }

    private var slashMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Skills and commands").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            ForEach(Array(suggestions.enumerated()), id: \.element.name) { index, command in
                Button { draft = "/\(command.name) "; menuDismissed = true } label: {
                    HStack(spacing: 10) {
                        Text("/\(command.name)").font(.system(.callout, design: .monospaced)).frame(minWidth: 110, alignment: .leading)
                        Text(command.description).font(.callout).lineLimit(1)
                            .foregroundStyle(index == highlighted ? Color.white.opacity(0.85) : Color.secondary)
                        Spacer()
                    }
                    .foregroundStyle(index == highlighted ? Color.white : Color.primary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(index == highlighted ? Color.accentColor : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
            }
            Divider().padding(.top, 4)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(["default", "acceptEdits", "plan"], id: \.self) { mode in
                    Button(AppModel.modeLabel(mode)) { model.submit(mode == "plan" ? "/plan" : "", in: pane, mode: mode) }
                }
            } label: { Text(AppModel.modeLabel(pane.chat.permissionMode ?? pane.spec.permissionMode)) }
                .menuStyle(.borderlessButton).fixedSize()
            Menu {
                if pane.chat.models.isEmpty { Text("Start the session to load models") }
                ForEach(pane.chat.models, id: \.value) { option in
                    Button(option.displayName) { model.submit("/model \(option.value)", in: pane) }
                }
            } label: { Text(modelLabel) }
                .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            if let usage = pane.chat.lastUsage {
                Text("\(AppModel.compact(usage.contextTokens)) context").font(.caption).foregroundStyle(.secondary)
            }
            if pane.state == .working {
                Button { pane.interrupt() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Stop (Esc or ⌘.)")
            }
            Button { submitOrComplete() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.plain)
                .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.accentColor)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send (Return)")
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    private var modelLabel: String {
        guard let current = pane.chat.model else { return "Model" }
        return pane.chat.models.first { $0.value == current }?.displayName ?? current
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        highlighted = (highlighted + delta + suggestions.count) % suggestions.count
        return .handled
    }

    private func complete() -> KeyPress.Result {
        guard suggestions.indices.contains(highlighted) else { return .ignored }
        draft = "/\(suggestions[highlighted].name) "
        menuDismissed = true
        return .handled
    }

    private func submitOrComplete() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Return on a partially typed command picks the highlighted one first.
        if !suggestions.isEmpty, suggestions.indices.contains(highlighted), text != "/\(suggestions[highlighted].name)" {
            _ = complete()
            return
        }
        guard !text.isEmpty else { return }
        draft = ""
        menuDismissed = false
        model.submit(text, in: pane)
    }
}

extension AppModel {
    /// Mode menu: switch mode without sending a message.
    func submit(_ text: String, in pane: Pane, mode: String) {
        if !pane.isRunning { pane.start(binDir: binDir, pluginDir: pluginDir) }
        pane.run { [$0.setPermissionMode(mode)] }
        pane.chat.note(mode == "plan" ? "Plan mode is on. Claude plans first and edits only after you approve." : "Mode: \(Self.modeLabel(mode))")
    }
}
