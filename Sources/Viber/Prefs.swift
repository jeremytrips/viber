import Foundation
import ViberCore

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
    /// When a session stops at the account's usage limit, tell it to carry on once the limit resets.
    static let continueAfterLimit = "continueAfterLimit"

    /// How many sessions an autopilot run keeps going at once, and the most worktrees it lets a project have open.
    static let autopilotSessions = "autopilotSessions"
    static let autopilotWorktrees = "autopilotWorktrees"
    /// The Jira sites Viber reads, as JSON; their tokens are in the Keychain.
    static let jiraSites = "jiraSites"
    /// Each project's check after a request (RequestCheck), by its path, as JSON.
    static let requestChecks = "requestChecks"

    /// New worktrees' branch patterns, by the repository's main checkout. A missing one is Worktree.defaultBranchPattern.
    static let branchPatterns = "branchPatterns"
    /// The account each project's sessions start with, by project, as `ProjectAccount.stored`. A missing one is clauth's default.
    static let projectAccounts = "projectAccounts"

    static func register() {
        UserDefaults.standard.register(defaults: [
            notifyFinished: true, notifyNeedsYou: true, notifyCache: true, cacheWarningMinutes: 2,
            newSessionMode: "auto", newSessionModel: "", previewTools: true, previewLocalActions: true,
            deviceTools: true, deviceActions: true, continueAfterLimit: true, autopilotSessions: 3, autopilotWorktrees: 8
        ])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func string(_ key: String) -> String { UserDefaults.standard.string(forKey: key) ?? "" }
    static func int(_ key: String) -> Int { UserDefaults.standard.integer(forKey: key) }

    static func branchPattern(project: String) -> String {
        (UserDefaults.standard.dictionary(forKey: branchPatterns)?[project] as? String) ?? Worktree.defaultBranchPattern
    }

    /// An empty pattern or the default one removes the project's own.
    static func setBranchPattern(_ pattern: String, project: String) {
        var all = UserDefaults.standard.dictionary(forKey: branchPatterns) ?? [:]
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        all[project] = trimmed.isEmpty || trimmed == Worktree.defaultBranchPattern ? nil : trimmed
        UserDefaults.standard.set(all, forKey: branchPatterns)
    }
}
