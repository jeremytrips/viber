import Foundation

/// The snapshot `clauth daemon` writes to ~/.clauth/status.json (same shape as `clauth status --json`).
public struct ClauthStatus: Decodable, Equatable {
    public struct Window: Decodable, Equatable {
        public var label: String
        public var utilizationPct: Double?
        public var resetsAt: String?
        public var resetDate: Date? { Dates.parse(resetsAt) }
    }
    public struct Profile: Decodable, Equatable, Identifiable {
        public var name: String
        public var active: Bool?
        public var tier: String?
        public var authStatus: String?
        public var stale: Bool?
        /// The daemon's last usage fetch: "Fresh", "Failed", or nil before the first one.
        public var fetchStatus: String?
        public var fetchedAt: String?
        public var windows: [Window]?
        /// Set for members of clauth's fallback chain.
        public var fallback: Fallback?
        public var id: String { name }
        public var loginProblem: String? {
            switch authStatus {
            case "expired": return "Login expired"
            case "broken": return "Login broken"
            default: return nil
            }
        }
    }
    public struct Fallback: Decodable, Equatable {
        /// 1 for the chain's first member.
        public var position: Int?
    }
    public var generatedAt: String?
    public var activeProfile: String?
    public var profiles: [Profile]

    public static func decode(_ data: Data) -> ClauthStatus? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(ClauthStatus.self, from: data)
    }

    /// clauth's fallback chain, in its order.
    public var chain: [String] {
        profiles.filter { $0.fallback != nil }.sorted { ($0.fallback?.position ?? 0) < ($1.fallback?.position ?? 0) }.map(\.name)
    }
}

/// A `clauth start` process as clauth tracks it in ~/.clauth/live_sessions.
public struct ClauthLiveSession: Decodable, Equatable {
    public var pid: Int32
    /// The account it started on, which `--auto` picked.
    public var startProfile: String?
    /// The chain member a session that follows the chain was swapped onto; nil until a swap.
    public var currentMember: String?
    public var profile: String? { currentMember ?? startProfile }

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clauth/live_sessions")
    }

    /// Every session clauth tracks, by the ID of its `clauth start` process.
    public static func load(from directory: URL = directory) -> [Int32: ClauthLiveSession] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var sessions: [Int32: ClauthLiveSession] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let session = try? decoder.decode(ClauthLiveSession.self, from: data) else { continue }
            sessions[session.pid] = session
        }
        return sessions
    }
}

/// One row of `clauth sessions --json`.
public struct ClauthSession: Decodable, Equatable, Identifiable {
    public var id: String
    public var lastRanProfile: String?
    public var workspace: String?
    public var updated: String?
    public var firstMessage: String?
    public var lastMessage: String?
    public var updatedDate: Date? { Dates.parse(updated) }

    public static func decodeList(_ data: Data) -> [ClauthSession] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode([ClauthSession].self, from: data)) ?? []
    }

    /// First message with wrappers like <ide_opened_file> removed, for a readable title.
    public var title: String {
        var text = firstMessage ?? ""
        // Drop whole wrapper blocks (<ide_opened_file>…</ide_opened_file>), then any stray tags.
        text = text.replacingOccurrences(of: #"<([a-z_-]+)[^>]*>[\s\S]*?</\1>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"</?[a-z_-]+[^>]*>"#, with: "", options: .regularExpression)
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? ""
        return line.isEmpty ? "Untitled session" : String(line.prefix(80))
    }
}

/// The login a project's sessions start with, chosen on its Settings tab or under the toolbar's account button.
public enum ProjectAccount: Hashable, Sendable {
    /// clauth's default account, whichever that is when a session starts. With a fallback chain, clauth picks a member
    /// at launch instead, and moves the session along the chain.
    case clauthDefault
    /// Plain `claude` with its own login, outside clauth.
    case plain
    /// A clauth profile, by name.
    case profile(String)

    /// How Viber stores it: nil for clauth's default, an empty string for plain `claude`, else the profile's name.
    public init(stored: String?) {
        switch stored {
        case .none: self = .clauthDefault
        case .some(let name) where name.isEmpty: self = .plain
        case .some(let name): self = .profile(name)
        }
    }

    public var stored: String? {
        switch self {
        case .clauthDefault: return nil
        case .plain: return ""
        case .profile(let name): return name
        }
    }

    /// The clauth profile a new session starts under; nil starts plain `claude`. With a fallback chain, clauth's default
    /// is a chain member: clauth picks the real one at launch (`--auto`), and this is the one to show until it does,
    /// so an account outside the chain, such as a personal one, never shows up for the project. Without a chain it
    /// falls back to plain `claude` while its login is broken. A profile the project names is used as it is, even with
    /// a broken login: its sessions never run on an account the project didn't choose, and the chat says when the
    /// login fails.
    public func launchProfile(status: ClauthStatus?) -> String? {
        switch self {
        case .plain: return nil
        case .profile(let name): return name
        case .clauthDefault:
            if let status, let first = status.chain.first {
                let working = status.chain.filter { name in status.profiles.first { $0.name == name }?.loginProblem == nil }
                if let active = status.activeProfile, working.contains(active) { return active }
                return working.first ?? first
            }
            guard let name = status?.activeProfile,
                  let profile = status?.profiles.first(where: { $0.name == name }), profile.loginProblem == nil else { return nil }
            return name
        }
    }
}
