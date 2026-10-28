import Foundation

/// What an Expo app's folder says about the link that opens it. Run through Claude's Bash tool, `expo start` has no
/// TTY and prints only `Waiting on http://<ip>:8081`, so Viber forms the link the way Expo would have
/// (@expo/cli start/resolveOptions.js, utils/scheme.js).
public struct ExpoProject: Equatable, Sendable {
    /// `expo start` targets a development build rather than Expo Go: the app depends on expo-dev-client.
    public var devClient: Bool
    /// The scheme its development build opens: from the native projects (an `exp+` one first, else the longest),
    /// else `exp+<slug>` for an app without them.
    public var scheme: String?

    public init(devClient: Bool, scheme: String?) {
        self.devClient = devClient; self.scheme = scheme
    }

    /// The app in `root`, or nil when its package.json doesn't depend on expo.
    public static func read(at root: String) -> ExpoProject? {
        let folder = URL(fileURLWithPath: root)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("package.json")),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let dependencies = ["dependencies", "devDependencies"].flatMap { (package[$0] as? [String: Any] ?? [:]).keys }
        guard dependencies.contains("expo") else { return nil }
        return ExpoProject(devClient: dependencies.contains("expo-dev-client"), scheme: scheme(at: folder))
    }

    /// Expo's choice: with one native project its scheme, with both the first iOS one Android shares too.
    static func scheme(at folder: URL) -> String? {
        let fm = FileManager.default
        let ios = fm.fileExists(atPath: folder.appendingPathComponent("ios").path)
        let android = fm.fileExists(atPath: folder.appendingPathComponent("android").path)
        switch (ios, android) {
        case (false, false): return slug(at: folder).flatMap(defaultScheme)
        case (true, false): return preferred(iosSchemes(at: folder)).first
        case (false, true): return preferred(androidSchemes(at: folder)).first
        case (true, true):
            let shared = Set(androidSchemes(at: folder))
            return preferred(iosSchemes(at: folder)).first(where: shared.contains)
        }
    }

    /// `exp+` schemes only when there are any, longest first: they belong to expo-dev-client, the rest may be the
    /// app's own or a third party's.
    static func preferred(_ schemes: [String]) -> [String] {
        let expo = schemes.filter { $0.hasPrefix("exp+") }
        return (expo.isEmpty ? schemes : expo).enumerated()
            .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .map(\.element)
    }

    /// CFBundleURLSchemes from `ios/<target>/Info.plist`.
    static func iosSchemes(at folder: URL) -> [String] {
        let ios = folder.appendingPathComponent("ios")
        let skipped: Set<String> = ["Pods", "build"]
        let targets = ((try? FileManager.default.contentsOfDirectory(atPath: ios.path)) ?? [])
            .filter { !$0.hasPrefix(".") && !skipped.contains($0) && !$0.hasSuffix(".xcodeproj") && !$0.hasSuffix(".xcworkspace") }
            .sorted()
        return targets.flatMap { target -> [String] in
            guard let data = try? Data(contentsOf: ios.appendingPathComponent(target).appendingPathComponent("Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
            let types = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
            return types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        }
    }

    /// `android:scheme` values in the app's manifest, without web links.
    static func androidSchemes(at folder: URL) -> [String] {
        let manifest = folder.appendingPathComponent("android/app/src/main/AndroidManifest.xml")
        guard let xml = try? String(contentsOf: manifest, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"android:scheme\s*=\s*"([^"]+)""#) else { return [] }
        var schemes: [String] = []
        for match in regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let range = Range(match.range(at: 1), in: xml) else { continue }
            let scheme = String(xml[range])
            if !["http", "https"].contains(scheme.lowercased()), !schemes.contains(scheme) { schemes.append(scheme) }
        }
        return schemes
    }

    /// The app's slug: a literal `slug:` in app.config.* (which Viber can't run), else app.json's.
    static func slug(at folder: URL) -> String? {
        for name in ["app.config.ts", "app.config.js", "app.config.mjs", "app.config.cjs"] {
            guard let source = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8),
                  let regex = try? NSRegularExpression(pattern: #"\bslug\s*:\s*['"`]([^'"`]+)['"`]"#),
                  let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                  let range = Range(match.range(at: 1), in: source) else { continue }
            return String(source[range])
        }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("app.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["expo"] as? [String: Any])?["slug"] as? String ?? json["slug"] as? String
    }

    /// expo-dev-client's getDefaultScheme: the slug without characters a scheme can't hold, lowercased, after `exp+`.
    static func defaultScheme(_ slug: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-.")
        let kept = String(String.UnicodeScalarView(slug.unicodeScalars.filter(allowed.contains))).lowercased()
        return kept.isEmpty ? nil : "exp+\(kept)"
    }
}
