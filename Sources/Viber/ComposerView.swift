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
        menuDismissed || Relay.isRelay(draft) ? [] : Array(SlashRouter.suggestions(for: draft, commands: pane.chat.commands).prefix(8))
    }

    /// For `//message`: the other sessions, best match first.
    private var relayTargets: [RelaySuggestion] {
        Relay.isRelay(draft) ? Array(Relay.rank(draft, candidates: model.relayCandidates(excluding: pane)).prefix(6)) : []
    }

    private var menuCount: Int { Relay.isRelay(draft) ? relayTargets.count : suggestions.count }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if Relay.isRelay(draft) { relayMenu } else if !suggestions.isEmpty { slashMenu }
                if !pane.attachments.isEmpty { attachmentChips }
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
                        if Relay.isRelay(draft) { draft = ""; return .handled }
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
        .onChange(of: pane.attachments.count) { old, new in if new > old { focused = true } }
    }

    /// Elements picked in the preview; they go out with the next message.
    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pane.attachments) { reference in
                    HStack(spacing: 5) {
                        Image(systemName: "cursorarrow.rays").font(.caption)
                        Text(reference.label).font(.caption).lineLimit(1)
                        Button { pane.attachments.removeAll { $0.id == reference.id } } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .help(reference.selector)
                }
            }
            .padding(.horizontal, 10).padding(.top, 9)
        }
    }

    private var placeholder: String {
        switch pane.state {
        case .permission, .input, .plan: return "Answer the card above, or type to send a message"
        case .working: return "Claude is working. Messages you send now are queued."
        case _ where !pane.attachments.isEmpty: return "Say what to do with the picked element"
        default: return "Message Claude. Type / for commands, // to message another session"
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

    private var relayMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(relayTargets.isEmpty ? "No other sessions to send to" : "Send to another session · ↑↓ to choose, Return to send")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            ForEach(Array(relayTargets.enumerated()), id: \.element.candidate.id) { index, target in
                let selected = index == highlighted
                Button { highlighted = index; submitOrComplete() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.right")
                        Text(target.candidate.title).fontWeight(.medium).lineLimit(1)
                        Text(target.candidate.project + (target.candidate.branch.map { " · \($0)" } ?? ""))
                            .lineLimit(1)
                            .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                        Spacer()
                        if index == 0, target.score > 0 { Text(target.addressed ? "named" : "best match").font(.caption2) }
                    }
                    .font(.callout)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
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
                ForEach(PermissionMode.offered, id: \.self) { mode in
                    Button(mode.label) { model.setMode(mode.rawValue, in: pane) }
                }
            } label: { Text(PermissionMode.label(for: pane.chat.permissionMode ?? pane.spec.permissionMode)) }
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
        guard menuCount > 0 else { return .ignored }
        highlighted = (highlighted + delta + menuCount) % menuCount
        return .handled
    }

    private func complete() -> KeyPress.Result {
        if Relay.isRelay(draft) { return move(1) }
        guard suggestions.indices.contains(highlighted) else { return .ignored }
        draft = "/\(suggestions[highlighted].name) "
        menuDismissed = true
        return .handled
    }

    private func submitOrComplete() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if Relay.isRelay(text) {
            guard relayTargets.indices.contains(highlighted) else { return }
            let target = relayTargets[highlighted]
            guard !target.message.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            draft = ""
            model.relay(target.message, from: pane, to: target.candidate.id)
            return
        }
        // Return on a partially typed command picks the highlighted one first.
        if !suggestions.isEmpty, suggestions.indices.contains(highlighted), text != "/\(suggestions[highlighted].name)" {
            _ = complete()
            return
        }
        guard !text.isEmpty else { return }
        draft = ""
        menuDismissed = false
        let message = ElementReference.compose(text, with: pane.attachments)
        pane.attachments = []
        model.submit(message, in: pane)
    }
}
