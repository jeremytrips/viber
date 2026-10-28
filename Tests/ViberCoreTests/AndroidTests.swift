import CoreGraphics
import XCTest
@testable import ViberCore

/// Real output captured from a Pixel 8 AVD (Android 17, 1080×2400 at 420 dpi): Settings, Network & internet with
/// Airplane mode on, and the settings search with "hello" typed.
func androidFixture(_ name: String, _ ext: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/Android"), "\(name).\(ext)")
    return try Data(contentsOf: url)
}

final class AdbCatalogTests: XCTestCase {
    func testParsesAdbDevices() {
        let output = """
            * daemon not running; starting now at tcp:5037
            List of devices attached
            emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
            emulator-5556          offline transport_id:3
            R58M123ABC             unauthorized usb:1-1 transport_id:2
            0A281FDD4002AB         device usb:2-1 product:husky model:Pixel_8_Pro device:husky transport_id:4
            ZY22                   no permissions (missing udev rules?); see [http://developer.android.com/tools/device.html] usb:1-2

            """
        let devices = Adb.parseDevices(output)
        XCTAssertEqual(devices.map(\.serial), ["emulator-5554", "emulator-5556", "R58M123ABC", "0A281FDD4002AB", "ZY22"])
        XCTAssertEqual(devices.map(\.state), ["device", "offline", "unauthorized", "device", "no permissions"])
        XCTAssertEqual(devices[3].model, "Pixel 8 Pro")
        XCTAssertTrue(devices[0].isEmulator && devices[0].isReady)
        XCTAssertFalse(devices[2].isEmulator || devices[2].isReady)
        XCTAssertTrue(Adb.notReadyReason("unauthorized").contains("allow USB debugging"))
    }

    func testReadsAVDs() throws {
        let ini = Adb.parseIni(String(decoding: try androidFixture("Viber_Pixel", "ini"), as: UTF8.self))
        let config = Adb.parseIni(String(decoding: try androidFixture("config", "ini"), as: UTF8.self))
        let avd = Adb.avd(name: "Viber_Pixel", ini: ini, config: config)
        XCTAssertEqual(avd, AVD(name: "Viber_Pixel", displayName: "Viber Pixel", api: "37.0", hardware: "pixel_8"))
        XCTAssertEqual(Adb.avd(name: "P", ini: [:], config: ["avd.ini.displayname": "Pixel 8 API 35", "image.sysdir.1": "system-images/android-35/google_apis/arm64-v8a/"]),
                       AVD(name: "P", displayName: "Pixel 8 API 35", api: "35", hardware: nil))
        XCTAssertEqual(Adb.androidVersion(api: "37.0"), "Android 17")
        XCTAssertEqual(Adb.androidVersion(api: "36.1"), "Android 16")
        XCTAssertEqual(Adb.androidVersion(api: "32"), "Android 12L")
        XCTAssertEqual(Adb.androidVersion(api: "99"), "API 99")
    }

    func testListsAVDsFromTheirFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("viber-avd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Tab.avd"), withIntermediateDirectories: true)
        try "path=/nowhere/Tab.avd\ntarget=android-36\n".write(to: home.appendingPathComponent("Tab.ini"), atomically: true, encoding: .utf8)
        try "hw.device.name=pixel_tablet\navd.ini.displayname=Pixel Tablet\n".write(to: home.appendingPathComponent("Tab.avd/config.ini"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Adb.listAVDs(in: home), [AVD(name: "Tab", displayName: "Pixel Tablet", api: "36", hardware: "pixel_tablet")])
    }

    func testMixedPlatformsSortIOSFirstAndNeverPreferAPhone() {
        let devices = [
            DeviceInfo(id: "tab", name: "Pixel Tablet", platform: .android, kind: .emulator, os: "Android 16", state: .shutdown, typeIdentifier: "pixel_tablet"),
            DeviceInfo(id: "avd", name: "Pixel 8", platform: .android, kind: .emulator, os: "Android 17", state: .shutdown, typeIdentifier: "pixel_8"),
            DeviceInfo(id: "usb", name: "Pixel 9", platform: .android, kind: .physical, os: "Android 16", state: .booted, serial: "usb"),
            DeviceInfo(id: "ios", name: "iPhone 17", platform: .ios, kind: .simulator, os: "iOS 26.5", state: .shutdown),
        ]
        XCTAssertEqual(DeviceCatalog.sorted(devices).map(\.id), ["usb", "ios", "avd", "tab"])
        XCTAssertEqual(DeviceCatalog.preferred(devices)?.id, "ios", "a running USB phone is not picked on its own")
        XCTAssertFalse(devices[0].isPhone)
        XCTAssertTrue(devices[1].isPhone)
        XCTAssertEqual(DeviceCatalog.match("pixel 8", in: devices)?.id, "avd")
        XCTAssertEqual(DeviceCatalog.match("android 17", in: devices)?.id, "avd")
        var booted = devices
        booted[1].state = .booted
        XCTAssertEqual(DeviceCatalog.preferred(booted)?.id, "avd", "a running emulator beats an iPhone that is off")
    }

    func testMetrics() {
        let plain = Adb.parseMetrics("Physical size: 1080x2400\nPhysical density: 420\n")
        XCTAssertEqual(plain?.size, CGSize(width: 1080, height: 2400))
        XCTAssertEqual(plain?.density, 420)
        let overridden = Adb.parseMetrics("Physical size: 1080x2400\nOverride size: 720x1600\nPhysical density: 420\nOverride density: 280")
        XCTAssertEqual(overridden?.size, CGSize(width: 720, height: 1600))
        XCTAssertEqual(overridden?.density, 280)
        XCTAssertNil(Adb.parseMetrics("nothing"))
    }

    func testCommands() {
        XCTAssertEqual(Adb.quote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(Adb.launchCommand(component: "com.x/.Main", arguments: ["--es", "k", "a b"], terminateRunning: true),
                       "am start -W -S -n 'com.x/.Main' '--es' 'k' 'a b'")
        XCTAssertEqual(Adb.openURLCommand("myapp://x?a=1&b=2"), "am start -W -a android.intent.action.VIEW -d 'myapp://x?a=1&b=2'")
        XCTAssertEqual(Adb.localPort("http://localhost:5173/"), 5173)
        XCTAssertEqual(Adb.localPort("exp://127.0.0.1:8081"), 8081)
        XCTAssertNil(Adb.localPort("exp://192.168.1.20:8081"))
        XCTAssertEqual(Adb.logArguments(since: 100, pid: "42"), ["logcat", "-d", "-b", "default,crash", "-v", "threadtime", "-T", "100.000", "--pid=42"])
        XCTAssertEqual(Adb.textCommand("a b%"), #"input text 'a%sb\%'"#)
        XCTAssertEqual(Adb.keyCommand(29, meta: [113]), "input keycombination 113 29")
        XCTAssertEqual(Adb.freeEmulatorPort(used: ["emulator-5554", "R58M"]), 5556)
        XCTAssertEqual(Adb.emulatorArguments(avd: "Pixel_8", port: 5556), ["-avd", "Pixel_8", "-port", "5556", "-no-window", "-no-boot-anim"])
        XCTAssertEqual(Adb.resolvedComponent("priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true\ncom.android.settings/.Settings\n"),
                       "com.android.settings/.Settings")
        XCTAssertNil(Adb.resolvedComponent("No activity found\n"))
        XCTAssertTrue(Adb.uiDumpCommand(thorough: false).contains("uiautomator dump --compressed /data/local/tmp/viber-ui.xml"))
    }

    func testSettingCommands() {
        XCTAssertEqual(Adb.nightModeCommand(dark: true), "cmd uimode night yes")
        XCTAssertEqual(Adb.geoFixArguments(latitude: 52.3731, longitude: 4.8922), ["emu", "geo", "fix", "4.892200", "52.373100"], "longitude first")
        XCTAssertEqual(Adb.permissions(for: .camera), ["android.permission.CAMERA"])
        XCTAssertEqual(Adb.permissions(for: .location_always).last, "android.permission.ACCESS_BACKGROUND_LOCATION")
        XCTAssertEqual(Adb.permissions(for: .reminders), [])
        let all = Adb.permissions(for: .all)
        XCTAssertEqual(Set(all).count, all.count, "no duplicates")
        for service in PrivacyService.allCases { XCTAssertTrue(Set(Adb.permissions(for: service)).isSubset(of: all), "\(service)") }
        let clean = Adb.statusBarCommand(clean: true)
        XCTAssertTrue(clean.hasPrefix("settings put global sysui_demo_allowed 1 && am broadcast -a com.android.systemui.demo -e command exit && am broadcast -a com.android.systemui.demo -e command enter && "), clean)
        XCTAssertTrue(clean.contains("-e command clock -e hhmm 0941"))
        XCTAssertTrue(clean.contains("-e command network -e mobile show -e datatype none -e level 4"), "older SystemUIs get no slot: " + clean)
        let newPipeline = Adb.statusBarCommand(clean: true, newMobilePipeline: true)
        XCTAssertTrue(newPipeline.contains("-e command network -e mobile show -e slot 941 -e datatype none -e level 4"), "not the real SIM's subscription 1: " + newPipeline)
        let dump = """
              receivers=[BatteryControllerImplGoogle, WifiRepositorySwitcher$isDemoMode$1$callback$1, MobileRepositorySwitcher$isDemoMode$1$callback$1, StatusBarIconControllerImpl]
            """
        XCTAssertTrue(Adb.usesNewMobilePipeline(demoModeDump: dump))
        XCTAssertFalse(Adb.usesNewMobilePipeline(demoModeDump: "receivers=[NetworkControllerImpl, StatusBarIconControllerImpl]"))
        XCTAssertFalse(Adb.usesNewMobilePipeline(demoModeDump: ""))
        XCTAssertEqual(Adb.statusBarCommand(clean: false), "am broadcast -a com.android.systemui.demo -e command exit")
    }

    func testRequestedPermissionsFromDumpsys() {
        let dumpsys = """
            Packages:
              Package [com.x] (6fa6d3e):
                requested permissions:
                  android.permission.CAMERA
                  android.permission.READ_EXTERNAL_STORAGE, maxSdkVersion=32
                install permissions:
                  android.permission.INTERNET: granted=true
              Package [com.x] (1b2c3d4):
                requested permissions:
                  android.permission.ACCESS_FINE_LOCATION
                User 0: ceDataInode=0 installed=true
                  runtime permissions:
                    android.permission.RECORD_AUDIO: granted=false
            """
        XCTAssertEqual(Adb.requestedPermissions(dumpsys: dumpsys),
                       ["android.permission.CAMERA", "android.permission.READ_EXTERNAL_STORAGE", "android.permission.ACCESS_FINE_LOCATION"])
        XCTAssertEqual(Adb.requestedPermissions(dumpsys: "Unable to find package: com.nope"), [])
    }

    func testDetectsAPKs() {
        let gradle = "> Task :app:assembleDebug\nAPK: /Users/me/app/app/build/outputs/apk/debug/app-debug.apk\nBUILD SUCCESSFUL in 9s"
        XCTAssertEqual(DeviceArtifact.detect(in: gradle), .apk("/Users/me/app/app/build/outputs/apk/debug/app-debug.apk"))
        XCTAssertEqual(DeviceArtifact.apk("/x/app-debug.apk").label, "Run app-debug.apk on device")
        XCTAssertEqual(DeviceArtifact.apk("/x/app-debug.apk").platform, .android)
        XCTAssertNil(DeviceArtifact.expo("exp://x").platform)
        XCTAssertNil(DeviceArtifact.devClient("exp+x://expo-development-client/?url=x").platform)
        let both = "/a/build/outputs/apk/debug/app-debug.apk\n/a/build/outputs/apk/release/app-release.apk"
        XCTAssertEqual(DeviceArtifact.detect(in: both), .apk("/a/build/outputs/apk/release/app-release.apk"))
    }
}

final class AndroidTreeTests: XCTestCase {
    static let scale: CGFloat = 420.0 / 160

    func testUIAutomatorSettings() throws {
        let tree = try XCTUnwrap(AndroidTree.parseUIAutomator(try androidFixture("settings", "xml"), scale: Self.scale))
        XCTAssertEqual(tree.app, "com.android.settings")
        XCTAssertEqual(tree.screen.size.width, 1080 / Self.scale, accuracy: 0.01)
        let network = try XCTUnwrap(tree.find("Network & internet"))
        XCTAssertEqual(network.role, "StaticText")
        XCTAssertEqual(network.identifier, "title", "android:id/title loses its package")
        XCTAssertEqual(network.frame.minX, 221 / Self.scale, accuracy: 0.01)
        XCTAssertEqual(network.frame.height, 57 / Self.scale, accuracy: 0.01)
        XCTAssertTrue(tree.isOnScreen(network))
        XCTAssertTrue(tree.elements.contains { $0.role == "Button" && $0.identifier == "search_action_bar" }, "a clickable layout is a button")
        let row = try XCTUnwrap(tree.element(at: network.center))
        XCTAssertEqual(row.label, "Network & internet", "picking finds the innermost named element")
        XCTAssertFalse(tree.isEmpty)
        XCTAssertNil(AndroidTree.parseUIAutomator(Data("ERROR: could not get idle state.".utf8), scale: Self.scale))
    }

    func testUIAutomatorSwitchAndTextField() throws {
        let network = try XCTUnwrap(AndroidTree.parseUIAutomator(try androidFixture("network", "xml"), scale: Self.scale))
        let toggle = try XCTUnwrap(network.elements.first { $0.role == "Switch" })
        XCTAssertEqual(toggle.value, "0")
        XCTAssertEqual(toggle.identifier, "switchWidget")
        XCTAssertTrue(toggle.isInteractive)
        let search = try XCTUnwrap(AndroidTree.parseUIAutomator(try androidFixture("search", "xml"), scale: Self.scale))
        let field = try XCTUnwrap(search.elements.first { $0.role == "TextField" })
        XCTAssertEqual(field.value, "hello")
        XCTAssertEqual(field.label, "Search settings", "the hint names an empty-looking field")
        XCTAssertEqual(search.find("search settings")?.role, "TextField")
    }

    func testUIAutomatorOutputWithStatusLine() {
        let output = Data("UI hierchary dumped to: /data/local/tmp/viber-ui.xml\n<?xml version='1.0' ?><hierarchy rotation=\"0\"></hierarchy>".utf8)
        XCTAssertEqual(AndroidTree.xml(in: output).map { String(decoding: $0, as: UTF8.self) }, "<?xml version='1.0' ?><hierarchy rotation=\"0\"></hierarchy>")
        XCTAssertNil(AndroidTree.xml(in: Data("Killed".utf8)))
    }

    func testAndroidLayoutJSON() throws {
        let settings = try XCTUnwrap(AndroidTree.parseLayout(try androidFixture("settings", "json"), scale: Self.scale))
        XCTAssertEqual(settings.app, "com.android.settings")
        XCTAssertEqual(settings.find("Network & internet")?.role, "StaticText")
        let network = try XCTUnwrap(AndroidTree.parseLayout(try androidFixture("network", "json"), scale: Self.scale))
        XCTAssertEqual(network.elements.first { $0.role == "Switch" }?.value, "1", "Airplane mode was on")
        let search = try XCTUnwrap(AndroidTree.parseLayout(try androidFixture("search", "json"), scale: Self.scale))
        let field = try XCTUnwrap(search.elements.first { $0.role == "TextField" })
        XCTAssertEqual(field.value, "hello")
        XCTAssertFalse(search.elements.contains { $0.frame.minY >= 1517 / Self.scale && $0.label == "q" }, "the keyboard window is left out")
        let noisy = Data("Installing layout instrumentation server...\n".utf8) + (try androidFixture("settings", "json"))
        XCTAssertEqual(AndroidTree.parseLayout(noisy, scale: Self.scale)?.app, "com.android.settings")
    }

    func testRoles() {
        func role(_ c: String, clickable: Bool = false, checkable: Bool = false, password: Bool = false) -> String {
            AndroidTree.role(className: c, clickable: clickable, checkable: checkable, editable: false, password: password, scrollable: false)
        }
        XCTAssertEqual(role("android.widget.ImageButton"), "Button")
        XCTAssertEqual(role("android.widget.EditText", password: true), "SecureTextField")
        XCTAssertEqual(role("androidx.appcompat.widget.SwitchCompat"), "Switch")
        XCTAssertEqual(role("com.google.android.material.checkbox.MaterialCheckBox"), "CheckBox")
        XCTAssertEqual(role("android.view.View", clickable: true), "Button", "Compose clickables")
        XCTAssertEqual(role("android.view.View"), "Group")
        XCTAssertEqual(role("android.widget.TextView"), "StaticText")
        XCTAssertEqual(role("androidx.recyclerview.widget.RecyclerView"), "ScrollView")
    }
}

final class ScrcpyProtocolTests: XCTestCase {
    // The expected bytes are scrcpy's own (app/tests/test_control_msg_serialize.c at v5.0.1).
    func testKeycode() {
        XCTAssertEqual([UInt8](Scrcpy.keycode(.up, AndroidKey.enter, repeat: 5, meta: 0x41)),
                       [0, 0x01, 0, 0, 0, 0x42, 0, 0, 0, 0x05, 0, 0, 0, 0x41])
    }

    func testText() {
        XCTAssertEqual([UInt8](Scrcpy.text("hello, world!")[0]), [1, 0, 0, 0, 0x0d] + Array("hello, world!".utf8))
        let long = Scrcpy.text(String(repeating: "a", count: 700))
        XCTAssertEqual(long.map(\.count), [305, 305, 105])
        let accents = Scrcpy.text(String(repeating: "é", count: 200))
        XCTAssertEqual(accents.map { $0.count - 5 }, [300, 100], "split between characters, never inside one")
        XCTAssertTrue(Scrcpy.text("").isEmpty)
    }

    func testTouch() {
        let bytes = [UInt8](Scrcpy.touch(.down, x: 100, y: 200, width: 1080, height: 1920, pointer: 0x1234_5678_8765_4321))
        XCTAssertEqual(bytes, [2, 0x00, 0x12, 0x34, 0x56, 0x78, 0x87, 0x65, 0x43, 0x21, 0, 0, 0, 0x64, 0, 0, 0, 0xc8,
                               0x04, 0x38, 0x07, 0x80, 0xff, 0xff, 0, 0, 0, 0, 0, 0, 0, 0])
        let up = [UInt8](Scrcpy.touch(.up, x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(up.count, 32)
        XCTAssertEqual(Array(up[2...9]), [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe], "a finger, not the mouse")
        XCTAssertEqual(Array(up[22...23]), [0, 0], "no pressure when lifted")
    }

    func testClipboardAndReset() {
        XCTAssertEqual([UInt8](Scrcpy.setClipboard("hello, world!", paste: true, sequence: 0x0102_0304_0506_0708)),
                       [9, 1, 2, 3, 4, 5, 6, 7, 8, 1, 0, 0, 0, 0x0d] + Array("hello, world!".utf8))
        XCTAssertEqual([UInt8](Scrcpy.resetVideo()), [17])
    }

    func testHeaders() {
        XCTAssertEqual(Scrcpy.header([0x80, 0, 0, 0, 0, 0, 0x04, 0x38, 0, 0, 0x09, 0x60]), .session(width: 1080, height: 2400))
        XCTAssertEqual(Scrcpy.header([0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x20]), .media(config: true, keyFrame: false, pts: 0, size: 32))
        XCTAssertEqual(Scrcpy.header([0x20, 0, 0, 0, 0, 0x0F, 0x42, 0x40, 0, 0x01, 0, 0]), .media(config: false, keyFrame: true, pts: 1_000_000, size: 65536))
        XCTAssertNil(Scrcpy.header([0, 0, 0]))
    }

    func testServerCommand() {
        XCTAssertEqual(Scrcpy.socketName(scid: 0x1234), "scrcpy_00001234")
        let command = Scrcpy.serverCommand(scid: 0x1234, maxSize: 1600)
        XCTAssertTrue(command.hasPrefix("CLASSPATH=/data/local/tmp/viber-scrcpy-server.jar app_process / com.genymobile.scrcpy.Server 5.0.1 scid=00001234 "))
        XCTAssertTrue(command.contains("tunnel_forward=true") && command.contains("audio=false") && command.contains("max_size=1600"))
        XCTAssertLessThanOrEqual(Scrcpy.randomSCID(), 0x7FFF_FFFF)
    }

    func testKeys() {
        XCTAssertEqual(AndroidKey.code(.back), 4)
        XCTAssertEqual(AndroidKey.code(.app_switch), 187)
        XCTAssertNil(AndroidKey.code(.siri))
        XCTAssertEqual(AndroidKey.code(macKeyCode: 0x33), 67)
        XCTAssertNil(AndroidKey.code(macKeyCode: 0x00), "letters go over as text")
    }
}

final class H264Tests: XCTestCase {
    let stream = Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x09, 0xF0, 0, 0, 1, 0x65, 9, 9])

    func testSplitsNALUnits() {
        XCTAssertEqual(H264.nalUnits(stream).map { [UInt8]($0) }, [[0x67, 1, 2], [0x68, 3], [0x09, 0xF0], [0x65, 9, 9]])
        XCTAssertEqual(H264.nalUnits(Data([1, 2, 3])), [])
    }

    func testParameterSetsAndAVCC() {
        let sets = H264.parameterSets(stream)
        XCTAssertEqual(sets.map { [UInt8]($0.sps) }, [0x67, 1, 2])
        XCTAssertEqual(sets.map { [UInt8]($0.pps) }, [0x68, 3])
        XCTAssertEqual([UInt8](H264.avcc(stream)), [0, 0, 0, 3, 0x65, 9, 9], "parameter sets and delimiters stay out of samples")
        XCTAssertNil(H264.parameterSets(Data([0, 0, 1, 0x65, 1])))
    }
}

@MainActor
final class AndroidToolboxTests: XCTestCase {
    func testAndroidDevicesUseDpAndStripLogcatBanners() async throws {
        let pixel = DeviceInfo(id: "Pixel_8", name: "Pixel 8", platform: .android, kind: .emulator, os: "Android 17", state: .booted, serial: "emulator-5554")
        let host = FakeHost([pixel])
        let shot = await DeviceToolbox.call("device_screenshot", [:], host: host)
        XCTAssertTrue(shot.text.contains("402×874 dp"), shot.text)
        let driver = try XCTUnwrap(host.drivers["Pixel_8"])
        driver.logText = "--------- beginning of main\n10-24 11:45:00.000  100  100 I Tag: hello\n--------- beginning of crash"
        let logs = await DeviceToolbox.call("device_logs", [:], host: host)
        XCTAssertTrue(logs.text.hasSuffix("instructions):\n10-24 11:45:00.000  100  100 I Tag: hello"), logs.text)
        let back = await DeviceToolbox.call("device_press", ["button": "back"], host: host)
        XCTAssertFalse(back.isError)
        XCTAssertEqual(driver.pressed, [.back])
        let list = await DeviceToolbox.call("device_list", [:], host: host)
        XCTAssertTrue(list.text.contains("Pixel 8 · Android 17 · running · id Pixel_8"), list.text)
    }

    func testSetOnAndroid() async throws {
        let pixel = DeviceInfo(id: "Pixel_8", name: "Pixel 8", platform: .android, kind: .emulator, os: "Android 17", state: .booted, serial: "emulator-5554")
        let phone = DeviceInfo(id: "R58M", name: "Galaxy", platform: .android, kind: .physical, os: "Android 15", state: .booted, serial: "R58M")
        let host = FakeHost([pixel, phone])
        let camera = await DeviceToolbox.call("device_set", ["grant": ["camera"], "app_id": "com.x", "latitude": 1, "longitude": 2], host: host)
        XCTAssertFalse(camera.isError, camera.text)
        XCTAssertEqual(host.drivers["Pixel_8"]?.settings, [.location(latitude: 1, longitude: 2), .grant(.camera, app: "com.x")])
        let reminders = await DeviceToolbox.call("device_set", ["grant": ["reminders"], "app_id": "com.x"], host: host)
        XCTAssertEqual(reminders.text, "Android has no permission matching reminders. Nothing was changed.")
        host.sessionDeviceID = "R58M"
        let location = await DeviceToolbox.call("device_set", ["latitude": 1, "longitude": 2], host: host)
        XCTAssertEqual(location.text, "The location can only be set on simulators and emulators. Nothing was changed.")
        let dark = await DeviceToolbox.call("device_set", ["appearance": "dark"], host: host)
        XCTAssertFalse(dark.isError, "a phone can switch to dark mode (after the user approves)")
    }
}

/// Drives a running Android emulator. Run with VIBER_LIVE_ANDROID=1 (needs the Android SDK and a booted AVD).
final class LiveAdbTests: XCTestCase {
    func runningEmulator() async throws -> (DeviceInfo, String) {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VIBER_LIVE_ANDROID"] == "1", "set VIBER_LIVE_ANDROID=1 to run")
        let devices = await Adb.devices()
        // ANDROID_SERIAL picks one when another session has an emulator of its own running.
        let wanted = ProcessInfo.processInfo.environment["ANDROID_SERIAL"]
        let emulator = try XCTUnwrap(devices.first { $0.kind == .emulator && $0.isBooted && (wanted == nil || $0.serial == wanted) }, "boot an AVD first: \(devices)")
        return (emulator, try XCTUnwrap(emulator.serial))
    }

    func testListsAndReadsTheScreen() async throws {
        let (emulator, serial) = try await runningEmulator()
        XCTAssertTrue(emulator.os.hasPrefix("Android "), emulator.os)
        let home = await Adb.homePackage(serial)
        XCTAssertNotNil(home)
        let metrics = try await Adb.metrics(serial)
        XCTAssertGreaterThan(metrics.density, 100)
        let png = try await Adb.screencap(serial)
        XCTAssertGreaterThan(png.count, 10_000)
        try await Adb.launch(serial, package: "com.android.settings", arguments: [], terminateRunning: true)
        let xml = try await Adb.uiDump(serial, thorough: false)
        let tree = try XCTUnwrap(AndroidTree.parseUIAutomator(xml, scale: metrics.density / 160))
        XCTAssertEqual(tree.app, "com.android.settings")
        XCTAssertFalse(tree.isEmpty)
        let logs = try await Adb.logs(serial, process: "com.android.settings", seconds: 30)
        XCTAssertFalse(logs.isEmpty)
    }

    func testSettings() async throws {
        let (_, serial) = try await runningEmulator()
        func shell(_ command: String) async -> String { await Adb.run(serial, ["shell", command]).output }
        let maps = "com.google.android.apps.maps"
        func mapsHasLocation() async -> Bool { await shell("dumpsys package \(maps)").contains("ACCESS_FINE_LOCATION: granted=true") }
        let wasDark = await shell("cmd uimode night").contains("yes")
        let hadLocation = await mapsHasLocation()
        var failure: Error?
        do {
            try await Adb.set(serial, .appearance(dark: true))
            let night = await shell("cmd uimode night")
            XCTAssertTrue(night.contains("Night mode: yes"), night)
            try await Adb.set(serial, .location(latitude: 52.3731, longitude: 4.8922))
            try await Adb.set(serial, .grant(.location, app: maps))
            let granted = await mapsHasLocation()
            XCTAssertTrue(granted)
            do {
                try await Adb.set(serial, .grant(.motion, app: "com.android.camera2"))
                XCTFail("Camera2 doesn't ask for ACTIVITY_RECOGNITION, so nothing can be granted")
            } catch {
                XCTAssertTrue(error.localizedDescription.hasPrefix("com.android.camera2 doesn't ask for motion"), error.localizedDescription)
            }
            do {
                try await Adb.set(serial, .grant(.camera, app: "com.example.nope"))
                XCTFail("not installed")
            } catch {
                XCTAssertEqual(error.localizedDescription, "com.example.nope is not installed on the device.")
            }
            try await Adb.set(serial, .statusBar(clean: true))
            let demo = await shell("settings get global sysui_demo_allowed")
            XCTAssertEqual(demo, "1")
            let sysui = "dumpsys activity service com.android.systemui/.SystemUIService"
            if Adb.usesNewMobilePipeline(demoModeDump: await shell("\(sysui) dependency DUMPABLE DemoModeController")) {
                let dumpables = await shell("\(sysui) --list")
                XCTAssertTrue(dumpables.contains("DemoMobileConnectionLog[941]"), "the demo cell signal has a subscription of its own")
            }
        } catch {
            failure = error
        }
        if ProcessInfo.processInfo.environment["VIBER_KEEP_SETTINGS"] != "1" {
            // Put the emulator back the way it was.
            _ = await shell(Adb.nightModeCommand(dark: wasDark))
            _ = await shell(Adb.statusBarCommand(clean: false))
            if !hadLocation { _ = await shell("pm revoke \(maps) android.permission.ACCESS_FINE_LOCATION; pm revoke \(maps) android.permission.ACCESS_COARSE_LOCATION") }
        }
        if let failure { throw failure }
    }

    func testScrcpyStreamsDecodedFrames() async throws {
        let (_, serial) = try await runningEmulator()
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let jar = repo.appendingPathComponent(".build/scrcpy/scrcpy-server-v\(Scrcpy.version)").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: jar), "run Scripts/fetch-scrcpy-server.sh first")
        let session = ScrcpySession(serial: serial)
        let frame = expectation(description: "a decoded frame")
        frame.assertForOverFulfill = false
        var frameSize: CGSize?
        session.onFrame = { buffer, _ in
            frameSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer), "frames are IOSurfaces Core Animation can show")
            frame.fulfill()
        }
        let size = try await session.start(jar: jar)
        XCTAssertLessThanOrEqual(max(size.width, size.height), 1600)
        // Something has to change on screen for a frame to come: open Settings.
        try await Adb.launch(serial, package: "com.android.settings", arguments: [], terminateRunning: true)
        await fulfillment(of: [frame], timeout: 15)
        XCTAssertEqual(frameSize, size)
        session.send(Scrcpy.keycode(.down, AndroidKey.home))
        session.send(Scrcpy.keycode(.up, AndroidKey.home))
        session.stop()
    }
}
