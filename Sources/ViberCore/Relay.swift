import Foundation

/// A session that a `//` message can be sent to.
public struct RelayCandidate: Equatable {
    public var id: String
    public var title: String
    public var project: String
    public var branch: String?
    /// Recent conversation text, used to guess which session a message is about.
    public var context: String

    public init(id: String, title: String, project: String, branch: String? = nil, context: String = "") {
        self.id = id; self.title = title; self.project = project; self.branch = branch; self.context = context
    }

    /// Names you can address the session by: its title, project and branch as slugs.
    var handles: [String] {
        [title, project, branch?.replacingOccurrences(of: "viber/", with: "") ?? ""]
            .map(Worktree.slug).filter { !$0.isEmpty }
    }
}

public struct RelaySuggestion: Equatable {
    public var candidate: RelayCandidate
    public var score: Double
    /// True when the message starts with this session's name; the name is then stripped from the message.
    public var addressed: Bool
    public var message: String
}

/// Where a `//` message stands, shown on its line in the sender's chat.
public enum RelayStatus: Equatable, Sendable {
    case queued, delivered, replied, noReply

    public var label: String {
        switch self {
        case .queued: return "delivered when its reply ends"
        case .delivered: return "waiting for reply"
        case .replied: return "replied"
        case .noReply: return "no reply"
        }
    }
}

/// `//message` routing: rank the other sessions by how well they match what you typed.
public enum Relay {
    public static func isRelay(_ text: String) -> Bool { text.hasPrefix("//") }

    public static func rank(_ raw: String, candidates: [RelayCandidate]) -> [RelaySuggestion] {
        guard isRelay(raw) else { return [] }
        let body = String(raw.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        let firstWord = body.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "," }).first.map { $0.lowercased() } ?? ""
        let rest = body.dropFirst(firstWord.count).drop { $0 == " " || $0 == ":" || $0 == "," }
        let words = tokens(body)

        var suggestions = candidates.map { candidate -> RelaySuggestion in
            let addressed = firstWord.count >= 2 && candidate.handles.contains { handle in
                // Only the start of a name counts; a word inside it ("firmware" in "ota-firmware-updates") is just content.
                handle == firstWord || handle.hasPrefix(firstWord)
            }
            var score: Double = addressed ? 100 : 0
            score += overlap(words, tokens(candidate.title)) * 3
            score += overlap(words, tokens(candidate.project + " " + (candidate.branch ?? ""))) * 2
            score += min(overlap(words, tokens(candidate.context)), 6)
            return RelaySuggestion(candidate: candidate, score: score, addressed: addressed,
                                   message: addressed ? String(rest) : body)
        }
        // Stable: ties keep the caller's order (most recently active first).
        let indexed = Array(suggestions.enumerated())
        let sorted = indexed.sorted { (a: (offset: Int, element: RelaySuggestion), b: (offset: Int, element: RelaySuggestion)) -> Bool in
            if a.element.score != b.element.score { return a.element.score > b.element.score }
            return a.offset < b.offset
        }
        suggestions = sorted.map { $0.element }
        return suggestions
    }

    /// The text the receiving session gets. The header is parsed back when history is reloaded.
    public static func envelope(from source: String, text: String) -> String {
        "[Message from “\(source)” via Viber]\n\(text)"
    }

    public static func parseEnvelope(_ text: String) -> (from: String, text: String)? {
        guard text.hasPrefix("[Message from “"), let close = text.range(of: "” via Viber]") else { return nil }
        let from = String(text[text.index(text.startIndex, offsetBy: "[Message from “".count)..<close.lowerBound])
        let body = text[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (from, body)
    }

    /// The reply posted back to the sender. It asks for no answer, so replies never bounce back and forth.
    public static func replyEnvelope(from source: String, text: String) -> String {
        "[Reply from “\(source)” via Viber, answering your earlier message. No need to reply to it.]\n\(text)"
    }

    public static func parseReplyEnvelope(_ text: String) -> (from: String, text: String)? {
        let open = "[Reply from “"
        guard text.hasPrefix(open), let close = text.range(of: "” via Viber"),
              let end = text.range(of: "]", range: close.upperBound..<text.endIndex) else { return nil }
        let from = String(text[text.index(text.startIndex, offsetBy: open.count)..<close.lowerBound])
        return (from, text[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static let stopwords: Set<String> = ["the", "and", "for", "you", "can", "this", "that", "with", "from", "please",
                                         "what", "which", "how", "are", "add", "use", "make", "into", "about", "need",
                                         "should", "would", "could", "will", "your", "our", "its", "it's", "have", "has"]

    static func tokens(_ text: String) -> Set<String> {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(words.filter { $0.count >= 3 && !stopwords.contains($0) }.map(stem))
    }

    /// Crude stemming so "endpoints" matches "endpoint" and "updates" matches "update".
    static func stem(_ word: String) -> String {
        for suffix in ["ing", "es", "s"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double { Double(a.intersection(b).count) }
}
