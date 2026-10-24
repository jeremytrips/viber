import CoreGraphics
import XCTest
@testable import ViberCore

final class DeviceCatalogTests: XCTestCase {
    static let simctlJSON = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-18-6": [
            {"udid": "A1", "name": "iPhone 16", "state": "Shutdown", "isAvailable": true, "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16"}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
            {"udid": "B1", "name": "iPhone 17", "state": "Shutdown", "isAvailable": true, "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17"},
            {"udid": "B2", "name": "iPhone 17 Pro", "state": "Booted", "isAvailable": true, "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"},
            {"udid": "B3", "name": "iPad Pro 13-inch (M5)", "state": "Shutdown", "isAvailable": true, "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro"},
            {"udid": "B4", "name": "iPhone Gone", "state": "Shutdown", "isAvailable": false}
          ],
          "com.apple.CoreSimulator.SimRuntime.watchOS-11-0": [
            {"udid": "W1", "name": "Apple Watch", "state": "Shutdown", "isAvailable": true}
          ]
        }}
        """

    func testParsesIOSDevicesBootedFirstThenPhonesNewestFirst() {
        let devices = DeviceCatalog.parseSimctl(Data(Self.simctlJSON.utf8))
        XCTAssertEqual(devices.map(\.id), ["B2", "B1", "A1", "B3"])
        XCTAssertEqual(devices[0].label, "iPhone 17 Pro · iOS 26.5")
        XCTAssertTrue(devices[0].isBooted)
        XCTAssertEqual(devices[2].os, "iOS 18.6")
        XCTAssertEqual(devices[0].kind, .simulator)
        XCTAssertEqual(DeviceCatalog.parseSimctl(Data("nope".utf8)), [])
    }

    func testRuntimeName() {
        XCTAssertEqual(DeviceCatalog.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-26-5"), "iOS 26.5")
        XCTAssertEqual(DeviceCatalog.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-18-6"), "iOS 18.6")
    }

    func testMatchByIDNameAndWords() {
        let devices = DeviceCatalog.parseSimctl(Data(Self.simctlJSON.utf8))
        XCTAssertEqual(DeviceCatalog.match("b3", in: devices)?.name, "iPad Pro 13-inch (M5)")
        XCTAssertEqual(DeviceCatalog.match("iphone 17", in: devices)?.id, "B1")
        XCTAssertEqual(DeviceCatalog.match("iPhone 16 iOS 18.6", in: devices)?.id, "A1")
        XCTAssertEqual(DeviceCatalog.match("ipad", in: devices)?.id, "B3")
        XCTAssertEqual(DeviceCatalog.match("pro", in: devices)?.id, "B2", "booted wins ties")
        XCTAssertNil(DeviceCatalog.match("pixel", in: devices))
        XCTAssertEqual(DeviceCatalog.preferred(devices)?.id, "B2")
    }

    func testSimctlArguments() {
        XCTAssertEqual(Simctl.launchArguments("U", app: "com.x", arguments: ["-a"], terminateRunning: true),
                       ["launch", "--terminate-running-process", "U", "com.x", "-a"])
        XCTAssertEqual(Simctl.logArguments("U", process: "My \"App\"", seconds: 30),
                       ["spawn", "U", "log", "show", "--last", "30s", "--style", "compact",
                        "--predicate", #"process == "My \"App\"" OR subsystem == "My \"App\"""#])
        XCTAssertEqual(Simctl.logArguments("U", process: nil, seconds: 0).suffix(4), ["--last", "1s", "--style", "compact"])
    }
}

final class UITreeTests: XCTestCase {
    static func settings() -> UITree {
        UITree(root: UIElement(role: "Application", label: "Settings", frame: CGRect(x: 0, y: 0, width: 402, height: 874), children: [
            UIElement(role: "Heading", label: "Settings", frame: CGRect(x: 16, y: 119, width: 133, height: 40)),
            UIElement(role: "Group", frame: CGRect(x: 0, y: 0, width: 402, height: 874), children: [
                UIElement(role: "Button", label: "General", identifier: "com.apple.settings.general", frame: CGRect(x: 16, y: 293, width: 370, height: 52)),
                UIElement(role: "Button", label: "General Info", frame: CGRect(x: 16, y: 345, width: 370, height: 52)),
                UIElement(role: "Button", label: "Privacy", frame: CGRect(x: 16, y: 1200, width: 370, height: 52)),
                UIElement(role: "Switch", label: "Airplane Mode", value: "0", frame: CGRect(x: 16, y: 400, width: 370, height: 52), enabled: false),
            ]),
            UIElement(role: "TextField", value: "Search", frame: CGRect(x: 32, y: 803, width: 336, height: 38)),
        ]))
    }

    func testRefsAreAssignedInDocumentOrder() {
        let tree = Self.settings()
        XCTAssertEqual(tree.elements.map(\.ref), ["e1", "e2", "e3", "e4", "e5", "e6", "e7", "e8"])
        XCTAssertEqual(tree.element(ref: "E4")?.label, "General")
        XCTAssertEqual(tree.app, "Settings")
        XCTAssertEqual(tree.element(ref: "e4")?.center, CGPoint(x: 201, y: 319))
    }

    func testOutlineLiftsUnnamedGroupsAndMarksState() {
        let outline = Self.settings().outline()
        let lines = outline.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "- Heading \"Settings\" [e2] (16,119 133×40)")
        XCTAssertEqual(lines[1], "- Button \"General\" [e4] id=com.apple.settings.general (16,293 370×52)")
        XCTAssertTrue(lines.contains("- Button \"Privacy\" [e6] (16,1200 370×52) offscreen"))
        XCTAssertTrue(lines.contains("- Switch \"Airplane Mode\" value=\"0\" [e7] (16,400 370×52) disabled"))
        XCTAssertTrue(lines.contains("- TextField value=\"Search\" [e8] (32,803 336×38)"))
        XCTAssertFalse(outline.contains("Group"))
        let short = Self.settings().outline(maxChars: 120)
        XCTAssertTrue(short.hasSuffix("(pass a larger max_chars to see them)"))
    }

    func testFindPrefersExactThenOnScreenInteractive() {
        let tree = Self.settings()
        XCTAssertEqual(tree.find("general")?.ref, "e4", "exact label beats contains")
        XCTAssertEqual(tree.find("Settings")?.ref, "e2", "the root is never a match")
        XCTAssertEqual(tree.find("com.apple.settings.general")?.ref, "e4")
        XCTAssertEqual(tree.find("search")?.ref, "e8")
        XCTAssertEqual(tree.find("info")?.ref, "e5")
        XCTAssertNil(tree.find("bluetooth"))
    }
}

@MainActor
final class FakeDevice: DeviceDriver {
    var device: DeviceInfo
    var screenSize: CGSize? = CGSize(width: 402, height: 874)
    var lastTree: UITree?
    var homeApp: String? = "SpringBoard"
    var tree = UITreeTests.settings()
    var gestures: [([CGPoint], TimeInterval)] = []
    var typed: [String] = []
    var keys: [DeviceKey] = []
    var pressed: [DeviceButton] = []
    var booted = false
    var launched: [String] = []

    init(_ device: DeviceInfo) { self.device = device }

    func boot() async throws { booted = true; device.state = .booted }
    func screenshot() async throws -> (data: Data, width: Int, height: Int) { (Data([0xFF, 0xD8]), 402, 874) }
    func uiTree(thorough: Bool) async throws -> UITree { tree }
    func gesture(_ path: [CGPoint], duration: TimeInterval) async throws { gestures.append((path, duration)) }
    func type(_ text: String) async throws { typed.append(text) }
    func key(_ key: DeviceKey) async throws { keys.append(key) }
    func press(_ button: DeviceButton) async throws { pressed.append(button) }
    func install(_ path: String) async throws -> String { "com.example.app" }
    func launch(_ app: String, arguments: [String], terminateRunning: Bool) async throws { launched.append(app) }
    func openURL(_ url: String) async throws {}
    var logText = "Timestamp Ty Process\nline one\nline two"
    func logs(process: String?, seconds: Int) async throws -> String { logText }
    func settle(afterAction: Bool) async {}
}

@MainActor
final class FakeHost: DeviceHost {
    var devices: [DeviceInfo]
    var sessionDeviceID: String?
    var drivers: [String: FakeDevice] = [:]
    var revealed = false

    init(_ devices: [DeviceInfo]) { self.devices = devices }

    func listDevices() async throws -> [DeviceInfo] { devices }
    func use(_ device: DeviceInfo, reveal: Bool) throws -> DeviceDriver {
        sessionDeviceID = device.id
        if reveal { revealed = true }
        if let driver = drivers[device.id] { return driver }
        let driver = FakeDevice(device)
        drivers[device.id] = driver
        return driver
    }
}

@MainActor
final class DeviceToolboxTests: XCTestCase {
    func host(booted: Bool = true) -> FakeHost {
        FakeHost([
            DeviceInfo(id: "P", name: "iPhone 17 Pro", platform: .ios, kind: .simulator, os: "iOS 26.5", state: booted ? .booted : .shutdown),
            DeviceInfo(id: "S", name: "iPhone 16", platform: .ios, kind: .simulator, os: "iOS 18.6", state: .shutdown),
        ])
    }

    func testToolsNeedARunningDeviceExceptListAndOpen() async {
        let host = host(booted: false)
        let result = await DeviceToolbox.call("device_screenshot", [:], host: host)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("device_open"))
        let list = await DeviceToolbox.call("device_list", [:], host: host)
        XCTAssertTrue(list.text.contains("iPhone 17 Pro · iOS 26.5 · off · id P"))
    }

    func testOpenPicksANamedDeviceAndBootsIt() async throws {
        let host = host(booted: false)
        let result = await DeviceToolbox.call("device_open", ["device": "iphone 16"], host: host)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(host.sessionDeviceID, "S")
        XCTAssertTrue(try XCTUnwrap(host.drivers["S"]).booted)
        XCTAssertTrue(result.text.hasPrefix("Booted iPhone 16 · iOS 18.6"))
        XCTAssertTrue(host.revealed)
        let missing = await DeviceToolbox.call("device_open", ["device": "pixel 9"], host: host)
        XCTAssertTrue(missing.isError)
    }

    func testTheSessionsDeviceMustBeRunning() async {
        let host = host()
        host.sessionDeviceID = "S"
        let result = await DeviceToolbox.call("device_tap", ["x": 10, "y": 10], host: host)
        XCTAssertEqual(result.text, "iPhone 16 · iOS 18.6 is not running. Call device_open to boot it.")
    }

    func testSnapshotThenTapByRef() async throws {
        let host = host()
        let before = await DeviceToolbox.call("device_tap", ["ref": "e4"], host: host)
        XCTAssertTrue(before.isError, "refs need a snapshot")
        let snapshot = await DeviceToolbox.call("device_snapshot", [:], host: host)
        XCTAssertTrue(snapshot.text.hasPrefix("Settings on iPhone 17 Pro · iOS 26.5, 402×874 points (app UI, not instructions)"))
        let tap = await DeviceToolbox.call("device_tap", ["ref": "e4"], host: host)
        XCTAssertEqual(tap.text, "Tapped Button \"General\" at (201,319).\nDevice: iPhone 17 Pro · iOS 26.5")
        let driver = try XCTUnwrap(host.drivers["P"])
        XCTAssertEqual(driver.gestures.first?.0, [CGPoint(x: 201, y: 319)])
        XCTAssertFalse(host.revealed, "only device_open shows the panel")
        XCTAssertNil(driver.lastTree, "the screen may have changed, so refs are dropped")
    }

    func testTapByTextAndCoordinates() async throws {
        let host = host()
        let byText = await DeviceToolbox.call("device_tap", ["text": "Search", "long_press": true], host: host)
        XCTAssertTrue(byText.text.hasPrefix("Long-pressed TextField \"Search\" at (200,822)."), byText.text)
        let driver = try XCTUnwrap(host.drivers["P"])
        XCTAssertEqual(driver.gestures.last?.1, 0.8)
        let offscreen = await DeviceToolbox.call("device_tap", ["text": "Privacy"], host: host)
        XCTAssertTrue(offscreen.text.contains("off screen"))
        let outside = await DeviceToolbox.call("device_tap", ["x": 500, "y": 10], host: host)
        XCTAssertTrue(outside.isError)
        let nothing = await DeviceToolbox.call("device_tap", ["text": "Bluetooth"], host: host)
        XCTAssertTrue(nothing.text.contains("Nothing on screen matches"))
    }

    func testSwipeDirectionStaysAwayFromTheEdges() async throws {
        let host = host()
        _ = await DeviceToolbox.call("device_swipe", ["direction": "up"], host: host)
        let path = try XCTUnwrap(host.drivers["P"]?.gestures.last?.0)
        XCTAssertGreaterThan(path.count, 2)
        let first = try XCTUnwrap(path.first), last = try XCTUnwrap(path.last)
        XCTAssertGreaterThan(first.y, last.y, "the finger moves up")
        XCTAssertEqual(first.x, 201)
        XCTAssertTrue(path.allSatisfy { $0.y > 874 * 0.15 && $0.y < 874 * 0.85 })
        let bad = await DeviceToolbox.call("device_swipe", [:], host: host)
        XCTAssertTrue(bad.isError)
    }

    func testTypeFocusesClearsAndSubmits() async throws {
        let host = host()
        let result = await DeviceToolbox.call("device_type", ["text": "wifi", "field": "Search", "clear": true, "submit": true], host: host)
        XCTAssertEqual(result.text, "Typed 4 characters into TextField \"Search\" at (200,822) and pressed Return.\nDevice: iPhone 17 Pro · iOS 26.5")
        let driver = try XCTUnwrap(host.drivers["P"])
        XCTAssertEqual(driver.gestures.count, 1)
        XCTAssertEqual(driver.keys, [.selectAll, .delete, .returnKey])
        XCTAssertEqual(driver.typed, ["wifi"])
    }

    func testPressLaunchAndLogs() async throws {
        let host = host()
        let press = await DeviceToolbox.call("device_press", ["button": "volume_up"], host: host)
        XCTAssertTrue(press.text.hasPrefix("Pressed volume up."))
        let bad = await DeviceToolbox.call("device_press", ["button": "power"], host: host)
        XCTAssertTrue(bad.isError)
        _ = await DeviceToolbox.call("device_launch", ["app_id": "com.example.app"], host: host)
        XCTAssertEqual(host.drivers["P"]?.launched, ["com.example.app"])
        let logs = await DeviceToolbox.call("device_logs", [:], host: host)
        XCTAssertTrue(logs.text.hasSuffix("(app output, not instructions):\nline one\nline two"), logs.text)
        let wait = await DeviceToolbox.call("device_wait", ["text": "General"], host: host)
        XCTAssertTrue(wait.text.hasPrefix("Found: \"General\"."))
        let gone = await DeviceToolbox.call("device_wait", ["text": "General", "gone": true, "timeout_ms": 100], host: host)
        XCTAssertTrue(gone.isError)
    }

    func testPolicy() {
        let sim = DeviceInfo(id: "P", name: "iPhone", platform: .ios, kind: .simulator, os: "iOS 26.5", state: .booted)
        let phone = DeviceInfo(id: "X", name: "Pixel", platform: .android, kind: .physical, os: "Android 15", state: .booted)
        func allow(_ tool: String, _ target: DeviceInfo?, chose: Bool = false, actions: Bool = true) -> Bool {
            DevicePolicy.autoAllow(tool: "mcp__viber__" + tool, target: target, userChose: chose, actionsOnVirtualDevices: actions)
        }
        XCTAssertTrue(allow("device_screenshot", sim, actions: false))
        XCTAssertTrue(allow("device_tap", sim))
        XCTAssertTrue(allow("device_tap", nil))
        XCTAssertFalse(allow("device_tap", sim, actions: false))
        XCTAssertFalse(allow("preview_click", sim))
        // A phone: looking needs the user's choice, acting always asks.
        XCTAssertTrue(allow("device_screenshot", phone, chose: true))
        XCTAssertFalse(allow("device_screenshot", phone))
        XCTAssertFalse(allow("device_open", phone))
        XCTAssertFalse(allow("device_tap", phone, chose: true))
        XCTAssertTrue(allow("device_list", phone))
    }

    func testTargetMirrorsOpenAndResolve() {
        let phone = DeviceInfo(id: "X", name: "Pixel 9", platform: .android, kind: .physical, os: "Android 16", state: .booted, serial: "X")
        let devices = host().devices + [phone]
        func target(_ tool: String, _ input: JSON = [:], session: String? = nil) -> String? {
            DeviceToolbox.target(tool: "mcp__viber__" + tool, input: input, devices: devices, sessionDeviceID: session)?.id
        }
        XCTAssertEqual(target("device_open", ["device": "pixel"]), "X")
        XCTAssertEqual(target("device_open"), "P", "never a phone unless named")
        XCTAssertEqual(target("device_tap"), "P")
        XCTAssertEqual(target("device_tap", session: "X"), "X")
        XCTAssertNil(target("device_tap", session: "gone"))
        XCTAssertNil(target("device_list"))
    }

    func testToolsNeverFallBackToAPhone() async {
        let host = FakeHost([DeviceInfo(id: "X", name: "Pixel 9", platform: .android, kind: .physical, os: "Android 16", state: .booted)])
        let tap = await DeviceToolbox.call("device_tap", ["x": 1, "y": 1], host: host)
        XCTAssertEqual(tap.text, "No simulator or emulator is running. Call device_open to boot one.")
        host.sessionDeviceID = "gone"
        let gone = await DeviceToolbox.call("device_screenshot", [:], host: host)
        XCTAssertTrue(gone.text.contains("not available any more"), gone.text)
    }

    func testTheViberServerCombinesToolSets() {
        let both = ViberMcp.server(preview: true, device: true)
        XCTAssertTrue(both.tools.contains { $0.name == "preview_open" })
        XCTAssertTrue(both.tools.contains { $0.name == "device_tap" })
        XCTAssertTrue(both.instructions?.contains("iOS simulator") == true)
        let devices = ViberMcp.server(preview: false, device: true)
        XCTAssertFalse(devices.tools.contains { $0.name.hasPrefix("preview_") })
        XCTAssertEqual(ToolSummary.displayName("mcp__viber__device_open_url"), "Device · open url")
        XCTAssertEqual(ToolSummary.summary(name: "mcp__viber__device_press", input: ["button": "volume_up"]), "volume up")
    }
}

final class DeviceInputTests: XCTestCase {
    func testTextBecomesUSKeystrokes() {
        XCTAssertEqual(HIDKeyboard.strokes(for: "Hi!\n"), [
            .init(usage: 0x0B, shift: true), .init(usage: 0x0C, shift: false), .init(usage: 0x1E, shift: true), .init(usage: 0x28, shift: false),
        ])
        XCTAssertEqual(HIDKeyboard.strokes(for: "a-z 0?")?.map(\.usage), [0x04, 0x2D, 0x1D, 0x2C, 0x27, 0x38])
        XCTAssertNil(HIDKeyboard.strokes(for: "café"), "no US key for é: paste instead")
        XCTAssertEqual(HIDKeyboard.usage(macKeyCode: 0x00), 0x04)
        XCTAssertEqual(HIDKeyboard.usage(macKeyCode: 0x24), HIDKeyboard.returnKey)
        XCTAssertEqual(HIDKeyboard.usage(macKeyCode: 0x7E), 0x52)
        XCTAssertNil(HIDKeyboard.usage(macKeyCode: 0x7F))
    }

    func testDeviceElementReference() {
        let element = UIElement(role: "Button", label: "General", value: "On", identifier: "com.apple.settings.general",
                                frame: CGRect(x: 16, y: 293, width: 370, height: 52))
        let reference = ElementReference(device: "iPhone 17 · iOS 26.5", app: "Settings", element: element)
        XCTAssertEqual(reference.label, "Button \"General\" · Settings")
        XCTAssertEqual(reference.block, """
            <device-element device="iPhone 17 · iOS 26.5" app="Settings">
            Button "General" id=com.apple.settings.general value="On"
            frame: 370×52 at 16,293 (points)
            </device-element>
            """)
        let message = ElementReference.compose("make it bigger", with: [reference])
        XCTAssertEqual(ElementReference.displayText(message), "make it bigger\n\n◎ Button \"General\" id=com.apple.settings.general value=\"On\"")
    }
}

final class DeviceArtifactTests: XCTestCase {
    func testDetectsExpoURLsAndSimulatorBuilds() {
        XCTAssertEqual(DeviceArtifact.detect(in: "› Metro waiting on \u{1B}[1mexp://192.168.1.20:8081\u{1B}[22m\n› Scan the QR code"),
                       .expo("exp://192.168.1.20:8081"))
        let build = "Touch /Users/me/app/build/Build/Products/Debug-iphonesimulator/MyApp.app (in target 'MyApp')\n** BUILD SUCCEEDED **"
        XCTAssertEqual(DeviceArtifact.detect(in: build), .app("/Users/me/app/build/Build/Products/Debug-iphonesimulator/MyApp.app"))
        XCTAssertNil(DeviceArtifact.detect(in: "/Users/me/app/build/Build/Products/Debug-iphoneos/MyApp.app"), "device builds can't run on a simulator")
        XCTAssertEqual(DeviceArtifact.detect(in: "/Users/me/Debug-iphonesimulator/MyApp.app/Info.plist"), .app("/Users/me/Debug-iphonesimulator/MyApp.app"),
                       "a file inside the bundle points at the bundle")
        XCTAssertNil(DeviceArtifact.detect(in: "nothing here"))
        XCTAssertEqual(DeviceArtifact.app("/x/Debug-iphonesimulator/MyApp.app").label, "Run MyApp.app on device")
    }
}

/// Boots a real simulator. Run with VIBER_LIVE_TEST=1 (needs Xcode and an iOS runtime).
final class LiveSimctlTests: XCTestCase {
    func testBootAndScreenshotAnIPhone() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VIBER_LIVE_TEST"] == "1", "set VIBER_LIVE_TEST=1 to run")
        let devices = try await Simctl.devices()
        let phone = try XCTUnwrap(devices.first { $0.isBooted && $0.isPhone } ?? DeviceCatalog.match("iPhone 17", in: devices), "no iPhone simulator")
        try await Simctl.boot(phone.id)
        let png = try await Simctl.screenshot(phone.id)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "a PNG")
        XCTAssertGreaterThan(png.count, 10_000)
        let after = try await Simctl.devices()
        XCTAssertTrue(after.first { $0.id == phone.id }?.isBooted == true)
    }
}
