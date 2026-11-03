import CoreGraphics
import XCTest
@testable import ViberCore

final class DevicectlTests: XCTestCase {
    /// `devicectl list devices` JSON, trimmed: a phone on Wi-Fi, one that is away, one on USB that doesn't trust the Mac yet,
    /// one without Developer Mode, a watch and a Mac.
    static let devicesJSON = """
        {"info": {"outcome": "success", "jsonVersion": 3},
         "result": {"devices": [
          {"identifier": "E3F4", "connectionProperties": {"pairingState": "paired", "transportType": "localNetwork", "tunnelState": "disconnected"},
           "deviceProperties": {"name": "iPhone (2)", "osVersionNumber": "18.7.8", "developerModeStatus": "enabled"},
           "hardwareProperties": {"platform": "iOS", "reality": "physical", "deviceType": "iPhone", "marketingName": "iPhone 14",
                                  "productType": "iPhone14,7", "udid": "00008110-000A3DA41A63A01E"}},
          {"identifier": "C237", "connectionProperties": {"pairingState": "paired", "tunnelState": "unavailable"},
           "deviceProperties": {"name": "Away", "osVersionNumber": "27.0.1"},
           "hardwareProperties": {"platform": "iOS", "reality": "physical", "productType": "iPhone17,3", "udid": "U2"}},
          {"identifier": "A1", "connectionProperties": {"pairingState": "unpaired", "transportType": "wired"},
           "deviceProperties": {"name": "New Phone", "osVersionNumber": "26.1"},
           "hardwareProperties": {"platform": "iOS", "reality": "physical", "productType": "iPhone18,1", "udid": "U3"}},
          {"identifier": "B1", "connectionProperties": {"pairingState": "paired", "transportType": "wired"},
           "deviceProperties": {"name": "Tablet", "osVersionNumber": "26.0", "developerModeStatus": "disabled"},
           "hardwareProperties": {"platform": "iOS", "reality": "physical", "productType": "iPad16,3", "udid": "U4"}},
          {"identifier": "W1", "connectionProperties": {"pairingState": "paired", "transportType": "localNetwork"},
           "deviceProperties": {"name": "Watch"}, "hardwareProperties": {"platform": "watchOS", "reality": "physical"}},
          {"identifier": "M1", "connectionProperties": {"pairingState": "paired", "transportType": "localNetwork"},
           "deviceProperties": {"name": "Mac"}, "hardwareProperties": {"platform": "macOS", "reality": "physical"}}
         ]}}
        """

    func testListsNearbyIPhonesAndSaysWhyOnesArentReady() throws {
        let phones = Devicectl.parseDevices(Data(Self.devicesJSON.utf8))
        XCTAssertEqual(phones.map(\.info.id), ["E3F4", "A1", "B1"], "away phones, watches and Macs are left out")
        let wifi = phones[0].info
        XCTAssertEqual(wifi.label, "iPhone (2) · iOS 18.7.8")
        XCTAssertEqual(wifi.kind, .physical)
        XCTAssertTrue(wifi.isBooted)
        XCTAssertTrue(wifi.wireless)
        XCTAssertTrue(wifi.isPhone, "a renamed iPhone is still a phone")
        XCTAssertEqual(wifi.serial, "00008110-000A3DA41A63A01E")
        XCTAssertNil(phones[0].notReady)
        XCTAssertFalse(phones[1].info.wireless)
        XCTAssertEqual(phones[1].info.state, .unknown)
        XCTAssertTrue(try XCTUnwrap(phones[1].notReady).contains("Trust"))
        XCTAssertTrue(try XCTUnwrap(phones[2].notReady).contains("Developer Mode"))
        XCTAssertFalse(phones[2].info.isPhone)
        XCTAssertEqual(Devicectl.parseDevices(Data("nope".utf8)), [])
    }

    func testPhonesAreNeverPreferred() {
        let phone = Devicectl.parseDevices(Data(Self.devicesJSON.utf8))[0].info
        let sim = DeviceInfo(id: "S", name: "iPhone 17", platform: .ios, kind: .simulator, os: "iOS 26.5", state: .shutdown)
        XCTAssertEqual(DeviceCatalog.preferred([phone, sim])?.id, "S")
        XCTAssertEqual(DeviceCatalog.match("iphone (2)", in: [phone, sim])?.id, "E3F4")
    }

    func testDisplays() throws {
        let json = """
            {"result": {"displays": [{"nativeSize": [1170, 2532], "pointScale": 3, "primary": true, "bounds": [[0, 0], [1170, 2532]]}]}}
            """
        let displays = try XCTUnwrap(Devicectl.parseDisplays(Data(json.utf8)))
        XCTAssertEqual(displays.pixels, CGSize(width: 1170, height: 2532))
        XCTAssertEqual(displays.scale, 3)
        XCTAssertNil(Devicectl.parseDisplays(Data(#"{"result": {"displays": []}}"#.utf8)))
    }

    func testLaunchArguments() {
        XCTAssertEqual(Devicectl.launchArguments("D", app: "com.x", arguments: ["-flag", "1"], terminateRunning: true),
                       ["device", "process", "launch", "--device", "D", "--terminate-existing", "--", "com.x", "-flag", "1"])
        XCTAssertEqual(Devicectl.launchArguments("D", app: "com.apple.mobilesafari", arguments: [], terminateRunning: false, url: "https://x.dev"),
                       ["device", "process", "launch", "--device", "D", "--payload-url", "https://x.dev", "--", "com.apple.mobilesafari"])
        let console = Devicectl.launchArguments("D", app: "com.x", arguments: [], terminateRunning: true, console: true)
        XCTAssertEqual(console.prefix(9), ["device", "process", "launch", "--device", "D", "--terminate-existing", "--console",
                                           "--environment-variables", #"{"OS_ACTIVITY_DT_MODE":"YES"}"#])
    }

    func testWhichAppOpensAURL() {
        let schemes = ["myapp": "com.example.app"]
        XCTAssertEqual(Devicectl.opener(for: "https://example.com", schemes: schemes, lastApp: "com.other"), "com.apple.mobilesafari")
        XCTAssertEqual(Devicectl.opener(for: "exp://192.168.1.20:8081", schemes: schemes, lastApp: nil), "host.exp.Exponent")
        XCTAssertEqual(Devicectl.opener(for: "MyApp://settings", schemes: schemes, lastApp: "com.other"), "com.example.app")
        XCTAssertEqual(Devicectl.opener(for: "other://x", schemes: schemes, lastApp: "com.other"), "com.other")
        XCTAssertNil(Devicectl.opener(for: "other://x", schemes: schemes, lastApp: nil))
        XCTAssertTrue(Devicectl.pointsAtLocalhost("exp://localhost:8081"))
        XCTAssertTrue(Devicectl.pointsAtLocalhost("http://127.0.0.1:3000/a"))
        XCTAssertFalse(Devicectl.pointsAtLocalhost("exp://192.168.1.20:8081"))
    }

    func testErrorText() {
        let output = """
            ERROR: Failed to install the app on the device. (com.apple.dt.CoreDeviceError error 3002 (0xBBA))
                   NSURL = file:///tmp/MyApp.app/
            --------------------------------------------------------------------------------
            ERROR: The application does not have a valid signature.
            """
        XCTAssertEqual(Devicectl.errorText(output),
                       "Failed to install the app on the device. (com.apple.dt.CoreDeviceError error 3002 (0xBBA)) The application does not have a valid signature.")
        XCTAssertEqual(Devicectl.errorText("  plain failure \n"), "plain failure")
        XCTAssertNil(Devicectl.errorText(" \n"))
    }

    func app(platform: String, schemes: [String] = []) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("viber-test-\(UUID().uuidString)/MyApp.app")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.MyApp", "CFBundleExecutable": "MyApp",
                                   "CFBundleSupportedPlatforms": [platform],
                                   "CFBundleURLTypes": [["CFBundleURLSchemes": schemes]]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: url.appendingPathComponent("Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    func testOnlyDeviceBuildsInstall() throws {
        let device = try app(platform: "iPhoneOS", schemes: ["MyApp"])
        let (_, bundle) = try Devicectl.deviceApp(device.path)
        XCTAssertEqual(bundle, Devicectl.AppBundle(identifier: "com.example.MyApp", executable: "MyApp", schemes: ["myapp"], platforms: ["iPhoneOS"]))
        let simulator = try app(platform: "iPhoneSimulator")
        XCTAssertThrowsError(try Devicectl.deviceApp(simulator.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("built for the iOS simulator"), error.localizedDescription)
        }
        XCTAssertThrowsError(try Devicectl.deviceApp("/tmp/app.ipa"))
        XCTAssertThrowsError(try Devicectl.deviceApp(device.deletingLastPathComponent().appendingPathComponent("Missing.app").path))
    }
}

final class IPhoneScreenTests: XCTestCase {
    func testPicksThePhonesScreen() {
        let screens = [(id: "BD654E58-65A3-4A3B-B42A-C8C024484AF4", name: "iPhone (2)"), (id: "C1", name: "Work iPhone")]
        XCTAssertEqual(IPhoneScreen.pick(screens, udid: "00008110-000A3DA41A63A01E", name: "Work iPhone", orOnly: true), 1, "by name")
        XCTAssertEqual(IPhoneScreen.pick(screens, udid: "c1", name: "Renamed", orOnly: true), 1, "by UDID, should macOS use it")
        XCTAssertNil(IPhoneScreen.pick(screens, udid: nil, name: "Other", orOnly: true), "two screens and no match: none")
        let one = Array(screens.prefix(1))
        XCTAssertEqual(IPhoneScreen.pick(one, udid: nil, name: "Renamed since", orOnly: true), 0, "the only screen")
        XCTAssertNil(IPhoneScreen.pick(one, udid: nil, name: "A phone on Wi-Fi", orOnly: false), "not another phone's screen")
        XCTAssertNil(IPhoneScreen.pick([], udid: nil, name: "iPhone", orOnly: true))
    }
}

final class AppConsoleTests: XCTestCase {
    func console(_ script: String) throws -> AppConsole {
        try AppConsole(app: "com.example.MyApp", executable: "MyApp", tool: "/bin/sh", arguments: ["-c", script])
    }

    func testKeepsTheAppsLines() async throws {
        let console = try console("""
            echo '12:00:01  Acquired tunnel connection to device.'
            echo 'MyApp(7018,0x1ff554440) malloc: early line' >&2
            echo 'Launched application with com.example.MyApp bundle identifier.'
            echo 'Waiting for the application to terminate…'
            echo 'hello from the app'
            echo '2026-10-24 12:00:02.123 MyApp[42:7] [Network] request failed' >&2
            sleep 5
            """)
        try await console.waitForLaunch(timeout: 5)
        var lines: [String] = []
        for _ in 0..<40 where lines.count < 3 {
            try await Task.sleep(nanoseconds: 50_000_000)
            lines = console.lines(since: .distantPast)
        }
        XCTAssertEqual(lines, ["MyApp(7018,0x1ff554440) malloc: early line", "hello from the app",
                               "2026-10-24 12:00:02.123 MyApp[42:7] [Network] request failed"], "the app can print before devicectl reports the launch")
        XCTAssertEqual(console.lines(since: .distantPast, matching: "network").count, 1)
        XCTAssertEqual(console.lines(since: Date().addingTimeInterval(60)), [])
        XCTAssertTrue(console.isApp("myapp"))
        XCTAssertTrue(console.isApp("com.example.MyApp"))
        XCTAssertFalse(console.isApp("SpringBoard"))
        XCTAssertTrue(console.isRunning)
        console.stop()
    }

    func testAFailedLaunchThrowsDevicectlsError() async throws {
        let console = try console("""
            echo '12:00:01  Acquired tunnel connection to device.'
            echo 'ERROR: The application failed to launch. (com.apple.dt.CoreDeviceError error 10002 (0x2712))' >&2
            echo '       BundleIdentifier = com.example.MyApp' >&2
            exit 1
            """)
        do {
            try await console.waitForLaunch(timeout: 5)
            XCTFail("the launch failed")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "Could not launch com.example.MyApp: The application failed to launch. (com.apple.dt.CoreDeviceError error 10002 (0x2712))")
        }
    }
}

@MainActor
final class PhoneToolboxTests: XCTestCase {
    final class PhoneHost: DeviceHost {
        let phone = DeviceInfo(id: "E3F4", name: "iPhone (2)", platform: .ios, kind: .physical, os: "iOS 18.7.8", state: .booted, wireless: true)
        lazy var driver = FakeDevice(phone)
        var sessionDeviceID: String? = "E3F4"
        func listDevices() async throws -> [DeviceInfo] { [phone] }
        func use(_ device: DeviceInfo, reveal: Bool) throws -> DeviceDriver { driver }
    }

    func testPhonesTakeInputLikeSimulators() async throws {
        let host = PhoneHost()
        let tap = await DeviceToolbox.call("device_tap", ["text": "General"], host: host)
        XCTAssertFalse(tap.isError, tap.text)
        XCTAssertEqual(host.driver.gestures.count, 1)
        let typed = await DeviceToolbox.call("device_type", ["text": "hi", "clear": true], host: host)
        XCTAssertFalse(typed.isError, typed.text)
        XCTAssertEqual(host.driver.typed, ["hi"])
        XCTAssertEqual(host.driver.keys, [.selectAll, .delete])
        host.driver.tree = UITree(root: UIElement(role: "Application", label: "SpringBoard", frame: .zero))
        let launch = await DeviceToolbox.call("device_launch", ["app_id": "com.example.app"], host: host)
        XCTAssertTrue(launch.text.hasPrefix("Launched com.example.app"), launch.text)
        let shot = await DeviceToolbox.call("device_screenshot", [:], host: host)
        XCTAssertEqual(shot.text, "Screenshot of iPhone (2) · iOS 18.7.8 (402×874 points; use these pixel coordinates as x and y).")
        let list = await DeviceToolbox.call("device_list", [:], host: host)
        XCTAssertEqual(list.text, "- iPhone (2) · iOS 18.7.8 · Wi-Fi · running · id E3F4 · this session's device")
        let dark = await DeviceToolbox.call("device_set", ["appearance": "dark"], host: host)
        XCTAssertTrue(dark.isError)
        XCTAssertTrue(dark.text.contains("physical iPhone's settings"), dark.text)
        let android = DeviceInfo(id: "X", name: "Pixel", platform: .android, kind: .physical, os: "Android 16", state: .booted)
        XCTAssertNil(DeviceSetting.appearance(dark: true).unsupported(on: android), "Android phones still take settings")
    }
}

/// Reads a real phone, without changing anything on it. Run with VIBER_LIVE_IPHONE=1 and an iPhone nearby.
final class LiveDevicectlTests: XCTestCase {
    func testListsAPhoneAndReadsItsScreenSize() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VIBER_LIVE_IPHONE"] == "1", "set VIBER_LIVE_IPHONE=1 to run")
        let phones = await Devicectl.phones()
        let phone = try XCTUnwrap(phones.first { $0.notReady == nil }, "no nearby iPhone that is ready")
        XCTAssertNotNil(phone.info.serial)
        let displays = try await Devicectl.displays(phone.info.id)
        XCTAssertGreaterThan(displays.scale, 1)
        XCTAssertGreaterThan(displays.pixels.height, displays.pixels.width, "natural orientation is portrait")
    }
}
