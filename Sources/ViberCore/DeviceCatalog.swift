import Foundation

public enum DevicePlatform: String, Codable, Sendable { case ios, android }
public enum DeviceKind: String, Codable, Sendable { case simulator, emulator, physical }
public enum DeviceState: String, Sendable { case booted, booting, shutdown, shuttingDown, unknown }

/// A phone or tablet Viber can show and Claude can drive: an iOS simulator, an Android emulator or a USB phone.
public struct DeviceInfo: Equatable, Identifiable, Sendable {
    /// A simulator's UDID, an emulator's AVD name (stable across boots) or a phone's adb serial.
    public var id: String
    public var name: String
    public var platform: DevicePlatform
    public var kind: DeviceKind
    /// "iOS 26.5"
    public var os: String
    public var state: DeviceState
    /// e.g. com.apple.CoreSimulator.SimDeviceType.iPhone-17, or an AVD's hardware profile (pixel_8)
    public var typeIdentifier: String
    /// Android: the adb serial while it is connected (emulator-5554).
    public var serial: String?

    public init(id: String, name: String, platform: DevicePlatform, kind: DeviceKind, os: String, state: DeviceState,
                typeIdentifier: String = "", serial: String? = nil) {
        self.id = id; self.name = name; self.platform = platform; self.kind = kind; self.os = os; self.state = state
        self.typeIdentifier = typeIdentifier; self.serial = serial
    }

    public var isBooted: Bool { state == .booted }
    public var isVirtual: Bool { kind != .physical }
    public var isPhone: Bool {
        switch platform {
        case .ios: return name.hasPrefix("iPhone") || typeIdentifier.contains("iPhone")
        case .android: return !name.lowercased().contains("tablet") && !typeIdentifier.lowercased().contains("tablet")
        }
    }
    /// "iPhone 17 · iOS 26.5"
    public var label: String { "\(name) · \(os)" }
    /// OS version as numbers, for "newest first".
    var osVersion: [Int] { os.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
}

public enum DeviceCatalog {
    /// Devices from `xcrun simctl list devices available -j`. Only iOS runtimes: iPhones and iPads.
    public static func parseSimctl(_ data: Data) -> [DeviceInfo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = json["devices"] as? [String: [[String: Any]]] else { return [] }
        var devices: [DeviceInfo] = []
        for (runtime, entries) in byRuntime {
            guard let os = runtimeName(runtime), os.hasPrefix("iOS ") else { continue }
            for entry in entries {
                guard let udid = entry["udid"] as? String, let name = entry["name"] as? String,
                      entry["isAvailable"] as? Bool ?? true else { continue }
                devices.append(DeviceInfo(id: udid, name: name, platform: .ios, kind: .simulator, os: os,
                                          state: state(entry["state"] as? String), typeIdentifier: entry["deviceTypeIdentifier"] as? String ?? ""))
            }
        }
        return sorted(devices)
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-5" → "iOS 26.5"
    public static func runtimeName(_ identifier: String) -> String? {
        guard let last = identifier.split(separator: ".").last else { return nil }
        let parts = last.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0]) " + parts.dropFirst().joined(separator: ".")
    }

    static func state(_ raw: String?) -> DeviceState {
        switch raw {
        case "Booted": return .booted
        case "Booting": return .booting
        case "Shutdown": return .shutdown
        case "Shutting Down": return .shuttingDown
        default: return .unknown
        }
    }

    /// Running simulators and emulators first, then running USB phones, then iOS before Android, phones before tablets,
    /// newest OS first, then by name.
    public static func sorted(_ devices: [DeviceInfo]) -> [DeviceInfo] {
        func rank(_ d: DeviceInfo) -> Int { d.isBooted ? (d.isVirtual ? 0 : 1) : 2 }
        return devices.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.platform != b.platform { return a.platform == .ios }
            if a.isPhone != b.isPhone { return a.isPhone }
            if a.osVersion != b.osVersion { return a.osVersion.lexicographicallyPrecedes(b.osVersion) == false }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// What to open when nothing was asked for: a running simulator or emulator, else the newest iPhone.
    /// Never a USB phone: those hold someone's real data, so they are only used when named.
    public static func preferred(_ devices: [DeviceInfo]) -> DeviceInfo? {
        sorted(devices).first(where: \.isVirtual)
    }

    /// A device by id or name ("iPhone 17", "iphone 17 pro", "iPhone 16 iOS 18.6"). Booted and newest win ties.
    public static func match(_ query: String, in devices: [DeviceInfo]) -> DeviceInfo? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }
        if let exact = devices.first(where: { $0.id.lowercased() == q }) { return exact }
        let ordered = sorted(devices)
        if let named = ordered.first(where: { $0.name.lowercased() == q || $0.label.lowercased() == q }) { return named }
        let words = q.replacingOccurrences(of: "·", with: " ").split(separator: " ").map(String.init)
        return ordered.first { device in
            let haystack = "\(device.name) \(device.os)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}

/// Something in a command's output that can run on a device: a simulator build, an Android build or an Expo dev server.
public enum DeviceArtifact: Equatable, Sendable {
    /// A `.app` built for the iOS simulator.
    case app(String)
    /// An `.apk` from a Gradle build.
    case apk(String)
    /// An `exp://` URL that opens the project in Expo Go.
    case expo(String)
    /// A link that opens the project in its development build, as `expo start --dev-client` prints it:
    /// `exp+<slug>://expo-development-client/?url=<encoded dev server URL>`, or with another scheme the app registers.
    case devClient(String)

    public var label: String {
        switch self {
        case .app(let path), .apk(let path): return "Run \((path as NSString).lastPathComponent) on device"
        case .expo: return "Open in Expo Go on device"
        case .devClient: return "Open in the development build on device"
        }
    }

    /// The platform it runs on; nil when either will do.
    public var platform: DevicePlatform? {
        switch self {
        case .app: return .ios
        case .apk: return .android
        case .expo, .devClient: return nil
        }
    }

    /// The last simulator app, Android build or Expo URL the output mentions; an Expo URL wins over a build.
    /// The last Expo URL counts because Expo prints it again when it switches between Expo Go and a development build.
    public static func detect(in text: String) -> DeviceArtifact? {
        let plain = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        if let match = lastMatch(expoLink, in: plain), let range = Range(match.range, in: plain) {
            let url = String(plain[range])
            return match.range(at: 1).location != NSNotFound ? .devClient(url) : .expo(url)
        }
        if let match = lastMatch(#"/[^\s"'`<>]*-iphonesimulator/[^\s"'`<>/]+\.app(?=[\s"'`<>/]|$)"#, in: plain),
           let range = Range(match.range, in: plain) {
            return .app(String(plain[range]))
        }
        if let range = plain.range(of: #"/[^\s"'`<>]*/build/outputs/apk/[^\s"'`<>]*?\.apk(?=[\s"'`<>]|$)"#, options: [.regularExpression, .backwards]) {
            return .apk(String(plain[range]))
        }
        return nil
    }

    /// Group 1 is a development build's link, group 2 an Expo Go URL. Neither starts inside a longer scheme,
    /// so `myexp://…` is not taken for `exp://…`.
    static let expoLink = #"(?<![A-Za-z0-9+.\-])(?:([A-Za-z][A-Za-z0-9+.\-]*://expo-development-client/?\?url=[^\s"'`<>)\]]+)|(exp://[A-Za-z0-9.\-]+(?::\d{2,5})?(?:/[^\s"'`<>)\]]*)?))"#

    /// `range(of:options:)` ignores `.backwards` for regular expressions and returns the first match.
    static func lastMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last
    }
}
