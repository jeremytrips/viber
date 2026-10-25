import SwiftUI
import ViberCore

/// The toolbar's account button: usage for the selected chat's account (else the selected project's, else clauth's
/// default), with every account in a popover, where the project's account can be switched.
struct UsageBar: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    /// The chat's account; nil when the chat uses the plain `claude` login, which clauth has no usage for.
    private var active: ClauthStatus.Profile? {
        guard let name = model.shownProfileName else { return nil }
        return model.profiles.first { $0.name == name }
    }
    /// The selected chat, or the selected project's new sessions, use the plain `claude` login.
    private var plain: Bool {
        model.shownProfileName == nil && (model.selectedPane != nil || model.selectedProject != nil && model.status != nil)
    }
    private var brokenCount: Int { model.profiles.filter { $0.loginProblem != nil }.count }

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
                if active.loginProblem != nil {
                    Text(active.loginProblem!).font(.caption).foregroundStyle(.red)
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
            } else if plain {
                StatusDot(color: .secondary)
                Text("Default login").font(.callout.weight(.medium))
            } else {
                Text(model.statusNote ?? "Loading accounts…").font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Red when this account needs a login, orange when its data is out of date.
    private var dotColor: Color {
        if active?.loginProblem != nil { return .red }
        if model.statusNote != nil || active?.stale == true { return .orange }
        return .green
    }

    private var helpText: String {
        let subject = model.selectedPane != nil ? "This chat's account"
            : model.selectedProject.map { "\(model.projectName($0))'s account. Click to switch it" } ?? "Default account"
        if brokenCount == 1 { return "\(subject). One account needs you to log in again" }
        if brokenCount > 1 { return "\(subject). \(brokenCount) accounts need you to log in again" }
        if active == nil, plain {
            return (model.selectedPane != nil ? "This chat uses" : "New sessions here use") + " the plain claude login, which clauth has no usage for"
        }
        return model.statusNote ?? subject
    }
}

private struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

/// A label, a short bar and the percentage, sized for the toolbar.
private struct MiniMeter: View {
    let window: ClauthStatus.Window

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
    /// The 5h and 7d windows, or the first two when clauth labels them differently.
    static func main(_ profile: ClauthStatus.Profile) -> [ClauthStatus.Window] {
        let all = profile.windows ?? []
        let main = all.filter { ["5h", "7d"].contains($0.label) }
        return main.isEmpty ? Array(all.prefix(2)) : main
    }

    static func emptyText(_ profile: ClauthStatus.Profile) -> String {
        switch profile.fetchStatus {
        case "Failed": return "Usage unavailable"
        case nil: return "Fetching usage…"
        default: return "No usage yet"
        }
    }

    static func color(_ pct: Double) -> Color {
        pct >= 90 ? .red : pct >= 75 ? .orange : .accentColor
    }

    static func resetText(_ window: ClauthStatus.Window, now: Date) -> String {
        guard let reset = window.resetDate else { return "" }
        return "resets in " + AppModel.span(reset.timeIntervalSince(now))
    }
}

/// Every clauth account: usage, reset times, and a way to log in again. With a project selected, its account too.
private struct AccountsPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Accounts").font(.headline).padding([.horizontal, .top], 14).padding(.bottom, 8)
            if let project = model.selectedProject {
                HStack(spacing: 8) {
                    Text("\(model.projectName(project)) uses").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    ProjectAccountPicker(project: project).labelsHidden().fixedSize()
                }
                .font(.callout)
                .padding(.horizontal, 14).padding(.bottom, 10)
                // The alert that offers to move the open sessions shows in the window.
                .onChange(of: model.accountMove?.id) { if model.accountMove != nil { dismiss() } }
                Divider()
            }
            if model.profiles.isEmpty {
                Text(model.statusNote ?? "Loading accounts…").font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 14)
            }
            ForEach(Array(model.profiles.enumerated()), id: \.element.id) { index, profile in
                if index > 0 { Divider().padding(.horizontal, 14) }
                AccountRow(profile: profile, active: profile.name == model.shownProfileName,
                           badge: profile.name == model.shownProfileName && model.selectedPane != nil ? "This chat"
                               : profile.name == model.shownProfileName && model.selectedProject != nil ? "This project"
                               : profile.name == model.defaultProfile ? "Default" : nil,
                           loggingIn: model.loggingIn.contains(profile.name), now: model.now) { model.login(profile.name) }
            }
            Divider()
            footer.padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 320)
    }

    @ViewBuilder private var footer: some View {
        if let note = model.statusNote {
            Label(note, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(updatedText).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var updatedText: String {
        guard let date = Dates.parse(model.status?.generatedAt) else { return "Usage from clauth" }
        let seconds = model.now.timeIntervalSince(date)
        if seconds < 60 { return "Updated just now" }
        return "Updated " + RelativeDateTimeFormatter().localizedString(for: date, relativeTo: model.now)
    }
}

private struct AccountRow: View {
    let profile: ClauthStatus.Profile
    let active: Bool
    let badge: String?
    let loggingIn: Bool
    let now: Date
    let login: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor).opacity(active ? 1 : 0)
                Text(profile.name).font(.callout.weight(.semibold))
                if let tier = profile.tier { Text(tier).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let badge { Text(badge).font(.caption).foregroundStyle(.secondary) }
            }
            Group {
                if loggingIn {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in your browser…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let problem = profile.loginProblem {
                    HStack {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                        Spacer()
                        Button("Log In…", action: login).controlSize(.small)
                    }
                } else if (profile.windows ?? []).isEmpty {
                    Text(UsageWindows.emptyText(profile)).font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(profile.windows ?? [], id: \.label) { window in
                            WindowRow(window: window, now: now)
                        }
                    }
                }
            }
            .padding(.leading, 18)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .opacity(profile.stale == true ? 0.7 : 1)
        .contextMenu {
            if profile.loginProblem == nil { Button("Log In Again…", action: login).disabled(loggingIn) }
        }
    }
}

private struct WindowRow: View {
    let window: ClauthStatus.Window
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
