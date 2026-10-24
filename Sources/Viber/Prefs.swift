import Foundation

/// Viber's own preferences (Settings → General). Views bind to the same keys with @AppStorage.
enum Prefs {
    static let notifyFinished = "notifyFinished"
    static let notifyNeedsYou = "notifyNeedsYou"
    static let notifyCache = "notifyCache"
    static let cacheWarningMinutes = "cacheWarningMinutes"
    static let newSessionMode = "newSessionMode"
    /// Empty: Claude Code's own default.
    static let newSessionModel = "newSessionModel"
    /// Serve the browser preview's MCP tools to sessions started from now on.
    static let previewTools = "previewTools"
    /// Approve preview clicks, typing and scripts on local pages without a permission card.
    static let previewLocalActions = "previewLocalActions"
    /// Serve the device panel's MCP tools to sessions started from now on.
    static let deviceTools = "deviceTools"
    /// Approve taps, typing, installs and launches on simulators and emulators without a permission card.
    static let deviceActions = "deviceActions"

    static func register() {
        UserDefaults.standard.register(defaults: [
            notifyFinished: true, notifyNeedsYou: true, notifyCache: true, cacheWarningMinutes: 2,
            newSessionMode: "auto", newSessionModel: "", previewTools: true, previewLocalActions: true,
            deviceTools: true, deviceActions: true
        ])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func string(_ key: String) -> String { UserDefaults.standard.string(forKey: key) ?? "" }
    static func int(_ key: String) -> Int { UserDefaults.standard.integer(forKey: key) }
}
