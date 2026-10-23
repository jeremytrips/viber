import Foundation

public struct WorktreeInfo: Codable, Equatable {
    public var repo: String
    public var path: String
    public var branch: String
    public var base: String
}

public struct WorktreeError: Error, LocalizedError {
    public var message: String
    public var errorDescription: String? { message }
}

/// Git worktrees for parallel sessions. Every operation shells out to `git` and is blocking.
public enum Worktree {
    public static func slug(_ title: String) -> String {
        let lowered = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(lowered).split(separator: "-").joined(separator: "-")
        return String(collapsed.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public static func repoRoot(_ dir: String) -> String? {
        let r = Shell.run("git", ["-C", dir, "rev-parse", "--show-toplevel"])
        return r.ok ? r.output : nil
    }

    /// Makes `dir` a git repository whose first commit is a README titled after the folder,
    /// so worktrees have a branch to start from. Only the README is committed; an existing one is kept as is.
    public static func createRepo(_ dir: String) throws {
        func check(_ r: ShellResult, _ step: String) throws {
            guard r.ok else { throw WorktreeError(message: "\(step) failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
        try check(Shell.run("git", ["-C", dir, "init", "-q"]), "git init")
        let readme = URL(fileURLWithPath: dir).appendingPathComponent("README.md")
        if !FileManager.default.fileExists(atPath: readme.path) {
            try "# \(URL(fileURLWithPath: dir).lastPathComponent)\n".write(to: readme, atomically: true, encoding: .utf8)
        }
        try check(Shell.run("git", ["-C", dir, "add", "README.md"]), "git add")
        try check(Shell.run("git", ["-C", dir, "commit", "-q", "-m", "Initial commit"]), "git commit")
    }

    /// Creates `<repo>/.claude/worktrees/<slug>` on a new `viber/<slug>` branch from the current branch.
    public static func create(repoDir: String, name: String) throws -> WorktreeInfo {
        guard let root = repoRoot(repoDir) else { throw WorktreeError(message: "\(repoDir) is not inside a git repository.") }
        let base = Shell.run("git", ["-C", root, "rev-parse", "--abbrev-ref", "HEAD"]).output
        guard !base.isEmpty, base != "HEAD" else { throw WorktreeError(message: "The repository has no current branch to start from.") }
        var slug = slug(name)
        if slug.isEmpty { slug = "session" }
        let dir = URL(fileURLWithPath: root).appendingPathComponent(".claude/worktrees")
        var candidate = slug, n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path)
                || Shell.run("git", ["-C", root, "rev-parse", "--verify", "--quiet", "refs/heads/viber/\(candidate)"]).ok {
            candidate = "\(slug)-\(n)"; n += 1
        }
        let path = dir.appendingPathComponent(candidate).path
        let branch = "viber/\(candidate)"
        excludeWorktreeDir(root: root)
        let add = Shell.run("git", ["-C", root, "worktree", "add", "-b", branch, path, base])
        guard add.ok else { throw WorktreeError(message: "git worktree add failed: \(add.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return WorktreeInfo(repo: root, path: path, branch: branch, base: base)
    }

    /// Keeps `.claude/worktrees/` out of `git status` in the main checkout without touching tracked files.
    static func excludeWorktreeDir(root: String) {
        let common = Shell.run("git", ["-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir"]).output
        guard !common.isEmpty else { return }
        let info = URL(fileURLWithPath: common).appendingPathComponent("info")
        let exclude = info.appendingPathComponent("exclude")
        let current = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        guard !current.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == ".claude/worktrees/" }) else { return }
        try? FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        let addition = (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + ".claude/worktrees/\n"
        try? (current + addition).write(to: exclude, atomically: true, encoding: .utf8)
    }

    /// "+12 −4" for everything the worktree changed relative to its base, committed or not.
    public static func diffStat(_ info: WorktreeInfo) -> String? {
        let mergeBase = Shell.run("git", ["-C", info.path, "merge-base", info.base, "HEAD"]).output
        guard !mergeBase.isEmpty else { return nil }
        let r = Shell.run("git", ["-C", info.path, "diff", "--shortstat", mergeBase])
        guard r.ok else { return nil }
        return formatShortstat(r.output)
    }

    public static func formatShortstat(_ text: String) -> String {
        func number(before word: String) -> Int {
            guard let range = text.range(of: word) else { return 0 }
            let head = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            return Int(head.split(separator: " ").last ?? "") ?? 0
        }
        return "+\(number(before: "insertion")) −\(number(before: "deletion"))"
    }

    public static func hasUncommittedChanges(_ path: String) -> Bool {
        !Shell.run("git", ["-C", path, "status", "--porcelain"]).output.isEmpty
    }

    /// Removes the worktree (refusing if it has uncommitted changes) and optionally its merged branch.
    /// Uses `branch -d`, never `-D`, so unmerged work is never thrown away.
    public static func remove(_ info: WorktreeInfo, deleteBranch: Bool) throws {
        if FileManager.default.fileExists(atPath: info.path) {
            if hasUncommittedChanges(info.path) {
                throw WorktreeError(message: "\(info.path) has uncommitted changes. Commit or discard them first.")
            }
            let r = Shell.run("git", ["-C", info.repo, "worktree", "remove", info.path])
            guard r.ok else { throw WorktreeError(message: "git worktree remove failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
        if deleteBranch {
            let r = Shell.run("git", ["-C", info.repo, "branch", "-d", info.branch])
            guard r.ok else { throw WorktreeError(message: "Kept branch \(info.branch): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
    }
}
