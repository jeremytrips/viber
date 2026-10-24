import CoreGraphics
import Foundation

/// The `xcrun devicectl` side of physical iPhones and iPads (CoreDevice, Xcode 15 and later): listing them, their screen
/// size, and installing and launching apps. devicectl has no screenshot, touch or log command: the live screen comes
/// through `IPhoneScreen`, and logs are the console of apps Viber launched (`AppConsole`).
/// Its JSON output, written to a file, is the stable interface; standard output is meant for people.
public enum Devicectl {
    /// A phone as devicectl lists it, and why it can't be used yet.
    public struct Phone: Equatable, Sendable {
        public var info: DeviceInfo
        public var notReady: String?
    }

    static let safari = "com.apple.mobilesafari"
    static let expoGo = "host.exp.Exponent"

    /// Runs devicectl with its JSON result written to a temporary file, and returns that JSON too.
    static func run(_ arguments: [String], timeout: TimeInterval) async -> (result: ShellResult, json: Data?) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("viber-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = await Shell.runAsync("xcrun", ["devicectl", "--quiet", "--json-output", file.path] + arguments, timeout: timeout)
        return (result, try? Data(contentsOf: file))
    }

    /// Runs devicectl and throws its error when it fails; returns the JSON result.
    @discardableResult
    static func check(_ arguments: [String], timeout: TimeInterval = 60, what: String) async throws -> Data {
        let (result, json) = await run(arguments, timeout: timeout)
        guard result.ok else { throw failure(result, what: what) }
        return json ?? Data()
    }

    static func failure(_ result: ShellResult, what: String) -> DeviceError {
        if result.status == 127 { return .failed("xcrun was not found. Install Xcode to use iPhones.") }
        if result.status == 124 { return .failed("Could not \(what): devicectl did not finish in time. Is the phone unlocked and nearby?") }
        return .failed("Could not \(what)" + (errorText(result.stderr + "\n" + result.stdout).map { ": \($0)" } ?? "."))
    }

    /// The `ERROR:` lines devicectl printed, without the prefix or the details indented under them.
    public static func errorText(_ output: String) -> String? {
        let errors = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            line.hasPrefix("ERROR:") ? line.dropFirst(6).trimmingCharacters(in: .whitespaces) : nil
        }
        let text = errors.isEmpty ? output.trimmingCharacters(in: .whitespacesAndNewlines) : errors.joined(separator: " ")
        return text.isEmpty ? nil : String(text.prefix(600))
    }

    // MARK: Listing

    /// iPhones and iPads from `devicectl list devices`. Only nearby ones: paired phones that are away have no transport.
    public static func parseDevices(_ data: Data) -> [Phone] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any], let entries = result["devices"] as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            let hardware = entry["hardwareProperties"] as? [String: Any] ?? [:]
            let properties = entry["deviceProperties"] as? [String: Any] ?? [:]
            let connection = entry["connectionProperties"] as? [String: Any] ?? [:]
            guard let id = entry["identifier"] as? String, hardware["platform"] as? String == "iOS",
                  hardware["reality"] as? String == "physical", let transport = connection["transportType"] as? String else { return nil }
            let name = properties["name"] as? String ?? hardware["marketingName"] as? String ?? "iPhone"
            var notReady: String?
            if connection["pairingState"] as? String != "paired" {
                notReady = "Unlock \(name) and tap Trust when it asks whether to trust this Mac."
            } else if properties["developerModeStatus"] as? String == "disabled" {
                notReady = "Turn on Developer Mode on \(name) (Settings → Privacy & Security → Developer Mode), then try again."
            }
            let info = DeviceInfo(id: id, name: name, platform: .ios, kind: .physical,
                                  os: (properties["osVersionNumber"] as? String).map { "iOS \($0)" } ?? "iOS",
                                  state: notReady == nil ? .booted : .unknown, typeIdentifier: hardware["productType"] as? String ?? "",
                                  serial: hardware["udid"] as? String, wireless: transport != "wired")
            return Phone(info: info, notReady: notReady)
        }
    }

    /// Nearby iPhones and iPads, and why each can't be used yet. Empty without Xcode; never throws, so Macs without phones are fine.
    public static func phones() async -> [Phone] {
        let (result, json) = await run(["list", "devices"], timeout: 15)
        guard result.ok, let json else { return [] }
        return parseDevices(json)
    }

    public static func devices() async -> [DeviceInfo] { await phones().map(\.info) }

    /// The main screen's size in pixels (natural orientation) and its pixels per point, from `device info displays`.
    public static func parseDisplays(_ data: Data) -> (pixels: CGSize, scale: Double)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any], let displays = result["displays"] as? [[String: Any]],
              let main = displays.first(where: { $0["primary"] as? Bool == true }) ?? displays.first,
              let size = main["nativeSize"] as? [Double], size.count == 2,
              let scale = main["pointScale"] as? Double, scale > 0 else { return nil }
        return (CGSize(width: size[0], height: size[1]), scale)
    }

    /// Connects to the phone (seconds over Wi-Fi) and reads its screen size.
    public static func displays(_ id: String) async throws -> (pixels: CGSize, scale: Double) {
        let json = try await check(["device", "info", "displays", "--device", id], timeout: 60, what: "connect to the phone")
        guard let displays = parseDisplays(json) else { throw DeviceError.failed("devicectl returned no screen size for the phone.") }
        return displays
    }

    // MARK: Apps

    /// What Viber needs from a built app's Info.plist.
    public struct AppBundle: Equatable, Sendable {
        public var identifier: String
        public var executable: String?
        /// The URL schemes it opens, lowercased ("myapp" for myapp://).
        public var schemes: [String]
        /// iPhoneOS for a device build, iPhoneSimulator for a simulator build.
        public var platforms: [String]
    }

    public static func appBundle(_ app: URL) -> AppBundle? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String else { return nil }
        let types = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return AppBundle(identifier: identifier, executable: info["CFBundleExecutable"] as? String,
                         schemes: types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.map { $0.lowercased() },
                         platforms: info["CFBundleSupportedPlatforms"] as? [String] ?? [])
    }

    static let deviceBuildHint = "Build for the device (xcodebuild -destination 'generic/platform=iOS' with a development team) and pass the .app from Build/Products/Debug-iphoneos."

    /// Checks that `path` is a finished `.app` built for devices.
    public static func deviceApp(_ path: String) throws -> (url: URL, bundle: AppBundle) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard url.pathExtension == "app" else { throw DeviceError.failed("\(path) is not an .app bundle. " + deviceBuildHint) }
        guard let bundle = appBundle(url) else {
            throw DeviceError.failed("\(path) has no Info.plist with a CFBundleIdentifier. Is the build finished?")
        }
        if bundle.platforms.contains("iPhoneSimulator") {
            throw DeviceError.failed("\(url.lastPathComponent) is built for the iOS simulator, which a physical iPhone can't run. " + deviceBuildHint)
        }
        return (url, bundle)
    }

    /// Installs a `.app` built and signed for devices, and returns what its Info.plist says.
    public static func install(_ id: String, app path: String) async throws -> AppBundle {
        let (url, bundle) = try deviceApp(path)
        try await check(["device", "install", "app", "--device", id, url.path], timeout: 600, what: "install \(url.lastPathComponent)")
        return bundle
    }

    /// `console` keeps devicectl attached to the app's output until the app quits, with os_log lines copied there too.
    public static func launchArguments(_ id: String, app: String, arguments: [String], terminateRunning: Bool,
                                       console: Bool = false, url: String? = nil) -> [String] {
        var args = ["device", "process", "launch", "--device", id]
        if terminateRunning { args.append("--terminate-existing") }
        if console { args += ["--console", "--environment-variables", #"{"OS_ACTIVITY_DT_MODE":"YES"}"#] }
        if let url { args += ["--payload-url", url] }
        // After --, arguments that start with a dash go to the app instead of devicectl.
        return args + ["--", app] + arguments
    }

    public static func launch(_ id: String, app: String, arguments: [String] = [], terminateRunning: Bool, url: String? = nil) async throws {
        try await check(launchArguments(id, app: app, arguments: arguments, terminateRunning: terminateRunning, url: url),
                        timeout: 90, what: url.map { "open \($0)" } ?? "launch \(app)")
    }

    /// The app that opens `url` on a phone, which has no "open this URL" command: Safari for web pages, Expo Go for exp://,
    /// an app Viber installed that claims the scheme (`schemes`: scheme to bundle id), else the app launched last.
    public static func opener(for url: String, schemes: [String: String], lastApp: String?) -> String? {
        guard let colon = url.firstIndex(of: ":") else { return nil }
        switch url[..<colon].lowercased() {
        case "http", "https": return safari
        case "exp", "exps": return expoGo
        case let scheme: return schemes[scheme] ?? lastApp
        }
    }

    /// Whether `url` points at localhost, which on a phone is the phone itself.
    public static func pointsAtLocalhost(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"].contains(host)
    }
}

/// An app's output while it runs, from `devicectl device process launch --console`, with when each line arrived so
/// device_logs can return the last seconds of it. OS_ACTIVITY_DT_MODE copies os_log and Logger lines there too.
/// devicectl forwards signals to the app, so stopping it stops the app.
public final class AppConsole: @unchecked Sendable {
    /// The bundle id.
    public let app: String
    public let executable: String?
    private let process = Process()
    private let lock = NSLock()
    private var entries: [(date: Date, text: String)] = []
    private var pending = Data()
    /// Everything before devicectl said the app started, for errors.
    private var preamble: [String] = []
    private var launched = false
    private let limit: Int

    /// Starts `tool arguments`, the devicectl launch command, and reads its output from then on.
    public init(app: String, executable: String?, tool: String, arguments: [String], limit: Int = 5000) throws {
        self.app = app
        self.executable = executable
        self.limit = limit
        guard let path = tool.hasPrefix("/") ? tool : Executables.find(tool) else { throw ShellError.notFound(tool) }
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
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

    /// devicectl's own lines around the launch. The rest is the app's, which can start before devicectl reports the launch.
    static func isDevicectlLine(_ line: String) -> Bool {
        ["Launched application with", "Waiting for the application to terminate", "Acquired tunnel connection",
         "Enabling developer disk image services", "Acquired usage assertion"].contains { line.contains($0) }
    }

    private func received(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: ["\r"])
            pending.removeSubrange(pending.startIndex...newline)
            if line.contains("Launched application with") || line.contains("Waiting for the application to terminate") { launched = true }
            if Self.isDevicectlLine(line) { continue }
            if !launched { preamble.append(line) }
            entries.append((Date(), line))
            if entries.count > limit { entries.removeFirst(entries.count - limit) }
        }
    }

    public var isRunning: Bool { process.isRunning }

    private var launchState: (started: Bool, said: String) {
        lock.lock(); defer { lock.unlock() }
        return (launched, preamble.joined(separator: "\n"))
    }

    /// Waits until devicectl says the app started. Throws devicectl's error when it quits first, and stops it when it
    /// takes longer than `timeout`.
    public func waitForLaunch(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var exitedAt: Date?
        while true {
            let (started, said) = launchState
            if started { return }
            if !process.isRunning {
                // Its last lines may still be in the pipe.
                if let exitedAt, Date().timeIntervalSince(exitedAt) > 0.3 {
                    throw DeviceError.failed("Could not launch \(app)" + (Devicectl.errorText(said).map { ": \($0)" } ?? "."))
                }
                exitedAt = exitedAt ?? Date()
            } else if Date() >= deadline {
                stop()
                throw DeviceError.failed("devicectl did not confirm within \(Int(timeout)) s that \(app) launched. Is the phone unlocked?")
            }
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { stop(); throw error }
        }
    }

    /// The app's lines since `date`; with `matching`, only those that contain it (ignoring case).
    public func lines(since date: Date, matching: String? = nil) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { entry in
            entry.date >= date && (matching.map { entry.text.localizedCaseInsensitiveContains($0) } ?? true)
        }.map(\.text)
    }

    /// Whether `process`, as device_logs takes it (a bundle id or executable name), names this app.
    public func isApp(_ process: String) -> Bool {
        process.caseInsensitiveCompare(app) == .orderedSame || executable.map { process.caseInsensitiveCompare($0) == .orderedSame } == true
    }

    /// Stops devicectl, and with it the app.
    public func stop() {
        if process.isRunning { process.terminate() }
    }
}
