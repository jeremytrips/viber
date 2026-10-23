import Foundation

/// One `//` message between sessions, and the reply that came back.
public struct RelayRecord: Codable, Identifiable, Equatable {
    public enum Status: String, Codable {
        case queued, delivered, replied, noReply
        public var label: String {
            switch self {
            case .queued: return "Not read yet"
            case .delivered: return "Waiting for reply"
            case .replied: return "Replied"
            case .noReply: return "No reply"
            }
        }
    }
    public var id: String
    public var sourceID: String
    public var sourceTitle: String
    public var targetID: String
    public var targetTitle: String
    public var text: String
    public var sentAt: Date
    public var deliveredAt: Date?
    public var reply: String?
    public var repliedAt: Date?
    public var status: Status

    /// When anything last happened to this message, for ordering and unread counts.
    public var updatedAt: Date { repliedAt ?? deliveredAt ?? sentAt }
}

/// Every message sent between sessions, newest last. Persisted so the Messages panel survives relaunch.
public struct RelayLog: Codable, Equatable {
    public private(set) var records: [RelayRecord] = []
    public var lastSeen: Date = .distantPast
    public static let limit = 300

    public init() {}

    @discardableResult
    public mutating func add(source: (id: String, title: String), target: (id: String, title: String),
                             text: String, queued: Bool, at now: Date = Date()) -> String {
        let id = UUID().uuidString
        records.append(RelayRecord(id: id, sourceID: source.id, sourceTitle: source.title, targetID: target.id,
                                   targetTitle: target.title, text: text, sentAt: now,
                                   deliveredAt: queued ? nil : now, status: queued ? .queued : .delivered))
        if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
        return id
    }

    public mutating func markDelivered(_ id: String, at now: Date = Date()) {
        update(id) { if $0.status == .queued { $0.status = .delivered; $0.deliveredAt = now } }
    }

    public mutating func recordReply(_ id: String, text: String, at now: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) {
            $0.reply = trimmed.isEmpty ? nil : trimmed
            $0.repliedAt = now
            $0.status = trimmed.isEmpty ? .noReply : .replied
        }
    }

    public func record(_ id: String) -> RelayRecord? { records.first { $0.id == id } }

    public var unreadCount: Int { records.filter { $0.updatedAt > lastSeen }.count }

    /// Messages involving one session, for jumping from a chat to its history.
    public func records(for paneID: String) -> [RelayRecord] {
        records.filter { $0.sourceID == paneID || $0.targetID == paneID }
    }

    private mutating func update(_ id: String, _ change: (inout RelayRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
    }
}
