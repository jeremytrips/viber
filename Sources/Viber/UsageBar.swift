import SwiftUI
import ViberCore

/// clauth usage for every account: 5h / 7d windows and when they reset.
struct UsageBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if model.profiles.isEmpty {
                Text(model.statusNote ?? "Loading usage…").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.profiles) { profile in
                ProfileUsage(profile: profile, active: profile.name == model.status?.activeProfile, now: model.now,
                             loggingIn: model.loggingIn.contains(profile.name)) { model.login(profile.name) }
            }
            if let note = model.statusNote, !model.profiles.isEmpty {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(note)
            }
        }
    }
}

struct ProfileUsage: View {
    let profile: ClauthStatus.Profile
    let active: Bool
    let now: Date
    let loggingIn: Bool
    let login: () -> Void

    private var windows: [ClauthStatus.Window] {
        let all = profile.windows ?? []
        let main = all.filter { ["5h", "7d"].contains($0.label) }
        return main.isEmpty ? Array(all.prefix(2)) : main
    }

    var body: some View {
        // A broken login makes the whole chip a button that starts the browser sign-in.
        Button { if profile.loginProblem != nil, !loggingIn { login() } } label: { chip }
            .buttonStyle(.plain)
            .contextMenu {
                Button(loggingIn ? "Waiting for browser sign-in…" : "Log In Again…", action: login).disabled(loggingIn)
            }
    }

    private var chip: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(profile.name).font(.caption.weight(.semibold))
                Text(profile.tier ?? "").font(.caption2).foregroundStyle(.secondary)
            }
            if loggingIn {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Finish in browser…").font(.caption2).foregroundStyle(.secondary)
                }
            } else if let problem = profile.loginProblem {
                VStack(alignment: .leading, spacing: 0) {
                    Text(problem).font(.caption2).foregroundStyle(.red)
                    Text("Click to log in").font(.caption2).foregroundStyle(Color.accentColor)
                }
            } else if windows.isEmpty {
                if profile.fetchStatus == "Failed" {
                    Text("Usage unavailable").font(.caption2).foregroundStyle(.orange)
                } else if profile.fetchStatus == nil {
                    Text("Fetching usage…").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("No usage yet").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                ForEach(windows, id: \.label) { window in
                    Meter(window: window, now: now)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.1) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor)))
        .contentShape(Rectangle())
        .opacity(profile.stale == true ? 0.75 : 1)
        .help(helpText)
    }

    private var helpText: String {
        if profile.loginProblem != nil { return "\(profile.name): click to log in again in your browser" }
        if profile.fetchStatus == "Failed" { return "\(profile.name): clauth could not fetch usage for this account" }
        if profile.stale == true { return "\(profile.name): usage data is stale" }
        return profile.name + (active ? " (active)" : "")
    }
}

struct Meter: View {
    let window: ClauthStatus.Window
    let now: Date

    var body: some View {
        let pct = window.utilizationPct ?? 0
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(window.label) \(Int(pct.rounded()))%")
                Spacer(minLength: 2)
                Text(resetText).foregroundStyle(.secondary)
            }
            .font(.system(size: 10).monospacedDigit())
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(pct >= 75 ? Color.orange : Color.accentColor)
                        .frame(width: geo.size.width * min(1, pct / 100))
                }
            }
            .frame(height: 4)
        }
        .frame(width: 92)
    }

    private var resetText: String {
        guard let reset = window.resetDate else { return "" }
        let seconds = max(0, reset.timeIntervalSince(now))
        let hours = Int(seconds / 3600), minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
