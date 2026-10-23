import Foundation

/// What the previewed page logged: console calls, uncaught errors, failed requests and navigations.
public struct ConsoleLog: Equatable, Sendable {
    public enum Level: String, Sendable {
        case log, info, debug, warn, error
        /// A page load, shown as a divider.
        case navigation

        public init(page raw: String) { self = Level(rawValue: raw) ?? (raw == "warning" ? .warn : .log) }
    }

    public struct Entry: Equatable, Identifiable, Sendable {
        public var id: Int
        public var level: Level
        public var text: String
        public var date: Date
        /// Consecutive identical lines are folded into one.
        public var count = 1
    }

    public private(set) var entries: [Entry] = []
    /// The last entry Claude has seen through `preview_console`.
    public private(set) var claudeCursor = 0
    /// Errors since the current page loaded, for the toolbar badge.
    public private(set) var errorsThisPage = 0
    public private(set) var lastNavigation: Date?
    /// The last hot update, or rebuild start, a dev server's client reported in the console.
    public private(set) var lastHotUpdate: Date?
    public private(set) var rebuilding = false
    private var nextID = 1
    private let limit: Int

    public init(limit: Int = 500) { self.limit = limit }

    public mutating func add(_ level: Level, _ text: String, at date: Date = Date()) {
        let text = text.count > 4000 ? String(text.prefix(4000)) + "…" : text
        switch HotUpdate.classify(text) {
        case .started?: rebuilding = true; lastHotUpdate = date
        case .applied?: rebuilding = false; lastHotUpdate = date
        case nil: break
        }
        if level == .error { errorsThisPage += 1 }
        if let last = entries.last, last.level == level, last.text == text, level != .navigation {
            entries[entries.count - 1].count += 1
            entries[entries.count - 1].date = date
            entries[entries.count - 1].id = nextID
        } else {
            entries.append(Entry(id: nextID, level: level, text: text, date: date))
            if entries.count > limit { entries.removeFirst(entries.count - limit) }
        }
        nextID += 1
    }

    public mutating func navigated(to url: URL?, at date: Date = Date()) {
        add(.navigation, "Loaded \(PreviewURL.short(url))", at: date)
        errorsThisPage = 0
        rebuilding = false
        lastNavigation = date
    }

    public mutating func clear() {
        entries.removeAll()
        errorsThisPage = 0
        claudeCursor = nextID - 1
    }

    /// Entries Claude has not read yet.
    public var unseen: [Entry] { entries.filter { $0.id > claudeCursor } }
    public var unseenErrorCount: Int { unseen.filter { $0.level == .error }.count }

    public mutating func markSeen() { claudeCursor = nextID - 1 }

    /// Anything after `date` that shows the page picked up a change: a hot update or a reload.
    public func updated(after date: Date) -> Bool {
        if let nav = lastNavigation, nav > date { return true }
        if let hot = lastHotUpdate, hot > date, !rebuilding { return true }
        return false
    }

    /// Plain-text listing for Claude, oldest first, one line per entry.
    public static func format(_ entries: [Entry], maxEntries: Int = 50, maxLine: Int = 500) -> String {
        let shown = entries.suffix(maxEntries)
        var lines: [String] = []
        if entries.count > shown.count { lines.append("(\(entries.count - shown.count) earlier entries not shown)") }
        for entry in shown {
            if entry.level == .navigation { lines.append("--- \(entry.text) ---"); continue }
            var text = entry.text.count > maxLine ? String(entry.text.prefix(maxLine)) + "…" : entry.text
            if entry.count > 1 { text += " (×\(entry.count))" }
            lines.append("[\(entry.level.rawValue)] \(text)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Dev server clients announce hot updates in the console; that is how the preview knows an edit has landed.
public enum HotUpdate: Equatable, Sendable {
    case started, applied

    public static func classify(_ text: String) -> HotUpdate? {
        let t = text.trimmingCharacters(in: .whitespaces)
        // Vite: "[vite] hot updated: /src/App.tsx", "[vite] page reload src/main.ts", "[vite] css hot updated: …"
        if t.hasPrefix("[vite]") {
            if t.contains("hot updated") || t.contains("page reload") { return .applied }
            return nil
        }
        // Next.js and React Refresh: "[Fast Refresh] rebuilding", "[Fast Refresh] done in 120ms"
        if t.hasPrefix("[Fast Refresh]") { return t.contains("rebuilding") ? .started : .applied }
        // webpack-dev-server: "[HMR] Updated modules:", "[HMR] App is up to date.", "[webpack-dev-server] App updated. Recompiling…"
        if t.hasPrefix("[HMR]") { return t.contains("Checking for updates") || t.contains("Waiting for update") ? .started : .applied }
        if t.hasPrefix("[webpack-dev-server]") && t.contains("Recompiling") { return .started }
        // Parcel: "[parcel] ✨ Built"; Astro: "[astro] … update"
        if t.hasPrefix("[parcel]") && t.contains("Built") { return .applied }
        return nil
    }
}
