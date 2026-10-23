import Foundation

/// Claude Code's permission modes. On the wire modes stay strings, since the CLI can report ones not listed here.
public enum PermissionMode: String, Sendable {
    case `default`, acceptEdits, auto, plan, bypassPermissions

    /// The modes Viber offers in its menus.
    public static let offered: [PermissionMode] = [.default, .acceptEdits, .auto, .plan]

    public var label: String {
        switch self {
        case .default: return "Ask before edits"
        case .acceptEdits: return "Edit automatically"
        case .auto: return "Auto mode"
        case .plan: return "Plan mode"
        case .bypassPermissions: return "Bypass permissions"
        }
    }

    /// What the mode does, for the modes that need explaining.
    public var summary: String? {
        switch self {
        case .plan: return "Claude plans first and edits only after you approve."
        case .auto: return "Claude edits and runs commands without asking; a classifier blocks risky actions."
        default: return nil
        }
    }

    /// The chat notice when a session switches to this mode.
    public var notice: String { summary.map { "\(label) is on. \($0)" } ?? "Mode: \(label)" }

    /// Label for a mode string from the CLI or a launch spec; nil is the CLI's default.
    public static func label(for mode: String?) -> String {
        guard let mode else { return PermissionMode.default.label }
        return PermissionMode(rawValue: mode)?.label ?? mode
    }
}
