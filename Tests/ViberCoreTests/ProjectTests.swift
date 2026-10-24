import XCTest
@testable import ViberCore

final class ProjectRootTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("viber-projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testFolderOutsideARepositoryIsItsOwnProject() throws {
        let folder = scratch.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(ProjectRoot.resolve(folder.path), real(folder))
    }

    func testSubfoldersAndWorktreesBelongToTheMainCheckout() throws {
        let repo = try makeRepo("app")
        let sub = repo.appendingPathComponent("apps/web")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let inside = repo.appendingPathComponent(".claude/worktrees/feature")
        let outside = scratch.appendingPathComponent("app-worktrees/other")
        XCTAssertTrue(git(repo, "worktree", "add", "-q", "-b", "feature", inside.path).ok)
        XCTAssertTrue(git(repo, "worktree", "add", "-q", "-b", "other", outside.path).ok)

        let root = real(repo)
        XCTAssertEqual(ProjectRoot.resolve(repo.path), root)
        XCTAssertEqual(ProjectRoot.resolve(sub.path), root)
        XCTAssertEqual(ProjectRoot.resolve(inside.path), root)
        XCTAssertEqual(ProjectRoot.resolve(outside.path), root, "a worktree a hook made beside the repo")
        XCTAssertEqual(ProjectRoot.resolve(outside.appendingPathComponent("src").path), root)
        XCTAssertEqual(ProjectRoot.resolve(repo.path + "/"), root)
    }

    func testRemovedWorktreeInsideTheRepoResolvesToIt() throws {
        let repo = try makeRepo("app")
        let gone = repo.appendingPathComponent(".claude/worktrees/gone")
        XCTAssertEqual(ProjectRoot.resolve(gone.path), real(repo))
    }

    func testSubmoduleIsAProjectOfItsOwn() throws {
        let repo = try makeRepo("super")
        let module = repo.appendingPathComponent("vendor/lib")
        let moduleGitDir = repo.appendingPathComponent(".git/modules/lib")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moduleGitDir, withIntermediateDirectories: true)
        try "gitdir: ../../.git/modules/lib\n".write(to: module.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectRoot.resolve(module.path), real(module))
    }

    func testRepoSummaryListsWorktreesAndBranches() throws {
        let repo = try makeRepo("app")
        let tree = repo.appendingPathComponent(".claude/worktrees/feature")
        XCTAssertTrue(git(repo, "worktree", "add", "-q", "-b", "feature", tree.path).ok)
        let summary = RepoSummary.load(repo.path)
        XCTAssertTrue(summary.isRepo)
        XCTAssertEqual(summary.currentBranch, "main")
        XCTAssertEqual(summary.worktrees.map(\.branch), ["main", "feature"])
        XCTAssertEqual(summary.worktrees.map(\.isMain), [true, false])
        XCTAssertEqual(Set(summary.branches.map(\.name)), ["main", "feature"])
        XCTAssertEqual(summary.branches.first?.subject, "First")
        XCTAssertNotNil(summary.branches.first?.date)

        let plain = scratch.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertFalse(RepoSummary.load(plain.path).isRepo)
    }

    private func makeRepo(_ name: String) throws -> URL {
        let repo = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"],
                     ["commit", "-q", "--allow-empty", "-m", "First"]] {
            XCTAssertTrue(git(repo, args).ok, args.joined(separator: " "))
        }
        return repo
    }

    @discardableResult
    private func git(_ repo: URL, _ args: String...) -> ShellResult { git(repo, args) }
    private func git(_ repo: URL, _ args: [String]) -> ShellResult { Shell.run("git", ["-C", repo.path] + args) }

    private func real(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

final class ProjectListTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_790_000_000)

    func testAddRenameCollapseMoveAndRemove() {
        var list = ProjectList()
        XCTAssertTrue(list.add("/code/app", at: at))
        XCTAssertFalse(list.add("/code/app", at: at), "added once")
        XCTAssertFalse(list.add("", at: at))
        list.add("/code/site", at: at)
        list.add("/code/tools", at: at)
        XCTAssertEqual(list.projects.map(\.name), ["app", "site", "tools"])

        list.rename("/code/site", to: "  Website ")
        XCTAssertEqual(list.project("/code/site")?.name, "Website")
        list.rename("/code/site", to: "site")
        XCTAssertNil(list.project("/code/site")?.customName, "the folder's own name clears the custom one")

        list.setCollapsed("/code/app", true)
        XCTAssertTrue(list.project("/code/app")?.isCollapsed == true)
        list.setCollapsed("/code/app", false)
        XCTAssertNil(list.project("/code/app")?.collapsed)

        list.move("/code/tools", to: 0)
        XCTAssertEqual(list.projects.map(\.name), ["tools", "app", "site"])
        list.move("/code/tools", to: 99)
        XCTAssertEqual(list.projects.map(\.name), ["app", "site", "tools"])

        list.remove("/code/site")
        XCTAssertEqual(list.projects.map(\.path), ["/code/app", "/code/tools"])
    }

    func testSaveAndLoad() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("viber-projects-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(ProjectList.load(from: url), "no file yet")
        var list = ProjectList()
        list.add("/code/app", at: at)
        list.rename("/code/app", to: "App")
        try list.save(to: url)
        XCTAssertEqual(ProjectList.load(from: url), list)
    }

    func testParseWorktrees() {
        let text = """
        worktree /code/app
        HEAD 1111
        branch refs/heads/main

        worktree /code/app/.claude/worktrees/x
        HEAD 2222
        detached

        worktree /tmp/gone
        HEAD 3333
        branch refs/heads/feat/NEX-1-thing
        prunable gitdir file points to non-existent location

        """
        let entries = RepoSummary.parseWorktrees(text)
        XCTAssertEqual(entries.map(\.path), ["/code/app", "/code/app/.claude/worktrees/x", "/tmp/gone"])
        XCTAssertEqual(entries.map(\.branch), ["main", nil, "feat/NEX-1-thing"])
        XCTAssertEqual(entries.map(\.isMain), [true, false, false])
        XCTAssertEqual(entries.map(\.isPrunable), [false, false, true])
        XCTAssertEqual(entries[1].head, "2222")

        let bare = RepoSummary.parseWorktrees("worktree /code/app.git\nbare\n\nworktree /code/one\nHEAD 1\nbranch refs/heads/one\n")
        XCTAssertEqual(bare.map(\.path), ["/code/one"])
        XCTAssertEqual(bare.map(\.isMain), [false], "the bare repository is not a checkout")
    }

    func testParseBranches() {
        let text = "main\u{0}1790000000\u{0}Fix: a, b\nfeature\u{0}\u{0}\n"
        let branches = RepoSummary.parseBranches(text)
        XCTAssertEqual(branches.map(\.name), ["main", "feature"])
        XCTAssertEqual(branches.first?.date, at)
        XCTAssertEqual(branches.first?.subject, "Fix: a, b")
        XCTAssertNil(branches.last?.date)
    }

    func testIdeasMoveToTheirProject() {
        var issues = IssueList()
        issues.add("one", project: "/code/app/apps/web", by: "you", at: at)
        issues.add("two", project: "/code/app", by: "you", at: at)
        XCTAssertTrue(issues.moveProjects { $0.hasPrefix("/code/app") ? "/code/app" : $0 })
        XCTAssertEqual(issues.issues.map(\.project), ["/code/app", "/code/app"])
        XCTAssertFalse(issues.moveProjects { $0 }, "nothing left to move")
    }
}
