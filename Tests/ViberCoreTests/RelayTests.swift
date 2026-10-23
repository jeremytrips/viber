import XCTest
@testable import ViberCore

final class RelayTests: XCTestCase {
    let sessions = [
        RelayCandidate(id: "ux", title: "HTML mockups of every screen", project: "nexus-cloud", branch: "viber/ux-mockups",
                       context: "Writing ux/login.html and the shared stylesheet"),
        RelayCandidate(id: "api", title: "Backend auth API", project: "nexus-cloud", branch: "viber/backend-auth",
                       context: "Added /auth/otp/send endpoint and tests for the OTP flow"),
        RelayCandidate(id: "ota", title: "OTA firmware updates", project: "nexus-device", branch: "viber/ota",
                       context: "partitions.csv, esp_https_ota, rollback")
    ]

    func testOnlyDoubleSlashIsARelay() {
        XCTAssertTrue(Relay.rank("/plan", candidates: sessions).isEmpty)
        XCTAssertEqual(Relay.rank("//", candidates: sessions).count, 3)
    }

    func testRanksByWhatTheMessageIsAbout() {
        XCTAssertEqual(Relay.rank("//we need a firmware download endpoint for OTA", candidates: sessions).first?.candidate.id, "ota")
        XCTAssertEqual(Relay.rank("//the OTP endpoints need rate limiting", candidates: sessions).first?.candidate.id, "api")
        XCTAssertEqual(Relay.rank("//update the login mockup stylesheet", candidates: sessions).first?.candidate.id, "ux")
    }

    func testAddressingByNameWinsAndIsStripped() {
        let top = Relay.rank("//backend: rate limit the login", candidates: sessions).first
        XCTAssertEqual(top?.candidate.id, "api")
        XCTAssertTrue(top?.addressed == true)
        XCTAssertEqual(top?.message, "rate limit the login")
        XCTAssertEqual(Relay.rank("//ota check the rollback", candidates: sessions).first?.message, "check the rollback")
    }

    func testUnaddressedMessageKeepsAllText() {
        let top = Relay.rank("//firmware endpoint please", candidates: sessions).first
        XCTAssertEqual(top?.addressed, false)
        XCTAssertEqual(top?.message, "firmware endpoint please")
    }

    func testTiesKeepCallerOrder() {
        XCTAssertEqual(Relay.rank("//hello there", candidates: sessions).map(\.candidate.id), ["ux", "api", "ota"])
    }

    func testEnvelopeRoundTrip() {
        let text = Relay.envelope(from: "OTA firmware updates", text: "Expose GET /firmware/latest")
        let parsed = Relay.parseEnvelope(text)
        XCTAssertEqual(parsed?.from, "OTA firmware updates")
        XCTAssertEqual(parsed?.text, "Expose GET /firmware/latest")
    }
}
