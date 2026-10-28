import CoreGraphics
import Foundation

/// Where the Android SDK's tools are. GUI apps don't see the shell's ANDROID_HOME, so the usual install places are tried too.
public struct AndroidSDK: Equatable, Sendable {
    public var root: String?
    public var adb: String?
    public var emulator: String?
    /// Google's Android CLI (`android`), whose `layout` command reads screens uiautomator can't.
    public var cli: String?

    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> AndroidSDK {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"], "\(home)/Library/Android/sdk",
                          "/opt/homebrew/share/android-commandlinetools", "/usr/local/share/android-commandlinetools"].compactMap { $0 }
        let root = candidates.first { fm.isExecutableFile(atPath: "\($0)/platform-tools/adb") || fm.isExecutableFile(atPath: "\($0)/emulator/emulator") }
        func tool(_ relative: String) -> String? {
            guard let root else { return nil }
            let path = "\(root)/\(relative)"
            return fm.isExecutableFile(atPath: path) ? path : nil
        }
        return AndroidSDK(root: root, adb: tool("platform-tools/adb") ?? Executables.find("adb"),
                          emulator: tool("emulator/emulator") ?? Executables.find("emulator"), cli: Executables.find("android"))
    }

    /// aapt2 from the newest build-tools, for reading an APK's package name.
    public var aapt2: String? {
        guard let root, let versions = try? FileManager.default.contentsOfDirectory(atPath: "\(root)/build-tools") else { return nil }
        return versions.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            .map { "\(root)/build-tools/\($0)/aapt2" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Child processes need to know the SDK too (the emulator, the Android CLI).
    public var environment: [String: String] {
        var extra: [String: String] = [:]
        if let root { extra["ANDROID_HOME"] = root; extra["ANDROID_SDK_ROOT"] = root }
        return Executables.environment(adding: root.map { ["\($0)/platform-tools"] } ?? [], extra: extra)
    }
}

/// One line of `adb devices -l`.
public struct AdbDevice: Equatable, Sendable {
    public var serial: String
    /// "device" when usable; else "offline", "unauthorized", "no permissions"…
    public var state: String
    public var model: String?
    public var isEmulator: Bool { serial.hasPrefix("emulator-") }
    public var isReady: Bool { state == "device" }
}

/// An Android Virtual Device, from `~/.android/avd/<name>.ini` and its `config.ini`.
public struct AVD: Equatable, Sendable {
    public var name: String
    public var displayName: String
    /// "37.0", from `target=android-37.0`.
    public var api: String?
    /// The hardware profile, e.g. "pixel_8" or "pixel_tablet".
    public var hardware: String?
}

/// The adb side of Android devices: everything except the live screen and input, which go through scrcpy.
public enum Adb {
    public static var sdk: AndroidSDK { AndroidSDK.locate() }

    static func run(_ serial: String?, _ arguments: [String], timeout: TimeInterval = 20, input: Data? = nil) async -> ShellResult {
        let sdk = sdk
        guard let adb = sdk.adb else { return ShellResult(status: 127, stdout: "", stderr: "adb not found") }
        return await Shell.runAsync(adb, (serial.map { ["-s", $0] } ?? []) + arguments, environment: sdk.environment, input: input, timeout: timeout)
    }

    /// Runs adb and throws its error output when it fails.
    @discardableResult
    static func check(_ serial: String?, _ arguments: [String], timeout: TimeInterval = 20, what: String) async throws -> ShellResult {
        let result = await run(serial, arguments, timeout: timeout)
        guard result.ok else { throw failure(result, what: what) }
        return result
    }

    static func failure(_ result: ShellResult, what: String) -> DeviceError {
        if result.status == 127 {
            return .failed("adb was not found. Install Android Studio (or the Android SDK platform-tools) to use Android devices.")
        }
        let detail = (result.stderr + "\n" + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed("Could not \(what)" + (detail.isEmpty ? "." : ": \(String(detail.suffix(600)))"))
    }

    /// Runs a command line in the device's shell and returns its output.
    @discardableResult
    public static func shell(_ serial: String, _ command: String, timeout: TimeInterval = 20, what: String) async throws -> String {
        try await check(serial, ["shell", command], timeout: timeout, what: what).stdout
    }

    /// Quotes one argument for the device's shell (adb joins `shell` arguments with spaces and hands them to sh).
    public static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Listing

    public static func parseDevices(_ output: String) -> [AdbDevice] {
        output.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("List of devices"), !line.hasPrefix("*") else { return nil }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2 else { return nil }
            var state = fields[1]
            if state == "no", fields.count > 2, fields[2] == "permissions" { state = "no permissions" }
            let model = fields.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
            return AdbDevice(serial: fields[0], state: state, model: model)
        }
    }

    public static func parseIni(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            values[line[..<eq].trimmingCharacters(in: .whitespaces)] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    /// Where AVDs live: ANDROID_AVD_HOME, else ANDROID_USER_HOME/avd, else ~/.android/avd.
    public static func avdHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["ANDROID_AVD_HOME"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        if let dir = environment["ANDROID_USER_HOME"], !dir.isEmpty { return URL(fileURLWithPath: dir).appendingPathComponent("avd") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android/avd")
    }

    /// The AVDs `emulator -list-avds` would list, read from the same files.
    public static func listAVDs(in home: URL = avdHome()) -> [AVD] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "ini" }.compactMap { file -> AVD? in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let ini = parseIni(text)
            let name = file.deletingPathExtension().lastPathComponent
            var folder = ini["path"].map { URL(fileURLWithPath: $0) }
            if folder.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
                folder = home.appendingPathComponent("\(name).avd")
            }
            let config = folder.flatMap { try? String(contentsOf: $0.appendingPathComponent("config.ini"), encoding: .utf8) }.map(parseIni) ?? [:]
            return avd(name: name, ini: ini, config: config)
        }.sorted { $0.name < $1.name }
    }

    public static func avd(name: String, ini: [String: String], config: [String: String]) -> AVD {
        let target = config["target"] ?? ini["target"] ?? config["image.sysdir.1"]?.split(separator: "/").first { $0.hasPrefix("android-") }.map(String.init)
        let api = target.flatMap { $0.hasPrefix("android-") ? String($0.dropFirst(8)) : nil }
        let display = config["avd.ini.displayname"].flatMap { $0.isEmpty ? nil : $0 } ?? name.replacingOccurrences(of: "_", with: " ")
        return AVD(name: name, displayName: display, api: api, hardware: config["hw.device.name"])
    }

    /// "Android 17" for API 37 ("37.0"), "API 99" when unknown.
    public static func androidVersion(api: String) -> String {
        let major = Int(api.split(whereSeparator: { !$0.isNumber }).first ?? "") ?? 0
        let names: [Int: String] = [21: "5.0", 22: "5.1", 23: "6", 24: "7.0", 25: "7.1", 26: "8.0", 27: "8.1", 28: "9", 29: "10",
                                    30: "11", 31: "12", 32: "12L", 33: "13", 34: "14", 35: "15", 36: "16", 37: "17"]
        return names[major].map { "Android \($0)" } ?? "API \(api)"
    }

    /// What we learned about running emulators and phones, so the 5-second refresh doesn't ask again.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var avdNames: [String: String] = [:]
        private var booted: Set<String> = []
        private var versions: [String: String] = [:]

        func get(_ serial: String) -> (avd: String?, booted: Bool, version: String?) {
            lock.lock(); defer { lock.unlock() }
            return (avdNames[serial], booted.contains(serial), versions[serial])
        }

        func set(_ serial: String, avd: String?, booted isBooted: Bool, version: String?) {
            lock.lock(); defer { lock.unlock() }
            if let avd, !avd.isEmpty { avdNames[serial] = avd }
            if isBooted { booted.insert(serial) }
            if let version, !version.isEmpty { versions[serial] = version }
        }

        func keep(_ serials: Set<String>) {
            lock.lock(); defer { lock.unlock() }
            avdNames = avdNames.filter { serials.contains($0.key) }
            booted = booted.filter { serials.contains($0) }
            versions = versions.filter { serials.contains($0.key) }
        }
    }

    private static let cache = Cache()

    /// AVDs (running or not) and USB phones. Empty without an SDK; never throws for a missing SDK, so iOS-only Macs are fine.
    public static func devices() async -> [DeviceInfo] {
        let avds = listAVDs()
        var attached: [AdbDevice] = []
        if sdk.adb != nil {
            let result = await run(nil, ["devices", "-l"], timeout: 10)
            if result.ok { attached = parseDevices(result.stdout) }
        }
        cache.keep(Set(attached.map(\.serial)))
        var running: [String: (serial: String, booted: Bool, version: String?)] = [:]
        var devices: [DeviceInfo] = []
        for device in attached {
            if device.isEmulator {
                // An emulator that is still coming up is offline; its AVD shows once adb can ask it.
                guard device.isReady else { continue }
                var known = cache.get(device.serial)
                if known.avd == nil || !known.booted || known.version == nil {
                    let props = await run(device.serial, ["shell", "getprop ro.boot.qemu.avd_name; getprop sys.boot_completed; getprop ro.build.version.release"], timeout: 5)
                    let lines = props.stdout.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    var avd = lines.first.flatMap { $0.isEmpty ? nil : $0 }
                    if avd == nil {
                        // Older images: ask the emulator's console ("Pixel_8\r\nOK").
                        let console = await run(device.serial, ["emu", "avd", "name"], timeout: 5)
                        avd = console.stdout.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
                    }
                    cache.set(device.serial, avd: avd, booted: lines.count > 1 && lines[1] == "1", version: lines.count > 2 ? lines[2] : nil)
                    known = cache.get(device.serial)
                }
                let name = known.avd ?? device.serial
                running[name] = (device.serial, known.booted, known.version)
                if !avds.contains(where: { $0.name == name }) {
                    devices.append(DeviceInfo(id: name, name: name.replacingOccurrences(of: "_", with: " "), platform: .android, kind: .emulator,
                                              os: known.version.map { "Android \($0)" } ?? "Android", state: known.booted ? .booted : .booting,
                                              serial: device.serial))
                }
            } else {
                var version = cache.get(device.serial).version
                if device.isReady, version == nil {
                    version = await run(device.serial, ["shell", "getprop ro.build.version.release"], timeout: 5).output
                    cache.set(device.serial, avd: nil, booted: false, version: version)
                }
                devices.append(DeviceInfo(id: device.serial, name: device.model ?? device.serial, platform: .android, kind: .physical,
                                          os: version.flatMap { $0.isEmpty ? nil : "Android \($0)" } ?? "Android",
                                          state: device.isReady ? .booted : .unknown, serial: device.serial))
            }
        }
        for avd in avds {
            let live = running[avd.name]
            devices.append(DeviceInfo(id: avd.name, name: avd.displayName, platform: .android, kind: .emulator,
                                      os: live?.version.map { "Android \($0)" } ?? avd.api.map(androidVersion) ?? "Android",
                                      state: live.map { $0.booted ? .booted : .booting } ?? .shutdown,
                                      typeIdentifier: avd.hardware ?? "", serial: live?.serial))
        }
        return devices
    }

    /// Why a phone in `adb devices` can't be used yet.
    public static func notReadyReason(_ state: String) -> String {
        switch state {
        case "unauthorized": return "Unlock the phone and allow USB debugging for this Mac."
        case "offline": return "adb lost the connection to the phone. Unplug it and plug it in again."
        case "no permissions": return "adb has no permission to use the phone."
        default: return "The phone is not ready (adb says \(state))."
        }
    }

    public static func state(of serial: String) async -> String? {
        let result = await run(nil, ["devices", "-l"], timeout: 10)
        return parseDevices(result.stdout).first { $0.serial == serial }?.state
    }

    // MARK: Emulators

    /// An even console port no running emulator uses; the emulator's serial becomes emulator-<port>.
    public static func freeEmulatorPort(used serials: [String]) -> Int {
        let used = Set(serials.compactMap { $0.hasPrefix("emulator-") ? Int($0.dropFirst(9)) : nil })
        return stride(from: 5554, through: 5682, by: 2).first { !used.contains($0) && !used.contains($0 + 1) } ?? 5554
    }

    public static func emulatorArguments(avd: String, port: Int) -> [String] {
        ["-avd", avd, "-port", "\(port)", "-no-window", "-no-boot-anim"]
    }

    /// Starts an AVD without a window (Viber shows its screen) and returns the emulator process and its serial.
    public static func startEmulator(avd: String, log: URL) async throws -> (process: Process, serial: String) {
        let sdk = sdk
        guard let emulator = sdk.emulator else {
            throw DeviceError.failed("The Android emulator was not found. Install it with Android Studio's SDK Manager (Android Emulator).")
        }
        let attached = sdk.adb != nil ? parseDevices(await run(nil, ["devices"], timeout: 10).stdout) : []
        let port = freeEmulatorPort(used: attached.map(\.serial))
        let process = try Shell.spawn(emulator, emulatorArguments(avd: avd, port: port), environment: sdk.environment, output: log)
        return (process, "emulator-\(port)")
    }

    /// Waits until Android has finished booting, the emulator quits, or `timeout` passes.
    public static func waitForBoot(_ serial: String, process: Process?, log: URL?, name: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled {
            if let process, !process.isRunning {
                let tail = log.map { Shell.tail($0, lines: 8) } ?? ""
                throw DeviceError.failed("The emulator for \(name) quit while booting." + (tail.isEmpty ? "" : "\n\(tail)"))
            }
            let result = await run(serial, ["shell", "getprop sys.boot_completed"], timeout: 5)
            if result.ok, result.output == "1" { return }
            if Date() >= deadline {
                throw DeviceError.failed("\(name) is still booting. Call device_open again in a minute.")
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Shuts an emulator down and waits (up to 30 s) until adb no longer lists it, so a refresh meanwhile doesn't see it running.
    public static func killEmulator(_ serial: String) async throws {
        try await check(serial, ["emu", "kill"], timeout: 10, what: "shut down the emulator")
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !Task.isCancelled {
            let listed = parseDevices(await run(nil, ["devices"], timeout: 10).stdout)
            if !listed.contains(where: { $0.serial == serial }) { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: Apps

    /// Installs an APK (replacing an older build, allowing test-only builds) and returns its package name.
    public static func install(_ serial: String, apk path: String) async throws -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard url.pathExtension.lowercased() == "apk" else {
            throw DeviceError.failed("\(path) is not an .apk. Build one (e.g. ./gradlew assembleDebug) and pass the file from build/outputs/apk.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw DeviceError.failed("\(path) does not exist.") }
        var package = await packageName(apk: url.path)
        let before = package == nil ? await thirdPartyPackages(serial) : []
        let result = try await check(serial, ["install", "-r", "-t", url.path], timeout: 300, what: "install \(url.lastPathComponent)")
        if !result.stdout.contains("Success") {
            throw DeviceError.failed("Could not install \(url.lastPathComponent): \(result.output.suffix(600))")
        }
        if package == nil {
            let added = await thirdPartyPackages(serial).subtracting(before)
            if added.count == 1 { package = added.first }
        }
        guard let package else {
            throw DeviceError.failed("Installed \(url.lastPathComponent), but its package name could not be read (no aapt2 in the SDK's build-tools). Launch it by package name.")
        }
        return package
    }

    /// The package name in an APK's manifest, from the SDK's aapt2.
    public static func packageName(apk path: String) async -> String? {
        guard let aapt2 = sdk.aapt2 else { return nil }
        let result = await Shell.runAsync(aapt2, ["dump", "packagename", path], timeout: 30)
        let name = result.output.split(whereSeparator: \.isNewline).last.map(String.init)
        return result.ok ? name.flatMap { $0.isEmpty ? nil : $0 } : nil
    }

    static func thirdPartyPackages(_ serial: String) async -> Set<String> {
        let output = await run(serial, ["shell", "pm list packages -3"], timeout: 20).stdout
        return Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            line.hasPrefix("package:") ? String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces) : nil
        })
    }

    /// The activity an intent resolves to ("com.example/.MainActivity"), from `cmd package resolve-activity --brief`.
    public static func resolvedComponent(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { $0.contains("/") && !$0.contains(" ") }
    }

    public static func launcherActivity(_ serial: String, package: String) async throws -> String {
        let output = try await shell(serial, "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER \(quote(package))",
                                     what: "find \(package)'s launcher activity")
        guard let component = resolvedComponent(output) else {
            throw DeviceError.failed("\(package) is not installed, or has no launcher activity.")
        }
        return component
    }

    /// The launcher's package: what is in front on the home screen.
    public static func homePackage(_ serial: String) async -> String? {
        let output = await run(serial, ["shell", "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME"], timeout: 10).stdout
        return resolvedComponent(output).map { String($0.split(separator: "/")[0]) }
    }

    /// `arguments` are extra `am start` options, e.g. ["--es", "key", "value"].
    public static func launchCommand(component: String, arguments: [String], terminateRunning: Bool) -> String {
        (["am", "start", "-W"] + (terminateRunning ? ["-S"] : []) + ["-n", quote(component)] + arguments.map(quote)).joined(separator: " ")
    }

    /// The first "Error: …" line `am start` printed. It exits with 0 for some errors and not for others, so its output decides.
    static func amError(_ result: ShellResult) -> String? {
        (result.stdout + "\n" + result.stderr).split(whereSeparator: \.isNewline).first { $0.hasPrefix("Error") }.map(String.init)
    }

    public static func launch(_ serial: String, package: String, arguments: [String], terminateRunning: Bool) async throws {
        let component = try await launcherActivity(serial, package: package)
        let result = await run(serial, ["shell", launchCommand(component: component, arguments: arguments, terminateRunning: terminateRunning)], timeout: 60)
        if let error = amError(result) { throw DeviceError.failed("Could not launch \(package): \(error)") }
        guard result.ok else { throw failure(result, what: "launch \(package)") }
    }

    public static func openURLCommand(_ url: String) -> String {
        "am start -W -a android.intent.action.VIEW -d \(quote(url))"
    }

    /// A port on the Mac a URL points at, which the device reaches through `adb reverse`.
    public static func localPort(_ url: String) -> Int? {
        guard let parts = URLComponents(string: url), let host = parts.host?.lowercased(),
              ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"].contains(host) else { return nil }
        return parts.port
    }

    public static func openURL(_ serial: String, _ url: String) async throws {
        if let port = localPort(url) {
            try await check(serial, ["reverse", "tcp:\(port)", "tcp:\(port)"], timeout: 10, what: "forward port \(port) to the Mac")
        }
        let result = await run(serial, ["shell", openURLCommand(url)], timeout: 30)
        if let error = amError(result) {
            if error.contains("unable to resolve Intent") {
                let hint = url.hasPrefix("exp://") ? " Install Expo Go on the device first." : ""
                throw DeviceError.failed("No app on the device opens \(url).\(hint)")
            }
            throw DeviceError.failed("Could not open \(url): \(error)")
        }
        guard result.ok else { throw failure(result, what: "open \(url)") }
    }

    // MARK: Logs

    public static func logArguments(since epoch: Int, pid: String?) -> [String] {
        ["logcat", "-d", "-b", "default,crash", "-v", "threadtime", "-T", "\(epoch).000"] + (pid.map { ["--pid=\($0)"] } ?? [])
    }

    /// The last `seconds` of the log, by the device's clock. `process` is a package or process name (its pid when it is
    /// running), else any text the lines must contain, such as a tag.
    public static func logs(_ serial: String, process: String?, seconds: Int) async throws -> String {
        let now = Int(try await shell(serial, "date +%s", timeout: 10, what: "read the device's clock").trimmingCharacters(in: .whitespacesAndNewlines))
            ?? Int(Date().timeIntervalSince1970)
        var pid: String?
        if let process, !process.isEmpty {
            let found = await run(serial, ["shell", "pidof -s \(quote(process))"], timeout: 10).output
            if Int(found) != nil { pid = found }
        }
        let output = try await check(serial, logArguments(since: now - max(1, seconds), pid: pid), timeout: 30, what: "read the device's log").stdout
        guard let process, !process.isEmpty, pid == nil else { return output }
        return output.split(separator: "\n").filter { $0.localizedCaseInsensitiveContains(process) }.joined(separator: "\n")
    }

    // MARK: Settings

    public static func nightModeCommand(dark: Bool) -> String { "cmd uimode night \(dark ? "yes" : "no")" }

    /// The emulator console takes longitude first. Phones have no console.
    public static func geoFixArguments(latitude: Double, longitude: Double) -> [String] {
        ["emu", "geo", "fix", String(format: "%.6f", longitude), String(format: "%.6f", latitude)]
    }

    /// The runtime permissions a service stands for. The lists span Android versions (READ_EXTERNAL_STORAGE before 13,
    /// READ_MEDIA_* from 13), and `set` changes the ones the app asks for.
    public static func permissions(for service: PrivacyService) -> [String] {
        let names: [String]
        switch service {
        case .all:
            var seen = Set<String>()
            return PrivacyService.allCases.filter { $0 != .all }.flatMap { permissions(for: $0) }.filter { seen.insert($0).inserted }
        case .calendar: names = ["READ_CALENDAR", "WRITE_CALENDAR"]
        case .contacts: names = ["READ_CONTACTS", "WRITE_CONTACTS"]
        case .contacts_limited: names = ["READ_CONTACTS"]
        case .location: names = ["ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION"]
        case .location_always: names = ["ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION", "ACCESS_BACKGROUND_LOCATION"]
        case .photos: names = ["READ_MEDIA_IMAGES", "READ_MEDIA_VIDEO", "READ_EXTERNAL_STORAGE"]
        case .media_library: names = ["READ_MEDIA_AUDIO", "READ_EXTERNAL_STORAGE"]
        case .microphone: names = ["RECORD_AUDIO"]
        case .motion: names = ["ACTIVITY_RECOGNITION"]
        case .camera: names = ["CAMERA"]
        case .notifications: names = ["POST_NOTIFICATIONS"]
        case .photos_add, .reminders, .siri: names = []
        }
        return names.map { "android.permission." + $0 }
    }

    /// SystemUI's demo mode: a fixed clock, full battery and signal, no notification icons. Android 17's SystemUI ignores
    /// the mobile part, so the cell type and bars stay real there.
    public static func statusBarCommand(clean: Bool) -> String {
        let demo = "am broadcast -a com.android.systemui.demo -e command"
        guard clean else { return "\(demo) exit" }
        return ["settings put global sysui_demo_allowed 1", "\(demo) enter", "\(demo) clock -e hhmm 0941",
                "\(demo) network -e wifi show -e level 4 -e fully true", "\(demo) network -e mobile show -e datatype none -e level 4 -e fully true",
                "\(demo) battery -e level 100 -e plugged false", "\(demo) notifications -e visible false"].joined(separator: " && ")
    }

    public static func set(_ serial: String, _ setting: DeviceSetting) async throws {
        switch setting {
        case .appearance(let dark):
            try await shell(serial, nightModeCommand(dark: dark), what: setting.what)
        case .location(let latitude, let longitude):
            let result = try await check(serial, geoFixArguments(latitude: latitude, longitude: longitude), timeout: 10, what: setting.what)
            // The console answers KO and a reason instead of failing.
            if let ko = result.output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("KO") }) {
                throw DeviceError.failed("Could not \(setting.what): \(ko)")
            }
        case .permission(let change, let service, let app):
            try await changePermission(serial, change, service, app: app)
        case .statusBar(let clean):
            try await shell(serial, statusBarCommand(clean: clean), what: setting.what)
        }
    }

    /// The permissions in the "requested permissions:" sections of `dumpsys package` (one per installed version of the app).
    public static func requestedPermissions(dumpsys output: String) -> Set<String> {
        var found = Set<String>()
        var sectionIndent: Int?
        for line in output.split(whereSeparator: \.isNewline) {
            let indent = line.prefix { $0 == " " }.count
            let text = line.trimmingCharacters(in: .whitespaces)
            if text == "requested permissions:" { sectionIndent = indent; continue }
            guard let section = sectionIndent else { continue }
            guard indent > section else { sectionIndent = nil; continue }
            // "android.permission.X" or "android.permission.X, maxSdkVersion=32"
            if let name = text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ":" }).first { found.insert(String(name)) }
        }
        return found
    }

    /// The shell commands that make one permission granted, denied for good, or not asked yet. `pm revoke` kills the app
    /// and leaves the "user decided" flags alone, so the flags decide whether the app may show the prompt again.
    public static func permissionCommand(_ change: PermissionChange, app: String, permission: String) -> String {
        let flags = "\(quote(app)) \(permission) user-set user-fixed"
        switch change {
        case .grant: return "pm grant \(quote(app)) \(permission)"
        case .revoke: return "pm revoke \(quote(app)) \(permission) && pm set-permission-flags \(flags)"
        case .reset: return "pm revoke \(quote(app)) \(permission) && pm clear-permission-flags \(flags)"
        }
    }

    /// Changes the service's permissions that the app asks for in its manifest. `pm grant` and `pm revoke` quietly do
    /// nothing for one the app doesn't ask for, so the manifest decides what changes, and asking for none of them is an
    /// error. (`pm reset-permissions` takes no package on Android 17: it resets every app.)
    static func changePermission(_ serial: String, _ change: PermissionChange, _ service: PrivacyService, app: String) async throws {
        let dumpsys = await run(serial, ["shell", "dumpsys package \(quote(app))"], timeout: 20).stdout
        guard dumpsys.contains("Package [\(app)]") else { throw DeviceError.failed("\(app) is not installed on the device.") }
        let wanted = permissions(for: service)
        let requested = requestedPermissions(dumpsys: dumpsys)
        let asked = wanted.filter(requested.contains)
        guard !asked.isEmpty else {
            throw DeviceError.failed("\(app) doesn't ask for \(service.rawValue) in its manifest (none of \(wanted.joined(separator: ", "))), and Android only \(change.rawValue)s permissions an app asks for.")
        }
        var changed = 0, lastError = ""
        for permission in asked {
            let result = await run(serial, ["shell", permissionCommand(change, app: app, permission: permission)], timeout: 10)
            if result.ok, !result.output.contains("Exception"), !result.output.contains("Error:") { changed += 1 } else { lastError = result.output }
        }
        guard changed == 0 else { return }
        // pm prints a stack trace; its message is the line naming the exception.
        let detail = lastError.split(whereSeparator: \.isNewline).first { $0.contains("Exception: ") }.map(String.init) ?? String(lastError.suffix(300))
        throw DeviceError.failed("Could not \(DeviceSetting.permission(change, service, app: app).what): \(detail.trimmingCharacters(in: .whitespaces))")
    }

    // MARK: Screen

    public static func screencap(_ serial: String) async throws -> Data {
        let data = try await check(serial, ["exec-out", "screencap", "-p"], timeout: 20, what: "take a screenshot").stdoutData
        guard data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { throw DeviceError.failed("The device returned no screenshot.") }
        return data
    }

    /// The screen's size in pixels in its natural orientation, and its density (dpi). Overrides (`wm size 720x1600`) win.
    public static func parseMetrics(_ output: String) -> (size: CGSize, density: Double)? {
        var size: CGSize?, density: Double?
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let override = parts[0].hasPrefix("Override")
            if parts[0].hasSuffix("size") {
                let wh = parts[1].split(separator: "x").compactMap { Double($0) }
                if wh.count == 2, override || size == nil { size = CGSize(width: wh[0], height: wh[1]) }
            } else if parts[0].hasSuffix("density"), let d = Double(parts[1]), override || density == nil {
                density = d
            }
        }
        guard let size, let density, density > 0 else { return nil }
        return (size, density)
    }

    public static func metrics(_ serial: String) async throws -> (size: CGSize, density: Double) {
        let output = try await shell(serial, "wm size; wm density", timeout: 10, what: "read the screen size")
        guard let metrics = parseMetrics(output) else { throw DeviceError.failed("Could not read the screen size: \(output.prefix(200))") }
        return metrics
    }

    public enum TreeError: Error, Equatable {
        /// The app's UI thread never went idle (endless animations): uiautomator gives up.
        case notIdle
        /// Another UI automation (the Android CLI's server, a test runner) holds the accessibility connection.
        case busy
        case failed(String)
    }

    public static let uiDumpPath = "/data/local/tmp/viber-ui.xml"

    public static func uiDumpCommand(thorough: Bool) -> String {
        "rm -f \(uiDumpPath); uiautomator dump\(thorough ? "" : " --compressed") \(uiDumpPath) 2>&1; cat \(uiDumpPath) 2>/dev/null"
    }

    /// The screen's view hierarchy as uiautomator XML. `thorough` keeps views uiautomator thinks unimportant.
    public static func uiDump(_ serial: String, thorough: Bool) async throws -> Data {
        let result = await run(serial, ["shell", uiDumpCommand(thorough: thorough)], timeout: 30)
        if result.status == 127 { throw failure(result, what: "read the screen") }
        if let xml = AndroidTree.xml(in: result.stdoutData) { return xml }
        let text = result.stdout + result.stderr
        if text.contains("idle state") { throw TreeError.notIdle }
        if text.contains("Killed") || result.status == 137 { throw TreeError.busy }
        throw TreeError.failed(String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)))
    }

    /// The screen as `android layout` JSON, without waiting for idle. Its first run installs a helper app on the device.
    public static func layout(_ serial: String, thorough: Bool) async throws -> Data {
        let sdk = sdk
        guard let cli = sdk.cli else { throw DeviceError.failed("The Android CLI (android) is not installed.") }
        let arguments = ["--no-metrics", "layout", "--no-idle", "--device=\(serial)"] + (thorough ? ["--full"] : [])
        let result = await Shell.runAsync(cli, arguments, environment: sdk.environment, timeout: 60)
        guard result.ok, result.stdout.contains("[") else { throw failure(result, what: "read the screen with android layout") }
        return result.stdoutData
    }

    // MARK: Input without scrcpy

    public static func tapCommand(_ p: CGPoint) -> String { "input tap \(Int(p.x)) \(Int(p.y))" }

    public static func swipeCommand(from a: CGPoint, to b: CGPoint, milliseconds: Int) -> String {
        "input swipe \(Int(a.x)) \(Int(a.y)) \(Int(b.x)) \(Int(b.y)) \(max(1, milliseconds))"
    }

    /// `input text` takes %s for spaces.
    public static func textCommand(_ text: String) -> String {
        "input text " + quote(text.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: " ", with: "%s"))
    }

    public static func keyCommand(_ code: Int32, meta: [Int32] = []) -> String {
        meta.isEmpty ? "input keyevent \(code)" : "input keycombination \((meta + [code]).map(String.init).joined(separator: " "))"
    }

    // MARK: scrcpy plumbing

    public static func push(_ serial: String, _ local: String, to remote: String) async throws {
        try await check(serial, ["push", local, remote], timeout: 60, what: "copy the screen server to the device")
    }

    /// Forwards a free Mac port to a socket on the device and returns the port.
    public static func forward(_ serial: String, toSocket name: String) async throws -> Int {
        let result = try await check(serial, ["forward", "tcp:0", "localabstract:\(name)"], timeout: 10, what: "open a tunnel to the device")
        guard let port = Int(result.output) else { throw DeviceError.failed("adb forward printed no port: \(result.output)") }
        return port
    }

    public static func removeForward(_ serial: String, port: Int) async {
        _ = await run(serial, ["forward", "--remove", "tcp:\(port)"], timeout: 10)
    }

    /// The adb invocation that runs `command` in the device's shell, for `Shell.spawn`.
    public static func shellInvocation(_ serial: String, _ command: String) -> (tool: String, arguments: [String], environment: [String: String])? {
        let sdk = sdk
        guard let adb = sdk.adb else { return nil }
        return (adb, ["-s", serial, "shell", command], sdk.environment)
    }
}
