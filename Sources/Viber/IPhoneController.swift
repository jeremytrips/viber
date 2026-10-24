import AppKit
import CoreImage
import CoreVideo
import Observation
import ViberCore

/// A physical iPhone or iPad, on USB or Wi-Fi. devicectl installs and launches apps and keeps their console for the logs;
/// over USB the live screen comes through AVFoundation, the way QuickTime records an iPhone. Nothing public sends touches
/// to a phone or reads its screen's elements, so the panel only shows the screen, and the tools that need input say so.
@MainActor @Observable
final class IPhoneController: DeviceController {
    private(set) var device: DeviceInfo
    /// The screen in points, in its current orientation, once known.
    private(set) var screenSize: CGSize?
    private(set) var isStreaming = false
    private(set) var failure: String?
    private(set) var inputFailure: String?
    var picking = false
    var activity: String?

    @ObservationIgnored var lastTree: UITree?
    @ObservationIgnored let screenView = DeviceScreenView()
    @ObservationIgnored var onPick: ((UIElement, String?) -> Void)?
    @ObservationIgnored private(set) var lastUsed = Date()
    @ObservationIgnored private let changes = ScreenChanges()
    @ObservationIgnored private var screen: IPhoneScreen?
    @ObservationIgnored private var starting: Task<Void, Never>?
    /// The screen in points in its natural orientation, from devicectl. The video may be scaled, so it can't tell.
    @ObservationIgnored private var points: CGSize?
    /// The last two frames, kept so the capture doesn't reuse a buffer the screen still shows.
    @ObservationIgnored private var frame: CVPixelBuffer?
    @ObservationIgnored private var previousFrame: CVPixelBuffer?
    /// The output of each app launched with a console, by bundle id, and the latest of them.
    @ObservationIgnored private var consoles: [String: AppConsole] = [:]
    @ObservationIgnored private var lastConsole: String?
    @ObservationIgnored private var lastApp: String?
    /// Apps installed from here, by bundle id: their URL schemes and executable names.
    @ObservationIgnored private var installed: [String: Devicectl.AppBundle] = [:]

    let booting = false
    let busyNote: String? = nil
    let homeApp: String? = "SpringBoard"
    let toolbarButtons: [DeviceButton] = []
    let canPowerCycle = false
    let canInteract = false
    let externalApp: String? = nil

    init(device: DeviceInfo) {
        self.device = device
        screenView.controller = self
    }

    func openExternally() {}

    func update(_ info: DeviceInfo) {
        let old = device
        device = info
        if old.isBooted && !info.isBooted { stopStream() }
        // Plugged in: try the screen again. Unplugging ends the stream by itself, and devicectl sometimes says Wi-Fi
        // while the cable is in, so a running stream is left alone.
        let pluggedIn = old.wireless && !info.wireless
        if pluggedIn, !isStreaming { failure = nil }
        if info.isBooted && isAttached && (!old.isBooted || pluggedIn) { startStream() }
    }

    /// Reads the screen size once per connection, which also checks that devicectl can reach the phone.
    private func prepare() async throws {
        lastUsed = Date()
        guard device.isBooted else {
            throw DeviceError.failed("\(device.label) is not ready. Call device_open to connect to it.")
        }
        if points == nil {
            let displays = try await Devicectl.displays(device.id)
            points = CGSize(width: displays.pixels.width / displays.scale, height: displays.pixels.height / displays.scale)
            if screenSize == nil { screenSize = points }
        }
    }

    // MARK: Stream

    func startStream() {
        lastUsed = Date()
        guard screen == nil, starting == nil, device.isBooted else { return }
        starting = Task { [weak self] in
            await self?.connect()
            self?.starting = nil
        }
    }

    private func connect() async {
        // Asking for Camera access without this key crashes the app; builds run from .build have no Info.plist.
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
            failure = "Showing a physical iPhone's screen needs the Viber app (Scripts/build-app.sh), which can ask for Camera access."
            return
        }
        // Only a cable carries the screen, but devicectl may say Wi-Fi with the cable in: look briefly anyway.
        let wireless = device.wireless
        guard let capture = await IPhoneScreen.captureDevice(udid: device.serial, name: device.name, timeout: wireless ? 1.5 : 5,
                                                             orOnly: !wireless) else {
            if !Task.isCancelled {
                failure = wireless ? "\(device.name) is connected over Wi-Fi. Connect it with USB to see its screen here; installing and launching apps work either way."
                                   : "macOS doesn't offer \(device.name)'s screen. Unlock the phone, or unplug it and plug it in again."
            }
            return
        }
        guard await IPhoneScreen.cameraAccess() else {
            failure = "macOS hands an iPhone's screen to apps as a camera. Allow Viber in System Settings → Privacy & Security → Camera, then retry."
            return
        }
        _ = try? await prepare()
        let screen = IPhoneScreen(device: capture)
        screen.onFrame = { [weak self] buffer, changed in self?.frameArrived(buffer, changed: changed) }
        screen.onEnd = { [weak self, weak screen] message in
            guard let self, let screen, self.screen === screen else { return }
            self.streamEnded(message)
        }
        do {
            try await screen.start()
            guard !Task.isCancelled, device.isBooted else {
                screen.stop()
                return
            }
            self.screen = screen
            isStreaming = true
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    func stopStream() {
        starting?.cancel()
        starting = nil
        screen?.stop()
        streamEnded(nil)
    }

    private func streamEnded(_ message: String?) {
        screen = nil
        isStreaming = false
        frame = nil
        previousFrame = nil
        screenView.show(nil)
        if let message { failure = message }
    }

    private func readyStream() {
        lastUsed = Date()
        if screen == nil { startStream() }
    }

    private func frameArrived(_ buffer: CVPixelBuffer, changed: Bool) {
        previousFrame = frame
        frame = buffer
        if changed { changes.lastChange = Date() }
        let pixels = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        if let points {
            let landscape = pixels.width > pixels.height
            screenSize = landscape == (points.width > points.height) ? points : CGSize(width: points.height, height: points.width)
        } else {
            screenSize = CGSize(width: pixels.width / 3, height: pixels.height / 3)
        }
        screenView.show(CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue())
    }

    /// The latest frame, starting the stream and waiting for its first frame if needed.
    private func latestFrame() async throws -> CVPixelBuffer {
        try await prepare()
        readyStream()
        let deadline = Date().addingTimeInterval(8)
        while true {
            if let frame { return frame }
            if starting == nil, screen == nil { throw DeviceError.failed(failure ?? "\(device.name)'s screen is not available.") }
            if Date() >= deadline { throw DeviceError.failed("\(device.name)'s screen sent no picture yet. Is the phone unlocked?") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: Device control

    /// Checks that the phone is nearby, trusts this Mac and is in Developer Mode, and connects to it.
    func boot() async throws {
        lastUsed = Date()
        guard let phone = await Devicectl.phones().first(where: { $0.info.id == device.id }) else {
            device.state = .unknown
            stopStream()
            let reason = "\(device.name) is not nearby. Connect it with USB, or unlock it on the same Wi-Fi as this Mac."
            failure = reason
            throw DeviceError.failed(reason)
        }
        update(phone.info)
        if let reason = phone.notReady {
            failure = reason
            throw DeviceError.failed(reason)
        }
        do {
            try await prepare()
        } catch {
            failure = error.localizedDescription
            throw error
        }
        if isStreaming || !device.wireless { failure = nil }
        readyStream()
    }

    func shutdown() async {}

    // MARK: DeviceDriver

    func screenshot() async throws -> (data: Data, width: Int, height: Int) {
        let buffer = try await latestFrame()
        guard let cg = Self.image(buffer) else { throw DeviceError.failed("The screenshot could not be read.") }
        let size = screenSize ?? CGSize(width: cg.width / 3, height: cg.height / 3)
        return try ImageEncoding.jpeg(NSImage(cgImage: cg, size: size), maxWidth: size.width, maxPixels: .greatestFiniteMagnitude)
    }

    func uiTree(thorough: Bool) async throws -> UITree { throw DeviceError.failed(DeviceToolbox.noInput(device)) }
    func gesture(_ path: [CGPoint], duration: TimeInterval) async throws { throw DeviceError.failed(DeviceToolbox.noInput(device)) }
    func type(_ text: String) async throws { throw DeviceError.failed(DeviceToolbox.noInput(device)) }
    func key(_ key: DeviceKey) async throws { throw DeviceError.failed(DeviceToolbox.noInput(device)) }
    func press(_ button: DeviceButton) async throws { throw DeviceError.failed(DeviceToolbox.noInput(device)) }

    func install(_ path: String) async throws -> String {
        try await prepare()
        let bundle = try await Devicectl.install(device.id, app: path)
        installed[bundle.identifier] = bundle
        return bundle.identifier
    }

    func launch(_ app: String, arguments: [String], terminateRunning: Bool) async throws {
        try await prepare()
        if terminateRunning {
            // devicectl stays attached to the app's output until it quits: that output is device_logs on a phone.
            let console = try AppConsole(app: app, executable: installed[app]?.executable, tool: "xcrun",
                                         arguments: ["devicectl"] + Devicectl.launchArguments(device.id, app: app, arguments: arguments,
                                                                                               terminateRunning: true, console: true))
            try await console.waitForLaunch(timeout: 90)
            consoles[app] = console
            lastConsole = app
        } else {
            try await Devicectl.launch(device.id, app: app, arguments: arguments, terminateRunning: false)
        }
        lastApp = app
    }

    func openURL(_ url: String) async throws {
        try await prepare()
        if Devicectl.pointsAtLocalhost(url) {
            throw DeviceError.failed("\(url) points at localhost, which on a physical iPhone is the phone itself. Use this Mac's address on the local network, with the phone on the same Wi-Fi.")
        }
        var schemes: [String: String] = [:]
        for bundle in installed.values { for scheme in bundle.schemes { schemes[scheme] = bundle.identifier } }
        guard let app = Devicectl.opener(for: url, schemes: schemes, lastApp: lastApp) else {
            throw DeviceError.failed("On a physical iPhone, Viber opens web pages in Safari and exp:// links in Expo Go. For other links, install or launch the app that opens them first.")
        }
        try await Devicectl.launch(device.id, app: app, terminateRunning: false, url: url)
    }

    func logs(process: String?, seconds: Int) async throws -> String {
        let process = process.flatMap { $0.isEmpty ? nil : $0 }
        let named = process.flatMap { name in consoles.values.first { $0.isApp(name) } }
        guard let console = named ?? lastConsole.flatMap({ consoles[$0] }) else {
            throw DeviceError.failed("On a physical iPhone, device_logs reads the output of apps device_launch started (the system log needs root). Launch the app, then call device_logs.")
        }
        return console.lines(since: Date().addingTimeInterval(-Double(seconds)), matching: named == nil ? process : nil).joined(separator: "\n")
    }

    /// `DeviceSetting.unsupported(on:)` already refuses every setting on a phone.
    func set(_ setting: DeviceSetting) async throws {
        throw DeviceError.failed(DeviceSetting.appearance(dark: true).unsupported(on: device) ?? "Not on a physical iPhone.")
    }

    func settle(afterAction: Bool) async {
        guard isStreaming else {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return
        }
        await changes.settle(afterAction: afterAction)
    }

    // MARK: The user's mouse and keyboard

    private func refuseInput() {
        lastUsed = Date()
        inputFailure = "Clicks and keys can't reach a physical iPhone. Use the phone itself."
    }

    func userTouch(_ phase: TouchPhase, at ratio: CGPoint) { if phase == .down { refuseInput() } }

    func userKey(_ event: NSEvent, down: Bool) { if down, event.type == .keyDown { refuseInput() } }

    func userScroll(dx: CGFloat, dy: CGFloat, at ratio: CGPoint, ended: Bool) { if !ended, dx != 0 || dy != 0 { refuseInput() } }

    func pasteFromMac() { refuseInput() }

    func pick(at ratio: CGPoint) { picking = false }

    private static let imageContext = CIContext()

    private static func image(_ buffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        return imageContext.createCGImage(image, from: image.extent)
    }

    func copyScreenshot() {
        guard let frame, let cg = Self.image(frame) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: cg, size: screenSize ?? CGSize(width: cg.width, height: cg.height))])
    }

    func screenshotPNG() -> Data? {
        guard let frame, let cg = Self.image(frame) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
