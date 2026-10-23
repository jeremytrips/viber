import XCTest
@testable import ViberCore

final class SettingsFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("viber-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testScopesMapToFiles() {
        XCTAssertNil(SettingsFile.url(.session, cwd: "/repo"))
        XCTAssertEqual(SettingsFile.url(.projectLocal, cwd: "/repo")?.path, "/repo/.claude/settings.local.json")
        XCTAssertEqual(SettingsFile.url(.projectShared, cwd: "/repo")?.path, "/repo/.claude/settings.json")
        XCTAssertEqual(SettingsScope(source: "localSettings"), .projectLocal)
        XCTAssertNil(SettingsScope(source: "policySettings"))
    }

    func testAddRuleCreatesTheFile() throws {
        let url = dir.appendingPathComponent(".claude/settings.local.json")
        try SettingsFile.addRule(RuleEdit(behavior: "allow", rule: "Bash(npm test:*)"), to: url)
        try SettingsFile.addRule(RuleEdit(behavior: "allow", rule: "Bash(npm test:*)"), to: url)
        XCTAssertEqual(SettingsFile.rules(in: url), [RuleEdit(behavior: "allow", rule: "Bash(npm test:*)")], "no duplicates")
    }

    func testEditsKeepUnrelatedKeys() throws {
        let url = dir.appendingPathComponent("settings.json")
        try Data(#"{"theme":"dark","permissions":{"allow":["Read"],"defaultMode":"plan"},"hooks":{"Stop":[]}}"#.utf8).write(to: url)
        try SettingsFile.addRule(RuleEdit(behavior: "deny", rule: "WebFetch"), to: url)
        try SettingsFile.removeRule(RuleEdit(behavior: "allow", rule: "Read"), from: url)
        let object = try json(url)
        XCTAssertEqual(object["theme"] as? String, "dark")
        XCTAssertNotNil(object["hooks"])
        let permissions = try XCTUnwrap(object["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["defaultMode"] as? String, "plan")
        XCTAssertEqual(permissions["deny"] as? [String], ["WebFetch"])
        XCTAssertEqual(permissions["allow"] as? [String], [])
    }

    func testInvalidJSONIsNeverOverwritten() throws {
        let url = dir.appendingPathComponent("settings.json")
        try Data("{ not json".utf8).write(to: url)
        XCTAssertThrowsError(try SettingsFile.addRule(RuleEdit(behavior: "allow", rule: "Read"), to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ not json")
    }

    func testWritesGoThroughSymlinks() throws {
        let real = dir.appendingPathComponent("real.json"), link = dir.appendingPathComponent("link.json")
        try Data("{}".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try SettingsFile.addRule(RuleEdit(behavior: "allow", rule: "Read"), to: link)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
        XCTAssertEqual(SettingsFile.rules(in: real), [RuleEdit(behavior: "allow", rule: "Read")])
    }

    func testNestedValueSetAndClear() throws {
        let url = dir.appendingPathComponent("settings.json")
        try Data(#"{"modelSettings":{"claude-opus-5-5":{"effortLevel":"xhigh"}}}"#.utf8).write(to: url)
        try SettingsFile.set("high", at: ["modelSettings", "claude-sonnet-5-5", "effortLevel"], in: url)
        try SettingsFile.set(nil, at: ["modelSettings", "claude-opus-5-5", "effortLevel"], in: url)
        let models = try XCTUnwrap(json(url)["modelSettings"] as? [String: Any])
        XCTAssertEqual((models["claude-sonnet-5-5"] as? [String: Any])?["effortLevel"] as? String, "high")
        XCTAssertNil(models["claude-opus-5-5"], "an emptied model entry is dropped")
    }

    func testHooksFromASettingsFile() throws {
        let url = dir.appendingPathComponent("settings.json")
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done","timeout":5}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"check.sh"}]}]}}"#.utf8).write(to: url)
        let hooks = SettingsFile.hooks(in: url, source: "All projects")
        XCTAssertEqual(hooks.map(\.event), ["PreToolUse", "Stop"])
        XCTAssertEqual(hooks.first?.matcher, "Bash")
        XCTAssertEqual(hooks.last?.timeout, 5)
    }

    func testLocalSettingsGetExcludedFromGit() throws {
        guard Shell.run("git", ["init", "-q"], cwd: dir.path).ok else { throw XCTSkip("git not available") }
        let url = dir.appendingPathComponent(".claude/settings.local.json")
        try SettingsFile.addRule(RuleEdit(behavior: "allow", rule: "Read"), to: url)
        if Shell.run("git", ["check-ignore", "-q", url.path], cwd: dir.path).status == 0 {
            throw XCTSkip("a global gitignore already covers settings.local.json")
        }
        SettingsFile.ensureIgnored(url, cwd: dir.path)
        XCTAssertEqual(Shell.run("git", ["check-ignore", "-q", url.path], cwd: dir.path).status, 0)
        SettingsFile.ensureIgnored(url, cwd: dir.path)
        let exclude = try String(contentsOf: dir.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        XCTAssertEqual(exclude.components(separatedBy: "**/.claude/settings.local.json").count, 2, "added once")
    }
}

final class UserMcpConfigTests: XCTestCase {
    func testServersAndAddArguments() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("viber-claude-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"projects":{},"mcpServers":{"sentry":{"type":"http","url":"https://mcp.sentry.dev/mcp"},"fs":{"command":"npx","args":["-y","fs-server"]}}}"#.utf8).write(to: url)
        let servers = SettingsFile.mcpServers(in: url)
        XCTAssertEqual(servers.map(\.name), ["fs", "sentry"])
        XCTAssertEqual(servers[0].transport, "stdio")
        XCTAssertEqual(servers[0].target, "npx -y fs-server")
        XCTAssertEqual(servers[1].target, "https://mcp.sentry.dev/mcp")

        XCTAssertEqual(SettingsFile.mcpAddArguments(name: "fs", transport: "stdio", target: "npx -y fs-server"),
                       ["mcp", "add", "--scope", "user", "fs", "--", "npx", "-y", "fs-server"])
        XCTAssertEqual(SettingsFile.mcpAddArguments(name: "sentry", transport: "http", target: "https://mcp.sentry.dev/mcp"),
                       ["mcp", "add", "--scope", "user", "--transport", "http", "sentry", "https://mcp.sentry.dev/mcp"])
        XCTAssertNil(SettingsFile.mcpEnvironment["CLAUDE_CONFIG_DIR"])
    }
}
