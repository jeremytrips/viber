import AppKit
import SwiftUI
import ViberCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` starts a bare executable; make it a regular app with a Dock icon and menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct ViberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Viber", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 560)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session…") { model.showNewSession = true }.keyboardShortcut("n")
                Button("Resume Session…") { model.reloadRecent(); model.showResume = true }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Session") {
                Button("Jump to Session…") { model.showSwitcher = true }.keyboardShortcut("k")
                Button("Next Session Waiting for You") { model.selectNextWaiting() }.keyboardShortcut("j")
                Button("Show Messages") { model.select(.messages) }.keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                Button("Stop Claude") { model.selectedPane?.interrupt() }.keyboardShortcut(".")
                Button("Open Folder in VS Code") {
                    if let pane = model.selectedPane { model.openInVSCode(pane.cwd) }
                    else if let session = model.selectedExternal { model.openInVSCode(session.project) }
                }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Close Session…") { if let pane = model.selectedPane { model.requestClose(pane) } }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Divider()
                ForEach(1..<10) { n in
                    Button("Session \(n)") { model.select(index: n - 1) }.keyboardShortcut(KeyEquivalent(Character("\(n)")))
                }
            }
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            Group {
                if model.selection == .messages {
                    MessagesView()
                } else if let pane = model.selectedPane {
                    PaneView(pane: pane).id(pane.id)
                } else if let session = model.selectedExternal {
                    ExternalView(session: session).id(session.id)
                } else {
                    EmptyStateView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { UsageBar() }
            }
        }
        .sheet(isPresented: $model.showNewSession) { NewSessionSheet() }
        .sheet(isPresented: $model.showResume) { ResumeSheet() }
        .sheet(isPresented: $model.showSwitcher) { QuickSwitcher() }
        .sheet(item: $model.closing) { pane in CloseSheet(pane: pane) }
        .alert("Viber", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No session selected").font(.title3.weight(.semibold))
            Text("Start a new Claude Code session, or resume one you ran before.")
                .foregroundStyle(.secondary)
            HStack {
                Button("New Session") { model.showNewSession = true }.keyboardShortcut(.defaultAction)
                Button("Resume…") { model.reloadRecent(); model.showResume = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
