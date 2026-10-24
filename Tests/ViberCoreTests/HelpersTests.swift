import XCTest
@testable import ViberCore

final class SlashRouterTests: XCTestCase {
    let commands = [SlashCommand(name: "compact", description: ""), SlashCommand(name: "viber:cleanup", description: "Clean up")]

    func testRouting() {
        XCTAssertEqual(SlashRouter.route("hello", commands: commands), .send("hello"))
        XCTAssertEqual(SlashRouter.route("/plan", commands: commands), .setMode("plan", then: nil))
        XCTAssertEqual(SlashRouter.route("/plan add OTA", commands: commands), .setMode("plan", then: "add OTA"))
        XCTAssertEqual(SlashRouter.route("/auto", commands: commands), .setMode("auto", then: nil))
        XCTAssertEqual(SlashRouter.route("/auto fix the build", commands: commands), .setMode("auto", then: "fix the build"))
        XCTAssertEqual(SlashRouter.route("/model opus", commands: commands), .setModel("opus"))
        XCTAssertEqual(SlashRouter.route("/model", commands: commands), .pickModel)
        XCTAssertEqual(SlashRouter.route("/compact", commands: commands), .send("/compact"))
        XCTAssertEqual(SlashRouter.route("/cleanup", commands: commands), .send("/viber:cleanup"))
        XCTAssertEqual(SlashRouter.route("/cleanup now", commands: commands), .send("/viber:cleanup now"))
        XCTAssertEqual(SlashRouter.route("/unknown", commands: commands), .send("/unknown"))
    }

    func testAddDirRouting() {
        XCTAssertEqual(SlashRouter.route("/add-dir ../shared", commands: []), .addDirectory("../shared"))
        XCTAssertEqual(SlashRouter.route("/add-dir", commands: []), .openSettings(.permissions))
    }

    func testTerminalPanelsOpenTheSettingsSheet() {
        XCTAssertEqual(SlashRouter.route("/mcp", commands: commands), .openSettings(.mcp))
        XCTAssertEqual(SlashRouter.route("/mcp reconnect all", commands: commands), .send("/mcp reconnect all"))
        XCTAssertEqual(SlashRouter.route("/context", commands: commands), .openSettings(.context))
        XCTAssertEqual(SlashRouter.route("/usage", commands: commands), .openSettings(.context))
        XCTAssertEqual(SlashRouter.route("/permissions", commands: commands), .openSettings(.permissions))
        XCTAssertEqual(SlashRouter.route("/hooks", commands: commands), .openSettings(.hooks))
        XCTAssertEqual(SlashRouter.route("/settings", commands: commands), .openSettings(.model))
        XCTAssertEqual(SlashRouter.route("/effort", commands: commands), .openSettings(.model))
        XCTAssertEqual(SlashRouter.route("/effort high", commands: commands), .send("/effort high"))
        XCTAssertEqual(SlashRouter.route("/config theme=dark", commands: commands), .send("/config theme=dark"))
    }

    func testSuggestionsShowShortNamesForViberSkills() {
        let names = SlashRouter.suggestions(for: "/c", commands: commands).map(\.name)
        XCTAssertEqual(names.prefix(5), ["clear", "cost", "context", "compact", "cleanup"])
        XCTAssertTrue(SlashRouter.suggestions(for: "/c x", commands: commands).isEmpty)
    }
}

final class LaunchTests: XCTestCase {
    func testClauthCommandForwardsClaudeArguments() {
        let spec = LaunchSpec(profile: "Private", cwd: "/tmp", resume: "abc", permissionMode: "plan", pluginDir: "/p")
        let command = spec.command
        XCTAssertEqual(command.tool, "clauth")
        XCTAssertEqual(Array(command.arguments.prefix(3)), ["start", "Private", "--"])
        XCTAssertTrue(command.arguments.contains("--permission-prompt-tool"))
        XCTAssertEqual(command.arguments.split(separator: "--resume").last?.first, "abc")
        XCTAssertEqual(LaunchSpec(profile: nil, cwd: "/tmp").command.tool, "claude")
    }

    func testTranscriptPathMatchesCLINaming() {
        let url = ViberPaths.transcript(sessionID: "s1", cwd: "/Users/jt.sidis/dev/viber")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "-Users-jt-sidis-dev-viber")
    }
}

final class VSCodeLinkTests: XCTestCase {
    func testFolderOpensInItsOwnWindow() {
        XCTAssertEqual(VSCodeLink.url(for: "/Users/me/repo/.claude/worktrees/x")?.absoluteString,
                       "vscode://file/Users/me/repo/.claude/worktrees/x/?windowId=_blank")
        XCTAssertNil(VSCodeLink.url(for: "relative/path"))
    }
}

final class ClauthTests: XCTestCase {
    func testStatusDecodes() throws {
        let json = #"""
        {"schema":2,"active_profile":"Private","profiles":[
          {"name":"Private","active":true,"tier":"Max 5x","auth_status":"expired","stale":true,
           "windows":[{"label":"7d","utilization_pct":4.0,"resets_at":"2026-10-25T08:59:59.873795+00:00"}]},
          {"name":"pinsound_1","active":false,"tier":"Max","auth_status":"broken","windows":[]}]}
        """#
        let status = try XCTUnwrap(ClauthStatus.decode(Data(json.utf8)))
        XCTAssertEqual(status.profiles.map(\.name), ["Private", "pinsound_1"])
        XCTAssertEqual(status.profiles[0].windows?.first?.utilizationPct, 4)
        XCTAssertNotNil(status.profiles[0].windows?.first?.resetDate)
        XCTAssertEqual(status.profiles[1].loginProblem, "Login broken")
    }

    func testSessionTitleStripsWrappers() {
        let json = #"[{"id":"1","workspace":"/w","updated":"2026-10-23T08:23:36+00:00","first_message":"<ide_opened_file>The user opened x.py</ide_opened_file>Refactor the board UI\nmore","last_message":"ok"}]"#
        let sessions = ClauthSession.decodeList(Data(json.utf8))
        XCTAssertEqual(sessions.first?.title, "Refactor the board UI")
    }
}

final class WorktreeTests: XCTestCase {
    var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("viber-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] {
            XCTAssertTrue(Shell.run("git", ["-C", repo.path] + args).ok)
        }
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(Shell.run("git", ["-C", repo.path, "add", "."]).ok)
        XCTAssertTrue(Shell.run("git", ["-C", repo.path, "commit", "-qm", "init"]).ok)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: repo) }

    func testSlug() {
        XCTAssertEqual(Worktree.slug("Phone-number login screen!"), "phone-number-login-screen")
    }

    func testCreateDiffAndRemove() throws {
        let info = try Worktree.create(repoDir: repo.path, name: "Login screen")
        XCTAssertEqual(info.branch, "viber/login-screen")
        XCTAssertEqual(info.base, "main")
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.path))
        XCTAssertTrue(Shell.run("git", ["-C", repo.path, "status", "--porcelain"]).output.isEmpty, "worktree dir is excluded")

        try "a\nb\n".write(to: URL(fileURLWithPath: info.path).appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Worktree.diffStat(info), "+1 −0")
        XCTAssertThrowsError(try Worktree.remove(info, deleteBranch: true), "uncommitted changes block removal")

        XCTAssertTrue(Shell.run("git", ["-C", info.path, "commit", "-qam", "b"]).ok)
        XCTAssertThrowsError(try Worktree.remove(info, deleteBranch: true), "unmerged branch is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: info.path), "worktree itself was removed")

        let second = try Worktree.create(repoDir: repo.path, name: "Login screen")
        XCTAssertEqual(second.branch, "viber/login-screen-2", "names never collide with a kept branch")
    }

    func testSwitchedBranch() throws {
        func git(_ path: String, _ args: String...) { XCTAssertTrue(Shell.run("git", ["-C", path] + args).ok, args.joined(separator: " ")) }
        func exists(_ branch: String) -> Bool { Shell.run("git", ["-C", repo.path, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]).ok }

        let info = try Worktree.create(repoDir: repo.path, name: "MQTT auth")
        XCTAssertEqual(Worktree.currentBranch(info.path), "viber/mqtt-auth")
        git(info.path, "switch", "-qc", "feat/NEX-703")
        XCTAssertEqual(Worktree.currentBranch(info.path), "feat/NEX-703")
        git(info.path, "switch", "-q", "--detach")
        XCTAssertNil(Worktree.currentBranch(info.path), "detached HEAD has no branch")
        git(info.path, "switch", "-q", "feat/NEX-703")

        try Worktree.remove(info, deleteBranch: true)
        XCTAssertFalse(exists("viber/mqtt-auth"), "the branch Viber created is deleted")
        XCTAssertTrue(exists("feat/NEX-703"), "the branch Claude switched to is kept")

        let renamed = try Worktree.create(repoDir: repo.path, name: "Renamed")
        git(renamed.path, "branch", "-m", "feat/NEX-704")
        XCTAssertNoThrow(try Worktree.remove(renamed, deleteBranch: true), "a renamed branch is skipped")
        XCTAssertTrue(exists("feat/NEX-704"))
    }

    func testCreateRepo() throws {
        let dir = try plainFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Worktree.createRepo(dir.path)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("README.md"), encoding: .utf8),
                       "# \(dir.lastPathComponent)\n")
        XCTAssertNotNil(Worktree.repoRoot(dir.path))
        XCTAssertTrue(Shell.run("git", ["-C", dir.path, "status", "--porcelain"]).output.isEmpty, "the README is committed")
        XCTAssertNoThrow(try Worktree.create(repoDir: dir.path, name: "First"), "worktrees have a commit to start from")
    }

    func testCreateRepoKeepsReadme() throws {
        let dir = try plainFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "Mine\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "x\n".write(to: dir.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try Worktree.createRepo(dir.path)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("README.md"), encoding: .utf8), "Mine\n")
        XCTAssertEqual(Shell.run("git", ["-C", dir.path, "status", "--porcelain"]).output, "?? other.txt", "only the README is committed")
    }

    /// A folder outside any repository. It is initialized up front only to give it a commit identity;
    /// `createRepo` running `git init` again is harmless.
    private func plainFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("My Project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] {
            XCTAssertTrue(Shell.run("git", ["-C", dir.path] + args).ok)
        }
        return dir
    }
}

final class RequestTests: XCTestCase {
    func testRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viber-req-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ViberRequest(paneID: "p1", command: .close, removeWorktree: true, deleteBranch: true).write(to: dir)
        let drained = ViberRequest.drain(dir)
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained.first?.paneID, "p1")
        XCTAssertTrue(drained.first?.deleteBranch == true)
        XCTAssertTrue(ViberRequest.drain(dir).isEmpty)
    }

    func testIdeaRequest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viber-req-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ViberRequest(paneID: "p1", command: .idea, text: "line one\nline two").write(to: dir)
        let drained = ViberRequest.drain(dir)
        XCTAssertEqual(drained.first?.command, .idea)
        XCTAssertEqual(drained.first?.text, "line one\nline two")
    }
}

final class IdeaListTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_790_000_000)

    func testAddEditAndPersist() throws {
        var list = IdeaList()
        let idea = try XCTUnwrap(list.add("  Retry failed MCP servers\nWith backoff.\n", project: "/repo", by: "you", at: at))
        XCTAssertEqual(idea.text, "Retry failed MCP servers\nWith backoff.")
        XCTAssertEqual(idea.title, "Retry failed MCP servers")
        XCTAssertEqual(idea.status, .open)
        XCTAssertNil(list.add(" \n", project: "/repo", by: "you"), "empty text adds nothing")

        list.edit(idea.id, text: "Retry MCP servers", at: at)
        XCTAssertEqual(list.idea(idea.id)?.text, "Retry MCP servers")
        list.edit(idea.id, text: "  ")
        XCTAssertEqual(list.idea(idea.id)?.text, "Retry MCP servers", "empty edits are ignored")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("viber-ideas-\(UUID().uuidString)/ideas.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try list.save(to: file)
        XCTAssertEqual(IdeaList.load(from: file, legacyNotes: file.appendingPathExtension("missing")), list)
        XCTAssertEqual(IdeaList.load(from: file.appendingPathExtension("missing"), legacyNotes: file.appendingPathExtension("missing")),
                       IdeaList())

        list.remove(idea.id)
        XCTAssertTrue(list.ideas.isEmpty)
    }

    func testLongIdeasAreCut() {
        var list = IdeaList()
        list.add(String(repeating: "x", count: IdeaList.maxLength + 10), project: "/repo", by: "you")
        XCTAssertEqual(list.ideas.first?.text.count, IdeaList.maxLength)
    }

    func testTitleSkipsMarkdownAndStaysShort() {
        XCTAssertEqual(Idea(project: "/r", text: "\n## Add search\nto messages", createdAt: at, createdBy: "you").title, "Add search")
        XCTAssertEqual(Idea(project: "/r", text: String(repeating: "a", count: 80), createdAt: at, createdBy: "you").title.count, 50)
    }

    func testStartedIdeasLinkTheirSessionUntilReopened() throws {
        var list = IdeaList()
        let idea = try XCTUnwrap(list.add("Login screen", project: "/repo", by: "you", at: at))
        list.start(idea.id, sessionID: "pane-1", sessionTitle: "Login screen")
        XCTAssertEqual(list.idea(idea.id)?.status, .started)
        XCTAssertEqual(list.idea(idea.id)?.sessionID, "pane-1")

        list.setStatus(idea.id, .done)
        XCTAssertEqual(list.idea(idea.id)?.sessionID, "pane-1", "done keeps where it was worked on")
        list.setStatus(idea.id, .open)
        XCTAssertNil(list.idea(idea.id)?.sessionID, "back to open forgets the session")
        XCTAssertNil(list.idea(idea.id)?.sessionTitle)
    }

    func testPendingListsOpenIdeasNewestFirstThenStarted() throws {
        var list = IdeaList()
        let first = try XCTUnwrap(list.add("first", project: "/repo", by: "you", at: at))
        list.add("second", project: "/repo", by: "you", at: at.addingTimeInterval(1))
        list.add("third", project: "/repo", by: "Backend", at: at.addingTimeInterval(2))
        let done = try XCTUnwrap(list.add("done", project: "/repo", by: "you", at: at.addingTimeInterval(3)))
        list.add("elsewhere", project: "/other", by: "you")
        list.start(first.id, sessionID: "p1", sessionTitle: "First")
        list.setStatus(done.id, .done)

        XCTAssertEqual(list.pending(in: "/repo").map(\.text), ["third", "second", "first"])
        XCTAssertEqual(list.toPlanCount(in: "/repo"), 2)
        XCTAssertEqual(list.toPlanCount(in: "/other"), 1)
        XCTAssertEqual(list.pending(in: "/nowhere"), [])
    }

    func testOldProjectNotesBecomeIdeas() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viber-ideas-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let notes = dir.appendingPathComponent("notes.json")
        try Data(#"{"notes":{"/repo":{"text":"Don't touch the firmware API.","updatedAt":1790000000,"updatedBy":"Login screen"}}}"#.utf8)
            .write(to: notes)

        let list = IdeaList.load(from: dir.appendingPathComponent("ideas.json"), legacyNotes: notes)
        XCTAssertEqual(list.ideas.count, 1)
        XCTAssertEqual(list.ideas.first?.project, "/repo")
        XCTAssertEqual(list.ideas.first?.text, "Don't touch the firmware API.")
        XCTAssertEqual(list.ideas.first?.createdBy, "Login screen")
        XCTAssertEqual(list.ideas.first?.createdAt, at)
        XCTAssertEqual(list.ideas.first?.status, .open)

        try IdeaList().save(to: dir.appendingPathComponent("ideas.json"))
        XCTAssertTrue(IdeaList.load(from: dir.appendingPathComponent("ideas.json"), legacyNotes: notes).ideas.isEmpty,
                      "once ideas are saved, old notes are not read again")
    }

    func testListingForTheCLI() throws {
        var list = IdeaList()
        list.add("Add search\nTo the Messages panel.", project: "/repo", by: "you", at: at)
        let started = try XCTUnwrap(list.add("Retry MCP", project: "/repo", by: "Backend", at: at))
        list.start(started.id, sessionID: "p1", sessionTitle: "MCP retry")
        let text = IdeaList.listing(list.pending(in: "/repo"), projectName: "viber")
        XCTAssertTrue(text.hasPrefix("Ideas for viber"))
        XCTAssertTrue(text.contains("- Add search\n  To the Messages panel.\n  (added by the user, 2026-09-21)"))
        XCTAssertTrue(text.contains("added by session “Backend”"))
        XCTAssertTrue(text.contains("started in session “MCP retry”"))
        XCTAssertEqual(IdeaList.listing([], projectName: "viber"), "No ideas for viber yet.")
    }
}
