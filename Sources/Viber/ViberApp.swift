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
                Button("New Chat") { if let path = model.selectedProject { model.newChat(in: path) } }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(model.selectedProject == nil)
                Button("Add Project…") { model.chooseProject() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Resume Session…") { model.reloadRecent(); model.showResume = true }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Session") {
                Button("Jump to Session…") { model.showSwitcher = true }.keyboardShortcut("k")
                Button("Next Session Waiting for You") { model.selectNextWaiting() }.keyboardShortcut("j")
                Button("Show Issues") { model.select(.issues) }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Show Project") { if let path = model.selectedProject { model.select(.project(path)) } }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.selectedProject == nil || model.selectedProjectPage != nil)
                Divider()
                Button("Stop Claude") { model.selectedPane?.interrupt() }.keyboardShortcut(".")
                Button("Open Folder in VS Code") {
                    if let pane = model.selectedPane { model.openInVSCode(pane.cwd) }
                    else if let session = model.selectedExternal { model.openInVSCode(session.project) }
                }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Close Session…") { if let pane = model.selectedPane { model.requestClose(pane) } }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Button("Session Settings…") { if let pane = model.selectedPane { model.openSettings(.model, in: pane) } }
                    .keyboardShortcut(",", modifiers: [.command, .option])
                    .disabled(model.selectedPane == nil)
                Divider()
                Button(model.selectedPane?.showPreview == true ? "Hide Browser Preview" : "Show Browser Preview") {
                    model.selectedPane?.togglePreview()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(model.selectedPane == nil)
                Button("Reload Preview") { model.selectedPane?.preview?.reload() }
                    .keyboardShortcut("r")
                    .disabled(model.selectedPane?.showPreview != true)
                Button("Pick Element in Preview") { model.selectedPane?.preview?.togglePicking() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.selectedPane?.showPreview != true || model.selectedPane?.preview?.pageURL == nil)
                Divider()
                Button(model.selectedPane?.showDevice == true ? "Hide Device" : "Show Device") {
                    model.selectedPane?.toggleDevice()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.selectedPane == nil)
                Button("Device Home") { Task { try? await model.selectedPane?.deviceController?.press(.home) } }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(model.selectedPane?.showDevice != true || model.selectedPane?.deviceController?.device.isBooted != true)
                Button("Attach Device Screenshot") { model.selectedPane?.attachDeviceScreenshot() }
                    .disabled(model.selectedPane?.showDevice != true || model.selectedPane?.deviceController?.isStreaming != true)
                Divider()
                ForEach(1..<10) { n in
                    Button("Session \(n)") { model.select(index: n - 1) }.keyboardShortcut(KeyEquivalent(Character("\(n)")))
                }
            }
        }

        // Settings that are not about one conversation (⌘, or the gear at the bottom of the sidebar).
        Settings {
            GlobalSettingsView().environment(model)
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var renameDraft = ""
    @State private var sheetRoom: CGFloat?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            Group {
                if model.selection == .issues {
                    IssuesView()
                } else if let path = model.selectedProjectPage {
                    ProjectView(path: path).id(path)
                } else if let pane = model.selectedPane {
                    PaneView(pane: pane).id(pane.id)
                } else if let session = model.selectedExternal {
                    ExternalView(session: session).id(session.id)
                } else if let job = model.selectedJob {
                    WorktreeJobView(job: job).id(job.id)
                } else {
                    EmptyStateView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { UsageBar() }
            }
        }
        // Sheets hang from the toolbar; leave a margin under them.
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { sheetRoom = max($0 - 40, 360) }
        .sheet(isPresented: $model.showNewSession) { NewSessionSheet() }
        .sheet(isPresented: $model.showResume) { ResumeSheet() }
        .sheet(isPresented: $model.showSwitcher) { QuickSwitcher() }
        .sheet(item: $model.closing) { pane in CloseSheet(pane: pane) }
        .sheet(item: $model.autopilotSheet) { request in AutopilotSheet(request: request) }
        .sheet(item: $model.jiraRunSheet) { request in JiraRunSheet(request: request) }
        .sheet(item: $model.settingsSheet) { request in
            if let pane = model.pane(request.paneID) { SessionSettingsSheet(pane: pane, tab: request.tab) }
        }
        .environment(\.sheetRoom, sheetRoom)
        .alert("Rename Project", isPresented: Binding(get: { model.renamingProject != nil }, set: { if !$0 { model.renamingProject = nil } })) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                if let path = model.renamingProject { model.renameProject(path, to: renameDraft) }
                model.renamingProject = nil
            }
            Button("Cancel", role: .cancel) { model.renamingProject = nil }
        } message: {
            Text("Only Viber uses this name. Leave it empty to show the folder's name.")
        }
        .onChange(of: model.renamingProject) { _, path in
            if let path { renameDraft = model.projectName(path) }
        }
        .alert("Still blocked", isPresented: Binding(get: { model.blockedStart != nil }, set: { if !$0 { model.blockedStart = nil } }),
               presenting: model.blockedStart) { issue in
            Button("Start Anyway") { model.plan(issue); model.blockedStart = nil }
            Button("Cancel", role: .cancel) { model.blockedStart = nil }
        } message: { issue in
            let blockers = model.issues.blockers(of: issue)
            Text("\(issue.key) is blocked by " + blockers.map { "\($0.key) (\($0.status.label.lowercased()))" }.joined(separator: ", ")
                 + ". The session will know, but it can't build on work that isn't there.")
        }
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
            if model.sidebarProjects.isEmpty {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Add your first project").font(.title3.weight(.semibold))
                Text("A project is a folder or git repository. Its sessions, worktrees and issues stay together in the sidebar.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                HStack {
                    Button("Add Project…") { model.chooseProject() }.keyboardShortcut(.defaultAction)
                    Button("Resume…") { model.reloadRecent(); model.showResume = true }
                }
            } else {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Nothing selected").font(.title3.weight(.semibold))
                Text("Pick a project or a session in the sidebar, or start a new session.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("New Session") { model.showNewSession = true }.keyboardShortcut(.defaultAction)
                    Button("Resume…") { model.reloadRecent(); model.showResume = true }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
