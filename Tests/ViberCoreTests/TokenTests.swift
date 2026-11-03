import XCTest
@testable import ViberCore

final class TokenTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("viber-tokens-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// An assistant row as the CLI writes it: one per content block, each with the call's whole usage.
    private func row(_ id: String, at seconds: Double, input: Int = 2, output: Int = 100, write: Int = 1000, read: Int = 5000,
                     model: String = "claude-opus-5-5", sidechain: Bool = false) -> String {
        let time = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
        return #"{"type":"assistant","timestamp":"\#(time)","isSidechain":\#(sidechain),"message":{"id":"\#(id)","model":"\#(model)","#
            + #""content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"#
            + #""cache_creation_input_tokens":\#(write),"cache_read_input_tokens":\#(read),"cache_creation":{"ephemeral_1h_input_tokens":\#(write)}}}}"#
    }

    func testTotalsLeaveOutCacheReads() {
        let count = TokenCount(input: 2, output: 100, cacheWrite: 1000, cacheRead: 5000)
        XCTAssertEqual(count.total, 1102)
        XCTAssertEqual((count + count).cacheRead, 10000)
    }

    func testEachCallCountsOnceAndNotesAndOtherRowsNotAtAll() async throws {
        let url = folder.appendingPathComponent("s.jsonl")
        let lines = [row("msg_1", at: 100), row("msg_1", at: 100), row("msg_1", at: 100),
                     row("msg_2", at: 200, input: 5, output: 10, write: 0, read: 20),
                     row("msg_3", at: 300, input: 0, output: 0, write: 0, read: 0, model: "<synthetic>"),
                     #"{"type":"user","timestamp":"2026-11-03T10:00:00Z","message":{"role":"user","content":"usage"}}"#]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let entries = await TokenTally().read(url)
        XCTAssertEqual(entries.map(\.id), ["msg_1", "msg_2"])
        XCTAssertEqual(entries.reduce(TokenCount()) { $0 + $1.count }, TokenCount(input: 7, output: 110, cacheWrite: 1000, cacheRead: 5020))
        XCTAssertEqual(entries.first?.at, Date(timeIntervalSince1970: 100))
    }

    func testReadsOnlyWhatTheFilesGainedAndWaitsForAWholeRow() async throws {
        let url = folder.appendingPathComponent("s.jsonl")
        try (row("msg_1", at: 100) + "\n").write(to: url, atomically: true, encoding: .utf8)
        let tally = TokenTally()
        let first = await tally.read(url)
        XCTAssertEqual(first.count, 1)
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        let next = row("msg_2", at: 200)
        handle.write(Data(next.prefix(40).utf8))
        let partial = await tally.read(url)
        XCTAssertEqual(partial.count, 1, "a row still being written waits")
        handle.write(Data((next.dropFirst(40) + "\n").utf8))
        try handle.close()
        let whole = await tally.read(url)
        XCTAssertEqual(whole.map(\.id), ["msg_1", "msg_2"])
    }

    func testSubagentsCountApart() async throws {
        let url = folder.appendingPathComponent("s.jsonl")
        try (row("msg_1", at: 100) + "\n").write(to: url, atomically: true, encoding: .utf8)
        let agents = folder.appendingPathComponent("s/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try (row("msg_a", at: 150, sidechain: true) + "\n" + row("msg_a", at: 150, sidechain: true) + "\n")
            .write(to: agents.appendingPathComponent("agent-abc.jsonl"), atomically: true, encoding: .utf8)
        try "{}".write(to: agents.appendingPathComponent("agent-abc.meta.json"), atomically: true, encoding: .utf8)
        let entries = await TokenTally().read(url)
        XCTAssertEqual(entries.map(\.id), ["msg_1", "msg_a"])
        XCTAssertEqual(entries.map(\.subagent), [false, true])
    }

    // MARK: Accounts over time

    private func entry(_ id: String, at seconds: Double?, output: Int, subagent: Bool = false) -> TokenEntry {
        TokenEntry(id: id, at: seconds.map(Date.init(timeIntervalSince1970:)), count: TokenCount(output: output, cacheRead: 1), subagent: subagent)
    }

    func testTokensSplitByTheAccountEachCallRanOn() {
        let spans = [AccountSpan(account: "creator1", from: Date(timeIntervalSince1970: 50)),
                     AccountSpan(account: "creator3", from: Date(timeIntervalSince1970: 250)),
                     AccountSpan(account: nil, from: Date(timeIntervalSince1970: 400))]
        let entries = [entry("a", at: 10, output: 1), entry("b", at: 100, output: 10), entry("c", at: 200, output: 20, subagent: true),
                       entry("d", at: 300, output: 30), entry("e", at: 500, output: 50)]
        let shares = SessionAccountLog.split(entries, spans: spans)
        XCTAssertEqual(shares.map(\.owner), [.unknown, .account("creator1"), .account("creator3"), .plain])
        XCTAssertEqual(shares[1].chat.output, 10)
        XCTAssertEqual(shares[1].subagents.output, 20)
        XCTAssertEqual(shares[1].all.cacheRead, 2)
        XCTAssertEqual(SessionAccountLog.split(entries, spans: spans, since: Date(timeIntervalSince1970: 250)).map(\.owner),
                       [.account("creator3"), .plain])
    }

    func testTheLogKeepsSwitchesAndMergesAnotherVibers() {
        var log = SessionAccountLog()
        XCTAssertTrue(log.record("s", account: "creator1", from: Date(timeIntervalSince1970: 10)))
        XCTAssertFalse(log.record("s", account: "creator1", from: Date(timeIntervalSince1970: 20)), "a restart on the same account")
        XCTAssertTrue(log.record("s", account: nil, from: Date(timeIntervalSince1970: 30)))
        XCTAssertNil(log.lastAccount("s"))
        var other = SessionAccountLog()
        other.record("s", account: "creator1", from: Date(timeIntervalSince1970: 10))
        other.record("t", account: "creator3", from: Date(timeIntervalSince1970: 15))
        log.merge(other)
        XCTAssertEqual(log.sessions["s"]?.count, 2)
        XCTAssertEqual(log.lastAccount("t"), "creator3")
    }

    func testTheLogStartsFromTheOldSessionAccounts() throws {
        let old = folder.appendingPathComponent("session-accounts.json"), url = folder.appendingPathComponent("log.json")
        try JSONEncoder().encode(["s": "creator1"]).write(to: old)
        let log = SessionAccountLog.load(from: url, migrating: old)
        XCTAssertEqual(log.lastAccount("s"), "creator1")
        XCTAssertEqual(SessionAccountLog.owner(at: Date(timeIntervalSince1970: 0), spans: log.sessions["s"] ?? []), .account("creator1"))
        try log.save(to: url)
        XCTAssertEqual(SessionAccountLog.load(from: url, migrating: folder.appendingPathComponent("missing")), log)
    }
}
