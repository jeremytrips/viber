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
