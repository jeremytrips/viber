import XCTest
@testable import ViberCore

final class AccountTests: XCTestCase {
    func testKeychainItemIsNamedAsTheCLINamesIt() {
        // Seen in the Keychain: clauth's runtime folder for Private, and the folder Viber signed Private in to.
        XCTAssertEqual(Accounts.keychainService(directory: "/Users/jt.sidis/.clauth/profiles/Private/runtime-48065-0"),
                       "Claude Code-credentials-59950df8")
        XCTAssertEqual(Accounts.keychainService(directory: "/Users/jt.sidis/Library/Application Support/Viber/accounts/Private"),
                       "Claude Code-credentials-27d7aad2")
        XCTAssertEqual(Accounts.keychainService(directory: "/Users/jt.sidis/Library/Application Support/Viber/accounts/Private/"),
                       "Claude Code-credentials-27d7aad2", "the CLI hashes the path without a trailing slash")
    }

    func testNamesAreFolderNames() {
        XCTAssertTrue(Accounts.isValidName("creator1"))
        XCTAssertTrue(Accounts.isValidName("pinsound_1"))
        XCTAssertFalse(Accounts.isValidName(""))
        XCTAssertFalse(Accounts.isValidName("../x"))
        XCTAssertFalse(Accounts.isValidName("a b"))
    }

    func testProjectAccountStoresAutomaticAsNothing() {
        for account in [ProjectAccount.automatic, .plain, .profile("creator1")] {
            XCTAssertEqual(ProjectAccount(stored: account.stored), account)
        }
        XCTAssertNil(ProjectAccount.automatic.stored)
        XCTAssertEqual(ProjectAccount.plain.stored, "")
        XCTAssertEqual(ProjectAccount(stored: "creator1"), .profile("creator1"), "projects pinned under clauth keep their account")
    }

    func testAccountListRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("viber-accounts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var list = AccountList()
        list.upsert(Account(name: "creator", email: "creator@pinsound.org"))
        list.upsert(Account(name: "Private", automatic: false))
        list.upsert(Account(name: "creator", email: "creator@pinsound.org", automatic: false))
        try list.save(to: url)
        let loaded = AccountList.load(from: url)
        XCTAssertEqual(loaded.accounts.map(\.name), ["creator", "Private"])
        XCTAssertEqual(loaded.account("creator")?.automatic, false)
        XCTAssertEqual(AccountList.load(from: url.appendingPathExtension("missing")), AccountList())
    }

    // MARK: Picking

    private func account(_ name: String, five: Double, week: Double, problem: String? = nil,
                         weekResets: Date? = nil, fiveResets: Date? = nil) -> AccountStatus {
        AccountStatus(name: name, loginProblem: problem, windows: [
            UsageWindow(label: "5h", utilizationPct: five, resetsAt: fiveResets),
            UsageWindow(label: "7d", utilizationPct: week, resetsAt: weekResets)])
    }

    /// As the accounts stood on 2026-10-28: creator's 5 hours spent, creator3's week spent, Private outside Automatic.
    func testTheLeastUsedAccountWithRoomWins() {
        let accounts = [account("Private", five: 0, week: 10), account("creator", five: 100, week: 42),
                        account("creator1", five: 0, week: 44), account("creator3", five: 0, week: 100)]
        let allowed: Set = ["creator", "creator1", "creator3"]
        XCTAssertEqual(AccountChoice.pick(from: accounts, allowed: allowed), "creator1")
        XCTAssertNil(AccountChoice.pick(from: accounts, allowed: []), "a project that allows nothing gets nothing")
    }

    func testSessionsStartedTogetherSpreadOverAccountsAboutAsUsed() {
        let accounts = [account("a", five: 20, week: 10), account("b", five: 5, week: 15), account("c", five: 0, week: 40)]
        let allowed: Set = ["a", "b", "c"]
        XCTAssertEqual(AccountChoice.pick(from: accounts, allowed: allowed), "b", "a and b are tied on the week; b's 5 hours are emptier")
        XCTAssertEqual(AccountChoice.pick(from: accounts, allowed: allowed, running: ["b": 1]), "a")
        XCTAssertEqual(AccountChoice.pick(from: accounts, allowed: allowed, running: ["a": 1, "b": 1]), "b")
        XCTAssertEqual(AccountChoice.pick(from: accounts, allowed: allowed, running: ["a": 3, "b": 3]), "b",
                       "c's week is far more used, so the least-used rule still keeps it out")
    }

    func testExcludedBrokenAndLimitedAccountsAreLeftOut() {
        let accounts = [account("a", five: 0, week: 10), account("b", five: 0, week: 12, problem: "Login expired"),
                        account("c", five: 0, week: 14), account("d", five: 0, week: 16)]
        XCTAssertEqual(AccountChoice.pick(from: accounts, allowed: ["b", "c", "d"]), "c", "a is left out of the project, b can't log in")
        XCTAssertEqual(AccountChoice.pick(from: accounts, allowed: ["c", "d"], limited: ["c"]), "d", "c turned a session away")
    }

    func testWithNoRoomTheFirstToFreeUpWinsAndAMoveFindsNothing() {
        let now = Date()
        let accounts = [account("a", five: 95, week: 50, fiveResets: now.addingTimeInterval(3600)),
                        account("b", five: 10, week: 99, weekResets: now.addingTimeInterval(86400)),
                        account("c", five: 100, week: 20, fiveResets: now.addingTimeInterval(600))]
        XCTAssertEqual(AccountChoice.pick(from: accounts, allowed: ["a", "b", "c"], now: now), "c")
        XCTAssertNil(AccountChoice.pick(from: accounts, allowed: ["a", "b", "c"], avoiding: "c", now: now),
                     "moving only makes sense to an account with room")
        XCTAssertEqual(AccountChoice.pick(from: [account("a", five: 0, week: 0)], allowed: ["a"], avoiding: "a"), nil)
    }

    // MARK: Usage

    /// Trimmed from a real reply of /api/oauth/usage on 2026-10-28.
    private let usageJSON = #"""
    {"five_hour":{"utilization":8.0,"resets_at":"2026-10-29T02:00:00.414530+00:00"},
     "seven_day":{"utilization":11.0,"resets_at":"2026-11-01T09:00:00.414552+00:00"},"extra_usage":null,
     "limits":[{"kind":"session","group":"session","percent":8,"severity":"normal","resets_at":"2026-10-29T02:00:00.344779+00:00","scope":null,"is_active":false},
               {"kind":"weekly_all","group":"weekly","percent":11,"severity":"normal","resets_at":"2026-11-01T09:00:00.344798+00:00","scope":null,"is_active":true},
               {"kind":"weekly_scoped","group":"weekly","percent":0,"severity":"normal","resets_at":"2026-11-01T09:00:00+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false},
               {"kind":"something_new","percent":3}]}
    """#

    func testUsageReplyGivesTheWindows() throws {
        let windows = try XCTUnwrap(AccountUsage.windows(from: Data(usageJSON.utf8)))
        XCTAssertEqual(windows.map(\.label), ["5h", "7d", "7d fable"])
        XCTAssertEqual(windows.map(\.utilizationPct), [8, 11, 0])
        XCTAssertNotNil(windows[0].resetsAt)

        let older = #"{"five_hour":{"utilization":50.5,"resets_at":null},"seven_day":{"utilization":3,"resets_at":"2026-11-01T09:00:00+00:00"}}"#
        let fallback = try XCTUnwrap(AccountUsage.windows(from: Data(older.utf8)))
        XCTAssertEqual(fallback.map(\.label), ["5h", "7d"])
        XCTAssertEqual(fallback.first?.utilizationPct, 50.5)
        XCTAssertNil(AccountUsage.windows(from: Data("{}".utf8)))
    }

    func testSessionsReportUsageAsTheyGo() {
        var chat = ChatTranscript()
        let at = Date(timeIntervalSince1970: 1_793_000_000)
        chat.apply(["type": "rate_limit_event", "rate_limit_info": [
            "status": "allowed_warning", "rateLimitType": "five_hour", "utilization": 0.91,
            "unifiedWindows": ["five_hour": ["utilization": 0.91, "resetsAt": 1_793_010_000],
                               "seven_day": ["utilization": 0.4, "resetsAt": 1_793_500_000]]]], now: at)
        XCTAssertEqual(chat.liveUsage?.windows.map(\.label), ["5h", "7d"])
        XCTAssertEqual(chat.liveUsage?.windows.first?.utilizationPct ?? 0, 91, accuracy: 0.001)
        XCTAssertEqual(chat.liveUsage?.at, at)

        chat.apply(["type": "rate_limit_event", "rate_limit_info": ["status": "allowed", "rateLimitType": "seven_day", "utilization": 0.5]], now: at)
        XCTAssertEqual(chat.liveUsage?.windows, [UsageWindow(label: "7d", utilizationPct: 50, resetsAt: nil)], "without unifiedWindows, the one it names")
    }

    func testLoginReadsTheCLIsItemAndARefreshKeepsTheRest() throws {
        let stored = #"""
        {"claudeAiOauth":{"accessToken":"old","refreshToken":"r1","expiresAt":1793250000000,"scopes":["user:inference","user:profile"],
          "subscriptionType":"max","rateLimitTier":"default_claude_max_20x"},"mcpOAuth":{"atlassian":{"accessToken":"m"}}}
        """#
        let login = try XCTUnwrap(OAuthLogin(json: Data(stored.utf8)))
        XCTAssertEqual(login.tier, "Max 20x")
        XCTAssertEqual(login.refreshToken, "r1")
        XCTAssertTrue(login.expired(at: Date(timeIntervalSince1970: 1_793_250_000)))
        XCTAssertFalse(login.expired(at: Date(timeIntervalSince1970: 1_793_240_000)))

        let now = Date(timeIntervalSince1970: 1_793_300_000)
        let reply = #"{"access_token":"new","refresh_token":"r2","expires_in":28800,"scope":"user:inference user:profile"}"#
        let updated = try XCTUnwrap(OAuthLogin.refreshed(Data(stored.utf8), with: Data(reply.utf8), now: now))
        let fresh = try XCTUnwrap(OAuthLogin(json: updated))
        XCTAssertEqual(fresh.accessToken, "new")
        XCTAssertEqual(fresh.refreshToken, "r2", "the old refresh token stops working, so the new one is kept")
        XCTAssertEqual(fresh.expiresAt, now.addingTimeInterval(28800))
        XCTAssertEqual(fresh.tier, "Max 20x")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        XCTAssertNotNil(object["mcpOAuth"], "MCP sign-ins in the same item survive")
        XCTAssertNil(OAuthLogin(json: Data("{}".utf8)))
    }

    // MARK: Folders

    func testConfigIsSharedExceptWhatNamesTheAccount() {
        let shared: [String: Any] = ["mcpServers": ["a": 1], "oauthAccount": ["emailAddress": "creator1@pinsound.org"],
                                     "cachedGrowthBookFeatures": ["x": 1], "groveConfigCache": 1, "projects": ["/p": [:]]]
        let own: [String: Any] = ["oauthAccount": ["emailAddress": "jeremy.trips@gmail.com"], "userID": "u", "mcpServers": ["old": 1]]
        let merged = Accounts.mergedConfig(shared: shared, own: own)
        XCTAssertEqual((merged["oauthAccount"] as? [String: String])?["emailAddress"], "jeremy.trips@gmail.com")
        XCTAssertEqual(merged["userID"] as? String, "u")
        XCTAssertEqual(merged["mcpServers"] as? [String: Int], ["a": 1], "MCP servers follow ~/.claude.json")
        XCTAssertNotNil(merged["projects"])
        XCTAssertNil(merged["cachedGrowthBookFeatures"], "another account's caches stay out")
        XCTAssertNil(merged["groveConfigCache"])
        XCTAssertNil(Accounts.mergedConfig(shared: shared, own: [:])["oauthAccount"], "a folder not signed in yet names no account")
    }

    func testPrepareLinksTheSharedFolderAndTakesBackFilesTheCLIReplaced() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("viber-prepare-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let home = base.appendingPathComponent("home"), root = base.appendingPathComponent("accounts")
        let claude = home.appendingPathComponent(".claude")
        try fm.createDirectory(at: claude.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try "{}".write(to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        try "# me".write(to: claude.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try "secret".write(to: claude.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
        try #"{"mcpServers":{"a":{}},"oauthAccount":{"emailAddress":"x"}}"#.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let folder = Accounts.directory("a1", root: root)
        try fm.createDirectory(at: folder.appendingPathComponent("plans"), withIntermediateDirectories: true)
        try fm.createDirectory(at: claude.appendingPathComponent("plans"), withIntermediateDirectories: true)
        try "kept".write(to: folder.appendingPathComponent("plans/p.md"), atomically: true, encoding: .utf8)

        try Accounts.prepare("a1", root: root, home: home)
        for entry in ["projects", "settings.json", "CLAUDE.md"] {
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: folder.appendingPathComponent(entry).path),
                           claude.appendingPathComponent(entry).path)
        }
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent(".credentials.json").path), "the plain login's file stays out")
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("plans/p.md").path), "a folder the CLI made is left alone")
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".claude.json"))) as? [String: Any])
        XCTAssertNotNil(config["mcpServers"])
        XCTAssertNil(config["oauthAccount"])

        // The CLI wrote settings.json through a rename, which left a file of its own in place of the link.
        let settings = folder.appendingPathComponent("settings.json")
        try fm.removeItem(at: settings)
        try #"{"model":"opus"}"#.write(to: settings, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: settings.path)
        try Accounts.prepare("a1", root: root, home: home)
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: settings.path))
        XCTAssertEqual(try String(contentsOf: claude.appendingPathComponent("settings.json"), encoding: .utf8), #"{"model":"opus"}"#)
    }

    func testWhatSessionsChangeInTheirCopyGoesBackToTheSharedConfig() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("viber-sync-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let home = base.appendingPathComponent("home"), root = base.appendingPathComponent("accounts")
        try fm.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let shared = home.appendingPathComponent(".claude.json")
        func write(_ object: [String: Any], _ url: URL) throws { try JSONSerialization.data(withJSONObject: object).write(to: url) }
        func read(_ url: URL) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) }
        try write(["mcpServers": ["a": 1], "projects": ["/p": ["x": 1], "/q": ["y": 1]]], shared)

        XCTAssertThrowsError(try Accounts.prepare("a1", root: root, home: home), "an account that was never added isn't made up")
        try Accounts.prepare("a1", creating: true, root: root, home: home)
        let copy = Accounts.directory("a1", root: root).appendingPathComponent(".claude.json")

        // A session on a1 turns a server off in /p; meanwhile another account's session changed /q in the shared file.
        var mine = try read(copy)
        mine["projects"] = ["/p": ["x": 1, "disabledMcpServers": ["a"]], "/q": ["y": 1]]
        mine["oauthAccount"] = ["emailAddress": "a1@x"]
        try write(mine, copy)
        try write(["mcpServers": ["a": 1], "projects": ["/p": ["x": 1], "/q": ["y": 2]]], shared)

        try Accounts.prepare("a1", root: root, home: home)
        let projects = try XCTUnwrap(try read(shared)["projects"] as? [String: [String: Any]])
        XCTAssertEqual(projects["/p"]?["disabledMcpServers"] as? [String], ["a"], "a1's change reached ~/.claude.json")
        XCTAssertEqual(projects["/q"]?["y"] as? Int, 2, "the other account's change in another project stays")
        XCTAssertNil(try read(shared)["oauthAccount"], "the account's identity stays in its copy")
        let synced = try read(copy)
        XCTAssertEqual((synced["projects"] as? [String: [String: Any]])?["/q"]?["y"] as? Int, 2)
        XCTAssertNotNil(synced["oauthAccount"])
    }

    func testAnEmptyFolderTheCLIMadeGetsLinked() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("viber-empty-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let home = base.appendingPathComponent("home"), root = base.appendingPathComponent("accounts")
        try fm.createDirectory(at: home.appendingPathComponent(".claude/todos"), withIntermediateDirectories: true)
        try fm.createDirectory(at: Accounts.directory("a1", root: root).appendingPathComponent("todos"), withIntermediateDirectories: true)
        try Accounts.prepare("a1", root: root, home: home)
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: Accounts.directory("a1", root: root).appendingPathComponent("todos").path))
    }

    // MARK: Earlier sessions

    func testALongFirstMessageStillGivesTheSession() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("viber-long-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("-repo")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let picture = String(repeating: "A", count: 600 * 1024)
        let first = #"{"type":"user","cwd":"/repo","message":{"role":"user","content":[{"type":"image","source":{"data":"\#(picture)"}},{"type":"text","text":"What is this?"}]}}"#
        let last = #"{"type":"user","message":{"role":"user","content":"thanks"}}"#
        try [first, last].joined(separator: "\n").write(to: folder.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)
        let session = try XCTUnwrap(SessionIndex.scan(root: root).first)
        XCTAssertEqual(session.title, "What is this?")
        XCTAssertEqual(session.lastMessage, "thanks")
    }

    func testSessionIndexReadsTitleFolderAndLastMessage() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("viber-index-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("-Users-me-repo")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"queue-operation","operation":"enqueue","sessionId":"s1","content":"ignored"}"#,
            #"{"type":"user","isMeta":true,"cwd":"/Users/me/repo","message":{"role":"user","content":"<local-command-caveat>x</local-command-caveat>"}}"#,
            #"{"type":"user","cwd":"/Users/me/repo","message":{"role":"user","content":"<ide_opened_file>The user opened x.py</ide_opened_file>Fix the bug\nin x"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"On it"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"and the tests"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: folder.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        try lines[3].write(to: folder.appendingPathComponent("empty.jsonl"), atomically: true, encoding: .utf8)
        try lines[2].write(to: folder.appendingPathComponent("agent-x.jsonl"), atomically: true, encoding: .utf8)

        let sessions = SessionIndex.scan(root: root)
        XCTAssertEqual(sessions.map(\.id), ["s1"], "subagent transcripts and ones with nothing from the user are left out")
        XCTAssertEqual(sessions.first?.workspace, "/Users/me/repo")
        XCTAssertEqual(sessions.first?.title, "Fix the bug")
        XCTAssertEqual(sessions.first?.lastMessage, "and the tests")
        XCTAssertNotNil(sessions.first?.updatedDate)
    }
}
