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
                ProfileUsage(profile: profile, active: profile.name == model.status?.activeProfile, now: model.now)
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

    private var windows: [ClauthStatus.Window] {
        let all = profile.windows ?? []
        let main = all.filter { ["5h", "7d"].contains($0.label) }
        return main.isEmpty ? Array(all.prefix(2)) : main
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(profile.name).font(.caption.weight(.semibold))
                Text(profile.tier ?? "").font(.caption2).foregroundStyle(.secondary)
            }
            if let problem = profile.loginProblem {
                Text(problem).font(.caption2).foregroundStyle(.red)
                    .help("Run: clauth login \(profile.name)")
            } else if windows.isEmpty {
                Text("No usage yet").font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(windows, id: \.label) { window in
                    Meter(window: window, now: now)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.1) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor)))
        .opacity(profile.stale == true ? 0.75 : 1)
        .help(profile.stale == true ? "\(profile.name): usage data is stale" : profile.name + (active ? " (active)" : ""))
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
