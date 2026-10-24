import Foundation

/// What the app saved about its open sessions, as far as the `viber` command needs it.
public enum RecordedSessions {
    private struct Record: Decodable {
        var id: String
        var worktree: WorktreeInfo?
    }

    /// The worktree Viber made for the session with this pane ID, if it made one.
    public static func worktree(paneID: String, file: URL = ViberPaths.panes) -> WorktreeInfo? {
        guard let data = try? Data(contentsOf: file),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return nil }
        return records.first { $0.id == paneID }?.worktree
    }
}

/// A request from the `viber` command (run by skills inside a session) to the app.
/// Delivered through the same atomic file-drop as HookInbox.
public struct ViberRequest: Codable, Equatable {
    public enum Command: String, Codable { case close, notify, rename, idea }
    public var paneID: String
    public var command: Command
    public var text: String?
    public var removeWorktree = false
    public var deleteBranch = false
    public var createdAt = Date()

    public init(paneID: String, command: Command, text: String? = nil, removeWorktree: Bool = false, deleteBranch: Bool = false) {
        self.paneID = paneID; self.command = command; self.text = text
        self.removeWorktree = removeWorktree; self.deleteBranch = deleteBranch
    }

    public func write(to directory: URL = ViberPaths.requests) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try HookInbox.write(encoder.encode(self), to: directory)
    }

    public static func drain(_ directory: URL = ViberPaths.requests, now: Date = Date()) -> [ViberRequest] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var requests: [ViberRequest] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            if info?.isSymbolicLink != true, (info?.fileSize ?? 0) <= 64 * 1024,
               let data = try? Data(contentsOf: file), let request = try? decoder.decode(ViberRequest.self, from: data),
               now.timeIntervalSince(request.createdAt) < 3600 {
                requests.append(request)
            }
            try? fm.removeItem(at: file)
        }
        return requests.sorted { $0.createdAt < $1.createdAt }
    }
}
