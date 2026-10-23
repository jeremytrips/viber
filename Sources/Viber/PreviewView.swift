import AppKit
import SwiftUI
import ViberCore

/// The browser preview beside a session's chat: the user and Claude look at the same page.
struct PreviewView: View {
    let pane: Pane
    let preview: PreviewController
    @State private var address = ""
    @State private var showConsole = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack(alignment: .top) {
                Divider()
                if preview.isLoading {
                    ProgressView(value: max(preview.progress, 0.05)).progressViewStyle(.linear).controlSize(.small).frame(height: 2)
                }
            }
            .frame(height: 2)
            ZStack {
                PreviewHost(preview: preview)
                if let failure = preview.failure {
                    PreviewMessage(icon: "exclamationmark.triangle", title: "Could not open \(PreviewURL.short(preview.pageURL))", detail: failure) {
                        Button("Retry") { preview.reload() }.keyboardShortcut(.defaultAction)
                    }
                } else if preview.pageURL == nil {
                    EmptyPreview(pane: pane, preview: preview)
                }
            }
            .overlay(alignment: .bottom) {
                if let activity = preview.activity {
                    Label("Claude: \(activity)", systemImage: "sparkles")
                        .font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(.regularMaterial)).padding(10)
                } else if preview.picking {
                    Text("Click an element to attach it to your message. Esc cancels.")
                        .font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(.regularMaterial)).padding(10)
                }
            }
        }
        .onAppear { address = PreviewURL.short(preview.pageURL) }
        .onChange(of: preview.pageURL) { if !addressFocused { address = PreviewURL.short(preview.pageURL) } }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { preview.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!preview.canGoBack).help("Back")
            Button { preview.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!preview.canGoForward).help("Forward")
            Button { preview.isLoading ? preview.stop() : preview.reload() } label: {
                Image(systemName: preview.isLoading ? "xmark" : "arrow.clockwise")
            }
            .disabled(preview.pageURL == nil).help(preview.isLoading ? "Stop" : "Reload (⌘R)")
            TextField("localhost:5173", text: $address)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .focused($addressFocused)
                .onSubmit { preview.go(address); addressFocused = false }
            Button { preview.togglePicking() } label: {
                Image(systemName: "cursorarrow.rays").foregroundStyle(preview.picking ? Color.accentColor : Color.primary)
            }
            .disabled(preview.pageURL == nil).help("Pick an element to attach to your message (⇧⌘C)")
            Button { showConsole.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "terminal")
                    if preview.console.errorsThisPage > 0 {
                        Text("\(preview.console.errorsThisPage)").font(.caption2.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 4).background(Capsule().fill(Color.red)).foregroundStyle(.white)
                    }
                }
            }
            .help("Console")
            .popover(isPresented: $showConsole, arrowEdge: .bottom) { ConsolePopover(preview: preview) }
            Button { preview.openExternally() } label: { Image(systemName: "arrow.up.forward.square") }
                .disabled(preview.pageURL == nil).help("Open in your browser")
            Button { pane.showPreview = false } label: { Image(systemName: "sidebar.right") }
                .help("Hide the preview (⇧⌘B)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}

/// Puts the controller's long-lived web view into whichever container is on screen.
struct PreviewHost: NSViewRepresentable {
    let preview: PreviewController

    func makeCoordinator() -> PreviewController { preview }

    func makeNSView(context: Context) -> PreviewContainer {
        let container = PreviewContainer()
        container.preview = preview
        preview.attach(to: container)
        return container
    }

    func updateNSView(_ container: PreviewContainer, context: Context) {
        container.preview = preview
        if container.window != nil { preview.attach(to: container) }
    }

    static func dismantleNSView(_ container: PreviewContainer, coordinator: PreviewController) {
        coordinator.detach(from: container)
    }
}

/// Hands the web view back to the offscreen window whenever it leaves the screen, even when SwiftUI
/// drops the whole hierarchy without dismantling it, and takes it back when it returns.
final class PreviewContainer: NSView {
    weak var preview: PreviewController?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let preview else { return }
        if window == nil { preview.detach(from: self) } else { preview.attach(to: self) }
    }
}

struct PreviewMessage<Actions: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
            HStack { actions }.padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Before anything is open: local URLs the session's tools printed, like a dev server's.
struct EmptyPreview: View {
    let pane: Pane
    let preview: PreviewController

    var body: some View {
        let urls = pane.recentLocalURLs
        PreviewMessage(icon: "safari", title: "Browser preview",
                       detail: "Type a URL above, or ask Claude to start the dev server and open it here. Claude can take screenshots, read the console and click through the page you see.") {
            ForEach(urls.prefix(3), id: \.self) { url in
                Button("Open \(PreviewURL.short(url))") { preview.navigate(url) }
            }
        }
    }
}

struct ConsolePopover: View {
    let preview: PreviewController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Console").font(.headline)
                Spacer()
                Button("Clear") { preview.console.clear() }.disabled(preview.console.entries.isEmpty)
            }
            .padding(10)
            Divider()
            if preview.console.entries.isEmpty {
                Text("Nothing logged yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(preview.console.entries.suffix(300)) { entry in
                                row(entry).id(entry.id)
                            }
                        }
                        .padding(8)
                    }
                    .onAppear { proxy.scrollTo(preview.console.entries.last?.id, anchor: .bottom) }
                }
            }
        }
        .frame(width: 520, height: 360)
    }

    @ViewBuilder
    private func row(_ entry: ConsoleLog.Entry) -> some View {
        if entry.level == .navigation {
            Text(entry.text).font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 3)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.text + (entry.count > 1 ? "  ×\(entry.count)" : ""))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(entry.level == .error ? Color.red : entry.level == .warn ? Color.orange : Color.primary)
                    .textSelection(.enabled)
                    .lineLimit(12)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(entry.level == .error ? Color.red.opacity(0.07) : entry.level == .warn ? Color.orange.opacity(0.07) : .clear)
        }
    }
}
