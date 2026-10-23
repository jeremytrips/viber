// Copied from claude-cache/Sources/CompanionCore/TranscriptWatcher.swift. Keep in sync by hand.
import Foundation

/// Incremental polling handles newly created nested directories and file replacement without
/// depending on the lifetime of a directory file descriptor. All I/O runs off the UI thread.
public final class TranscriptWatcher {
    private struct Cursor {
        var inode: UInt64
        var offset: UInt64 = 0
        var pending = Data()
        var droppingLongLine = false
        var modified: Date = .distantPast
    }
    private var cursors: [String: Cursor] = [:]
    public let root: URL
    public init(root: URL) { self.root = root }

    public func scan(fallbackTTL: TimeInterval) -> (events: [Event], catchingUp: Bool, issues: [String]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            return ([], false, ["No transcripts found at \(root.path). Start Claude Code or choose its projects folder."])
        }
        var issues: [String] = []
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles], errorHandler: { _, _ in
                issues.append("Some transcript folders could not be read. Check folder permissions.")
                return true
            }) else { return ([], false, ["Cannot read projects folder."]) }
        var events: [Event] = []
        var found: Set<String> = []
        var budget = 16 * 1024 * 1024
        var catchingUp = false
        for case let url as URL in iterator {
            if url.lastPathComponent == "subagents" { iterator.skipDescendants(); continue }
            guard url.pathExtension == "jsonl" else { continue }
            do {
                let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard resource.isRegularFile == true, resource.isSymbolicLink != true else { continue }
                found.insert(url.path)
                let attributes = try fm.attributesOfItem(atPath: url.path)
                let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let modified = attributes[.modificationDate] as? Date ?? .distantPast
                var cursor = cursors[url.path] ?? Cursor(inode: inode)
                if inode != cursor.inode || size < cursor.offset || (size == cursor.offset && modified != cursor.modified) {
                    cursor = Cursor(inode: inode)
                }
                if size > cursor.offset {
                    guard budget > 0 else { catchingUp = true; continue }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: cursor.offset)
                    let chunk = try handle.read(upToCount: min(budget, 2 * 1024 * 1024)) ?? Data()
                    budget -= chunk.count
                    cursor.offset += UInt64(chunk.count)
                    cursor.pending.append(chunk)
                    while let newline = cursor.pending.firstIndex(of: 10) {
                        let line = Data(cursor.pending[..<newline])
                        cursor.pending.removeSubrange(...newline)
                        if cursor.droppingLongLine { cursor.droppingLongLine = false; continue }
                        if line.count > 8 * 1024 * 1024 { issues.append("Skipped an oversized transcript row."); continue }
                        if let event = EventParser.transcript(line, path: url.path, fallbackTTL: fallbackTTL) { events.append(event) }
                    }
                    if cursor.pending.count > 8 * 1024 * 1024 {
                        cursor.pending.removeAll()
                        cursor.droppingLongLine = true
                        issues.append("Skipped an oversized transcript row.")
                    }
                    if cursor.offset < size { catchingUp = true }
                }
                cursor.modified = modified
                cursors[url.path] = cursor
            } catch {
                issues.append("A transcript could not be read. Check folder permissions.")
            }
        }
        cursors = cursors.filter { found.contains($0.key) }
        return (events, catchingUp, Array(Set(issues)))
    }
}
