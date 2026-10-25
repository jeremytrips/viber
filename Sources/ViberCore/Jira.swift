import Foundation

/// A Jira Cloud site Viber reads with an API token: `pinsound.atlassian.net`. The token is in the Keychain.
public struct JiraSite: Codable, Equatable, Identifiable, Sendable {
    public var host: String
    public var email: String
    /// The name the token signed in as, from the last test.
    public var displayName: String?

    public init(host: String, email: String, displayName: String? = nil) {
        self.host = Self.cleanHost(host); self.email = email; self.displayName = displayName
    }

    public var id: String { host }

    /// "https://x.atlassian.net" → "x.atlassian.net"; a bare name gets ".atlassian.net".
    public static func cleanHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if !host.isEmpty, !host.contains("."), !host.hasPrefix("localhost") { host += ".atlassian.net" }
        return host
    }

    /// `http` for a site on this machine, such as a mock while developing; `https` everywhere else.
    public var baseURL: String {
        host.hasPrefix("localhost") || host.hasPrefix("127.0.0.1") ? "http://\(host)" : "https://\(host)"
    }

    public func browseURL(_ key: String) -> URL? { URL(string: "\(baseURL)/browse/\(key)") }
    public func searchURL(jql: String) -> URL? {
        var parts = URLComponents(string: "\(baseURL)/issues/")
        parts?.queryItems = [URLQueryItem(name: "jql", value: jql)]
        return parts?.url
    }
}

/// Jira's three status categories, which every status falls into; what a column or a chip's colour is based on.
public enum JiraCategory: String, Codable, Sendable {
    case todo, progress, done

    static func parse(_ key: String?) -> JiraCategory {
        switch key {
        case "indeterminate": return .progress
        case "done": return .done
        default: return .todo
        }
    }
}

public struct JiraIssue: Equatable, Identifiable, Sendable {
    public var key: String
    public var summary: String
    public var status: String
    public var category: JiraCategory
    public var type: String
    public var isEpic: Bool
    public var priority: String?
    public var assignee: String?
    public var assigneeID: String?
    public var parentKey: String?
    public var labels: [String]
    public var updated: Date?
    /// The description as plain text, for the first message of a session.
    public var description: String

    public init(key: String, summary: String, status: String, category: JiraCategory, type: String, isEpic: Bool = false,
                priority: String? = nil, assignee: String? = nil, assigneeID: String? = nil, parentKey: String? = nil,
                labels: [String] = [], updated: Date? = nil, description: String = "") {
        self.key = key; self.summary = summary; self.status = status; self.category = category; self.type = type
        self.isEpic = isEpic; self.priority = priority; self.assignee = assignee; self.assigneeID = assigneeID
        self.parentKey = parentKey; self.labels = labels; self.updated = updated; self.description = description
    }

    public var id: String { key }

    /// The project part of the key: `NEX` in `NEX-224`.
    public var projectKey: String { String(key.prefix { $0 != "-" }) }

    /// `NEX-224` in `feat/nex-224-user-admin`, in upper case; nil when a branch names no issue.
    public static func key(inBranch branch: String) -> String? {
        var best: String?
        for part in branch.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }) {
            // The key is `LETTERS-DIGITS`, possibly followed by more `-words`: take the first letters and digits.
            let pieces = part.split(separator: "-", omittingEmptySubsequences: false)
            guard pieces.count >= 2, let first = pieces.first, !first.isEmpty, first.first!.isLetter,
                  first.allSatisfy({ $0.isLetter || $0.isNumber }), pieces[1].allSatisfy(\.isNumber), !pieces[1].isEmpty else { continue }
            let key = "\(first.uppercased())-\(pieces[1])"
            if best == nil { best = key }
        }
        return best
    }
}

public struct JiraPage: Equatable, Sendable {
    public var issues: [JiraIssue]
    public var nextPageToken: String?
    public var isLast: Bool
    public init(issues: [JiraIssue], nextPageToken: String? = nil, isLast: Bool = true) {
        self.issues = issues; self.nextPageToken = nextPageToken; self.isLast = isLast
    }
}

public struct JiraUser: Equatable, Sendable {
    public var accountID: String
    public var displayName: String
    public init(accountID: String, displayName: String) { self.accountID = accountID; self.displayName = displayName }
}

public struct JiraError: Error, LocalizedError, Equatable {
    public var message: String
    public var status: Int?
    public var errorDescription: String? { message }
    public init(_ message: String, status: Int? = nil) { self.message = message; self.status = status }
    /// The token was refused: expired, revoked, or wrong.
    public var isAuth: Bool { status == 401 || status == 403 }
}

/// Jira Cloud's REST API v3, read-only, with an API token. Searches page with `nextPageToken`, as the
/// `/search/jql` endpoint does; the old `/search` with `startAt` is gone.
public struct JiraClient: Sendable {
    public var site: JiraSite
    public var token: String
    public var session: URLSession

    public static let fields = ["summary", "status", "issuetype", "priority", "assignee", "parent", "labels", "updated", "description"]
    public static let pageSize = 50

    public init(site: JiraSite, token: String, session: URLSession = .shared) {
        self.site = site; self.token = token; self.session = session
    }

    public func myself() async throws -> JiraUser {
        let json = try await get("/rest/api/3/myself")
        guard let id = json["accountId"]?.string else { throw JiraError("Jira answered without an account.") }
        return JiraUser(accountID: id, displayName: json["displayName"]?.string ?? site.email)
    }

    /// One page of a JQL search, with the fields a row needs.
    public func search(_ jql: String, pageToken: String? = nil, maxResults: Int = pageSize) async throws -> JiraPage {
        var body: [String: JSON] = ["jql": .string(jql), "fields": .array(Self.fields.map { .string($0) }), "maxResults": .number(Double(maxResults))]
        if let pageToken { body["nextPageToken"] = .string(pageToken) }
        let json = try await post("/rest/api/3/search/jql", body: .object(body))
        return Self.parsePage(json)
    }

    /// Roughly how many issues a query matches; Jira estimates rather than counts.
    public func count(_ jql: String) async throws -> Int {
        let json = try await post("/rest/api/3/search/approximate-count", body: ["jql": .string(jql)])
        return json["count"]?.int ?? 0
    }

    public func issue(_ key: String) async throws -> JiraIssue {
        let json = try await get("/rest/api/3/issue/\(key)?fields=\(Self.fields.joined(separator: ","))")
        guard let issue = Self.parseIssue(json) else { throw JiraError("Jira answered without the issue \(key).") }
        return issue
    }

    // MARK: Parsing

    public static func parsePage(_ json: JSON) -> JiraPage {
        JiraPage(issues: (json["issues"]?.array ?? []).compactMap(parseIssue),
                 nextPageToken: json["nextPageToken"]?.string,
                 isLast: json["isLast"]?.bool ?? (json["nextPageToken"]?.string == nil))
    }

    public static func parseIssue(_ json: JSON) -> JiraIssue? {
        guard let key = json["key"]?.string, let fields = json["fields"] else { return nil }
        let type = fields["issuetype"]
        let typeName = type?["name"]?.string ?? ""
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let updatedText = fields["updated"]?.string
        // Jira writes "2026-10-24T10:02:37.000+0200": a zone without a colon, which ISO8601DateFormatter wants.
        let updated = updatedText.flatMap { text -> Date? in
            var fixed = text
            if fixed.count > 5, !fixed.hasSuffix("Z"), fixed[fixed.index(fixed.endIndex, offsetBy: -3)] != ":" {
                fixed.insert(":", at: fixed.index(fixed.endIndex, offsetBy: -2))
            }
            return formatter.date(from: fixed)
        }
        return JiraIssue(key: key, summary: fields["summary"]?.string ?? "",
                         status: fields["status"]?["name"]?.string ?? "",
                         category: JiraCategory.parse(fields["status"]?["statusCategory"]?["key"]?.string),
                         type: typeName,
                         isEpic: (type?["hierarchyLevel"]?.int ?? 0) >= 1 || typeName.lowercased() == "epic",
                         priority: fields["priority"]?["name"]?.string,
                         assignee: fields["assignee"]?["displayName"]?.string,
                         assigneeID: fields["assignee"]?["accountId"]?.string,
                         parentKey: fields["parent"]?["key"]?.string,
                         labels: (fields["labels"]?.array ?? []).compactMap(\.string),
                         updated: updated,
                         description: plainText(fields["description"]))
    }

    /// Atlassian Document Format down to text: paragraphs on their own lines, list items with "- ".
    public static func plainText(_ node: JSON?) -> String {
        guard let node else { return "" }
        if let text = node.string { return text }
        var out = ""
        func walk(_ n: JSON, depth: Int) {
            let type = n["type"]?.string ?? ""
            switch type {
            case "text": out += n["text"]?.string ?? ""
            case "hardBreak": out += "\n"
            case "mention": out += "@" + (n["attrs"]?["text"]?.string ?? "")
            case "inlineCard": out += n["attrs"]?["url"]?.string ?? ""
            case "listItem": out += String(repeating: "  ", count: max(depth - 1, 0)) + "- "
            case "heading": out += String(repeating: "#", count: n["attrs"]?["level"]?.int ?? 1) + " "
            default: break
            }
            for child in n["content"]?.array ?? [] { walk(child, depth: type == "bulletList" || type == "orderedList" ? depth + 1 : depth) }
            if ["paragraph", "heading", "listItem", "codeBlock", "blockquote", "rule", "tableRow"].contains(type), !out.hasSuffix("\n") { out += "\n" }
        }
        walk(node, depth: 0)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Requests

    private func get(_ path: String) async throws -> JSON {
        try await send(request(path, method: "GET", body: nil))
    }

    private func post(_ path: String, body: JSON) async throws -> JSON {
        try await send(request(path, method: "POST", body: try JSONSerialization.data(withJSONObject: body.any)))
    }

    private func request(_ path: String, method: String, body: Data?) throws -> URLRequest {
        guard let url = URL(string: "\(site.baseURL)\(path)") else { throw JiraError("Not a usable site: \(site.host)") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Basic " + Data("\(site.email):\(token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func send(_ request: URLRequest) async throws -> JSON {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw JiraError("Couldn't reach \(site.host): \(error.localizedDescription)") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)).map { JSON(any: $0) } ?? .null
        guard (200..<300).contains(status) else {
            let messages = (json["errorMessages"]?.array ?? []).compactMap(\.string)
            let detail = messages.isEmpty ? (json["message"]?.string ?? "") : messages.joined(separator: " ")
            switch status {
            case 401: throw JiraError("Jira refused the token for \(site.email). It may have expired; make a new one.", status: 401)
            case 403: throw JiraError("The token isn't allowed to do this: " + (detail.isEmpty ? "check its scopes." : detail), status: 403)
            case 404: throw JiraError(detail.isEmpty ? "Jira found nothing there." : detail, status: 404)
            default: throw JiraError("Jira answered \(status)" + (detail.isEmpty ? "." : ": \(detail)"), status: status)
            }
        }
        return json
    }
}
