import XCTest
import XPC
@testable import SimulatorBridge

final class SimInputTests: XCTestCase {
    func testDTUHIDFromCoreSimulator1155_4() {
        for version in [nil, "1051.55", "1155", "1155.3"] { XCTAssertFalse(SimFrameworks.usesDTUHID(version), "\(version ?? "nil")") }
        for version in ["1155.4", "1155.10", "1155.4.2", "1160"] { XCTAssertTrue(SimFrameworks.usesDTUHID(version), version) }
    }

    func testTouchMessages() throws {
        for (phase, type) in [(SimTouchPhase.down, UInt64(0)), (.move, 1), (.up, 2)] {
            let payload = try envelope(DTUHIDInput.touchMessage(phase, x: 0.25, y: 1.5), type: "IndigoDigitizerEvent")
            XCTAssertEqual(try uint(payload, "eventType"), type)
            XCTAssertEqual(try uint(payload, "edge"), 0)
            XCTAssertEqual(try uint(payload, "target"), 0)
            let point = try XCTUnwrap(xpc_dictionary_get_value(payload, "pointOne"))
            XCTAssertEqual(xpc_get_type(xpc_dictionary_get_value(point, "x")!), XPC_TYPE_DOUBLE)
            XCTAssertEqual(xpc_dictionary_get_double(point, "x"), 0.25)
            XCTAssertEqual(xpc_dictionary_get_double(point, "y"), 1, "clamped to the screen")
            XCTAssertNil(xpc_dictionary_get_value(payload, "pointTwo"))
        }
    }

    func testKeyAndButtonMessages() throws {
        let key = try envelope(DTUHIDInput.keyMessage(usage: 0x04, down: true), type: "IndigoKeyboardButtonEvent")
        XCTAssertEqual(try uint(key, "usageCode"), 0x04)
        XCTAssertEqual(try uint(key, "state"), 1)

        let lock = try envelope(DTUHIDInput.buttonMessage(.lock, down: false), type: "IndigoButtonEvent")
        XCTAssertEqual(try uint(lock, "usagePage"), 0x0C)
        XCTAssertEqual(try uint(lock, "usageCode"), 0x30)
        XCTAssertEqual(try uint(lock, "state"), 2)
        let volume = try envelope(DTUHIDInput.buttonMessage(.volumeDown, down: true), type: "IndigoButtonEvent")
        XCTAssertEqual(try uint(volume, "usageCode"), 0xEA)
    }

    func testTheProbeIsABarrierTheGuestDoesNotSee() throws {
        let message = DTUHIDInput.barrierMessage()
        XCTAssertTrue(xpc_dictionary_get_bool(message, "isBarrier"))
        let payload = try XCTUnwrap(xpc_dictionary_get_value(message, "payload"))
        XCTAssertEqual(try uint(payload, "usageCode"), 0)
        XCTAssertEqual(try uint(payload, "state"), 2)
    }

    /// Needs a booted simulator. Run with: VIBER_SIM_UDID=<udid> swift test --filter SimInputTests
    /// Taps the middle of the screen with the input this Xcode gets. Below Xcode 27 it also checks that the
    /// DTUHID input fails with a message rather than crashing.
    func testLiveTap() throws {
        guard let udid = ProcessInfo.processInfo.environment["VIBER_SIM_UDID"] else { throw XCTSkip("set VIBER_SIM_UDID to run") }
        let version = SimFrameworks.coreSimulatorVersion
        let input = try SimInputFactory.make(udid: udid)
        XCTAssertEqual(input is DTUHIDInput, SimFrameworks.usesDTUHID(version), "CoreSimulator \(version ?? "?")")
        // Give a cold dtuhidd time to answer before the tap goes out.
        Thread.sleep(forTimeInterval: input is DTUHIDInput ? 5 : 0.2)
        try input.touch(.down, x: 0.5, y: 0.5)
        Thread.sleep(forTimeInterval: 0.05)
        try input.touch(.up, x: 0.5, y: 0.5)
        Thread.sleep(forTimeInterval: 0.5)
        if !SimFrameworks.usesDTUHID(version) {
            XCTAssertThrowsError(try DTUHIDInput(udid: udid)) { error in
                XCTAssertTrue(error is SimBridgeError, "\(error)")
                print("DTUHID on CoreSimulator \(version ?? "?"): \(error.localizedDescription)")
            }
        }
    }

    /// Checks the envelope dtuhidd decodes and returns its payload.
    private func envelope(_ message: xpc_object_t, type: String) throws -> xpc_object_t {
        XCTAssertEqual(xpc_get_type(message), XPC_TYPE_DICTIONARY)
        XCTAssertEqual(xpc_dictionary_get_string(message, "messageType").map { String(cString: $0) }, type)
        XCTAssertEqual(xpc_dictionary_get_string(message, "featureIdentifier").map { String(cString: $0) }, DTUHIDInput.service)
        XCTAssertFalse(xpc_dictionary_get_bool(message, "isBarrier"))
        return try XCTUnwrap(xpc_dictionary_get_value(message, "payload"))
    }

    /// A field that has to be a `uint64`: dtuhidd rejects the same number as an `int64`.
    private func uint(_ dictionary: xpc_object_t, _ key: String) throws -> UInt64 {
        let value = try XCTUnwrap(xpc_dictionary_get_value(dictionary, key), key)
        XCTAssertEqual(xpc_get_type(value), XPC_TYPE_UINT64, key)
        return xpc_uint64_get_value(value)
    }
}
