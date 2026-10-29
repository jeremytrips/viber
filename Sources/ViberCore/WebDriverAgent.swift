import CoreGraphics
import CryptoKit
import Foundation

/// Appium's WebDriverAgent: an XCUITest runner with an HTTP server that reads a physical iPhone's elements and sends it
/// touches, keys and buttons. XCUITest is the only public way to do either on a phone. Viber downloads a pinned release,
/// builds it once per development team (Xcode registers the bundle id and makes the profile), and runs it with
/// `xcodebuild test-without-building`. Xcode reaches iOS 17 and later through CoreDevice's own tunnel, so nothing needs
/// sudo (go-ios and pymobiledevice3 do, for a tunnel of their own), and the server is reached at the phone's address in
/// that tunnel, over USB and Wi-Fi alike.
public enum WebDriverAgent {
    /// Scripts and docs name the same release.
    static let version = "9.9.0"
    static let sha256 = "e8222dfd70c4837c0c3735c5ba20cae3a426b19a2542e69b303de6f580632d2d"
    static let source = URL(string: "https://github.com/appium/WebDriverAgent/archive/refs/tags/v\(version).tar.gz")!
    public static let port = 8100
    /// The runner's bundle id in the project, replaced by one of the team's own.
    static let upstreamBundleID = "com.facebook.WebDriverAgentRunner"
    /// `defaults write dev.jeremytrips.Viber WebDriverAgentTeam <team id>` picks the team when Xcode has several.
    public static let teamDefaultsKey = "WebDriverAgentTeam"

    static var folder: URL { ViberPaths.support.appendingPathComponent("WebDriverAgent") }

    public struct Team: Equatable, Sendable {
        public var id: String
        public var name: String
        /// A Personal Team: works, but its profiles expire after 7 days.
        public var free: Bool
    }

    // MARK: Signing

    /// The development teams of the accounts in Xcode → Settings → Accounts, from Xcode's preferences. Paid teams first.
    public static func parseTeams(_ plist: Data) -> [Team] {
        guard let prefs = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let byAccount = prefs["IDEProvisioningTeamByIdentifier"] as? [String: Any] ?? prefs["IDEProvisioningTeams"] as? [String: Any]
        else { return [] }
        var teams: [Team] = []
        for case let list as [[String: Any]] in byAccount.values {
            for entry in list {
                guard let id = entry["teamID"] as? String, !teams.contains(where: { $0.id == id }) else { continue }
                let free = (entry["isFreeProvisioningTeam"] as? Bool) ?? ((entry["isFreeProvisioningTeam"] as? Int) == 1)
                teams.append(Team(id: id, name: entry["teamName"] as? String ?? id, free: free))
            }
        }
        return teams.sorted { ($0.free ? 1 : 0, $0.name) < ($1.free ? 1 : 0, $1.name) }
    }

    /// The team to sign with: the one set with `teamDefaultsKey`, else the only paid team, else the only team.
    public static func chooseTeam(_ teams: [Team], preferred: String?) throws -> Team {
        if let preferred, !preferred.isEmpty {
            return teams.first { $0.id == preferred } ?? Team(id: preferred, name: preferred, free: false)
        }
        let paid = teams.filter { !$0.free }
        if paid.count == 1 { return paid[0] }
        if paid.isEmpty, teams.count == 1 { return teams[0] }
        if teams.isEmpty {
            throw DeviceError.failed("Driving a physical iPhone needs Viber's test agent signed by a development team, and Xcode has none. Add your Apple ID in Xcode → Settings → Accounts, then try again.")
        }
        let list = (paid.isEmpty ? teams : paid).map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
        throw DeviceError.failed("Xcode has several development teams (\(list)). Pick the one that signs Viber's test agent with `defaults write dev.jeremytrips.Viber \(teamDefaultsKey) <team id>`, then try again.")
    }

    static func team() async throws -> Team {
        let prefs = await Shell.runAsync("defaults", ["export", "com.apple.dt.Xcode", "-"], timeout: 20)
        return try chooseTeam(parseTeams(Data(prefs.stdout.utf8)), preferred: UserDefaults.standard.string(forKey: teamDefaultsKey))
    }

    /// The runner's bundle id for a team. Bundle ids are unique across Apple, so it carries the team id.
    public static func bundleID(team: String) -> String { "dev.viber.wda.\(team.lowercased()).WebDriverAgentRunner" }

    // MARK: Building

    /// The built runner's .xctestrun for the team, downloading and building it the first time (a few minutes).
    /// `progress` says what is going on, for the user.
    public static func xctestrun(progress: @escaping @MainActor (String) -> Void) async throws -> URL {
        let team = try await team()
        let root = folder.appendingPathComponent("\(version)-\(team.id)")
        let products = root.appendingPathComponent("build/Build/Products")
        if let built = findXctestrun(in: products) { return built }

        await progress("Downloading WebDriverAgent \(version)…")
        let project = try await unpack(into: root, team: team.id)
        await progress("Building WebDriverAgent for \(team.name); this takes a few minutes the first time…")
        let result = await Subprocess.run("xcrun", [
            "xcodebuild", "build-for-testing", "-project", project.path, "-scheme", "WebDriverAgentRunner",
            "-destination", "generic/platform=iOS", "-derivedDataPath", root.appendingPathComponent("build").path,
            "-allowProvisioningUpdates", "DEVELOPMENT_TEAM=\(team.id)", "CODE_SIGN_STYLE=Automatic",
        ], timeout: 1200)
        guard result.ok, let built = findXctestrun(in: products) else {
            throw DeviceError.failed("Could not build WebDriverAgent signed by \(team.name): " + buildError(result.output))
        }
        return built
    }

    /// Downloads the pinned source, checks it, and unpacks it with the runner's bundle id set to the team's.
    static func unpack(into root: URL, team: String) async throws -> URL {
        let fm = FileManager.default
        let project = root.appendingPathComponent("WebDriverAgent-\(version)/WebDriverAgent.xcodeproj")
        if fm.fileExists(atPath: project.path) { return project }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let (download, response) = try await URLSession.shared.download(from: source)
        defer { try? fm.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DeviceError.failed("Could not download WebDriverAgent from GitHub.")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: download)).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw DeviceError.failed("The WebDriverAgent download does not match its pinned SHA-256.") }
        let untar = await Shell.runAsync("tar", ["-xzf", download.path, "-C", root.path], timeout: 120)
        guard untar.status == 0 else { throw DeviceError.failed("Could not unpack WebDriverAgent: \(untar.stderr)") }
        let pbxproj = project.appendingPathComponent("project.pbxproj")
        let text = try String(contentsOf: pbxproj, encoding: .utf8)
        try text.replacingOccurrences(of: upstreamBundleID, with: bundleID(team: team)).write(to: pbxproj, atomically: true, encoding: .utf8)
        return project
    }

    static func findXctestrun(in products: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.pathExtension == "xctestrun" && $0.lastPathComponent.contains("iphoneos") }
    }

    /// The `error:` lines of an xcodebuild log, or its end.
    public static func buildError(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        var errors: [String] = []
        for line in lines where line.contains("error:") {
            let text = line.components(separatedBy: "error:").last!.trimmingCharacters(in: .whitespaces)
            if !errors.contains(text) { errors.append(text) }
        }
        let text = errors.isEmpty ? lines.suffix(8).joined(separator: "\n") : errors.prefix(4).joined(separator: " ")
        return String(text.prefix(1200))
    }

    /// The URL the server prints when it starts: `ServerURLHere->http://192.168.1.20:8100<-ServerURLHere`.
    public static func serverURL(in line: String) -> URL? {
        guard let start = line.range(of: "ServerURLHere->"), let end = line.range(of: "<-ServerURLHere", range: start.upperBound..<line.endIndex)
        else { return nil }
        return URL(string: String(line[start.upperBound..<end.lowerBound]))
    }

    /// The server's address through the phone's CoreDevice tunnel.
    public static func tunnelURL(_ address: String) -> URL? {
        URL(string: "http://[\(address)]:\(port)")
    }
}

/// `xcodebuild test-without-building` running WebDriverAgent on a phone. Its test never ends on its own: stopping this
/// process stops the server.
public final class WebDriverAgentRun: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var pending = Data()
    private var tail: [String] = []
    private var announced: URL?

    public init(xctestrun: URL, udid: String) throws {
        guard let xcrun = Executables.find("xcrun") else { throw ShellError.notFound("xcrun") }
        process.executableURL = URL(fileURLWithPath: xcrun)
        process.arguments = ["xcodebuild", "test-without-building", "-xctestrun", xctestrun.path,
                             "-destination", "id=\(udid)", "-destination-timeout", "60"]
        process.environment = Executables.environment()
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.received(data)
        }
        try process.run()
    }

    private func received(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            if let url = WebDriverAgent.serverURL(in: line) { announced = url }
            tail.append(line)
            if tail.count > 200 { tail.removeFirst(tail.count - 200) }
        }
    }

    public var isRunning: Bool { process.isRunning }

    /// The URL the server announced, once it is up.
    public var serverURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return announced
    }

    /// Why it stopped, from xcodebuild's output.
    public var failure: String {
        lock.lock(); defer { lock.unlock() }
        let output = tail.joined(separator: "\n")
        if output.contains("Developer App Certificate is not trusted") || output.contains("invalid code signature") {
            return "iOS doesn't trust the developer who signed WebDriverAgent yet. On the phone, open Settings → General → VPN & Device Management, trust the developer, then try again."
        }
        if output.contains("is locked") || output.contains("Unlock") {
            return "The phone is locked. Unlock it, then try again."
        }
        return "WebDriverAgent stopped: " + WebDriverAgent.buildError(output)
    }

    public func stop() {
        if process.isRunning { process.terminate() }
    }

    deinit { stop() }
}

/// WebDriverAgent's HTTP API, the part Viber uses.
public final class WebDriverAgentClient: @unchecked Sendable {
    public let base: URL
    private let lock = NSLock()
    private var sessionID: String?
    private let urlSession: URLSession

    public init(base: URL) {
        self.base = base
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        urlSession = URLSession(configuration: config)
    }

    /// Whether the server answers.
    public func isUp(timeout: TimeInterval = 3) async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("status"))
        request.timeoutInterval = timeout
        guard let (_, response) = try? await urlSession.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Sends a request and returns the response's `value`.
    @discardableResult
    func send(_ method: String, _ path: String, _ body: JSON? = nil) async throws -> JSON {
        var request = URLRequest(url: URL(string: base.absoluteString + path)!)
        request.httpMethod = method
        if let body {
            request.httpBody = Data(body.line().utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        do {
            (data, _) = try await urlSession.data(for: request)
        } catch {
            throw DeviceError.failed("WebDriverAgent on the phone did not answer (\(error.localizedDescription)).")
        }
        let reply = JSON(data: data)
        let value = reply?["value"] ?? .null
        if let error = value["error"]?.string {
            throw WebDriverAgentError(code: error, message: value["message"]?.string ?? error)
        }
        return value
    }

    /// Sends a request in the session, starting one first, and again once if the old one is gone.
    @discardableResult
    func inSession(_ method: String, _ path: String, _ body: JSON? = nil) async throws -> JSON {
        do {
            return try await send(method, "/session/\(try await session())" + path, body)
        } catch let error as WebDriverAgentError where error.code == "invalid session id" {
            lock.withLock { sessionID = nil }
            return try await send(method, "/session/\(try await session())" + path, body)
        }
    }

    /// A session on whatever app is in front.
    private func session() async throws -> String {
        if let id = lock.withLock({ sessionID }) { return id }
        let value = try await send("POST", "/session", ["capabilities": ["alwaysMatch": [:]]])
        guard let id = value["sessionId"]?.string else { throw DeviceError.failed("WebDriverAgent did not start a session.") }
        lock.withLock { sessionID = id }
        return id
    }

    /// The front app's elements. Visibility and accessibility are left out: WebDriverAgent computes them slowly.
    public func tree() async throws -> UITree {
        let value = try await send("GET", "/source?format=json&excluded_attributes=visible,accessible,focused,placeholderValue,nativeFrame,traits,minValue,maxValue,customActions")
        guard let root = Self.element(value) else { throw DeviceError.failed("WebDriverAgent returned no elements.") }
        return UITree(root: root)
    }

    /// An element of `GET /source?format=json`.
    public static func element(_ json: JSON) -> UIElement? {
        guard let type = json["type"]?.string, let rect = json["rect"] else { return nil }
        func text(_ key: String) -> String? {
            guard let s = json[key]?.string, !s.isEmpty else { return nil }
            return s
        }
        let frame = CGRect(x: rect["x"]?.double ?? 0, y: rect["y"]?.double ?? 0,
                           width: rect["width"]?.double ?? 0, height: rect["height"]?.double ?? 0)
        let enabled: Bool
        switch json["isEnabled"] {
        case .bool(let b)?: enabled = b
        case .string(let s)?: enabled = s != "0" && s != "false"
        case .number(let n)?: enabled = n != 0
        default: enabled = true
        }
        return UIElement(role: type, label: text("label"), value: text("value"), identifier: text("rawIdentifier"),
                         frame: frame, enabled: enabled, children: (json["children"]?.array ?? []).compactMap(element))
    }

    /// One finger along `path` in points: a tap or long press for one point, a drag for more.
    public func gesture(_ path: [CGPoint], duration: TimeInterval) async throws {
        try await inSession("POST", "/actions", Self.actions(path, duration: duration))
    }

    /// The W3C pointer actions for a gesture. A swipe keeps at most 10 steps: each is a request round trip's worth of
    /// work on the phone, and the line between them is straight anyway.
    public static func actions(_ path: [CGPoint], duration: TimeInterval) -> JSON {
        guard let first = path.first else { return ["actions": []] }
        func move(_ p: CGPoint, _ ms: Int) -> JSON {
            ["type": "pointerMove", "duration": .number(Double(ms)), "x": .number(p.x.rounded()), "y": .number(p.y.rounded())]
        }
        var steps: [JSON] = [move(first, 0), ["type": "pointerDown", "button": 0]]
        let totalMs = max(Int(duration * 1000), 1)
        if path.count == 1 {
            steps.append(["type": "pause", "duration": .number(Double(totalMs))])
        } else {
            let stride = max(1, (path.count - 1 + 9) / 10)
            var points = Swift.stride(from: stride, to: path.count - 1, by: stride).map { path[$0] }
            points.append(path[path.count - 1])
            for p in points { steps.append(move(p, totalMs / points.count)) }
        }
        steps.append(["type": "pointerUp", "button": 0])
        return ["actions": [["type": "pointer", "id": "finger", "parameters": ["pointerType": "touch"], "actions": .array(steps)]]]
    }

    /// Types into the focused field. "\n" is Return and "\u{8}" deletes.
    public func type(_ text: String) async throws {
        try await inSession("POST", "/wda/keys", ["value": .array(text.map { .string(String($0)) })])
    }

    /// Empties the focused field.
    public func clearFocused() async throws {
        let active = try await inSession("GET", "/element/active")
        guard let id = active["ELEMENT"]?.string ?? active["element-6066-11e4-a52e-4f735466cecf"]?.string else {
            throw DeviceError.failed("No text field has the focus. Tap one first.")
        }
        try await inSession("POST", "/element/\(id)/clear")
    }

    public func home() async throws { try await send("POST", "/wda/homescreen") }
    public func lock() async throws { try await send("POST", "/wda/lock") }
    /// `volumeup` or `volumedown`.
    public func pressButton(_ name: String) async throws { try await inSession("POST", "/wda/pressButton", ["name": .string(name)]) }

    /// The screen as PNG, in pixels.
    public func screenshot() async throws -> Data {
        guard let base64 = try await send("GET", "/screenshot").string, let data = Data(base64Encoded: base64) else {
            throw DeviceError.failed("WebDriverAgent returned no screenshot.")
        }
        return data
    }
}

public struct WebDriverAgentError: Error, LocalizedError {
    public var code: String
    public var message: String
    public var errorDescription: String? { "WebDriverAgent: " + String(message.prefix(400)) }
}
