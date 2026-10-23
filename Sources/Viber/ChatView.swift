import SwiftUI
import ViberCore

struct PaneView: View {
    @Environment(AppModel.self) private var model
    let pane: Pane

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: pane)
            Divider()
            ChatList(pane: pane, readOnly: false)
            ComposerView(pane: pane)
        }
        .background(Color(nsColor: .textBackgroundColor))
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
            Button("Open in VS Code") { model.openInVSCode(pane.cwd) }
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
                        MarkdownText(text: chat.streamingText).id("streaming")
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
            Text(starting ? "Starting Claude…" : "Working…").foregroundStyle(.secondary)
            Spacer()
            if !starting, let pane {
                Button("Stop") { pane.interrupt() }.help("Interrupt Claude (⌘.)")
            }
        }
        .font(.callout)
    }
}

struct ChatItemView: View {
    let item: ChatItem
    let pane: Pane?

    var body: some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.6)))
            }
        case .assistant(let text):
            MarkdownText(text: text)
        case .tool(let call):
            ToolRow(call: call)
        case .permission(let prompt):
            PermissionCard(itemID: item.id, prompt: prompt, pane: pane)
        case .question(let prompt):
            QuestionCard(itemID: item.id, prompt: prompt, pane: pane)
        case .plan(let prompt):
            PlanCard(itemID: item.id, prompt: prompt, pane: pane)
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

/// Markdown with fenced code blocks as boxes and headings in bold; inline markdown otherwise.
struct MarkdownText: View {
    let text: String

    private enum Block: Hashable { case prose(String), code(String) }

    private var blocks: [Block] {
        var result: [Block] = []
        var prose: [Substring] = [], code: [Substring] = []
        var inCode = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode { result.append(.code(code.joined(separator: "\n"))); code = [] }
                else if !prose.isEmpty { result.append(.prose(prose.joined(separator: "\n"))); prose = [] }
                inCode.toggle()
            } else if inCode { code.append(line) } else { prose.append(line) }
        }
        if inCode, !code.isEmpty { result.append(.code(code.joined(separator: "\n"))) }
        if !prose.isEmpty { result.append(.prose(prose.joined(separator: "\n"))) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let s):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(paragraphs(s).enumerated()), id: \.offset) { _, line in line }
                    }
                case .code(let s):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(s).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(10)
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func paragraphs(_ s: String) -> [Text] {
        s.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            if line.hasPrefix("#") {
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                return Text(inline(title)).font(.headline)
            }
            return Text(inline(line.isEmpty ? " " : line)).font(.body)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct ToolRow: View {
    let call: ToolCall
    @State private var open = false

    private var detail: Bool { !ToolSummary.diff(name: call.name, input: call.input).isEmpty || !(call.result ?? "").isEmpty || call.name == "Bash" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { if detail { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Circle().fill(call.isError ? Color.red : call.done ? Color.green : Color.blue).frame(width: 7, height: 7)
                    Text(call.name).fontWeight(.semibold)
                    Text(ToolSummary.summary(name: call.name, input: call.input))
                        .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let counts = ToolSummary.counts(name: call.name, input: call.input) {
                        Text(counts).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if detail { Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            if open { ToolDetail(call: call).padding(.leading, 15) }
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
            if let result = call.result, !result.isEmpty {
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
            case .approvedAuto: return ("Approved · editing automatically", "checkmark.circle", .green)
            case .approvedAsk: return ("Approved · asking before edits", "checkmark.circle", .green)
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
            Card(title: "Allow Claude to use \(prompt.toolName)?", color: .orange) {
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

    var body: some View {
        Card(title: prompt.decision == nil && prompt.requestID != nil ? "Plan ready for review" : "Plan", color: .orange) {
            ScrollView {
                MarkdownText(text: prompt.plan).padding(12)
            }
            .frame(maxHeight: 360)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            if let decision = prompt.decision {
                DecisionLabel(decision: decision)
            } else if let pane, prompt.requestID != nil {
                TextField("Optional: tell Claude what to change", text: $feedback, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                HStack {
                    Button("Approve, edit automatically") { pane.run { $0.decidePlan(itemID: itemID, decision: .approvedAuto) } }
                        .keyboardShortcut(.defaultAction)
                    Button("Approve, ask before edits") { pane.run { $0.decidePlan(itemID: itemID, decision: .approvedAsk) } }
                    Button("Keep planning") { pane.run { $0.decidePlan(itemID: itemID, decision: .keepPlanning, feedback: feedback) } }
                }
            }
        }
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
                if let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) { chat.loadHistory(data) }
                return chat
            }.value
            history = loaded
        }
    }
}
