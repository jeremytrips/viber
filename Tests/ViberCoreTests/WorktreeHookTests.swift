import XCTest
@testable import ViberCore

final class SubprocessTests: XCTestCase {
    func testOutputInputAndStatus() async {
        let result = await Subprocess.run("/bin/sh", ["-c", "read line; echo \"got $line\"; echo oops >&2; exit 3"],
                                          input: Data("hello\n".utf8))
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stdout, "got hello\n")
        XCTAssertEqual(result.stderr, "oops\n")
        XCTAssertFalse(result.ok)
    }

    func testTimeoutStopsTheWholeProcessGroup() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("viber-sub-\(UUID().uuidString)")
        let started = Date()
        // The child `sleep` would outlive a kill of just the shell; the group kill stops it too.
        let result = await Subprocess.run("/bin/sh", ["-c", "sleep 30 & echo $! > '\(marker.path)'; wait"], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        let child = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotEqual(kill(child, 0), 0, "the background child was stopped as well")
        try? FileManager.default.removeItem(at: marker)
    }

    func testCancelling() async {
        let task = Task { await Subprocess.run("/bin/sleep", ["30"]) }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.ok)
    }

    func testStreamsOutputAndReportsMissingPrograms() async {
        let collected = Collector()
        let result = await Subprocess.run("/bin/sh", ["-c", "echo one; echo two >&2; echo three"], onOutput: { collected.add($0) })
        XCTAssertTrue(result.ok)
        XCTAssertEqual(collected.text.split(separator: "\n").sorted(), ["one", "three", "two"])
        let missing = await Subprocess.run("no-such-program-\(UUID().uuidString)", [])
        XCTAssertTrue(missing.failedToStart)
    }

    func testSplitCharactersAreHeldBack() {
        let euro = Data("a€".utf8)  // € is three bytes
        XCTAssertEqual(Subprocess.completeUTF8Prefix(euro.prefix(2)), 1)
        XCTAssertEqual(Subprocess.completeUTF8Prefix(euro), 4)
        XCTAssertEqual(Subprocess.completeUTF8Prefix(Data("abc".utf8)), 3)
        XCTAssertEqual(Subprocess.completeUTF8Prefix(Data()), 0)
    }
}

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String] = []
    func add(_ s: String) { lock.withLock { parts.append(s) } }
    var text: String { lock.withLock { parts.joined() } }
}

final class WorktreeHookParsingTests: XCTestCase {
    func testParsesCommandAndExecHooks() {
        let hooks: [String: Any] = ["WorktreeCreate": [
            ["matcher": "ignored", "hooks": [["type": "command", "command": "pnpm wt:new", "timeout": 900]]],
            ["hooks": [["type": "command", "command": "node", "args": ["tools/x.mjs", "${CLAUDE_PROJECT_DIR}"]],
                       ["type": "prompt", "prompt": "skipped, as in Claude Code"],
                       ["type": "http", "url": "https://example.com"]]]
        ], "WorktreeRemove": [["hooks": [["type": "command", "command": "pnpm wt:rm"]]]]]
        let parsed = WorktreeHooks.parse(.create, hooks: hooks, source: "s.json")
        XCTAssertEqual(parsed.commands, [HookCommand(command: "pnpm wt:new", timeout: 900, source: "s.json"),
                                         HookCommand(command: "node", args: ["tools/x.mjs", "${CLAUDE_PROJECT_DIR}"], source: "s.json")])
        XCTAssertEqual(parsed.unsupported, ["a http hook"])
        XCTAssertEqual(parsed.commands[0].effectiveTimeout, 900)
        XCTAssertEqual(parsed.commands[1].effectiveTimeout, 600, "Claude Code's default for command hooks")
        XCTAssertEqual(WorktreeHooks.parse(.remove, hooks: hooks, source: "s").commands.map(\.command), ["pnpm wt:rm"])
    }

    func testMergesFilesAndHonoursDisableSettings() throws {
        let dir = try temporaryFolder()
        func file(_ name: String, _ object: [String: Any], managed: Bool = false) throws -> HookSettingsFile {
            let url = dir.appendingPathComponent(name)
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            return HookSettingsFile(url: url, managed: managed)
        }
        func create(_ command: String) -> [String: Any] {
            ["hooks": ["WorktreeCreate": [["hooks": [["type": "command", "command": command]]]]]]
        }
        let user = try file("user.json", create("user-hook"))
        let project = try file("project.json", create("project-hook"))
        let duplicate = try file("local.json", create("project-hook"))
        XCTAssertEqual(try WorktreeHooks.hooks(.create, files: [user, project, duplicate]).map(\.command), ["user-hook", "project-hook"],
                       "hooks add up across files, and the same command runs once")

        let disabled = try file("off.json", ["disableAllHooks": true])
        XCTAssertEqual(try WorktreeHooks.hooks(.create, files: [user, project, disabled]), [])
        let reenabled = try file("on.json", ["disableAllHooks": false])
        XCTAssertEqual(try WorktreeHooks.hooks(.create, files: [disabled, project, reenabled]).count, 1, "the later file wins")

        let managed = try file("managed.json", create("managed-hook"), managed: true)
        XCTAssertEqual(try WorktreeHooks.hooks(.create, files: [project, disabled, managed]).map(\.command), ["managed-hook"],
                       "a user's disableAllHooks leaves managed hooks running")
        let managedOnly = try file("policy.json", ["allowManagedHooksOnly": true], managed: true)
        XCTAssertEqual(try WorktreeHooks.hooks(.create, files: [project, managed, managedOnly]).map(\.command), ["managed-hook"])
        let managedOff = try file("policy-off.json", ["disableAllHooks": true], managed: true)
        XCTAssertEqual(try WorktreeHooks.hooks(.create, files: [project, managed, managedOff]), [])

        let http = try file("http.json", ["hooks": ["WorktreeCreate": [["hooks": [["type": "http", "url": "https://x"]]]]]])
        XCTAssertThrowsError(try WorktreeHooks.hooks(.create, files: [http]), "an HTTP hook Viber can't run is not silently skipped")
        XCTAssertEqual(try WorktreeHooks.hooks(.create, files: [http, disabled]), [], "unless hooks are off anyway")
    }

    func testSettingsFilesForAFolderInAWorktree() throws {
        let repo = try temporaryRepo()
        let home = try temporaryFolder()
        let linked = repo.deletingLastPathComponent().appendingPathComponent("linked-\(UUID().uuidString)")
        XCTAssertTrue(Shell.run("git", ["-C", repo.path, "worktree", "add", "-q", "-b", "x", linked.path]).ok)
        defer { try? FileManager.default.removeItem(at: linked) }
        func std(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
        let realRepo = std(try XCTUnwrap(WorktreeHooks.mainCheckout(repo.path)))
        let realLinked = std(try XCTUnwrap(Worktree.repoRoot(linked.path)))
        XCTAssertEqual(WorktreeHooks.mainCheckout(linked.path).map(std), realRepo)
        let files = WorktreeHooks.settingsFiles(folder: realLinked, home: home, managed: home.appendingPathComponent("managed"))
        XCTAssertEqual(files.map { std($0.url.path) }, [
            home.appendingPathComponent(".claude/settings.json").path,
            realLinked + "/.claude/settings.json",
            realLinked + "/.claude/settings.local.json",
            realRepo + "/.claude/settings.local.json",
            home.appendingPathComponent("managed/managed-settings.json").path
        ], "the local file is read at the main checkout's root, after the folder's older copy")
        let plain = try temporaryFolder()
        XCTAssertEqual(WorktreeHooks.settingsFiles(folder: plain.path, home: home, managed: home).map(\.url.lastPathComponent),
                       ["settings.json", "settings.json", "settings.local.json", "managed-settings.json"])
    }

    func testInputAndPrintedPath() throws {
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: WorktreeHooks.input(.create, cwd: "/r", name: "feat/x")) as? [String: String])
        XCTAssertEqual(input, ["session_id": "", "transcript_path": "", "cwd": "/r", "hook_event_name": "WorktreeCreate", "name": "feat/x"])
        let remove = try XCTUnwrap(JSONSerialization.jsonObject(with: WorktreeHooks.input(.remove, cwd: "/r", worktreePath: "/w")) as? [String: String])
        XCTAssertEqual(remove["worktree_path"], "/w")
        XCTAssertEqual(remove["hook_event_name"], "WorktreeRemove")

        XCTAssertEqual(WorktreeHooks.printedPath("Installing…\n\u{1B}[32m/tmp/wt/login\u{1B}[0m\n\n  \n"), "/tmp/wt/login")
        XCTAssertNil(WorktreeHooks.printedPath("\n \n"))
    }

    func testValidatesTheWorktreePath() throws {
        let repo = try temporaryRepo()
        let outside = try temporaryFolder()
        XCTAssertEqual(try WorktreeHooks.validateWorktreePath(outside.path, cwd: repo.path, repo: repo.path),
                       outside.standardizedFileURL.path)
        let sibling = outside.deletingLastPathComponent()
        XCTAssertEqual(try WorktreeHooks.validateWorktreePath("../\(outside.lastPathComponent)", cwd: sibling.appendingPathComponent("x").path,
                                                              repo: repo.path),
                       outside.standardizedFileURL.path, "a relative path is resolved against the folder the hook ran in")
        XCTAssertThrowsError(try WorktreeHooks.validateWorktreePath(outside.path + "/../" + outside.lastPathComponent, cwd: "/", repo: repo.path))
        XCTAssertThrowsError(try WorktreeHooks.validateWorktreePath(outside.path + "/missing", cwd: "/", repo: repo.path))
        XCTAssertThrowsError(try WorktreeHooks.validateWorktreePath(repo.path, cwd: "/", repo: repo.path), "the checkout itself is no worktree")
        let link = repo.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try WorktreeHooks.validateWorktreePath(link.path, cwd: "/", repo: repo.path))
    }
}

final class WorktreeIncludeTests: XCTestCase {
    func testGitignoreMatching() {
        let m = GitignoreMatcher("""
        # comment
        .env
        *.local
        /build/
        config/secrets.json
        docs/**/notes.md
        logs/**
        !keep.local
        """)
        XCTAssertTrue(m.ignores(".env"))
        XCTAssertTrue(m.ignores("apps/api/.env"), "a pattern without a slash matches at any depth")
        XCTAssertTrue(m.ignores(".ENV"), "case doesn't matter, as in the ignore package")
        XCTAssertFalse(m.ignores(".env.example"))
        XCTAssertTrue(m.ignores("a/b.local"))
        XCTAssertFalse(m.ignores("keep.local"), "a later negation wins")
        XCTAssertTrue(m.ignores("build/"))
        XCTAssertFalse(m.ignores("build"), "a directory-only pattern needs a directory")
        XCTAssertTrue(m.ignores("build/out.js"), "files inside an ignored directory are ignored")
        XCTAssertFalse(m.ignores("src/build/"), "a leading slash anchors to the root")
        XCTAssertTrue(m.ignores("config/secrets.json"))
        XCTAssertFalse(m.ignores("x/config/secrets.json"), "a slash in the middle anchors too")
        XCTAssertTrue(m.ignores("docs/notes.md"))
        XCTAssertTrue(m.ignores("docs/a/b/notes.md"))
        XCTAssertTrue(m.ignores("logs/a.txt"))
        XCTAssertFalse(m.ignores("logs/"), "logs/** matches what is inside, not the folder")
        XCTAssertTrue(GitignoreMatcher("**/.claude/skills/*.md").ignores("a/.claude/skills/x.md"))
        XCTAssertTrue(GitignoreMatcher("file[0-9].txt").ignores("file3.txt"))
        XCTAssertFalse(GitignoreMatcher("file[!0-9].txt").ignores("file3.txt"))
    }

    func testSelectionFollowsClaudeCode() {
        let ignored = [".env", ".env.local", "notes.txt", "node_modules/", "vendor/", "local/", ".claude/"]
        let text = ".env\n.env.local\nvendor/**/config.json\n**/.claude/skills/*.md\nlocal\n"
        let picked = WorktreeInclude.select(ignored: ignored, text: text)
        XCTAssertEqual(picked.files, [".env", ".env.local"])
        XCTAssertEqual(picked.expand, ["vendor/", "local/", ".claude/"],
                       "vendor/ by its name, local/ because it matches, .claude/ as the first name after **/; never node_modules/")
        XCTAssertFalse(WorktreeInclude.reaches("**/config.json", into: "vendor/"))
        XCTAssertTrue(WorktreeInclude.reaches("conf*/x.json", into: "config/"))
        XCTAssertEqual(WorktreeInclude.select(ignored: ignored, text: "# nothing\n\n").files, [])
    }

    func testGitWorktreeGetsTheListedIgnoredFiles() throws {
        let repo = try temporaryRepo()
        try ".env\n.env.*\nsecrets/\nnode_modules/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try ".env\nsecrets/key.pem\n".write(to: repo.appendingPathComponent(".worktreeinclude"), atomically: true, encoding: .utf8)
        XCTAssertTrue(Shell.run("git", ["-C", repo.path, "add", "."]).ok)
        XCTAssertTrue(Shell.run("git", ["-C", repo.path, "commit", "-qm", "ignore"]).ok)
        for (path, text) in [(".env", "A=1\n"), (".env.test", "B=2\n"), ("secrets/key.pem", "k\n"), ("node_modules/x/.env", "n\n")] {
            let url = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let info = try Worktree.create(repoDir: repo.path, name: "env")
        let made = URL(fileURLWithPath: info.path)
        XCTAssertEqual(try String(contentsOf: made.appendingPathComponent(".env"), encoding: .utf8), "A=1\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.appendingPathComponent("secrets/key.pem").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.appendingPathComponent(".env.test").path), "not listed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.appendingPathComponent("node_modules").path), "not reached")
        XCTAssertFalse(Worktree.hasUncommittedChanges(info.path), "copies are ignored files, so the worktree stays clean")
    }
}

final class WorktreeCreateHookTests: XCTestCase {
    var home: URL!
    var savedHome: URL!
    var savedManaged: URL!

    override func setUpWithError() throws {
        home = try temporaryFolder()
        savedHome = WorktreeHooks.userHome
        savedManaged = WorktreeHooks.managedDirectory
        WorktreeHooks.userHome = home
        WorktreeHooks.managedDirectory = home.appendingPathComponent("managed")
    }

    override func tearDown() {
        WorktreeHooks.userHome = savedHome
        WorktreeHooks.managedDirectory = savedManaged
    }

    private func writeHook(_ event: WorktreeHookEvent, _ command: String, in repo: URL) throws {
        let dir = repo.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.local.json")
        var settings = (try? SettingsFile.read(url)) ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        hooks[event.rawValue] = [["hooks": [["type": "command", "command": command]]]]
        settings["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: settings).write(to: url)
    }

    func testHookReplacesGitWorktreeAdd() async throws {
        let repo = try temporaryRepo()
        let target = repo.deletingLastPathComponent().appendingPathComponent("hooked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: target) }
        // Reads the name from stdin, makes the worktree on its own branch, prints noise to stderr and the path last.
        try writeHook(.create, """
        name=$(sed -n 's/.*"name":"\\([^"]*\\)".*/\\1/p'); echo "setting up $name" >&2; \
        git worktree add -q -b "team/$name" '\(target.path)' >&2 && echo "$CLAUDE_PROJECT_DIR" >&2 && echo '\(target.path)'
        """, in: repo)
        let steps = Collector()
        let info = try await Worktree.create(WorktreeRequest(folder: repo.path, name: "Login screen")) { progress in
            if case .output(let text) = progress { steps.add(text) }
        }
        XCTAssertEqual(info.path, target.standardizedFileURL.path)
        XCTAssertEqual(info.branch, "team/login-screen", "the branch is read from the new worktree's HEAD")
        XCTAssertTrue(info.madeByHook)
        XCTAssertEqual(info.folder, repo.path)
        XCTAssertTrue(steps.text.contains("setting up login-screen"), "the hook's output is shown as it runs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".claude/worktrees").path), "git was not used")
    }

    func testHookFailureAndMissingPath() async throws {
        let repo = try temporaryRepo()
        try writeHook(.create, "echo 'all slots are in use' >&2; exit 1", in: repo)
        do {
            _ = try await Worktree.create(WorktreeRequest(folder: repo.path, name: "x")) { _ in }
            XCTFail("a failing hook fails the worktree")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("exited with status 1"))
            XCTAssertTrue(error.localizedDescription.contains("all slots are in use"))
        }
        try writeHook(.create, "echo done >&2", in: repo)
        do {
            _ = try await Worktree.create(WorktreeRequest(folder: repo.path, name: "x")) { _ in }
            XCTFail("a hook that prints no path fails")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("printed no worktree path"))
        }
    }
}

func temporaryFolder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viber-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A repository with one commit on `main`.
func temporaryRepo() throws -> URL {
    let repo = try temporaryFolder()
    for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] {
        XCTAssertTrue(Shell.run("git", ["-C", repo.path] + args).ok)
    }
    try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    XCTAssertTrue(Shell.run("git", ["-C", repo.path, "add", "."]).ok)
    XCTAssertTrue(Shell.run("git", ["-C", repo.path, "commit", "-qm", "init"]).ok)
    return repo
}
