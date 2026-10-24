import Foundation

/// Claude Code saves its memory files without asking, except when its memory folder sits behind a symlink.
/// Under clauth it does: the runtime config folder's `projects` links to `~/.claude/projects`, and Claude Code
/// also checks where a path leads on disk, which falls outside the folder it knows and fails a check only a
/// person can pass. Viber answers those requests itself, as Claude Code would without the link.
public enum MemoryWrite {
    /// Whether a permission request is an Edit or Write of a Markdown file in `folder`, the CLI's auto-memory
    /// folder, that still lands inside that folder once links are followed.
    public static func allows(toolName: String, input: JSON, folder: String) -> Bool {
        guard ["Edit", "Write"].contains(toolName), let path = input["file_path"]?.string,
              path.hasPrefix("/"), path.hasSuffix(".md") else { return false }
        let root = folder.hasSuffix("/") ? folder : folder + "/"
        guard path.hasPrefix(root) else { return false }
        let inside = (String(path.dropFirst(root.count)) as NSString).pathComponents
        guard !inside.isEmpty, !inside.contains(where: { $0.hasPrefix(".") || $0 == "/" }) else { return false }
        guard let realRoot = WorktreeInclude.realpath(root) else { return false }
        return WorktreeInclude.staysInside(path, root: realRoot)
    }
}
