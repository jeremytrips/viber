import XCTest
@testable import ViberCore

final class UsageLimitTests: XCTestCase {
    /// 23:10 in Paris on 2026-10-24, when a real session hit its 5-hour limit.
    private let hitAt = Date(timeIntervalSince1970: 1_792_876_200)
    /// 23:30 in Paris, its reset.
    private let resetsAt = Date(timeIntervalSince1970: 1_792_877_400)
    private let limitText = "You've hit your session limit · resets 11:30pm (Europe/Paris)"

    private func limitEvent(_ status: String = "rejected") -> JSON {
        ["type": "rate_limit_event", "rate_limit_info": ["status": .string(status), "resetsAt": 1_792_877_400,
                                                          "rateLimitType": "five_hour", "overageStatus": "rejected"]]
    }

    /// The made-up message the CLI ends a turned-away turn with.
    private func limitMessage(_ id: String = "m1") -> JSON {
        ["type": "assistant", "error": "rate_limit", "message": [
            "id": .string(id), "role": "assistant", "model": "<synthetic>", "content": [["type": "text", "text": .string(limitText)]]]]
    }

    private func result(isError: Bool = true) -> JSON {
        ["type": "result", "subtype": "success", "is_error": .bool(isError), "result": .string(isError ? limitText : "done")]
    }

    func testTurnAtTheLimitRecordsWhenItResets() {
        var chat = ChatTranscript()
        _ = chat.userMessage("carry on")
        chat.apply(limitEvent(), now: hitAt)
        chat.apply(limitMessage(), now: hitAt)
        chat.apply(result(), now: hitAt)
        XCTAssertEqual(chat.state, .failed)
        XCTAssertEqual(chat.usageLimit, UsageLimit(resetsAt: resetsAt, kind: "five_hour", hits: 1))
        XCTAssertEqual(chat.items.dropFirst().map(\.kind), [.assistant(limitText)], "the result repeats the message, so it isn't shown twice")
        XCTAssertEqual(chat.usageLimit?.name, "session limit")
    }

    func testTheErrorTextGivesTheResetWithoutAnEvent() {
        var chat = ChatTranscript()
        _ = chat.userMessage("carry on")
        chat.apply(limitMessage(), now: hitAt)
        chat.apply(result(isError: false), now: hitAt)
        XCTAssertEqual(chat.state, .failed, "the CLI's error message counts even if the result doesn't say error")
        XCTAssertEqual(chat.usageLimit?.resetsAt, resetsAt)
    }

    func testTheNextMessageClearsTheLimitAndASuccessResetsTheCount() {
        var chat = ChatTranscript()
        _ = chat.userMessage("carry on")
        chat.apply(limitEvent(), now: hitAt)
        chat.apply(limitMessage("m1"), now: hitAt)
        chat.apply(result(), now: hitAt)
        _ = chat.userMessage(UsageLimit.continueMessage)
        XCTAssertNil(chat.usageLimit)
        let late = resetsAt.addingTimeInterval(61)
        chat.apply(limitMessage("m2"), now: late)
        chat.apply(result(), now: late)
        XCTAssertEqual(chat.usageLimit?.hits, 2, "the limit outlasted the wait")

        _ = chat.userMessage(UsageLimit.continueMessage)
        chat.apply(limitEvent("allowed"))
        chat.apply(["type": "assistant", "message": ["id": "m3", "role": "assistant", "content": [["type": "text", "text": "Back at it."]]]])
        chat.apply(result(isError: false))
        XCTAssertNil(chat.usageLimit)
        XCTAssertEqual(chat.state, .finished)

        _ = chat.userMessage("more")
        chat.apply(limitMessage("m4"), now: hitAt)
        chat.apply(result(), now: hitAt)
        XCTAssertEqual(chat.usageLimit?.hits, 1, "a turn that got through starts the count again")
    }

    func testATurnBeforeTheResetIsTheSameWait() {
        var chat = ChatTranscript()
        _ = chat.userMessage("carry on")
        chat.apply(limitEvent(), now: hitAt)
        chat.apply(limitMessage("m1"), now: hitAt)
        chat.apply(result(), now: hitAt)
        // A background command finished while it waited, and the CLI's turn for it was turned away too.
        let later = hitAt.addingTimeInterval(600)
        chat.apply(limitMessage("m2"), now: later)
        chat.apply(result(), now: later)
        XCTAssertEqual(chat.usageLimit?.hits, 1)
        XCTAssertEqual(chat.usageLimit?.continueAt(now: later), resetsAt.addingTimeInterval(60))
    }

    func testOtherErrorsAreNotALimit() {
        var chat = ChatTranscript()
        _ = chat.userMessage("hi")
        chat.apply(["type": "result", "subtype": "success", "is_error": true, "result": "API Error: 500"])
        XCTAssertNil(chat.usageLimit)
        XCTAssertEqual(chat.state, .failed)
    }

    func testAnOldLimitInTheTranscriptIsIgnored() {
        var chat = ChatTranscript()
        let row: JSON = ["type": "assistant", "uuid": "u1", "error": "rate_limit", "apiError": "usage_limit_reached",
                         "apiErrorParams": ["rate_limit_info": ["status": "rejected", "resetsAt": 1_792_877_400, "rateLimitType": "five_hour"]],
                         "message": ["id": "m1", "role": "assistant", "model": "<synthetic>", "content": [["type": "text", "text": .string(limitText)]]]]
        chat.loadHistory(Data(row.line().utf8))
        _ = chat.userMessage("hi")
        chat.apply(["type": "result", "subtype": "success", "is_error": true, "result": "API Error: 500"])
        XCTAssertNil(chat.usageLimit)
    }

    func testContinuesJustAfterTheReset() {
        let limit = UsageLimit(resetsAt: resetsAt, kind: "five_hour")
        XCTAssertEqual(limit.continueAt(now: hitAt), resetsAt.addingTimeInterval(60))
    }

    func testWaitsLongerEachTimeTheLimitOutlastsTheReset() {
        let late = resetsAt.addingTimeInterval(61)
        XCTAssertEqual(UsageLimit(resetsAt: resetsAt, kind: nil, hits: 2).continueAt(now: late), late.addingTimeInterval(6 * 60))
        XCTAssertEqual(UsageLimit(resetsAt: resetsAt, kind: nil, hits: 3).continueAt(now: late), late.addingTimeInterval(11 * 60))
        XCTAssertNil(UsageLimit(resetsAt: resetsAt, kind: nil, hits: UsageLimit.maxHits + 1).continueAt(now: late))
    }

    func testANewLimitAfterTheResetIsWaitedOutInFull() {
        // The 5-hour window reset, then the weekly limit turned the next turn away.
        let weekly = resetsAt.addingTimeInterval(2 * 86400)
        XCTAssertEqual(UsageLimit(resetsAt: weekly, kind: "seven_day", hits: 2).continueAt(now: resetsAt), weekly.addingTimeInterval(60))
    }

    func testUnknownResetWaitsHalfAnHour() {
        XCTAssertEqual(UsageLimit(resetsAt: nil, kind: nil).continueAt(now: hitAt), hitAt.addingTimeInterval(31 * 60))
    }

    func testResetTimeFromTheErrorText() {
        XCTAssertEqual(UsageLimit.resetTime(in: limitText, now: hitAt), resetsAt)
        // Paris leaves summer time that night, so tomorrow's 11:30pm is 25 hours on.
        XCTAssertEqual(UsageLimit.resetTime(in: limitText, now: resetsAt.addingTimeInterval(1)), Date(timeIntervalSince1970: 1_792_967_400),
                       "a time already past is tomorrow's")
        XCTAssertEqual(UsageLimit.resetTime(in: "You've hit your limit · resets 5am (Europe/Paris)", now: hitAt),
                       Date(timeIntervalSince1970: 1_792_900_800))
        XCTAssertEqual(UsageLimit.resetTime(in: "Claude AI usage limit reached|1792877400", now: hitAt), resetsAt)
        XCTAssertNil(UsageLimit.resetTime(in: "API Error: 429 rate limited", now: hitAt))
    }
}
