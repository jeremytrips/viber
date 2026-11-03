import CryptoKit
import Foundation

/// A Claude account Viber signs in to itself. Each has its own config folder (`CLAUDE_CONFIG_DIR`), where the CLI keeps
/// its login in a Keychain item of its own; everything else in the folder points at ~/.claude, so sessions share
/// transcripts, settings, plugins and memory whichever account runs them.
public struct Account: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    /// The address the login belongs to, as `claude auth status` reported it after signing in.
    public var email: String?
    /// Whether Viber may pick it for a new chat, or move a chat to it. Off for a personal account, used only when chosen.
    public var automatic: Bool
    public var id: String { name }

    public init(name: String, email: String? = nil, automatic: Bool = true) {
        self.name = name; self.email = email; self.automatic = automatic
    }
}

/// The accounts Viber signs in to, kept in accounts.json in its support folder.
public struct AccountList: Codable, Equatable {
    public var accounts: [Account] = []

    public init(accounts: [Account] = []) { self.accounts = accounts }

    public static func load(from url: URL = ViberPaths.accounts) -> AccountList {
        guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode(AccountList.self, from: data) else { return AccountList() }
        return list
    }

    public func save(to url: URL = ViberPaths.accounts) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public func account(_ name: String) -> Account? { accounts.first { $0.name == name } }

    public mutating func upsert(_ account: Account) {
        if let index = accounts.firstIndex(where: { $0.name == account.name }) { accounts[index] = account } else { accounts.append(account) }
    }
}

public enum Accounts {
    public static var root: URL { ViberPaths.support.appendingPathComponent("accounts") }

    public static func directory(_ name: String, root: URL = root) -> URL { root.appendingPathComponent(name) }

    /// Letters, digits, `-` and `_`: it names a folder.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 40 && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// The Keychain item the CLI keeps a config folder's login in: "Claude Code-credentials-" and the first 8 hex digits
    /// of the folder path's SHA-256, under the user's name.
    public static func keychainService(directory: String) -> String {
        var path = directory.precomposedStringWithCanonicalMapping
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + digest.prefix(8)
    }

    public static func keychainService(_ name: String) -> String { keychainService(directory: directory(name).path) }

    /// The environment `claude` runs on an account with; nil runs it on the plain login in ~/.claude.
    public static func environment(_ env: [String: String], account: String?) -> [String: String] {
        var env = env
        env["CLAUDE_CONFIG_DIR"] = account.map { directory($0).path }
        return env
    }

    /// Runs `claude auth login` in the account's folder. Its standard input stays open, as the CLI reads a pasted code
    /// from it when the browser can't hand the login back; it gives up after ten minutes.
    public static func signIn(_ name: String, email: String?) -> ShellResult {
        guard let claude = Executables.find("claude") else { return ShellResult(status: 127, stdout: "", stderr: "claude was not found.") }
        // Linked first, so nothing the CLI makes while signing in ends up apart from ~/.claude.
        do { try prepare(name, creating: true) } catch { return ShellResult(status: 1, stdout: "", stderr: error.localizedDescription) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["auth", "login", "--claudeai"] + (email.map { ["--email", $0] } ?? [])
        process.environment = environment(Executables.environment(), account: name)
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return ShellResult(status: 126, stdout: "", stderr: error.localizedDescription) }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        try? input.fileHandleForWriting.close()
        return ShellResult(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self), stderr: "")
    }

    /// Entries of ~/.claude that stay the account's own: its login, its copy of the config (which names the account),
    /// the backups the CLI makes of that copy, and the lock around it.
    static let ownEntries: Set<String> = [".claude.json", ".credentials.json", ".config.json", ".claude.json.lock", "backups", "daemon", "daemon.log"]

    public enum Failure: Error, LocalizedError {
        case notAdded(String)
        public var errorDescription: String? {
            switch self {
            case .notAdded(let name):
                return "\(name) isn't one of Viber's accounts. Add it under the account button in the toolbar (Add Account…, same name), or choose another account."
            }
        }
    }

    /// Readies an account's folder for a session: links every entry of ~/.claude into it, and syncs its copy of
    /// ~/.claude.json both ways. A file the CLI replaced with a copy of its own (writing it through a rename drops the
    /// link) is copied back when it is the newer one, and linked again. Only a sign-in makes the folder: a session on an
    /// account that was never added, or was removed, fails instead.
    public static func prepare(_ name: String, creating: Bool = false, root: URL = root,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let fm = FileManager.default
        let folder = directory(name, root: root)
        if !creating, !isDirectory(folder) { throw Failure.notAdded(name) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let shared = home.appendingPathComponent(".claude")
        for entry in (try? fm.contentsOfDirectory(atPath: shared.path)) ?? [] where !ownEntries.contains(entry) {
            let target = shared.appendingPathComponent(entry)
            let link = folder.appendingPathComponent(entry)
            let attributes = try? fm.attributesOfItem(atPath: link.path)
            switch attributes?[.type] as? FileAttributeType {
            case .typeSymbolicLink?:
                continue
            case .typeRegular?:
                let mine = attributes?[.modificationDate] as? Date ?? .distantPast
                let theirs = (try? fm.attributesOfItem(atPath: target.path))?[.modificationDate] as? Date ?? .distantPast
                if mine > theirs, !isDirectory(target) {
                    _ = try? fm.removeItem(at: target)
                    try fm.copyItem(at: link, to: target)
                }
                try fm.removeItem(at: link)
            case .some:
                // A folder the CLI made before it was linked: linked once empty, else left rather than lose what is in it.
                guard (try? fm.contentsOfDirectory(atPath: link.path))?.isEmpty == true else { continue }
                try fm.removeItem(at: link)
            case nil:
                break
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
        }
        try syncConfig(account: folder.appendingPathComponent(".claude.json"), shared: home.appendingPathComponent(".claude.json"))
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    /// Syncs the account's copy of ~/.claude.json both ways. What the account's sessions changed since Viber last wrote
    /// the copy (an MCP server turned off in a project, a server added) goes to ~/.claude.json; then the copy becomes
    /// ~/.claude.json again, with the account's own keys kept.
    static func syncConfig(account: URL, shared: URL) throws {
        let base = account.deletingLastPathComponent().appendingPathComponent(".viber-config-base.json")
        guard var sharedConfig = readObject(shared) else { return }
        let own = readObject(account) ?? [:]
        if let last = readObject(base) {
            let changes = configChanges(own: own, base: last)
            if !changes.isEmpty {
                sharedConfig = applying(changes, to: sharedConfig)
                try writePrivately(JSONSerialization.data(withJSONObject: sharedConfig, options: [.prettyPrinted, .sortedKeys]), to: shared)
            }
        }
        let merged = mergedConfig(shared: sharedConfig, own: own)
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        if !same(own, merged) { try writePrivately(data, to: account) }
        try writePrivately(data, to: base)
    }

    /// Readable by the user only, as the CLI keeps its config.
    private static func writePrivately(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func readObject(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a?, let b?): return (a as AnyObject).isEqual(b)
        default: return false
        }
    }

    /// One shared setting the account's sessions changed: a top-level key, or one project's entry in `projects`. A nil
    /// value removes it.
    public struct ConfigChange {
        public var key: String
        public var project: String?
        public var value: Any?
    }

    /// The shared settings the account's sessions changed in its copy since `base`, what Viber last wrote there.
    /// Projects compare one by one, so sessions on two accounts in different projects don't undo each other.
    public static func configChanges(own: [String: Any], base: [String: Any]) -> [ConfigChange] {
        var changes: [ConfigChange] = []
        for key in Set(own.keys).union(base.keys).sorted() where !isAccountKey(key) {
            if key == "projects" {
                let mine = own[key] as? [String: Any] ?? [:], before = base[key] as? [String: Any] ?? [:]
                for project in Set(mine.keys).union(before.keys).sorted() where !same(mine[project], before[project]) {
                    changes.append(ConfigChange(key: key, project: project, value: mine[project]))
                }
            } else if !same(own[key], base[key]) {
                changes.append(ConfigChange(key: key, value: own[key]))
            }
        }
        return changes
    }

    public static func applying(_ changes: [ConfigChange], to config: [String: Any]) -> [String: Any] {
        var config = config
        for change in changes {
            if let project = change.project {
                var projects = config[change.key] as? [String: Any] ?? [:]
                projects[project] = change.value
                config[change.key] = projects
            } else {
                config[change.key] = change.value
            }
        }
        return config
    }

    /// ~/.claude.json with the account's own keys in place of the shared ones: the account it is signed in to, and the
    /// caches the CLI fills per account (usage, feature flags, eligibility). MCP servers and project settings are shared.
    public static func mergedConfig(shared: [String: Any], own: [String: Any]) -> [String: Any] {
        var merged = shared
        for key in Set(shared.keys).union(own.keys) where isAccountKey(key) { merged[key] = own[key] }
        return merged
    }

    static func isAccountKey(_ key: String) -> Bool {
        ["oauthAccount", "userID", "primaryApiKey", "customApiKeyResponses"].contains(key)
            || key.hasPrefix("cached") || key.lowercased().hasSuffix("cache") || key.hasSuffix("CacheSlots")
    }
}

// MARK: - Login

/// The login the CLI keeps in an account's Keychain item: `{"claudeAiOauth": {…}}`, plus MCP sign-ins.
public struct OAuthLogin: Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scopes: [String]
    public var subscriptionType: String?
    public var rateLimitTier: String?

    public init?(json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String else { return nil }
        accessToken = token
        refreshToken = oauth["refreshToken"] as? String
        expiresAt = Date(timeIntervalSince1970: ((oauth["expiresAt"] as? Double) ?? 0) / 1000)
        scopes = oauth["scopes"] as? [String] ?? []
        subscriptionType = oauth["subscriptionType"] as? String
        rateLimitTier = oauth["rateLimitTier"] as? String
    }

    public func expired(at now: Date) -> Bool { expiresAt.timeIntervalSince(now) < 120 }

    /// "Max 20x", "Max 5x", "Pro".
    public var tier: String? {
        if let tier = rateLimitTier, let range = tier.range(of: #"max_(\d+x)"#, options: .regularExpression) {
            return "Max " + tier[range].dropFirst(4)
        }
        return subscriptionType.map(\.capitalized)
    }

    /// The stored item with a refreshed token in it, keeping everything else (MCP sign-ins, the plan).
    public static func refreshed(_ stored: Data, with response: Data, now: Date) -> Data? {
        guard var object = try? JSONSerialization.jsonObject(with: stored) as? [String: Any],
              var oauth = object["claudeAiOauth"] as? [String: Any],
              let reply = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let access = reply["access_token"] as? String else { return nil }
        oauth["accessToken"] = access
        if let refresh = reply["refresh_token"] as? String { oauth["refreshToken"] = refresh }
        if let seconds = reply["expires_in"] as? Double { oauth["expiresAt"] = ((now.timeIntervalSince1970 + seconds) * 1000).rounded() }
        if let scope = reply["scope"] as? String { oauth["scopes"] = scope.split(separator: " ").map(String.init) }
        object["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: object)
    }
}

public enum Keychain {
    private static var user: String { ProcessInfo.processInfo.environment["USER"] ?? NSUserName() }

    /// The item's contents. Read through `security`, which wrote it for the CLI, so macOS doesn't ask.
    public static func read(_ service: String) -> Data? {
        let result = Shell.run("/usr/bin/security", ["find-generic-password", "-a", user, "-s", service, "-w"])
        guard result.ok else { return nil }
        let text = result.stdout.trimmingCharacters(in: .newlines)
        // `security` prints the value as hex when it isn't plain text.
        if !text.hasPrefix("{"), let data = Data(hex: text) { return data }
        return Data(text.utf8)
    }

    /// Replaces the item's contents the way the CLI writes it: through `security`'s standard input, so the token never
    /// shows in a process list. `security` cuts that line at 4096 bytes, so a bigger item (one with MCP sign-ins) goes
    /// on the command line, as the CLI does too.
    @discardableResult
    public static func write(_ service: String, _ data: Data) -> Bool {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let line = "add-generic-password -U -a \"\(user)\" -s \"\(service)\" -X \(hex)\n"
        if line.utf8.count < 4000, Shell.run("/usr/bin/security", ["-i"], input: Data(line.utf8), timeout: 10).ok,
           read(service) == data { return true }
        return Shell.run("/usr/bin/security", ["add-generic-password", "-U", "-a", user, "-s", service, "-X", hex], timeout: 10).ok
            && read(service) == data
    }

    @discardableResult
    public static func delete(_ service: String) -> Bool {
        Shell.run("/usr/bin/security", ["delete-generic-password", "-a", user, "-s", service]).ok
    }
}

// MARK: - MCP sign-ins

/// The CLI keeps MCP servers' sign-ins (`mcpOAuth`, one per server name and config) in the same Keychain item as the
/// Claude login, so each account would sign in to Atlassian or PostHog on its own, and a session that lands on another
/// account would ask again. They are the user's, not the account's: every item gets the newest of each. Signing out of
/// a server on one account doesn't reach the others; it comes back from them.
public enum MCPSignIns {
    /// The item the CLI keeps the plain login in ~/.claude in.
    public static let defaultService = "Claude Code-credentials"

    /// The plain login's item and every account's.
    public static func services(_ accounts: [Account]) -> [String] {
        [defaultService] + accounts.map { Accounts.keychainService($0.name) }
    }

    public static func entries(in stored: Data) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: stored) as? [String: Any])?["mcpOAuth"] as? [String: Any]) ?? [:]
    }

    /// `own` with each sign-in of `others` it lacks, or that expires later than its copy: a server whose refresh token
    /// turns over (Atlassian's does) leaves the older copies signed out, so the latest wins. A tie keeps its own.
    public static func merged(own: [String: Any], others: [[String: Any]]) -> [String: Any] {
        var merged = own
        for other in others {
            for (key, entry) in other where merged[key] == nil || expiry(entry) > expiry(merged[key]) { merged[key] = entry }
        }
        return merged
    }

    private static func expiry(_ entry: Any?) -> Double { ((entry as? [String: Any])?["expiresAt"] as? NSNumber)?.doubleValue ?? 0 }

    /// The stored item with these MCP sign-ins, keeping the login.
    public static func replacing(_ stored: Data, with entries: [String: Any]) -> Data? {
        guard var object = try? JSONSerialization.jsonObject(with: stored) as? [String: Any] else { return nil }
        object["mcpOAuth"] = entries
        return try? JSONSerialization.data(withJSONObject: object)
    }

    /// Gives each signed-in item of `targets` (all of `services` by default) the newest of every MCP sign-in in
    /// `services`. An item the CLI wrote since it was read is left for the next time rather than undo what it wrote.
    public static func share(among services: [String], into targets: [String]? = nil) {
        var stored: [String: Data] = [:]
        for service in Set(services + (targets ?? [])) { stored[service] = Keychain.read(service) }
        let signIns = stored.mapValues(entries(in:))
        for service in targets ?? services {
            guard let data = stored[service], OAuthLogin(json: data) != nil, let own = signIns[service] else { continue }
            let wanted = merged(own: own, others: signIns.filter { $0.key != service }.map(\.value))
            guard !(wanted as NSDictionary).isEqual(to: own), Keychain.read(service) == data,
                  let updated = replacing(data, with: wanted) else { continue }
            Keychain.write(service, updated)
        }
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

// MARK: - Usage

/// One usage window of an account: "5h", "7d", or a model's week such as "7d fable".
public struct UsageWindow: Codable, Equatable, Sendable {
    public var label: String
    /// 0–100.
    public var utilizationPct: Double?
    public var resetsAt: Date?

    public init(label: String, utilizationPct: Double?, resetsAt: Date?) {
        self.label = label; self.utilizationPct = utilizationPct; self.resetsAt = resetsAt
    }
}

/// What the toolbar and Automatic know about an account: its login, plan and usage.
public struct AccountStatus: Identifiable, Equatable, Sendable {
    public var name: String
    public var email: String?
    public var automatic: Bool
    public var tier: String?
    public var loginProblem: String?
    public var windows: [UsageWindow] = []
    public var fetchedAt: Date?
    /// The last fetch failed; `windows` are older.
    public var fetchFailed = false
    public var id: String { name }

    public init(name: String, email: String? = nil, automatic: Bool = true, tier: String? = nil, loginProblem: String? = nil,
                windows: [UsageWindow] = [], fetchedAt: Date? = nil, fetchFailed: Bool = false) {
        self.name = name; self.email = email; self.automatic = automatic; self.tier = tier; self.loginProblem = loginProblem
        self.windows = windows; self.fetchedAt = fetchedAt; self.fetchFailed = fetchFailed
    }

    public func usage(_ label: String) -> Double? { windows.first { $0.label == label }?.utilizationPct }
    public var fiveHour: Double { usage("5h") ?? 0 }
    public var week: Double { usage("7d") ?? 0 }
}

public enum AccountUsage {
    public static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Claude Code's OAuth client, which the account's tokens were issued to.
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// The windows in a `/api/oauth/usage` reply. Its `limits` list names the model of a model's own week; older replies
    /// only have `five_hour` and `seven_day`.
    public static func windows(from data: Data) -> [UsageWindow]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let limits = object["limits"] as? [[String: Any]], !limits.isEmpty {
            return limits.compactMap { limit in
                let label: String
                switch limit["kind"] as? String {
                case "session": label = "5h"
                case "weekly_all": label = "7d"
                case "weekly_scoped":
                    let scope = limit["scope"] as? [String: Any]
                    guard let model = (scope?["model"] as? [String: Any])?["display_name"] as? String else { return nil }
                    label = "7d " + model.lowercased()
                default: return nil
                }
                return UsageWindow(label: label, utilizationPct: number(limit["percent"]), resetsAt: Dates.parse(limit["resets_at"] as? String))
            }
        }
        let names = [("five_hour", "5h"), ("seven_day", "7d"), ("seven_day_opus", "7d opus"), ("seven_day_sonnet", "7d sonnet")]
        let windows = names.compactMap { key, label -> UsageWindow? in
            guard let window = object[key] as? [String: Any] else { return nil }
            return UsageWindow(label: label, utilizationPct: number(window["utilization"]), resetsAt: Dates.parse(window["resets_at"] as? String))
        }
        return windows.isEmpty ? nil : windows
    }

    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

    public enum Failure: Error, Equatable {
        /// The token was turned away: the login needs refreshing or is gone.
        case unauthorized
        case failed(String)
    }

    /// Reads an account's usage with its access token.
    public static func fetch(token: String) async -> Result<[UsageWindow], Failure> {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else {
            return .failure(.failed("Anthropic could not be reached"))
        }
        if http.statusCode == 401 || http.statusCode == 403 { return .failure(.unauthorized) }
        guard http.statusCode == 200, let windows = windows(from: data) else { return .failure(.failed("HTTP \(http.statusCode)")) }
        return .success(windows)
    }

    /// Exchanges a refresh token for a new access token, as the CLI does when its token expires. The reply carries a
    /// new refresh token too: the old one stops working, so the reply must be stored.
    public static func refresh(_ login: OAuthLogin) async -> Result<Data, Failure> {
        guard let refreshToken = login.refreshToken else { return .failure(.unauthorized) }
        var request = URLRequest(url: tokenURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID,
                                   "scope": login.scopes.joined(separator: " ")]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else {
            return .failure(.failed("Anthropic could not be reached"))
        }
        // A refresh token that no longer works; anything else (429, 5xx) is worth another try later.
        if http.statusCode == 400 || http.statusCode == 401 { return .failure(.unauthorized) }
        guard http.statusCode == 200 else { return .failure(.failed("HTTP \(http.statusCode)")) }
        return .success(data)
    }

    /// An account's login and usage, read fresh. An expired token is refreshed only when no session runs on the account:
    /// a running CLI refreshes it itself, and two refreshes with the same refresh token would sign one of them out.
    public static func status(of account: Account, sessionRunning: Bool, previous: AccountStatus?, now: Date = Date()) async -> AccountStatus {
        var status = AccountStatus(name: account.name, email: account.email, automatic: account.automatic,
                                   tier: previous?.tier, windows: previous?.windows ?? [], fetchedAt: previous?.fetchedAt)
        let service = Accounts.keychainService(account.name)
        guard var stored = Keychain.read(service), var login = OAuthLogin(json: stored) else {
            status.loginProblem = "Not logged in"
            return status
        }
        status.tier = login.tier ?? status.tier
        var refreshed = false
        func refresh() async -> Bool {
            switch await AccountUsage.refresh(login) {
            case .success(let reply):
                guard let updated = OAuthLogin.refreshed(stored, with: reply, now: now), let fresh = OAuthLogin(json: updated) else {
                    status.fetchFailed = true
                    return false
                }
                // The old refresh token stopped working with this reply: losing the new one would sign the account out.
                var saved = Keychain.write(service, updated)
                for _ in 0..<2 where !saved {
                    try? await Task.sleep(for: .seconds(1))
                    saved = Keychain.write(service, updated)
                }
                if !saved { status.loginProblem = "Login could not be saved" }
                stored = updated; login = fresh; refreshed = true
                return true
            case .failure(.unauthorized):
                // Another Viber may have refreshed it a moment ago.
                if let again = Keychain.read(service), let other = OAuthLogin(json: again), other.accessToken != login.accessToken,
                   !other.expired(at: now) {
                    stored = again; login = other
                    return true
                }
                status.loginProblem = "Login expired"
                return false
            case .failure:
                status.fetchFailed = true
                return false
            }
        }
        if login.expired(at: now) {
            if sessionRunning { return status }
            guard await refresh() else { return status }
        }
        switch await fetch(token: login.accessToken) {
        case .success(let windows):
            status.windows = windows
            status.fetchedAt = now
        case .failure(.unauthorized) where !sessionRunning && !refreshed:
            guard await refresh() else { return status }
            if case .success(let windows) = await fetch(token: login.accessToken) {
                status.windows = windows
                status.fetchedAt = now
            } else {
                status.fetchFailed = true
            }
        case .failure:
            status.fetchFailed = true
        }
        return status
    }
}

// MARK: - Automatic

/// Which account a new chat starts on, and where a chat Viber picked the account for moves when it runs low.
public enum AccountChoice {
    /// An account at or past these has no room for more work: its 5-hour window, or its week.
    public static let fiveHourLine = 90.0
    public static let weekLine = 95.0
    /// Accounts this close to the least-used week count as tied, and the one running the fewest sessions wins.
    public static let tie = 10.0

    public static func hasRoom(_ account: AccountStatus) -> Bool {
        account.fiveHour < fiveHourLine && account.week < weekLine
    }

    /// The account with the least-used week, spreading sessions over accounts that are about as used; nil when the
    /// project may use none. With `avoiding` (a move), only an account with room counts. Without, when none has room,
    /// the one that frees up first: the session waits out its limit there.
    public static func pick(from accounts: [AccountStatus], allowed: Set<String>, running: [String: Int] = [:],
                            limited: Set<String> = [], avoiding: String? = nil, now: Date = Date()) -> String? {
        let candidates = accounts.filter { allowed.contains($0.name) && $0.loginProblem == nil && $0.name != avoiding }
        let open = candidates.filter { hasRoom($0) && !limited.contains($0.name) }
        if let least = open.map(\.week).min() {
            return open.filter { $0.week <= least + tie }
                .min { a, b in
                    let (ra, rb) = (running[a.name] ?? 0, running[b.name] ?? 0)
                    if ra != rb { return ra < rb }
                    if a.fiveHour != b.fiveHour { return a.fiveHour < b.fiveHour }
                    if a.week != b.week { return a.week < b.week }
                    return a.name < b.name
                }?.name
        }
        guard avoiding == nil else { return nil }
        return candidates.min { freesAt($0, now: now) < freesAt($1, now: now) }?.name
    }

    /// When the windows that keep an account full reset.
    static func freesAt(_ account: AccountStatus, now: Date) -> Date {
        let full = account.windows.filter { window in
            let pct = window.utilizationPct ?? 0
            return window.label == "5h" ? pct >= fiveHourLine : window.label == "7d" ? pct >= weekLine : false
        }
        return full.compactMap(\.resetsAt).max() ?? now
    }
}
