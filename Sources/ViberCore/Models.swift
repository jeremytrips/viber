// Copied from claude-cache/Sources/CompanionCore/Models.swift. Keep in sync by hand.
import Foundation

public enum SessionState: String, Codable {
    case working = "Working"
    case input = "Needs input"
    case plan = "Plan approval requested"
    case permission = "Needs permission"
    case finished = "Finished responding"
    case ended = "Session ended"
    case failed = "Response failed"

    public var alerts: Bool { [.input, .plan, .permission, .finished, .failed].contains(self) }
}

public struct CacheEstimate: Codable, Equatable {
    public var observedAt: Date
    public var ttl: TimeInterval
    public var basis: String
    public var generation: String
    public var expiresAt: Date { observedAt.addingTimeInterval(ttl) }
    public func remaining(at now: Date) -> TimeInterval { max(0, expiresAt.timeIntervalSince(now)) }
}

public struct Session: Identifiable, Codable {
    public var id: String
    public var project: String
    public var lastActivity: Date
    public var state: SessionState = .working
    public var stateAt: Date = .distantPast
    public var stateEventID = ""
    public var estimatedState = true
    public var cache: CacheEstimate?
    public var lastCacheMessage = ""
    public var cacheMessageAt: Date = .distantPast
    public var transcriptPath: String?
    /// The current turn was started by a background task or agent message, not by the user.
    public var automatedTurn = false
    public var turnStartedAt: Date = .distantPast
    public var projectName: String {
        let name = URL(fileURLWithPath: project).lastPathComponent
        return name.isEmpty ? "Unknown project" : name
    }
    public func isRecent(at now: Date) -> Bool {
        state != .ended && now.timeIntervalSince(lastActivity) < 86_400
    }
}

public struct Event {
    public var id: String
    public var sessionID: String
    public var project: String
    public var time: Date
    public var state: SessionState?
    public var estimated: Bool
    public var cacheTTL: TimeInterval?
    public var cacheBasis: String?
    public var messageID: String?
    public var transcriptPath: String?
    public var genericPermissionNotice: Bool = false
    /// Set only by rows that start a turn: true for task notifications and agent messages, false for the user.
    public var automatedTurn: Bool?
}

public enum Dates {
    public static func parse(_ value: Any?) -> Date? {
        if let number = value as? Double { return Date(timeIntervalSince1970: number) }
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

public enum Paths {
    public static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeCompanion")
    }
    public static var projects: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }
}
