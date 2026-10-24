import Foundation

public struct WorktreeInfo: Codable, Equatable, Sendable {
    public var repo: String
    public var path: String
    /// The branch the worktree was created on (read from its HEAD when a hook made it; empty if detached).
    public var branch: String
    public var base: String
    /// A project's WorktreeCreate hook made it, so its WorktreeRemove hook removes it.
    public var createdByHook: Bool?
    /// The folder the session was started from, whose settings define the hooks.
    public var folder: String?

    public init(repo: String, path: String, branch: String, base: String, createdByHook: Bool? = nil, folder: String? = nil) {
        self.repo = repo; self.path = path; self.branch = branch; self.base = base
        self.createdByHook = createdByHook; self.folder = folder
    }

    public var madeByHook: Bool { createdByHook == true }
}

public struct WorktreeError: Error, LocalizedError {
    public var message: String
    public var errorDescription: String? { message }
    public init(message: String) { self.message = message }
}

/// The worktree is gone, but `git branch -d` kept its branch (usually because it isn't merged).
public struct BranchKept: Error, LocalizedError {
    public var message: String
    public var errorDescription: String? { message }
}

/// What a new worktree session asked for.
public struct WorktreeRequest: Sendable {
    public var folder: String
    /// The session's name, which the worktree's folder and default branch are named after.
    public var name: String
    public var permissionMode: String?

    public init(folder: String, name: String, permissionMode: String? = nil) {
        self.folder = folder; self.name = name; self.permissionMode = permissionMode
    }
}

/// How far creating or removing a worktree has got, for showing while it runs.
public enum WorktreeProgress: Sendable {
    /// What is happening now.
    case step(String)
    /// Output from a hook, as it arrives.
    case output(String)
}

/// Git worktrees for parallel sessions. The synchronous operations shell out to `git` and block;
/// the async ones run project hooks without blocking the caller.
public enum Worktree {
    /// Where Viber (like Claude Code) puts the worktrees it makes with git, under the repository root.
    public static let directory = ".claude/worktrees"

    /// Makes a worktree for a new session: with the project's WorktreeCreate hook when the folder's Claude Code
    /// settings define one (the hook replaces `git worktree add`, as in Claude Code), otherwise with git.
    public static func create(_ request: WorktreeRequest, progress: @escaping @Sendable (WorktreeProgress) -> Void) async throws -> WorktreeInfo {
        guard let root = repoRoot(request.folder) else { throw WorktreeError(message: "\(request.folder) is not inside a git repository.") }
        let hooks = try WorktreeHooks.hooks(.create, folder: request.folder)
        try Task.checkCancellation()
        guard !hooks.isEmpty else {
            progress(.step("Creating the worktree with git"))
            let info = try create(repoDir: request.folder, name: request.name)
            return info
        }
        var name = slug(request.name)
        if name.isEmpty { name = "session" }
        let input = WorktreeHooks.input(.create, cwd: request.folder, name: name, permissionMode: request.permissionMode)
        let checkout = WorktreeHooks.mainCheckout(request.folder) ?? root
        var created: String?
        var failures: [String] = []
        // Like Claude Code, every configured hook runs and the first one that succeeds with a path is used.
        for hook in hooks {
            progress(.step("Running the WorktreeCreate hook: \(hook.display)"))
            let result = await WorktreeHooks.run(hook, input: input, folder: request.folder) { progress(.output($0)) }
            if result.cancelled || Task.isCancelled {
                throw WorktreeError(message: "Stopped the WorktreeCreate hook. It may have left a partly made worktree behind.")
            }
            guard result.ok else { failures.append(WorktreeHooks.failure(hook, result, event: .create)); continue }
            guard created == nil else { continue }
            guard let printed = WorktreeHooks.printedPath(result.stdout) else {
                failures.append("The WorktreeCreate hook succeeded but printed no worktree path: \(hook.display). It must print the directory it made as the last line of its output, with everything else on stderr.")
                continue
            }
            created = try WorktreeHooks.validateWorktreePath(printed, cwd: request.folder, repo: checkout)
        }
        guard let path = created else { throw WorktreeError(message: failures.joined(separator: "\n\n")) }
        let base = Shell.run("git", ["-C", root, "rev-parse", "--abbrev-ref", "HEAD"]).output
        return WorktreeInfo(repo: root, path: path, branch: currentBranch(path) ?? "", base: base,
                            createdByHook: true, folder: request.folder)
    }

    /// The branch checked out at `path`, or nil when HEAD is detached or it isn't a git checkout.
    public static func currentBranch(_ path: String) -> String? {
        let r = Shell.run("git", ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"])
        guard r.ok, !r.output.isEmpty, r.output != "HEAD" else { return nil }
        return r.output
    }

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

    /// Creates `<repo>/.claude/worktrees/<slug>` on a new `viber/<slug>` branch from the current branch, then copies
    /// the gitignored files `.worktreeinclude` lists into it, as Claude Code does for worktrees it makes with git.
    public static func create(repoDir: String, name: String) throws -> WorktreeInfo {
        guard let root = repoRoot(repoDir) else { throw WorktreeError(message: "\(repoDir) is not inside a git repository.") }
        let base = Shell.run("git", ["-C", root, "rev-parse", "--abbrev-ref", "HEAD"]).output
        guard !base.isEmpty, base != "HEAD" else { throw WorktreeError(message: "The repository has no current branch to start from.") }
        var slug = slug(name)
        if slug.isEmpty { slug = "session" }
        let dir = URL(fileURLWithPath: root).appendingPathComponent(directory)
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
        WorktreeInclude.copy(from: root, to: path)
        return WorktreeInfo(repo: root, path: path, branch: branch, base: base, folder: repoDir)
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

    /// Removes the worktree, refusing if it has uncommitted changes, and optionally its merged branch.
    /// A worktree a WorktreeCreate hook made is removed by the project's WorktreeRemove hook when there is one
    /// (as in Claude Code, which only runs that hook for worktrees a hook made); otherwise by `git worktree remove`.
    /// If the hook fails and the worktree is still there, it is kept and the error says why.
    /// The branch is deleted with `branch -d`, never `-D`, so unmerged work is never thrown away.
    /// Returns a sentence saying what was done.
    @discardableResult
    public static func remove(_ info: WorktreeInfo, deleteBranch: Bool,
                              progress: @escaping @Sendable (WorktreeProgress) -> Void = { _ in }) async throws -> String {
        let fm = FileManager.default
        var said: [String] = []
        if fm.fileExists(atPath: info.path) {
            if hasUncommittedChanges(info.path) {
                throw WorktreeError(message: "\(info.path) has uncommitted changes. Commit or discard them first.")
            }
            let folder = info.folder ?? info.repo
            let hooks = info.madeByHook ? try WorktreeHooks.hooks(.remove, folder: folder) : []
            if hooks.isEmpty {
                progress(.step("Removing the worktree with git"))
                let r = Shell.run("git", ["-C", info.repo, "worktree", "remove", info.path])
                guard r.ok else { throw WorktreeError(message: "git worktree remove failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
                said.append("Removed the worktree.")
            } else {
                let input = WorktreeHooks.input(.remove, cwd: folder, worktreePath: info.path)
                var failure: String?
                var lastLine: String?
                for hook in hooks {
                    progress(.step("Running the WorktreeRemove hook: \(hook.display)"))
                    let result = await WorktreeHooks.run(hook, input: input, folder: folder) { progress(.output($0)) }
                    if !result.ok, failure == nil { failure = WorktreeHooks.failure(hook, result, event: .remove) }
                    lastLine = WorktreeHooks.printedPath(result.output) ?? lastLine
                }
                // Like Claude Code: a failed hook that still removed the directory counts as removed.
                if let failure {
                    if fm.fileExists(atPath: info.path) {
                        throw WorktreeError(message: "Kept the worktree at \(info.path).\n\n\(failure)")
                    }
                    said.append("The WorktreeRemove hook failed, but the worktree is gone.")
                } else {
                    said.append("The WorktreeRemove hook removed the worktree" + (lastLine.map { ": \($0)" } ?? "."))
                }
            }
        }
        guard !info.branch.isEmpty else { return said.joined(separator: " ") }
        guard deleteBranch else { return (said + ["Kept branch \(info.branch)."]).joined(separator: " ") }
        // A hook may have deleted just the folder; git still counts the branch as checked out there until pruned.
        Shell.run("git", ["-C", info.repo, "worktree", "prune"])
        guard Shell.run("git", ["-C", info.repo, "rev-parse", "--verify", "--quiet", "refs/heads/\(info.branch)"]).ok else {
            return (said + ["Branch \(info.branch) was already gone."]).joined(separator: " ")
        }
        let r = Shell.run("git", ["-C", info.repo, "branch", "-d", info.branch])
        guard r.ok else {
            throw BranchKept(message: (said + ["Kept branch \(info.branch): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"]).joined(separator: " "))
        }
        return (said + ["Deleted branch \(info.branch)."]).joined(separator: " ")
    }
}
