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

    func testSuggestionsShowShortNamesForViberSkills() {
        let names = SlashRouter.suggestions(for: "/c", commands: commands).map(\.name)
        XCTAssertEqual(names.prefix(4), ["clear", "cost", "compact", "cleanup"])
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
}
