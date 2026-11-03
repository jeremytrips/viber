import SwiftUI
import ViberCore

/// The toolbar's account button: usage for the selected chat's account (else the one a new chat in the selected project
/// would start on), with every account in a popover, where accounts are added and the chat's account is switched.
struct UsageBar: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    /// The chat's account; nil when the chat uses the plain `claude` login, which Viber has no usage for.
    private var active: AccountStatus? { model.shownProfileName.flatMap { model.status(of: $0) } }
    /// The selected chat, or a new chat in the selected project, uses the plain `claude` login.
    private var plain: Bool { model.shownProfileName == nil && (model.selectedPane != nil || model.selectedProject != nil) }
    private var brokenCount: Int { model.accounts.filter { $0.loginProblem != nil }.count }

    var body: some View {
        Button { showing.toggle() } label: { label }
            .buttonStyle(.plain)
            .help(helpText)
            .popover(isPresented: $showing, arrowEdge: .bottom) { AccountsPopover() }
    }

    @ViewBuilder private var label: some View {
        HStack(spacing: 8) {
            if let active {
                StatusDot(color: dotColor)
                Text(active.name).font(.callout.weight(.medium))
                if let problem = active.loginProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                } else {
                    let windows = UsageWindows.main(active)
                    if windows.isEmpty {
                        Text(UsageWindows.emptyText(active)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(windows, id: \.label) { MiniMeter(window: $0) }
                        }
                    }
                }
            } else if plain || model.shownProfileName == nil {
                StatusDot(color: .secondary)
                Text(model.accounts.isEmpty ? "Add an account" : "Default login").font(.callout.weight(.medium))
            } else {
                Text(model.shownProfileName ?? "").font(.callout.weight(.medium))
            }
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Red when this account needs a login, orange when its usage couldn't be read.
    private var dotColor: Color {
        if active?.loginProblem != nil { return .red }
        if active?.fetchFailed == true { return .orange }
        return .green
    }

    private var helpText: String {
        let subject = model.selectedPane != nil ? "This chat's account. Click to switch it"
            : model.selectedProject.map { "The account a new chat in \(model.projectName($0)) starts on" } ?? "Accounts"
        if brokenCount == 1 { return "\(subject). One account needs you to log in again" }
        if brokenCount > 1 { return "\(subject). \(brokenCount) accounts need you to log in again" }
        if active == nil, plain {
            return (model.selectedPane != nil ? "This chat uses" : "New chats here use") + " the plain claude login, which Viber has no usage for"
        }
        return subject
    }
}

private struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

/// A label, a short bar and the percentage, sized for the toolbar.
private struct MiniMeter: View {
    let window: UsageWindow

    var body: some View {
        let pct = window.utilizationPct ?? 0
        HStack(spacing: 5) {
            Text(window.label).frame(width: 14, alignment: .leading).foregroundStyle(.secondary)
            UsageBarShape(pct: pct).frame(width: 46, height: 4)
            Text("\(Int(pct.rounded()))%").frame(width: 28, alignment: .trailing)
        }
        .font(.system(size: 9).monospacedDigit())
    }
}

private struct UsageBarShape: View {
    let pct: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(UsageWindows.color(pct)).frame(width: geo.size.width * min(1, pct / 100))
            }
        }
    }
}

enum UsageWindows {
    /// The 5h and 7d windows, or the first two when there are neither.
    static func main(_ account: AccountStatus) -> [UsageWindow] {
        let main = account.windows.filter { ["5h", "7d"].contains($0.label) }
        return main.isEmpty ? Array(account.windows.prefix(2)) : main
    }

    static func emptyText(_ account: AccountStatus) -> String {
        if account.fetchFailed { return "Usage unavailable" }
        if account.fetchedAt == nil { return "Fetching usage…" }
        return "No usage yet"
    }

    static func color(_ pct: Double) -> Color {
        pct >= 90 ? .red : pct >= 75 ? .orange : .accentColor
    }

    static func resetText(_ window: UsageWindow, now: Date) -> String {
        guard let reset = window.resetsAt else { return "" }
        return "resets in " + AppModel.span(reset.timeIntervalSince(now))
    }
}

/// Every account: usage, reset times, logging in, and whether new chats are picked onto it. With a chat selected, its
/// account, to switch; with a project, the accounts its new chats may start on.
private struct AccountsPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Accounts").font(.headline).padding([.horizontal, .top], 14).padding(.bottom, 8)
            if let pane = model.selectedPane {
                ChatAccount(pane: pane)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.bottom, 10)
                Divider()
            } else if let project = model.selectedProject {
                VStack(alignment: .leading, spacing: 8) {
                    Text("New chats in \(model.projectName(project)) start on the least used of").lineLimit(2)
                    ProjectAutomaticAccounts(project: project).font(.caption)
                }
                .font(.callout)
                .padding(.horizontal, 14).padding(.bottom, 10)
                Divider()
            }
            if model.accounts.isEmpty && !adding {
                Text("No accounts yet. Add each Claude account once; Viber keeps it signed in.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Divider().padding(.horizontal, 14) }
                AccountRow(account: account, active: account.name == model.shownProfileName,
                           badge: account.name == model.shownProfileName && model.selectedPane != nil ? "This chat"
                               : account.name == model.shownProfileName && model.selectedProject != nil ? "Next chat" : nil,
                           loggingIn: model.loggingIn.contains(account.name), now: model.now)
            }
            Divider()
            if adding {
                AddAccountForm { adding = false }.padding(14)
                Divider()
            }
            HStack {
                Text(updatedText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !adding { Button("Add Account…") { adding = true }.controlSize(.small) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 340)
    }

    private var updatedText: String {
        guard let date = model.accounts.compactMap(\.fetchedAt).max() else { return "Usage from Anthropic" }
        let seconds = model.now.timeIntervalSince(date)
        if seconds < 60 { return "Updated just now" }
        return "Updated " + RelativeDateTimeFormatter().localizedString(for: date, relativeTo: model.now)
    }
}

/// The selected chat's account, to switch it, and whether Viber may move it to the least-used account when this one
/// runs low.
private struct ChatAccount: View {
    @Environment(AppModel.self) private var model
    let pane: Pane

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("This chat runs on").lineLimit(1).layoutPriority(1)
                AccountPicker(selection: Binding(get: { pane.spec.profile }, set: { model.setAccount($0, for: pane) }),
                              best: model.bestAccount(for: pane.projectPath))
                    .labelsHidden()
            }
            Toggle("Move it to the least-used account when this one runs low",
                   isOn: Binding(get: { pane.spec.autoAccount == true }, set: { model.setAutoAccount($0, for: pane) }))
                .toggleStyle(.checkbox)
                .font(.caption)
            Text("Switching restarts Claude on the other account and keeps the conversation; a busy chat moves once it's done. Its next message reads the conversation again, uncached.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A name for the account, the address to sign in with, and whether new chats are picked onto it. Adding opens the browser.
private struct AddAccountForm: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void
    @State private var name = ""
    @State private var email = ""
    @State private var automatic = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name, such as creator1", text: $name)
            TextField("Email (optional, fills in the sign-in page)", text: $email)
            Toggle("Picked for new chats", isOn: $automatic)
                .help("New chats start on the least used of these accounts. Leave it off for a personal account, used only when you choose it.")
            Text("Your browser opens to sign in. Check it is signed in to this account's address, or the wrong account gets saved under this name.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: done)
                Button("Add and Log In") {
                    model.addAccount(name.trimmingCharacters(in: .whitespaces), email: email.trimmingCharacters(in: .whitespaces), automatic: automatic)
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!Accounts.isValidName(name.trimmingCharacters(in: .whitespaces)))
            }
            .controlSize(.small)
        }
        .textFieldStyle(.roundedBorder)
        .font(.callout)
    }
}

private struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let account: AccountStatus
    let active: Bool
    let badge: String?
    let loggingIn: Bool
    let now: Date
    @State private var confirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor).opacity(active ? 1 : 0)
                Text(account.name).font(.callout.weight(.semibold))
                if let tier = account.tier { Text(tier).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let badge { Text(badge).font(.caption).foregroundStyle(.secondary) }
                if !account.automatic {
                    Text("Only when chosen").font(.caption).foregroundStyle(.secondary)
                        .help("New chats never start here unless you choose it in New Session, or switch a chat to it")
                }
            }
            Group {
                if let email = account.email { Text(email).font(.caption).foregroundStyle(.secondary) }
                if loggingIn {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in your browser…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let problem = account.loginProblem {
                    HStack {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                        Spacer()
                        Button("Log In…") { model.login(account.name) }.controlSize(.small)
                    }
                } else if account.windows.isEmpty {
                    Text(UsageWindows.emptyText(account)).font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(account.windows, id: \.label) { window in
                            WindowRow(window: window, now: now)
                        }
                    }
                }
            }
            .padding(.leading, 18)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .opacity(account.fetchFailed ? 0.7 : 1)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Log In Again…") { model.login(account.name) }.disabled(loggingIn)
            Toggle("Picked for New Chats", isOn: Binding(get: { account.automatic }, set: { model.setAutomatic(account.name, $0) }))
            Divider()
            Button("Remove…", role: .destructive) { confirmingRemove = true }
        }
        .confirmationDialog("Remove \(account.name)?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { model.removeAccount(account.name) }
        } message: {
            Text("Viber signs it out and forgets it. Sessions on it stay open and ask you to log in.")
        }
    }
}

private struct WindowRow: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        let pct = window.utilizationPct ?? 0
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label)
                Spacer()
                Text("\(Int(pct.rounded()))%").fontWeight(.medium)
                Text(UsageWindows.resetText(window, now: now)).foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())
            UsageBarShape(pct: pct).frame(height: 5)
        }
    }
}
