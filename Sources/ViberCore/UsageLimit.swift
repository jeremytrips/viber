import Foundation

/// A turn that stopped at the account's plan limit (the 5-hour session limit, a weekly one), and when Claude can go on.
/// The CLI says when the limit lifts in a `rate_limit_event`; its error message says it too ("resets 11:30pm (Europe/Paris)").
public struct UsageLimit: Codable, Equatable, Sendable {
    /// When the limit lifts. Nil when the CLI didn't say.
    public var resetsAt: Date?
    /// The CLI's name for the limit: five_hour, seven_day, seven_day_opus…
    public var kind: String?
    /// Turns in a row that ended at a limit, this one included. More than one means the limit outlasted
    /// the reset time Viber waited for.
    public var hits: Int

    public init(resetsAt: Date?, kind: String?, hits: Int = 1) {
        self.resetsAt = resetsAt; self.kind = kind; self.hits = hits
    }

    /// After this many turns in a row stop at a limit, Viber stops waiting it out: the reset times aren't working.
    public static let maxHits = 4
    /// Sent once the limit has lifted.
    public static let continueMessage = "The usage limit has reset. Carry on where you left off."
    /// After the reset time, so the first request lands in the new window.
    static let margin: TimeInterval = 60
    /// How long to wait when the CLI didn't say when the limit lifts.
    static let unknownWait: TimeInterval = 30 * 60
    /// Added each time the limit was still there when Viber carried on.
    static let backoff: TimeInterval = 5 * 60

    /// When to send the session on: just after the reset, later each time the limit outlasted it. Nil once that kept happening.
    public func continueAt(now: Date) -> Date? {
        guard hits <= Self.maxHits else { return nil }
        let reset = resetsAt ?? now.addingTimeInterval(Self.unknownWait)
        let earliest = now.addingTimeInterval(Self.backoff * Double(hits - 1))
        return max(reset, earliest).addingTimeInterval(Self.margin)
    }

    /// "session limit", as Claude Code calls the 5-hour window, "weekly limit"…
    public var name: String {
        switch kind {
        case "five_hour": return "session limit"
        case "seven_day": return "weekly limit"
        case "seven_day_opus": return "Opus weekly limit"
        case "seven_day_sonnet": return "Sonnet weekly limit"
        default: return "usage limit"
        }
    }

    /// The limit a `rate_limit_info` object describes, if it turns requests away.
    static func rejected(_ info: JSON?) -> (resetsAt: Date?, kind: String?)? {
        guard let info, info["status"]?.string == "rejected" else { return nil }
        return (info["resetsAt"]?.double.map(Date.init(timeIntervalSince1970:)), info["rateLimitType"]?.string)
    }

    /// The reset time in the CLI's error text, for when no `rate_limit_event` said it:
    /// "You've hit your session limit · resets 11:30pm (Europe/Paris)", or older CLIs' "Claude AI usage limit reached|1729789200".
    static func resetTime(in text: String, now: Date) -> Date? {
        if let epoch = match(#"limit reached\|(\d{9,})"#, in: text)?.first.flatMap(Double.init) {
            return Date(timeIntervalSince1970: epoch)
        }
        guard let parts = match(#"resets (\d{1,2})(?::(\d{2}))? ?([ap]m)(?: \(([^)]+)\))?"#, in: text),
              let hour12 = Int(parts[0]), (1...12).contains(hour12) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: parts[3]) ?? .current
        let hour = hour12 % 12 + (parts[2].lowercased() == "pm" ? 12 : 0)
        guard let today = calendar.date(bySettingHour: hour, minute: Int(parts[1]) ?? 0, second: 0, of: now) else { return nil }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    /// The pattern's capture groups, "" for one that didn't take part.
    private static func match(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<found.numberOfRanges).map { index in
            Range(found.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
