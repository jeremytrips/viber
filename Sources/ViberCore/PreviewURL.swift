import Foundation

/// URL handling for the browser preview.
public enum PreviewURL {
    /// What someone types or a dev server prints, as a loadable URL. "localhost:5173" becomes http, 0.0.0.0 becomes localhost.
    public static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("/") || text.hasPrefix("~") {
            return URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
        }
        if !text.contains("://") {
            let host = text.split(separator: "/").first.map(String.init) ?? text
            let local = host.hasPrefix("localhost") || host.hasPrefix("127.") || host.hasPrefix("0.0.0.0") || host.hasPrefix("[")
            text = (local || !host.contains(".") ? "http://" : "https://") + text
        }
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else { return nil }
        if components.host == "0.0.0.0" || components.host == "[::]" || components.host == "::" { components.host = "localhost" }
        if scheme != "file", components.host?.isEmpty ?? true { return nil }
        return components.url
    }

    /// Pages served from this machine or the local network, where Claude may click and type without asking.
    public static func isLocal(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.isFileURL { return true }
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".test") { return true }
        if host == "::1" || host == "[::1]" { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, host.split(separator: ".").count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// Local URLs in tool output, such as a dev server's "➜  Local:   http://localhost:5173/". First seen first.
    public static func detect(in text: String) -> [URL] {
        let plain = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        let pattern = #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|[A-Za-z0-9-]+\.localhost)(?::\d{2,5})?(?:/[^\s"'`<>)\]]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<String>()
        var urls: [URL] = []
        for match in regex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let range = Range(match.range, in: plain) else { continue }
            var raw = String(plain[range])
            while let last = raw.last, ".,;:".contains(last) { raw.removeLast() }
            guard let url = normalize(raw), seen.insert(url.absoluteString).inserted else { continue }
            urls.append(url)
        }
        return urls
    }

    /// "localhost:5173/about" for display.
    public static func short(_ url: URL?) -> String {
        guard let url else { return "" }
        if url.isFileURL { return url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }
        var text = url.absoluteString
        for prefix in ["http://", "https://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if text.hasSuffix("/") && text.filter({ $0 == "/" }).count == 1 { text.removeLast() }
        return text
    }
}
