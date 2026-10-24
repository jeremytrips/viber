import Foundation

public enum DevicePlatform: String, Codable, Sendable { case ios, android }
public enum DeviceKind: String, Codable, Sendable { case simulator, emulator, physical }
public enum DeviceState: String, Sendable { case booted, booting, shutdown, shuttingDown, unknown }

/// A phone or tablet Viber can show and Claude can drive: a simulator, an emulator or (later) a USB device.
public struct DeviceInfo: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var platform: DevicePlatform
    public var kind: DeviceKind
    /// "iOS 26.5"
    public var os: String
    public var state: DeviceState
    /// e.g. com.apple.CoreSimulator.SimDeviceType.iPhone-17
    public var typeIdentifier: String

    public init(id: String, name: String, platform: DevicePlatform, kind: DeviceKind, os: String, state: DeviceState, typeIdentifier: String = "") {
        self.id = id; self.name = name; self.platform = platform; self.kind = kind; self.os = os; self.state = state
        self.typeIdentifier = typeIdentifier
    }

    public var isBooted: Bool { state == .booted }
    public var isVirtual: Bool { kind != .physical }
    public var isPhone: Bool { name.hasPrefix("iPhone") || typeIdentifier.contains("iPhone") || platform == .android }
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

    /// Booted first, then phones before tablets, newest OS first, then by name.
    public static func sorted(_ devices: [DeviceInfo]) -> [DeviceInfo] {
        devices.sorted { a, b in
            if a.isBooted != b.isBooted { return a.isBooted }
            if a.isPhone != b.isPhone { return a.isPhone }
            if a.osVersion != b.osVersion { return a.osVersion.lexicographicallyPrecedes(b.osVersion) == false }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// What to open when nothing was asked for: a booted device, else the newest iPhone.
    public static func preferred(_ devices: [DeviceInfo]) -> DeviceInfo? {
        sorted(devices).first
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

/// Something in a command's output that can run on a device: a simulator build or an Expo dev server.
public enum DeviceArtifact: Equatable, Sendable {
    /// A `.app` built for the iOS simulator.
    case app(String)
    /// An `exp://` URL that opens the project in Expo Go.
    case expo(String)

    public var label: String {
        switch self {
        case .app(let path): return "Run \((path as NSString).lastPathComponent) on device"
        case .expo: return "Open in Expo Go on device"
        }
    }

    /// The last simulator app or Expo URL the output mentions.
    public static func detect(in text: String) -> DeviceArtifact? {
        let plain = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        if let range = plain.range(of: #"exp://[A-Za-z0-9.\-]+(?::\d{2,5})?(?:/[^\s"'`<>)\]]*)?"#, options: [.regularExpression, .backwards]) {
            return .expo(String(plain[range]))
        }
        if let range = plain.range(of: #"/[^\s"'`<>]*-iphonesimulator/[^\s"'`<>/]+\.app(?=[\s"'`<>/]|$)"#, options: [.regularExpression, .backwards]) {
            return .app(String(plain[range]))
        }
        return nil
    }
}
