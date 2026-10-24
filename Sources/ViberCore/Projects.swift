import Darwin
import Foundation

/// What Viber groups sessions, ideas and settings under. In a git repository it is the main checkout's root, so
/// sessions in subfolders and in worktrees (made by Viber, by a hook or by hand) all belong to it.
public struct Project: Codable, Equatable, Identifiable, Sendable {
    public var path: String
    /// Shown instead of the folder's name when set.
    public var customName: String?
    public var addedAt: Date
    /// Its sessions are hidden in the sidebar.
    public var collapsed: Bool?

    public init(path: String, customName: String? = nil, addedAt: Date, collapsed: Bool? = nil) {
        self.path = path; self.customName = customName; self.addedAt = addedAt; self.collapsed = collapsed
    }

    public var id: String { path }
    public var name: String { customName ?? Self.folderName(path) }
    public var isCollapsed: Bool { collapsed == true }

    public static func folderName(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }
}

/// The projects in the sidebar, in the order they were added. They stay there with no session open,
/// until the user removes them. Stored by Viber, not in the repos.
public struct ProjectList: Codable, Equatable {
    public private(set) var projects: [Project] = []

    public init() {}

    public func project(_ path: String) -> Project? { projects.first { $0.path == path } }
    public func contains(_ path: String) -> Bool { projects.contains { $0.path == path } }

    /// Adds a project at the end. Returns false when it is there already.
    @discardableResult
    public mutating func add(_ path: String, at now: Date = Date()) -> Bool {
        guard !path.isEmpty, !contains(path) else { return false }
        projects.append(Project(path: path, addedAt: now))
        return true
    }

    /// Takes a project out of the sidebar. Its folder, ideas and settings are left alone.
    public mutating func remove(_ path: String) { projects.removeAll { $0.path == path } }

    /// An empty name, or the folder's own, goes back to showing the folder's name.
    public mutating func rename(_ path: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(path) { $0.customName = trimmed.isEmpty || trimmed == Project.folderName(path) ? nil : trimmed }
    }

    public mutating func setCollapsed(_ path: String, _ collapsed: Bool) {
        update(path) { $0.collapsed = collapsed ? true : nil }
    }

    /// Moves a project to `index` in the sidebar order.
    public mutating func move(_ path: String, to index: Int) {
        guard let from = projects.firstIndex(where: { $0.path == path }) else { return }
        let project = projects.remove(at: from)
        projects.insert(project, at: min(max(index, 0), projects.count))
    }

    /// Nil when there is no file yet, so the caller can fill the list from what was open before projects.
    public static func load(from url: URL = ViberPaths.projects) -> ProjectList? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(ProjectList.self, from: data)) ?? ProjectList()
    }

    public func save(to url: URL = ViberPaths.projects) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    private mutating func update(_ path: String, _ change: (inout Project) -> Void) {
        guard let index = projects.firstIndex(where: { $0.path == path }) else { return }
        change(&projects[index])
    }
}

public enum ProjectRoot {
    /// The project a folder belongs to: the main checkout of the git repository it is in, else the folder itself.
    /// It only reads `.git` entries, without running git, so the main thread can call it. A folder that is gone
    /// (a removed worktree) resolves through its nearest parent that is in a repository.
    public static func resolve(_ folder: String) -> String {
        let start = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL
        let fm = FileManager.default
        var dir = start
        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return real(dir.path) }
                return real(mainCheckout(gitFile: dotGit) ?? dir.path)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return real(start.path)
    }

    /// A linked worktree's `.git` file names its git dir, whose `commondir` leads to the main repository's.
    /// A submodule's has no `commondir`; it is a project of its own, so this returns nil.
    static func mainCheckout(gitFile: URL) -> String? {
        guard let text = try? String(contentsOf: gitFile, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let base = gitFile.deletingLastPathComponent()
        let gitDir = url(line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces), relativeTo: base)
        guard let common = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) else { return nil }
        let commonDir = url(common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitDir)
        // A bare repository's worktrees have no main checkout; the bare folder stands in for it.
        return commonDir.lastPathComponent == ".git" ? commonDir.deletingLastPathComponent().path : commonDir.path
    }

    private static func url(_ path: String, relativeTo base: URL) -> URL {
        (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)).standardizedFileURL
    }

    /// Symlinks resolved as git resolves them, so the keys match the paths git prints (`/private/var/…`, not `/var/…`).
    private static func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// A checkout of a project's repository.
public struct WorktreeEntry: Equatable, Sendable, Identifiable {
    public var path: String
    /// Nil on a detached HEAD.
    public var branch: String?
    public var head: String
    /// The repository's own checkout, rather than a linked worktree.
    public var isMain: Bool
    /// Its folder is gone; `git worktree prune` would forget it.
    public var isPrunable: Bool
    public var id: String { path }

    public init(path: String, branch: String?, head: String, isMain: Bool, isPrunable: Bool = false) {
        self.path = path; self.branch = branch; self.head = head; self.isMain = isMain; self.isPrunable = isPrunable
    }
}

public struct BranchEntry: Equatable, Sendable, Identifiable {
    public var name: String
    /// Of its last commit.
    public var date: Date?
    public var subject: String
    public var id: String { name }

    public init(name: String, date: Date?, subject: String) {
        self.name = name; self.date = date; self.subject = subject
    }
}

/// What a project page shows about its repository.
public struct RepoSummary: Equatable, Sendable {
    public var isRepo: Bool
    /// What the main checkout has checked out.
    public var currentBranch: String?
    public var worktrees: [WorktreeEntry]
    /// Local branches, most recently committed to first.
    public var branches: [BranchEntry]

    public init(isRepo: Bool, currentBranch: String? = nil, worktrees: [WorktreeEntry] = [], branches: [BranchEntry] = []) {
        self.isRepo = isRepo; self.currentBranch = currentBranch; self.worktrees = worktrees; self.branches = branches
    }

    /// Runs git. Blocking: call it off the main thread.
    public static func load(_ root: String, maxBranches: Int = 200) -> RepoSummary {
        let inside = Shell.run("git", ["-C", root, "rev-parse", "--is-inside-work-tree"], timeout: 10)
        guard inside.ok, inside.output == "true" else { return RepoSummary(isRepo: false) }
        let worktrees = Shell.run("git", ["-C", root, "worktree", "list", "--porcelain"], timeout: 10)
        let branches = Shell.run("git", ["-C", root, "for-each-ref", "--sort=-committerdate", "--count=\(maxBranches)",
                                         "--format=%(refname:short)%00%(committerdate:unix)%00%(subject)", "refs/heads"], timeout: 10)
        return RepoSummary(isRepo: true, currentBranch: Worktree.currentBranch(root),
                           worktrees: worktrees.ok ? parseWorktrees(worktrees.stdout) : [],
                           branches: branches.ok ? parseBranches(branches.stdout) : [])
    }

    /// `git worktree list --porcelain`: one block per worktree, the main one first. A bare main entry is left out.
    public static func parseWorktrees(_ text: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var isFirst = true
        for block in text.components(separatedBy: "\n\n") {
            var path: String?, branch: String?, head = "", bare = false, prunable = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                else if line.hasPrefix("HEAD ") { head = String(line.dropFirst("HEAD ".count)) }
                else if line.hasPrefix("branch ") {
                    let ref = line.dropFirst("branch ".count)
                    branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : String(ref)
                }
                else if line == "bare" { bare = true }
                else if line == "prunable" || line.hasPrefix("prunable ") { prunable = true }
            }
            guard let path else { continue }
            defer { isFirst = false }
            if bare { continue }
            entries.append(WorktreeEntry(path: path, branch: branch, head: head, isMain: isFirst, isPrunable: prunable))
        }
        return entries
    }

    /// `git for-each-ref` lines of name, commit time and subject, separated by NUL.
    public static func parseBranches(_ text: String) -> [BranchEntry] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
            guard let name = parts.first, !name.isEmpty else { return nil }
            let date = parts.count > 1 ? TimeInterval(parts[1]).map(Date.init(timeIntervalSince1970:)) : nil
            return BranchEntry(name: String(name), date: date, subject: parts.count > 2 ? String(parts[2]) : "")
        }
    }
}
