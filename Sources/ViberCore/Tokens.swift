import Foundation

/// Tokens one or more model calls used, as their `usage` reports them.
public struct TokenCount: Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheWrite = 0
    public var cacheRead = 0

    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
        self.input = input; self.output = output; self.cacheWrite = cacheWrite; self.cacheRead = cacheRead
    }

    init(usage: [String: Any]) {
        func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        self.init(input: count("input_tokens"), output: count("output_tokens"),
                  cacheWrite: count("cache_creation_input_tokens"), cacheRead: count("cache_read_input_tokens"))
    }

    /// Everything but cache reads: each call reads the whole conversation from the cache again, so they would swamp
    /// what the work actually added.
    public var total: Int { input + output + cacheWrite }
    public var isEmpty: Bool { total == 0 && cacheRead == 0 }

    public static func + (a: TokenCount, b: TokenCount) -> TokenCount {
        TokenCount(input: a.input + b.input, output: a.output + b.output, cacheWrite: a.cacheWrite + b.cacheWrite,
                   cacheRead: a.cacheRead + b.cacheRead)
    }

    public static func += (a: inout TokenCount, b: TokenCount) { a = a + b }
}

/// One model call of a session, from its transcript.
public struct TokenEntry: Equatable, Sendable {
    /// The API message's ID. The transcript has a row per content block, each with the call's whole usage.
    public var id: String
    public var at: Date?
    public var count: TokenCount
    /// Made by one of the session's subagents.
    public var subagent: Bool

    public init(id: String, at: Date?, count: TokenCount, subagent: Bool) {
        self.id = id; self.at = at; self.count = count; self.subagent = subagent
    }

    private static let usageKey = Data("\"usage\"".utf8)

    /// The call an assistant row is part of; nil for any other row, and for the CLI's own `<synthetic>` notes.
    public static func parse(_ line: Data, subagent: Bool) -> TokenEntry? {
        // Most rows have no usage; skip parsing those.
        guard line.range(of: usageKey) != nil,
              let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any], row["type"] as? String == "assistant",
              let message = row["message"] as? [String: Any], let id = message["id"] as? String,
              message["model"] as? String != "<synthetic>", let usage = message["usage"] as? [String: Any] else { return nil }
        return TokenEntry(id: id, at: Dates.parse(row["timestamp"]), count: TokenCount(usage: usage),
                          subagent: subagent || row["isSidechain"] as? Bool == true)
    }
}

/// Reads a session's model calls from its transcript and its subagents' (in `<session>/subagents/`). Each read takes
/// only what the files gained since the last one.
public actor TokenTally {
    private struct Cursor {
        var inode: UInt64
        var offset: UInt64 = 0
        var pending = Data()
    }
    private var transcript: URL?
    private var cursors: [String: Cursor] = [:]
    private var entries: [String: TokenEntry] = [:]

    public init() {}

    /// Every call so far, oldest first.
    public func read(_ url: URL) -> [TokenEntry] {
        if url != transcript { transcript = url; cursors = [:]; entries = [:] }
        let folder = url.deletingPathExtension().appendingPathComponent("subagents")
        let agents = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
        readNew(url, subagent: false)
        for file in agents { readNew(file, subagent: true) }
        return entries.values.sorted { ($0.at ?? .distantPast, $0.id) < ($1.at ?? .distantPast, $1.id) }
    }

    private func readNew(_ url: URL, subagent: Bool) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        var cursor = cursors[url.path] ?? Cursor(inode: inode)
        // Replaced or cut short: read it again. Calls already counted keep their IDs, so nothing counts twice.
        if inode != cursor.inode || size < cursor.offset { cursor = Cursor(inode: inode) }
        guard size > cursor.offset, let handle = try? FileHandle(forReadingFrom: url) else { cursors[url.path] = cursor; return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: cursor.offset)
        let chunk = (try? handle.readToEnd()) ?? Data()
        cursor.offset += UInt64(chunk.count)
        cursor.pending.append(chunk)
        // A row still being written waits for its newline.
        if let last = cursor.pending.lastIndex(of: 10) {
            for line in cursor.pending[..<last].split(separator: 10) {
                if let entry = TokenEntry.parse(Data(line), subagent: subagent) { entries[entry.id] = entry }
            }
            cursor.pending.removeSubrange(...last)
        }
        cursors[url.path] = cursor
    }
}

// MARK: - Accounts over time

/// From when a session ran on an account: Viber started its Claude there. A nil account is the plain `claude` login.
public struct AccountSpan: Codable, Equatable, Sendable {
    public var account: String?
    public var from: Date

    public init(account: String?, from: Date) { self.account = account; self.from = from }
}

/// Whose a model call's tokens were.
public enum TokenOwner: Hashable, Sendable {
    case account(String)
    case plain
    /// Before Viber recorded which account the session ran on.
    case unknown

    public var label: String {
        switch self {
        case .account(let name): return name
        case .plain: return "Plain login"
        case .unknown: return "Unknown account"
        }
    }
}

/// One owner's share of a session's tokens.
public struct TokenShare: Equatable, Identifiable, Sendable {
    public var owner: TokenOwner
    public var chat = TokenCount()
    public var subagents = TokenCount()
    public var id: TokenOwner { owner }
    public var all: TokenCount { chat + subagents }

    public init(owner: TokenOwner, chat: TokenCount = TokenCount(), subagents: TokenCount = TokenCount()) {
        self.owner = owner; self.chat = chat; self.subagents = subagents
    }
}

/// Which account ran each session from when, kept in session-account-log.json, so a session's tokens split by account.
public struct SessionAccountLog: Codable, Equatable {
    /// Oldest first, by session ID.
    public var sessions: [String: [AccountSpan]] = [:]

    public init(sessions: [String: [AccountSpan]] = [:]) { self.sessions = sessions }

    /// The log, else the account each session last ran on from session-accounts.json, which it replaced. Those spans
    /// start at the beginning of time: earlier accounts weren't kept.
    public static func load(from url: URL = ViberPaths.sessionAccountLog,
                            migrating old: URL = ViberPaths.sessionAccounts) -> SessionAccountLog {
        if let data = try? Data(contentsOf: url), let log = try? JSONDecoder().decode(SessionAccountLog.self, from: data) { return log }
        guard let data = try? Data(contentsOf: old), let last = try? JSONDecoder().decode([String: String].self, from: data) else {
            return SessionAccountLog()
        }
        return SessionAccountLog(sessions: last.mapValues { [AccountSpan(account: $0, from: .distantPast)] })
    }

    public func save(to url: URL = ViberPaths.sessionAccountLog) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// The account the session last ran on; nil for the plain login, or when it was never recorded.
    public func lastAccount(_ session: String) -> String? { sessions[session]?.last?.account }

    /// Notes that the session runs on `account` from `from`, unless that is where it already runs.
    @discardableResult
    public mutating func record(_ session: String, account: String?, from: Date) -> Bool {
        var spans = sessions[session] ?? []
        if let last = spans.last, last.account == account { return false }
        spans.append(AccountSpan(account: account, from: from))
        sessions[session] = spans.sorted { $0.from < $1.from }
        return true
    }

    /// Adds what `other` has that this lacks: what another Viber running at the same time wrote.
    public mutating func merge(_ other: SessionAccountLog) {
        for (session, theirs) in other.sessions {
            let mine = sessions[session] ?? []
            sessions[session] = (mine + theirs.filter { !mine.contains($0) }).sorted { $0.from < $1.from }
        }
    }

    /// Who ran a call made at `at`: the account the session ran on then.
    public static func owner(at: Date?, spans: [AccountSpan]) -> TokenOwner {
        let span = at.map { at in spans.last { $0.from <= at } } ?? spans.last
        guard let span else { return .unknown }
        return span.account.map(TokenOwner.account) ?? .plain
    }

    /// A session's tokens by the account each call ran on, in the order the accounts were first used; with `since`,
    /// only calls from then on.
    public static func split(_ entries: [TokenEntry], spans: [AccountSpan], since: Date? = nil) -> [TokenShare] {
        var shares: [TokenShare] = []
        for entry in entries {
            if let since { guard let at = entry.at, at >= since else { continue } }
            let owner = owner(at: entry.at, spans: spans)
            var index = shares.firstIndex { $0.owner == owner }
            if index == nil { shares.append(TokenShare(owner: owner)); index = shares.count - 1 }
            if entry.subagent { shares[index!].subagents += entry.count } else { shares[index!].chat += entry.count }
        }
        return shares
    }
}
