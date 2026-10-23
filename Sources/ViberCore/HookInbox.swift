// Copied from claude-cache/Sources/CompanionCore/HookInbox.swift. Keep in sync by hand.
import Foundation

public enum HookInbox {
    /// Allowlist only metadata. Never persist prompts, tool input, response text, or credentials.
    public static func sanitized(_ input: Data, now: Date = Date()) throws -> Data {
        guard input.count <= 4 * 1024 * 1024,
              let row = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              let session = row["session_id"] as? String, !session.isEmpty,
              row["hook_event_name"] is String else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var output: [String: Any] = ["event_id": UUID().uuidString, "observed_at": now.timeIntervalSince1970]
        for key in ["session_id", "hook_event_name", "cwd", "tool_name", "tool_use_id", "notification_type", "agent_id"] {
            if let value = row[key] as? String { output[key] = String(value.prefix(4096)) }
        }
        return try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    }

    public static func write(_ data: Data, to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Atomic rename means the reader never sees a half-written hook.
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let target = directory.appendingPathComponent("\(UUID().uuidString).json")
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try fm.moveItem(at: temporary, to: target)
    }

    public static func drain(_ directory: URL, now: Date = Date()) throws -> [Event] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])
        var events: [Event] = []
        for file in files where file.pathExtension == "json" {
            let info = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            if info.isSymbolicLink != true, (info.fileSize ?? 0) <= 64 * 1024,
               let data = try? Data(contentsOf: file), let event = EventParser.hook(data),
               now.timeIntervalSince(event.time) < 86_400, event.time <= now.addingTimeInterval(60) {
                events.append(event)
            }
            try fm.removeItem(at: file)
        }
        return events
    }
}
