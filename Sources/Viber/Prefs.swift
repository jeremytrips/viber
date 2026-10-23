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

    static func register() {
        UserDefaults.standard.register(defaults: [
            notifyFinished: true, notifyNeedsYou: true, notifyCache: true, cacheWarningMinutes: 2,
            newSessionMode: "default", newSessionModel: ""
        ])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func string(_ key: String) -> String { UserDefaults.standard.string(forKey: key) ?? "" }
    static func int(_ key: String) -> Int { UserDefaults.standard.integer(forKey: key) }
}
