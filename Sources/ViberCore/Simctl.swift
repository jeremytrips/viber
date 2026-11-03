import Foundation

public enum DeviceError: Error, LocalizedError, Equatable {
    case failed(String)
    public var errorDescription: String? { if case .failed(let m) = self { return m }; return nil }
}

/// The public `xcrun simctl` side of the iOS simulator: everything that does not need the live screen.
public enum Simctl {
    static func run(_ arguments: [String], input: Data? = nil) async -> ShellResult {
        await Task.detached { Shell.run("xcrun", ["simctl"] + arguments, input: input) }.value
    }

    /// Runs simctl and throws its error output when it fails.
    @discardableResult
    static func check(_ arguments: [String], input: Data? = nil, what: String) async throws -> ShellResult {
        let result = await run(arguments, input: input)
        guard result.ok else {
            if result.status == 127 { throw DeviceError.failed("xcrun was not found. Install Xcode to use iOS simulators.") }
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DeviceError.failed("Could not \(what)" + (detail.isEmpty ? "." : ": \(String(detail.suffix(600)))"))
        }
        return result
    }

    public static func devices() async throws -> [DeviceInfo] {
        let result = try await check(["list", "devices", "available", "-j"], what: "list simulators")
        return DeviceCatalog.parseSimctl(result.stdoutData)
    }

    /// Boots the device if needed and waits until it has finished booting.
    public static func boot(_ udid: String) async throws {
        let result = await run(["boot", udid])
        // Already booted is fine.
        if !result.ok, !result.stderr.contains("current state: Booted") {
            throw DeviceError.failed("Could not boot the simulator: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        try await check(["bootstatus", udid, "-b"], what: "wait for the simulator to boot")
    }

    public static func shutdown(_ udid: String) async throws {
        let result = await run(["shutdown", udid])
        if !result.ok, !result.stderr.contains("current state: Shutdown") {
            throw DeviceError.failed("Could not shut down the simulator: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Installs a built `.app` and returns its bundle identifier.
    public static func install(_ udid: String, app path: String) async throws -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard url.pathExtension == "app" else {
            throw DeviceError.failed("\(path) is not an .app bundle. Build for the simulator (e.g. xcodebuild -sdk iphonesimulator) and pass the .app from the build folder.")
        }
        guard let identifier = bundleIdentifier(of: url) else {
            throw DeviceError.failed("\(path) has no Info.plist with a CFBundleIdentifier. Is the build finished?")
        }
        try await check(["install", udid, url.path], what: "install \(url.lastPathComponent)")
        return identifier
    }

    public static func bundleIdentifier(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleIdentifier"] as? String
    }

    public static func launchArguments(_ udid: String, app: String, arguments: [String], terminateRunning: Bool) -> [String] {
        ["launch"] + (terminateRunning ? ["--terminate-running-process"] : []) + [udid, app] + arguments
    }

    /// Returns the new process's pid as simctl prints it ("com.example.app: 4242").
    @discardableResult
    public static func launch(_ udid: String, app: String, arguments: [String] = [], terminateRunning: Bool = true) async throws -> String {
        let result = try await check(launchArguments(udid, app: app, arguments: arguments, terminateRunning: terminateRunning), what: "launch \(app)")
        return result.output.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    public static func terminate(_ udid: String, app: String) async throws {
        try await check(["terminate", udid, app], what: "stop \(app)")
    }

    public static func openURL(_ udid: String, _ url: String) async throws {
        do {
            try await check(["openurl", udid, url], what: "open \(url)")
        } catch DeviceError.failed(let message) where message.contains("-10814") {
            // LaunchServices' "application not found" (simctl exits 194): nothing installed handles the scheme.
            throw DeviceError.failed(noAppMessage(for: url))
        }
    }

    static func noAppMessage(for url: String) -> String {
        let scheme = String(url.prefix { $0 != ":" })
        let app = scheme == "exp" ? "Expo Go" : scheme.hasPrefix("exp+") ? "the development build" : "the app"
        return "No app on the simulator opens \(scheme):// links. Install \(app) first."
    }

    /// The screen as PNG, without the live stream. Slower (a few hundred ms) but needs nothing private.
    public static func screenshot(_ udid: String) async throws -> Data {
        // simctl's help offers "-" for stdout, but it writes a file named "-" instead.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("viber-screenshot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try await check(["io", udid, "screenshot", "--type=png", file.path], what: "take a screenshot")
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { throw DeviceError.failed("The simulator returned an empty screenshot.") }
        return data
    }

    /// Puts text on the simulator's pasteboard.
    public static func pbcopy(_ udid: String, _ text: String) async throws {
        try await check(["pbcopy", udid], input: Data(text.utf8), what: "set the simulator's clipboard")
    }

    public static func logArguments(_ udid: String, process: String?, seconds: Int) -> [String] {
        var args = ["spawn", udid, "log", "show", "--last", "\(max(1, seconds))s", "--style", "compact"]
        if let process, !process.isEmpty {
            let quoted = "\"" + process.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            args += ["--predicate", "process == \(quoted) OR subsystem == \(quoted)"]
        }
        return args
    }

    public static func logs(_ udid: String, process: String?, seconds: Int) async throws -> String {
        try await check(logArguments(udid, process: process, seconds: seconds), what: "read the simulator's log").stdout
    }

    // MARK: Settings

    /// The service's name for `simctl privacy`; nil when simctl has no such service.
    public static func privacyService(_ service: PrivacyService) -> String? {
        switch service {
        case .camera, .notifications: return nil
        default: return service.rawValue.replacingOccurrences(of: "_", with: "-")
        }
    }

    /// What `set` runs; nil when simctl can't change the setting.
    public static func settingArguments(_ udid: String, _ setting: DeviceSetting) -> [String]? {
        switch setting {
        case .appearance(let dark):
            return ["ui", udid, "appearance", dark ? "dark" : "light"]
        case .location(let latitude, let longitude):
            // simctl wants "." as the decimal separator, whatever the Mac's locale.
            return ["location", udid, "set", String(format: "%.6f,%.6f", latitude, longitude)]
        case .permission(let change, let service, let app):
            return privacyService(service).map { ["privacy", udid, change.rawValue, $0, app] }
        case .statusBar(clean: true):
            return ["status_bar", udid, "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
                    "--cellularMode", "active", "--cellularBars", "4", "--operatorName", "", "--batteryState", "charged", "--batteryLevel", "100"]
        case .statusBar(clean: false):
            return ["status_bar", udid, "clear"]
        }
    }

    public static func set(_ udid: String, _ setting: DeviceSetting) async throws {
        guard let arguments = settingArguments(udid, setting) else { throw DeviceError.failed("simctl can't \(setting.what).") }
        try await check(arguments, what: setting.what)
    }
}
