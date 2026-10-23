import SwiftUI
import ViberCore

/// Timeline of every `//` message sent between sessions, newest first.
struct MessagesView: View {
    @Environment(AppModel.self) private var model

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", waiting = "Waiting", replied = "Replied"
        var id: Self { self }

        func matches(_ record: RelayRecord) -> Bool {
            switch self {
            case .all: return true
            case .waiting: return record.status == .queued || record.status == .delivered
            case .replied: return record.status == .replied
            }
        }
    }

    @State private var filter: Filter = .all
    @State private var search = ""

    private var filtered: [RelayRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.relayLog.records.reversed().filter { record in
            guard filter.matches(record) else { return false }
            guard !query.isEmpty else { return true }
            return [record.sourceTitle, record.targetTitle, record.text, record.reply ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// Records grouped by calendar day of when they were sent, newest day first.
    private var days: [(day: Date, records: [RelayRecord])] {
        let calendar = Calendar.current
        var result: [(day: Date, records: [RelayRecord])] = []
        for record in filtered {
            let day = calendar.startOfDay(for: record.sentAt)
            if let last = result.last, last.day == day {
                result[result.count - 1].records.append(record)
            } else {
                result.append((day, [record]))
            }
        }
        return result
    }

    var body: some View {
        Group {
            if model.relayLog.records.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        controls
                        let days = days
                        if days.isEmpty {
                            Text("No messages match.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                        ForEach(days, id: \.day) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(Self.dayTitle(group.day))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                                ForEach(group.records) { record in
                                    RelayRow(record: record)
                                }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("Messages")
        .onAppear { model.markMessagesSeen() }
        .onChange(of: model.relayLog.records.count) { model.markMessagesSeen() }
        .onChange(of: model.relayLog.records.last?.updatedAt) { model.markMessagesSeen() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Messages between sessions").font(.title2.weight(.semibold))
            Text("Type // in any chat to message another session.").foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
            TextField("Search messages", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No messages yet").font(.title3.weight(.semibold))
            Text("Start a message with // in any chat to send it to another session. Replies come back automatically.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .complete, time: .omitted)
    }
}

/// One message and its reply, as a card.
struct RelayRow: View {
    @Environment(AppModel.self) private var model
    let record: RelayRecord

    @State private var showFullText = false
    @State private var showFullReply = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(record.sentAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                paneLink(id: record.sourceID, title: record.sourceTitle)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                paneLink(id: record.targetID, title: record.targetTitle)
                Spacer(minLength: 8)
                RelayStatusChip(status: record.status)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(record.text)
                    .textSelection(.enabled)
                    .lineLimit(showFullText ? nil : 6)
                    .fixedSize(horizontal: false, vertical: true)
                if Self.isLong(record.text) {
                    ExpandButton(expanded: $showFullText)
                }
            }

            if let reply = record.reply {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("↩ \(record.targetTitle) replied")
                        if let repliedAt = record.repliedAt {
                            Text("· \(Self.relative(repliedAt, now: model.now))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    let long = Self.isLong(reply)
                    MarkdownText(text: reply)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(maxHeight: long && !showFullReply ? 120 : nil, alignment: .top)
                        .clipped()
                    if long {
                        ExpandButton(expanded: $showFullReply)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                .padding(.leading, 16)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    @ViewBuilder
    private func paneLink(id: String, title: String) -> some View {
        let exists = model.pane(id) != nil
        Button(title) { model.select(.pane(id)) }
            .buttonStyle(.borderless)
            .fontWeight(.medium)
            .foregroundStyle(exists ? Color.accentColor : Color.secondary)
            .disabled(!exists)
            .lineLimit(1)
            .help(exists ? "Open \(title)" : "\(title) is no longer open")
    }

    /// Heuristic for whether text is likely to exceed ~6 lines in the card.
    static func isLong(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).count > 6 || text.count > 480
    }

    static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
    }
}

private struct ExpandButton: View {
    @Binding var expanded: Bool

    var body: some View {
        Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
            .buttonStyle(.borderless)
            .font(.caption)
    }
}

struct RelayStatusChip: View {
    let status: RelayRecord.Status

    private var color: Color {
        switch status {
        case .queued: return .orange
        case .delivered: return .blue
        case .replied: return .green
        case .noReply: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if status == .delivered {
                ProgressView().controlSize(.mini)
            }
            Text(status.label)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
        .fixedSize()
    }
}
