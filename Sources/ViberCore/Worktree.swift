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
    /// The branch to create; nil for `branchPattern` filled in, numbered if that is taken.
    public var branch: String?
    /// The project's pattern for the default branch, such as `viber/<slug>`.
    public var branchPattern: String
    /// The key of the issue the session is for, such as `EST-12`: what `<key>` in the pattern becomes.
    public var issueKey: String?
    /// Where a git worktree starts. A WorktreeCreate hook decides that itself.
    public var base: WorktreeBase
    /// A branch to start from instead, such as one an issue builds on that isn't merged yet.
    public var startBranch: String?
    public var permissionMode: String?

    public init(folder: String, name: String, branch: String? = nil, branchPattern: String = Worktree.defaultBranchPattern,
                issueKey: String? = nil, base: WorktreeBase = .originDefault, startBranch: String? = nil, permissionMode: String? = nil) {
        self.folder = folder; self.name = name; self.branch = branch; self.branchPattern = branchPattern
        self.issueKey = issueKey; self.base = base; self.startBranch = startBranch; self.permissionMode = permissionMode
    }
}

/// Where a new git worktree's branch starts.
public enum WorktreeBase: String, Equatable, Sendable, CaseIterable {
    /// origin's default branch (origin/HEAD, else origin/main or origin/master), fetched first; like Claude Code.
    case originDefault
    /// The branch checked out in the folder now.
    case current
}

/// The bases the New Session sheet offers for a repository.
public struct BaseChoices: Equatable, Sendable {
    public var hasOrigin: Bool
    /// origin's default branch as cached locally, such as `origin/main`; nil until origin has been fetched.
    public var originDefault: String?
    /// The branch checked out now; nil when HEAD is detached.
    public var current: String?

    public init(hasOrigin: Bool, originDefault: String?, current: String?) {
        self.hasOrigin = hasOrigin; self.originDefault = originDefault; self.current = current
    }

    /// The base to use when `wanted` isn't available: there is no origin, or HEAD is detached.
    public func available(_ wanted: WorktreeBase) -> WorktreeBase {
        switch wanted {
        case .originDefault: return hasOrigin || current == nil ? .originDefault : .current
        case .current: return current != nil || !hasOrigin ? .current : .originDefault
        }
    }
}

/// Whether a branch name typed for a new worktree can be used.
public enum BranchCheck: Equatable, Sendable {
    case ok
    case problem(String)
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
        let stopped = WorktreeError(message: "Stopped before the worktree was made.")
        let hooks = try WorktreeHooks.hooks(.create, folder: request.folder)
        if Task.isCancelled { throw stopped }
        guard !hooks.isEmpty else {
            var base: String?
            if let start = request.startBranch, branchExists(start, repo: root) {
                progress(.output("Starting from \(start).\n"))
                base = start
            } else if request.base == .originDefault {
                if hasOrigin(root) {
                    progress(.step("Fetching origin"))
                    let fetched = await fetchOriginDefault(root)
                    if let note = fetched.note { progress(.output(note + "\n")) }
                    base = fetched.ref
                    if base == nil { progress(.output("origin has no default branch here, so the worktree starts from the current branch.\n")) }
                } else {
                    progress(.output("There is no origin remote, so the worktree starts from the current branch.\n"))
                }
                if Task.isCancelled { throw stopped }
            }
            progress(.step("Creating the worktree with git"))
            return try create(repoDir: request.folder, name: request.name, branch: request.branch,
                              pattern: request.branchPattern, issueKey: request.issueKey, base: base)
        }
        // The hook gets the branch as the worktree `name` (Claude Code's only naming field), so it must also be
        // a name Claude Code itself would pass.
        let name = request.branch ?? unusedDefaultBranch(forName: request.name, root: root, pattern: request.branchPattern, key: request.issueKey)
        if case .problem(let problem) = checkBranch(name, repo: root) { throw WorktreeError(message: problem) }
        if let problem = hookNameProblem(name) { throw WorktreeError(message: problem) }
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
        // The hook chose where the branch starts; for the diff stat, compare with origin's default branch
        // (what the work will be merged into), else with the folder's current branch.
        let base = originDefaultBranch(root) ?? currentBranch(root) ?? "HEAD"
        return WorktreeInfo(repo: root, path: path, branch: currentBranch(path) ?? "", base: base,
                            createdByHook: true, folder: request.folder)
    }

    // MARK: Base branch

    public static func hasOrigin(_ root: String) -> Bool {
        Shell.run("git", ["-C", root, "remote", "get-url", "origin"]).ok
    }

    /// origin's default branch as cached locally: `origin/HEAD`'s target, else `origin/main`, else `origin/master`.
    public static func originDefaultBranch(_ root: String) -> String? {
        let head = Shell.run("git", ["-C", root, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])
        var candidates = ["origin/main", "origin/master"]
        if head.ok, head.output.hasPrefix("origin/"), head.output != "origin/HEAD" { candidates.insert(head.output, at: 0) }
        return candidates.first { Shell.run("git", ["-C", root, "rev-parse", "--verify", "--quiet", "refs/remotes/\($0)"]).ok }
    }

    /// What the New Session sheet can offer. Blocking: call it off the main thread.
    public static func baseChoices(_ root: String) -> BaseChoices {
        BaseChoices(hasOrigin: hasOrigin(root), originDefault: originDefaultBranch(root), current: currentBranch(root))
    }

    /// Fetches origin's default branch (all of origin when it isn't known yet), giving up after `timeout` seconds
    /// and never waiting for a password. Offline, the cached ref is used. Returns the ref to start from, if any.
    public static func fetchOriginDefault(_ root: String, timeout: TimeInterval = 8) async -> (ref: String?, note: String?) {
        let known = originDefaultBranch(root)
        var env = Executables.environment()
        env["GIT_TERMINAL_PROMPT"] = "0"
        let target = known.map { [String($0.dropFirst("origin/".count))] } ?? []
        let result = await Subprocess.run("git", ["-C", root, "fetch", "--quiet", "origin"] + target, environment: env, timeout: timeout)
        if result.cancelled { return (known, nil) }
        let ref = originDefaultBranch(root)
        guard !result.ok else { return (ref, nil) }
        let why = result.timedOut ? "it took longer than \(Int(timeout)) seconds"
            : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "git fetch failed"
        return (ref, "Couldn't fetch origin (\(why))" + (ref.map { "; starting from the cached \($0)." } ?? "."))
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

    /// The branch pattern a project has until it sets its own. `<slug>` becomes the session name.
    public static let defaultBranchPattern = "viber/<slug>"

    /// The `<…>` parts of a branch name or pattern, in order, such as ["<id>", "<slug>"].
    public static func placeholders(in text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<") {
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(where: { $0 == "<" || $0 == ">" }) else { break }
            if rest[close] == ">", close > after {
                found.append(String(rest[open...close]))
                rest = rest[rest.index(after: close)...]
            } else {
                rest = rest[close...]
            }
        }
        return found
    }

    /// True when the pattern has a part to fill in for each session that Viber can't fill itself: anything but
    /// `<slug>`, and `<key>` when the session isn't for an issue.
    public static func needsInput(_ pattern: String, key: String? = nil) -> Bool {
        placeholders(in: pattern).contains { $0 != "<slug>" && ($0 != "<key>" || key == nil) }
    }

    /// The branch a worktree session gets unless another one is typed: `pattern` with the name's slug for `<slug>`
    /// and the issue's key, in lower case, for `<key>`. A pattern without `<key>` (or any other part to fill in)
    /// still names the issue: its key goes in front of the slug, as in `viber/est-12-login`.
    public static func defaultBranch(forName name: String, pattern: String = defaultBranchPattern, key: String? = nil) -> String {
        fill(pattern, slug: slug(forName: name, pattern: pattern, key: key), key: key)
    }

    static func fill(_ pattern: String, slug: String, key: String? = nil) -> String {
        var branch = pattern.replacingOccurrences(of: "<slug>", with: slug)
        if let key { branch = branch.replacingOccurrences(of: "<key>", with: key.lowercased()) }
        return branch
    }

    /// The slug for `<slug>`: the name's, with the issue's key in front when the pattern has nowhere else for it.
    static func slug(forName name: String, pattern: String, key: String?) -> String {
        var s = slug(name)
        // A name that starts with the key ("NEX-198 Invite links") would repeat it next to `<key>`.
        if let key, !key.isEmpty, s.hasPrefix(slug(key) + "-") { s = String(s.dropFirst(slug(key).count + 1)) }
        if s.isEmpty { s = "session" }
        if let key, !key.isEmpty, placeholders(in: pattern) == ["<slug>"] { s = slug(key) + "-" + s }
        return s
    }

    /// The default branch, numbered after the slug (`viber/login-2`) if one by that name exists.
    static func unusedDefaultBranch(forName name: String, root: String, pattern: String = defaultBranchPattern, key: String? = nil) -> String {
        guard pattern.contains("<slug>") else { return fill(pattern, slug: "", key: key) }
        let s = slug(forName: name, pattern: pattern, key: key)
        var candidate = fill(pattern, slug: s, key: key), n = 2
        while branchExists(candidate, repo: root) { candidate = fill(pattern, slug: "\(s)-\(n)", key: key); n += 1 }
        return candidate
    }

    /// "Replace <id> in the branch name." when `name` still has parts to fill in.
    static func placeholderProblem(_ name: String) -> String? {
        let parts = placeholders(in: name)
        guard let last = parts.last else { return nil }
        let list = parts.count == 1 ? last : parts.dropLast().joined(separator: ", ") + " and " + last
        return "Replace \(list) in the branch name."
    }

    public static func branchExists(_ branch: String, repo: String) -> Bool {
        Shell.run("git", ["-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]).ok
    }

    /// Whether `name` can be a new branch: `git check-ref-format --branch` must accept it, and it may not exist yet.
    /// Blocking: call it off the main thread.
    public static func checkBranch(_ name: String, repo: String?) -> BranchCheck {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .problem("Enter a branch name.") }
        guard trimmed == name, !name.hasPrefix("-") else { return .problem("“\(name)” is not a valid branch name.") }
        // Git accepts `<` and `>`, so a pattern's leftover `<id>` would otherwise become part of the name.
        if let problem = placeholderProblem(name) { return .problem(problem) }
        let check = Shell.run("git", (repo.map { ["-C", $0] } ?? []) + ["check-ref-format", "--branch", name])
        guard check.ok, check.output == name else { return .problem("“\(name)” is not a valid branch name.") }
        if let repo, branchExists(name, repo: repo) { return .problem("A branch named \(name) already exists.") }
        return .ok
    }

    /// Claude Code's rules for a worktree name, which is what a WorktreeCreate hook receives: at most 64 characters,
    /// and each `/`-separated part made of letters, digits, `.`, `_` and `-` (not `.`, `..` or `.git`).
    public static func hookNameProblem(_ name: String) -> String? {
        if name.count > 64 { return "The project's WorktreeCreate hook gets the branch as its worktree name, which can be at most 64 characters." }
        for part in name.split(separator: "/", omittingEmptySubsequences: false) {
            let plain = part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
            var lowered = part.lowercased()
            while lowered.hasSuffix(".") { lowered.removeLast() }
            if part.isEmpty || !plain || part == "." || part == ".." || lowered == ".git" {
                return "The project's WorktreeCreate hook gets the branch as its worktree name, so each part between slashes may only use letters, digits, “.”, “_” and “-”."
            }
        }
        return nil
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

    /// Creates `<repo>/.claude/worktrees/<slug>` on a new branch (`pattern` filled in with the folder's name, unless
    /// `branch` names one) starting at `base` (a ref such as `origin/main`; nil for the current branch), then copies
    /// the gitignored files `.worktreeinclude` lists into it, as Claude Code does for worktrees it makes with git.
    /// The base is recorded, so the diff stat compares with it.
    public static func create(repoDir: String, name: String, branch: String? = nil,
                              pattern: String = defaultBranchPattern, issueKey: String? = nil, base chosen: String? = nil) throws -> WorktreeInfo {
        guard let root = repoRoot(repoDir) else { throw WorktreeError(message: "\(repoDir) is not inside a git repository.") }
        let base = chosen ?? Shell.run("git", ["-C", root, "rev-parse", "--abbrev-ref", "HEAD"]).output
        guard !base.isEmpty, base != "HEAD" else { throw WorktreeError(message: "The repository has no current branch to start from.") }
        // A pattern without `<slug>` can't be numbered, so it has to be new like a typed name.
        let requested = branch ?? (pattern.contains("<slug>") ? nil : fill(pattern, slug: "", key: issueKey))
        if requested == nil, let problem = placeholderProblem(fill(pattern, slug: "", key: issueKey)) {
            throw WorktreeError(message: problem)
        }
        if let requested, case .problem(let problem) = checkBranch(requested, repo: root) { throw WorktreeError(message: problem) }
        let slug = slug(forName: name, pattern: pattern, key: issueKey)
        let dir = URL(fileURLWithPath: root).appendingPathComponent(directory)
        // The folder is numbered when it is taken, and so is the default branch along with it.
        var candidate = slug, n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path)
                || (requested == nil && branchExists(fill(pattern, slug: candidate, key: issueKey), repo: root)) {
            candidate = "\(slug)-\(n)"; n += 1
        }
        let path = dir.appendingPathComponent(candidate).path
        let branch = requested ?? fill(pattern, slug: candidate, key: issueKey)
        excludeWorktreeDir(root: root)
        // --no-track: a branch started from origin/main must not push to (or count as behind) origin/main.
        let add = Shell.run("git", ["-C", root, "worktree", "add", "--no-track", "-b", branch, path, base])
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
    /// Only the branch the worktree was created on is deleted; one the session switched to is kept, and said so.
    /// Returns a sentence saying what was done.
    @discardableResult
    public static func remove(_ info: WorktreeInfo, deleteBranch: Bool,
                              progress: @escaping @Sendable (WorktreeProgress) -> Void = { _ in }) async throws -> String {
        let fm = FileManager.default
        var said: [String] = []
        if fm.fileExists(atPath: info.path) {
            let switched = currentBranch(info.path).flatMap { $0 == info.branch ? nil : $0 }
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
                for hook in hooks {
                    progress(.step("Running the WorktreeRemove hook: \(hook.display)"))
                    let result = await WorktreeHooks.run(hook, input: input, folder: folder) { progress(.output($0)) }
                    if !result.ok, failure == nil { failure = WorktreeHooks.failure(hook, result, event: .remove) }
                }
                // Like Claude Code: a failed hook that still removed the directory counts as removed.
                if let failure {
                    if fm.fileExists(atPath: info.path) {
                        throw WorktreeError(message: "Kept the worktree at \(info.path).\n\n\(failure)")
                    }
                    said.append("The WorktreeRemove hook failed, but the worktree is gone.")
                } else {
                    // Its output is in the removal's log; its last line (e.g. "Its volumes are kept") isn't a summary.
                    said.append("The WorktreeRemove hook removed the worktree.")
                }
            }
            if let switched { said.append("Kept \(switched), the branch the session switched to.") }
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
