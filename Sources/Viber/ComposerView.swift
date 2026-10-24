import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ViberCore

/// The message box: multi-line input, a "/" menu of skills and commands, an "@" menu of files,
/// images (pasted, dropped or picked), and mode/model menus.
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let pane: Pane
    @State private var draft = ""
    @State private var attachments: [ImageAttachment] = []
    @State private var highlighted = 0
    @State private var menuDismissed = false
    @State private var fileMenuDismissed = false
    @State private var dropTargeted = false
    @State private var keyMonitor: Any?
    @FocusState private var focused: Bool

    private var suggestions: [SlashCommand] {
        menuDismissed || Relay.isRelay(draft) ? [] : Array(SlashRouter.suggestions(for: draft, commands: pane.chat.commands).prefix(8))
    }

    /// For `//message`: the other sessions, best match first.
    private var relayTargets: [RelaySuggestion] {
        Relay.isRelay(draft) ? Array(Relay.rank(draft, candidates: model.relayCandidates(excluding: pane)).prefix(6)) : []
    }

    /// For `@path`: the project's files, best match first.
    private var fileSuggestions: [String] {
        guard !fileMenuDismissed, !Relay.isRelay(draft), let query = FileIndex.mentionQuery(in: draft), let files = pane.files else { return [] }
        return FileIndex.suggestions(query, in: files)
    }

    private var menuCount: Int {
        Relay.isRelay(draft) ? relayTargets.count : !fileSuggestions.isEmpty ? fileSuggestions.count : suggestions.count
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if Relay.isRelay(draft) { relayMenu } else if !fileSuggestions.isEmpty { fileMenu } else if !suggestions.isEmpty { slashMenu }
                if !pane.pickedElements.isEmpty { pickedElementChips }
                if !attachments.isEmpty { attachmentRow }
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
                        if !fileSuggestions.isEmpty { fileMenuDismissed = true; return .handled }
                        if !suggestions.isEmpty { menuDismissed = true; return .handled }
                        if pane.state == .working { pane.interrupt(); return .handled }
                        return .ignored
                    }
                    .onChange(of: draft) {
                        highlighted = 0
                        if !draft.hasPrefix("/") { menuDismissed = false }
                        if FileIndex.mentionQuery(in: draft) == nil { fileMenuDismissed = false } else { pane.loadFiles() }
                    }
                bottomBar
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(dropTargeted ? Color.accentColor : focused ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor),
                              lineWidth: dropTargeted ? 2 : 1))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
            .frame(maxWidth: 760)
            .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted, perform: drop)
        }
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .onAppear {
            focused = true
            installKeyMonitor()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .onChange(of: pane.pickedElements.count) { old, new in if new > old { focused = true } }
        // Screenshots attached from the device panel.
        .onChange(of: pane.pendingAttachments.count) {
            guard !pane.pendingAttachments.isEmpty else { return }
            attachments += pane.pendingAttachments
            pane.pendingAttachments = []
            focused = true
        }
    }

    /// Elements picked in the preview; they go out with the next message.
    private var pickedElementChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pane.pickedElements) { reference in
                    HStack(spacing: 5) {
                        Image(systemName: reference.device == nil ? "cursorarrow.rays" : "iphone").font(.caption)
                        Text(reference.label).font(.caption).lineLimit(1)
                        Button { pane.pickedElements.removeAll { $0.id == reference.id } } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .help(reference.device ?? reference.selector)
                }
            }
            .padding(.horizontal, 10).padding(.top, 9)
        }
    }

    private var placeholder: String {
        switch pane.state {
        case .permission, .input, .plan: return "Answer the card above, or type to send a message"
        case .working: return "Claude is working. Messages you send now are queued."
        case _ where !pane.pickedElements.isEmpty: return "Say what to do with the picked element"
        default: return "Message Claude. Type / for commands, @ for files, // to message another session"
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

    private var fileMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Files · Tab or Return to mention").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            ForEach(Array(fileSuggestions.enumerated()), id: \.element) { index, path in
                let selected = index == highlighted
                Button { highlighted = index; _ = complete() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                        Text((path as NSString).lastPathComponent).fontWeight(.medium).lineLimit(1)
                        Text((path as NSString).deletingLastPathComponent).lineLimit(1).truncationMode(.head)
                            .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                        Spacer()
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

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { image in
                    HStack(spacing: 6) {
                        if let thumb = NSImage(data: image.data) {
                            Image(nsImage: thumb).resizable().scaledToFill().frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        Text(image.label).font(.caption).lineLimit(1).frame(maxWidth: 140)
                        Button { attachments.removeAll { $0.id == image.id } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove")
                    }
                    .padding(4).padding(.trailing, 2)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
                }
            }
            .padding(.horizontal, 12).padding(.top, 10)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button(action: pickFiles) { Image(systemName: "paperclip") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Attach images, or mention files (you can also paste or drop them)")
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
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                .disabled(!canSend)
                .help("Send (Return). Shift-Return starts a new line.")
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
        let files = fileSuggestions
        if !files.isEmpty {
            guard files.indices.contains(highlighted) else { return .ignored }
            draft = FileIndex.complete(draft, with: files[highlighted])
            return .handled
        }
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
        // Return while choosing a file mentions it instead of sending.
        if !fileSuggestions.isEmpty { _ = complete(); return }
        // Return on a partially typed command picks the highlighted one first.
        if !suggestions.isEmpty, suggestions.indices.contains(highlighted), text != "/\(suggestions[highlighted].name)" {
            _ = complete()
            return
        }
        guard !text.isEmpty || !attachments.isEmpty else { return }
        draft = ""
        menuDismissed = false
        // Picked elements ride along with anything that reaches Claude, but not with commands like /model.
        let carries: Bool
        switch SlashRouter.route(text, commands: pane.chat.commands) {
        case .send: carries = true
        case .setMode(_, let then): carries = then != nil
        default: carries = false
        }
        let message = carries ? ElementReference.compose(text, with: pane.pickedElements) : text
        if model.submit(message, images: attachments, in: pane) {
            attachments = []
            if carries { pane.pickedElements = [] }
        }
    }

    // MARK: Attachments

    /// Images become attachments; other files and folders are mentioned by path, which the CLI reads itself.
    private func add(_ urls: [URL]) {
        var mentions: [String] = []
        for url in urls {
            if let image = ImageAttachment(fileURL: url) { attachments.append(image); continue }
            let path = url.path.hasPrefix(pane.cwd + "/") ? String(url.path.dropFirst(pane.cwd.count + 1)) : url.path
            mentions.append(path.contains(" ") ? "@\"\(path)\"" : "@\(path)")
        }
        guard !mentions.isEmpty else { return }
        let separator = draft.isEmpty || draft.last?.isWhitespace == true ? "" : " "
        draft += separator + mentions.joined(separator: " ") + " "
        fileMenuDismissed = true
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: pane.cwd)
        panel.prompt = "Attach"
        if panel.runModal() == .OK { add(panel.urls) }
        focused = true
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in add([url]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let image = ImageAttachment(data: data, label: "Dropped image") else { return }
                    Task { @MainActor in attachments.append(image) }
                }
            }
        }
        return !providers.isEmpty
    }

    /// ⌘V with files or an image on the pasteboard attaches them; text pastes as usual.
    /// Shift-Return starts a new line, as Option-Return does; Return alone sends.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard focused else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Return or the keypad's Enter. The field editor inserts at the cursor, replacing any selection.
            if modifiers == .shift, [36, 76].contains(event.keyCode), let editor = event.window?.firstResponder as? NSTextView {
                editor.insertNewlineIgnoringFieldEditor(nil)
                return nil
            }
            guard modifiers == .command, event.charactersIgnoringModifiers == "v" else { return event }
            let board = NSPasteboard.general
            if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                add(urls)
                return nil
            }
            if board.string(forType: .string) == nil, let data = board.data(forType: .png) ?? board.data(forType: .tiff),
               let image = ImageAttachment(data: data, label: "Pasted image") {
                attachments.append(image)
                return nil
            }
            return event
        }
    }
}
