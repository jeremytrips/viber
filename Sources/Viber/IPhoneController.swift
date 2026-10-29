import AppKit
import CoreImage
import CoreVideo
import Observation
import ViberCore

/// A physical iPhone or iPad, on USB or Wi-Fi. devicectl installs and launches apps and keeps their console for the logs;
/// over USB the live screen comes through AVFoundation, the way QuickTime records an iPhone. Touches, keys, buttons and
/// the screen's elements go through WebDriverAgent, an XCUITest runner Viber builds and starts on the phone on first use.
@MainActor @Observable
final class IPhoneController: DeviceController {
    private(set) var device: DeviceInfo
    /// The screen in points, in its current orientation, once known.
    private(set) var screenSize: CGSize?
    private(set) var isStreaming = false
    private(set) var failure: String?
    private(set) var inputFailure: String?
    /// What starting WebDriverAgent is doing.
    private(set) var busyNote: String?
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
    /// WebDriverAgent's server on the phone once it answers, the xcodebuild run that keeps it up, and its start.
    @ObservationIgnored private var agentClient: WebDriverAgentClient?
    @ObservationIgnored private var agentRun: WebDriverAgentRun?
    @ObservationIgnored private var agentStart: Task<WebDriverAgentClient, Error>?
    /// The user's touches and keys, sent one after another.
    @ObservationIgnored private var userInputs: Task<Void, Never>?
    @ObservationIgnored private var touchStart: (ratio: CGPoint, at: Date)?
    @ObservationIgnored private var touchLast = CGPoint.zero
    @ObservationIgnored private var scrollStart: CGPoint?
    @ObservationIgnored private var scrollDelta = CGSize.zero

    let booting = false
    let homeApp: String? = "SpringBoard"
    let toolbarButtons: [DeviceButton] = [.home]
    let canPowerCycle = false
    let externalApp: String? = nil

    init(device: DeviceInfo) {
        self.device = device
        screenView.controller = self
    }

    func openExternally() {}

    func update(_ info: DeviceInfo) {
        let old = device
        device = info
        if old.isBooted && !info.isBooted {
            stopStream()
            stopAgent()
        }
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

    /// From the live screen, else (over Wi-Fi) from WebDriverAgent when it is already running.
    func screenshot() async throws -> (data: Data, width: Int, height: Int) {
        let cg: CGImage
        do {
            let buffer = try await latestFrame()
            guard let image = Self.image(buffer) else { throw DeviceError.failed("The screenshot could not be read.") }
            cg = image
        } catch {
            guard let client = agentClient, await client.isUp(),
                  let png = try? await client.screenshot(), let image = NSBitmapImageRep(data: png)?.cgImage else { throw error }
            cg = image
        }
        let size = screenSize ?? CGSize(width: cg.width / 3, height: cg.height / 3)
        return try ImageEncoding.jpeg(NSImage(cgImage: cg, size: size), maxWidth: size.width, maxPixels: .greatestFiniteMagnitude)
    }

    func uiTree(thorough: Bool) async throws -> UITree { try await agent().tree() }

    func gesture(_ path: [CGPoint], duration: TimeInterval) async throws { try await agent().gesture(path, duration: duration) }

    func type(_ text: String) async throws { try await agent().type(text) }

    func key(_ key: DeviceKey) async throws {
        let client = try await agent()
        switch key {
        case .returnKey: try await client.type("\n")
        case .delete: try await client.type("\u{8}")
        // device_type's clear selects all, then deletes. XCUITest can't select all on a phone, so this empties the
        // focused field, and the delete after it finds nothing left.
        case .selectAll: try await client.clearFocused()
        }
    }

    func press(_ button: DeviceButton) async throws {
        switch button {
        case .home: try await agent().home()
        case .lock: try await agent().lock()
        case .volume_up: try await agent().pressButton("volumeup")
        case .volume_down: try await agent().pressButton("volumedown")
        case .siri, .back, .app_switch:
            throw DeviceError.failed("Viber can't press \(button.rawValue.replacingOccurrences(of: "_", with: " ")) on a physical iPhone; it presses home, lock, volume up and volume down.")
        }
    }

    // MARK: WebDriverAgent

    /// WebDriverAgent's server on the phone, starting it if it isn't up: building it the first time, which takes minutes.
    private func agent() async throws -> WebDriverAgentClient {
        lastUsed = Date()
        if let client = agentClient, await client.isUp() { return client }
        agentClient = nil
        if let agentStart { return try await agentStart.value }
        let start = Task { try await self.startAgent() }
        agentStart = start
        defer { agentStart = nil; busyNote = nil }
        do {
            let client = try await start.value
            agentClient = client
            return client
        } catch {
            stopAgent()
            throw error
        }
    }

    private func startAgent() async throws -> WebDriverAgentClient {
        try await prepare()
        // One from before, such as before Viber restarted, may still be running.
        if let address = try? await Devicectl.tunnelAddress(device.id), let url = WebDriverAgent.tunnelURL(address) {
            let client = WebDriverAgentClient(base: url)
            if await client.isUp() { return client }
        }
        let xctestrun = try await WebDriverAgent.xctestrun { [weak self] note in self?.busyNote = note }
        busyNote = "Starting WebDriverAgent on \(device.name)…"
        let run = try WebDriverAgentRun(xctestrun: xctestrun, udid: device.serial ?? device.id)
        agentRun = run
        // xcodebuild installs it, launches it and opens the tunnel; the server then prints where it listens.
        let deadline = Date().addingTimeInterval(240)
        var tunnel: URL?
        var lastLookup = Date.distantPast
        while Date() < deadline {
            try Task.checkCancellation()
            guard run.isRunning else { throw DeviceError.failed(run.failure) }
            if tunnel == nil, Date().timeIntervalSince(lastLookup) > 5 {
                lastLookup = Date()
                tunnel = (try? await Devicectl.tunnelAddress(device.id)).flatMap(WebDriverAgent.tunnelURL)
            }
            if let announced = run.serverURL {
                for url in [tunnel, announced].compactMap({ $0 }) {
                    let client = WebDriverAgentClient(base: url)
                    if await client.isUp() { return client }
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw DeviceError.failed("WebDriverAgent did not start on \(device.name) within 4 minutes. Unlock the phone and keep it nearby, then try again.")
    }

    private func stopAgent() {
        agentRun?.stop()
        agentRun = nil
        agentClient = nil
    }

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

    /// Sends one of the user's touches or keys after the ones before it, and says on the screen why it couldn't.
    /// Each is a round trip to WebDriverAgent, so a click becomes one tap or drag when the button comes up.
    private func userInput(_ send: @escaping (WebDriverAgentClient) async throws -> Void) {
        lastUsed = Date()
        let previous = userInputs
        userInputs = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await send(try await self.agent())
                if self.inputFailure != nil { self.inputFailure = nil }
            } catch {
                self.inputFailure = error.localizedDescription
            }
        }
    }

    private func points(_ ratio: CGPoint) -> CGPoint? {
        guard let size = screenSize else { return nil }
        return CGPoint(x: ratio.x * size.width, y: ratio.y * size.height)
    }

    func userTouch(_ phase: TouchPhase, at ratio: CGPoint) {
        switch phase {
        case .down:
            touchStart = (ratio, Date())
            touchLast = ratio
        case .move:
            touchLast = ratio
        case .up:
            guard let start = touchStart, let from = points(start.ratio), let to = points(ratio) else { return }
            touchStart = nil
            let held = Date().timeIntervalSince(start.at)
            let path = hypot(to.x - from.x, to.y - from.y) < 8 ? [from] : [from, to]
            userInput { try await $0.gesture(path, duration: path.count == 1 ? min(held, 2) : max(held, 0.1)) }
        }
    }

    func userKey(_ event: NSEvent, down: Bool) {
        guard down, event.type == .keyDown else { return }
        let text: String
        switch event.keyCode {
        case 0x24, 0x4C: text = "\n"
        case 0x33: text = "\u{8}"
        default:
            guard let characters = event.characters, !characters.isEmpty,
                  !event.modifierFlags.contains(.command), characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) })
            else { return }
            text = characters
        }
        userInput { try await $0.type(text) }
    }

    /// A scroll wheel or trackpad pan as one drag once it ends.
    func userScroll(dx: CGFloat, dy: CGFloat, at ratio: CGPoint, ended: Bool) {
        if !ended {
            if scrollStart == nil { scrollStart = ratio; scrollDelta = .zero }
            scrollDelta.width += dx
            scrollDelta.height += dy
            return
        }
        guard let start = scrollStart, let from = points(start), let size = screenSize else { return }
        scrollStart = nil
        let to = CGPoint(x: min(max(from.x + scrollDelta.width, size.width * 0.05), size.width * 0.95),
                         y: min(max(from.y + scrollDelta.height, size.height * 0.05), size.height * 0.95))
        guard hypot(to.x - from.x, to.y - from.y) >= 8 else { return }
        userInput { try await $0.gesture([from, to], duration: 0.3) }
    }

    func pasteFromMac() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        userInput { try await $0.type(text) }
    }

    func pick(at ratio: CGPoint) {
        picking = false
        guard let point = points(ratio) else { return }
        Task {
            guard let tree = try? await agent().tree(), let element = tree.element(at: point) else { return }
            onPick?(element, tree.app)
        }
    }

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
