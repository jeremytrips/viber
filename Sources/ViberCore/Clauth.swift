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
        public var id: String { name }
        public var loginProblem: String? {
            switch authStatus {
            case "expired": return "Login expired"
            case "broken": return "Login broken"
            default: return nil
            }
        }
    }
    public var generatedAt: String?
    public var activeProfile: String?
    public var profiles: [Profile]

    public static func decode(_ data: Data) -> ClauthStatus? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(ClauthStatus.self, from: data)
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
    /// clauth's default account, whichever that is when a session starts.
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

    /// The clauth profile a new session starts under; nil starts plain `claude`. clauth's default falls back to plain
    /// `claude` while its login is broken. A profile the project names is used as it is, even with a broken login:
    /// its sessions never run on an account the project didn't choose, and the chat says when the login fails.
    public func launchProfile(status: ClauthStatus?) -> String? {
        switch self {
        case .plain: return nil
        case .profile(let name): return name
        case .clauthDefault:
            guard let name = status?.activeProfile,
                  let profile = status?.profiles.first(where: { $0.name == name }), profile.loginProblem == nil else { return nil }
            return name
        }
    }
}
