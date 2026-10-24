import AppKit
import CoreImage
import CoreVideo
import Observation
import ViberCore

/// One Android emulator or USB phone shown in Viber. The live screen and input go through a scrcpy server;
/// everything else (screenshots, the screen's outline, apps, logs) through adb. Tools measure in dp.
@MainActor @Observable
final class AndroidController: DeviceController {
    private(set) var device: DeviceInfo
    /// The screen in dp, in its current orientation, once known.
    private(set) var screenSize: CGSize?
    private(set) var isStreaming = false
    private(set) var booting = false
    private(set) var failure: String?
    private(set) var inputFailure: String?
    var picking = false
    private(set) var busyNote: String?
    var activity: String?

    @ObservationIgnored var lastTree: UITree?
    @ObservationIgnored let screenView = DeviceScreenView()
    @ObservationIgnored var onPick: ((UIElement, String?) -> Void)?
    @ObservationIgnored private(set) var lastUsed = Date()
    @ObservationIgnored private(set) var homeApp: String?
    @ObservationIgnored private let changes = ScreenChanges()
    @ObservationIgnored private var scroller = TouchScroller()
    @ObservationIgnored private var session: ScrcpySession?
    @ObservationIgnored private var starting: Task<Void, Never>?
    /// The screen in pixels in its natural orientation, and its density (dpi).
    @ObservationIgnored private var metrics: (size: CGSize, density: Double)?
    /// The video's size in pixels: what touches are measured against.
    @ObservationIgnored private var videoSize: CGSize?
    @ObservationIgnored private var landscape = false
    /// The last two decoded frames, kept so the decoder doesn't reuse a surface the screen still shows.
    @ObservationIgnored private var frame: CVPixelBuffer?
    @ObservationIgnored private var previousFrame: CVPixelBuffer?
    @ObservationIgnored private var emulator: Process?
    @ObservationIgnored private var emulatorLog: URL?
    /// uiautomator until it can't read the screen; then the Android CLI, whose helper keeps uiautomator out while it runs.
    @ObservationIgnored private var useLayoutCLI = false
    @ObservationIgnored private var shuttingDown = false

    let toolbarButtons: [DeviceButton] = [.back, .home, .app_switch]
    let externalApp: String? = nil
    var canPowerCycle: Bool { device.kind == .emulator }

    init(device: DeviceInfo) {
        self.device = device
        screenView.controller = self
    }

    func openExternally() {}

    func update(_ info: DeviceInfo) {
        guard !shuttingDown else { return }
        let old = device
        var info = info
        // While we boot it, the list still says off (adb sees the emulator only once it is online).
        if booting, !info.isBooted {
            info.state = old.state
            info.serial = info.serial ?? old.serial
        }
        device = info
        if let serial = old.serial, info.serial != serial {
            stopStream()
            metrics = nil
            homeApp = nil
            useLayoutCLI = false
        }
        if old.isBooted && !info.isBooted && !booting { stopStream() }
        if !old.isBooted && info.isBooted && isAttached { startStream() }
    }

    private var scale: CGFloat { CGFloat((metrics?.density ?? 160) / 160) }

    private func requireSerial() throws -> String {
        guard device.isBooted, let serial = device.serial else {
            throw DeviceError.failed(device.state == .booting ? "\(device.label) is still booting. Call device_open to wait for it."
                                                              : "\(device.label) is not running. Call device_open to boot it.")
        }
        return serial
    }

    /// Reads what the tools need once per connection: the screen's size and density, and the launcher.
    private func prepare() async throws -> String {
        lastUsed = Date()
        let serial = try requireSerial()
        if metrics == nil {
            metrics = try await Adb.metrics(serial)
            updateScreenSize()
        }
        if homeApp == nil { homeApp = await Adb.homePackage(serial) }
        return serial
    }

    private func updateScreenSize() {
        guard let metrics else { return }
        var pixels = metrics.size
        if let videoSize { landscape = videoSize.width > videoSize.height }
        if landscape != (pixels.width > pixels.height) { pixels = CGSize(width: pixels.height, height: pixels.width) }
        screenSize = CGSize(width: pixels.width / scale, height: pixels.height / scale)
    }

    // MARK: Stream

    func startStream() {
        lastUsed = Date()
        guard session == nil, starting == nil, device.isBooted, let serial = device.serial else { return }
        starting = Task { [weak self] in
            await self?.connect(serial)
            self?.starting = nil
        }
    }

    private func connect(_ serial: String) async {
        do {
            _ = try await prepare()
            guard let jar = ScrcpySession.serverJar() else {
                failure = "The live screen needs scrcpy-server, which Scripts/build-app.sh downloads (or set VIBER_SCRCPY_SERVER)."
                return
            }
            let session = ScrcpySession(serial: serial)
            session.onSize = { [weak self] size in self?.videoSizeChanged(size) }
            session.onFrame = { [weak self] buffer, changed in self?.frameArrived(buffer, changed: changed) }
            session.onEnd = { [weak self, weak session] message in
                guard let self, let session, self.session === session else { return }
                self.sessionEnded(message)
            }
            let size = try await session.start(jar: jar)
            guard !Task.isCancelled, device.serial == serial, device.isBooted else {
                session.stop()
                return
            }
            self.session = session
            isStreaming = true
            failure = nil
            inputFailure = nil
            videoSizeChanged(size)
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }

    func stopStream() {
        starting?.cancel()
        starting = nil
        if let session { scroller.lift { phase, r in self.touch(phase, ratio: r, via: session) } }
        session?.stop()
        session = nil
        isStreaming = false
        frame = nil
        previousFrame = nil
        screenView.show(nil)
    }

    private func readyStream() {
        lastUsed = Date()
        if session == nil { startStream() }
    }

    /// The control connection, starting the stream if needed; nil when it can't be had (tools fall back to `adb shell input`).
    private func control() async -> ScrcpySession? {
        readyStream()
        if let starting { await starting.value }
        return videoSize == nil ? nil : session
    }

    private func videoSizeChanged(_ size: CGSize) {
        videoSize = size
        updateScreenSize()
    }

    private func frameArrived(_ buffer: CVPixelBuffer, changed: Bool) {
        previousFrame = frame
        frame = buffer
        if changed { changes.lastChange = Date() }
        screenView.show(CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue())
    }

    private func sessionEnded(_ message: String?) {
        session = nil
        isStreaming = false
        videoSize = nil
        frame = nil
        previousFrame = nil
        screenView.show(nil)
        if let message, device.isBooted { failure = message }
    }

    // MARK: Device control

    func boot() async throws {
        lastUsed = Date()
        if device.kind == .physical {
            let state = await Adb.state(of: device.id)
            guard state == "device" else {
                let reason = state.map(Adb.notReadyReason) ?? "\(device.name) is not connected. Plug it in with USB."
                failure = reason
                throw DeviceError.failed(reason)
            }
            device.serial = device.id
            device.state = .booted
            failure = nil
            readyStream()
            return
        }
        if !device.isBooted {
            booting = true
            defer { booting = false }
            do {
                let serial: String
                if device.state == .booting, let known = device.serial {
                    serial = known  // started elsewhere (Android Studio, an earlier call): just wait
                } else {
                    let log = FileManager.default.temporaryDirectory.appendingPathComponent("viber-emulator-\(device.id).log")
                    let started = try await Adb.startEmulator(avd: device.id, log: log)
                    emulator = started.process
                    emulatorLog = log
                    serial = started.serial
                }
                device.serial = serial
                device.state = .booting
                try await Adb.waitForBoot(serial, process: emulator, log: emulatorLog, name: device.name, timeout: 150)
                device.state = .booted
                failure = nil
            } catch {
                if emulator?.isRunning != true { device.state = .shutdown }
                failure = error.localizedDescription
                throw error
            }
        }
        readyStream()
    }

    func shutdown() async {
        guard let serial = device.serial else { return }
        stopStream()
        // Until the emulator is gone, adb still lists it: don't let the hub's refresh restart the stream meanwhile.
        shuttingDown = true
        defer { shuttingDown = false }
        do {
            try await Adb.killEmulator(serial)
            device.state = .shutdown
            device.serial = nil
            metrics = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: DeviceDriver

    func screenshot() async throws -> (data: Data, width: Int, height: Int) {
        let serial = try await prepare()
        let png = try await Adb.screencap(serial)
        guard let image = NSImage(data: png), let rep = image.representations.first else { throw DeviceError.failed("The screenshot could not be read.") }
        if videoSize == nil {
            landscape = rep.pixelsWide > rep.pixelsHigh
            updateScreenSize()
        }
        let size = CGSize(width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale)
        image.size = size
        return try ImageEncoding.jpeg(image, maxWidth: size.width, maxPixels: .greatestFiniteMagnitude)
    }

    func uiTree(thorough: Bool) async throws -> UITree {
        let serial = try await prepare()
        if !useLayoutCLI {
            do {
                let xml = try await Adb.uiDump(serial, thorough: thorough)
                guard let tree = AndroidTree.parseUIAutomator(xml, scale: scale, screen: screenSize) else {
                    throw DeviceError.failed("uiautomator returned an outline Viber could not read.")
                }
                return tree
            } catch let error as Adb.TreeError {
                guard error == .notIdle || error == .busy else {
                    if case .failed(let message) = error { throw DeviceError.failed("Could not read the screen: \(message)") }
                    throw DeviceError.failed("Could not read the screen.")
                }
                guard Adb.sdk.cli != nil else {
                    throw DeviceError.failed(error == .notIdle
                        ? "uiautomator can't read this screen because it never goes idle (something keeps animating). Google's Android CLI (developer.android.com/tools/agents) can; install it and try again. Screenshots still work."
                        : "Another tool is using Android's UI automation, so uiautomator can't read the screen. Stop it, or install Google's Android CLI so Viber can use its reader. Screenshots still work.")
                }
                useLayoutCLI = true
            }
        }
        let json = try await Adb.layout(serial, thorough: thorough)
        guard let tree = AndroidTree.parseLayout(json, scale: scale, screen: screenSize) else {
            throw DeviceError.failed("android layout returned an outline Viber could not read.")
        }
        return tree
    }

    /// dp to video pixels, for scrcpy.
    private func videoPoint(_ p: CGPoint) -> (x: Int, y: Int)? {
        guard let videoSize, let screenSize, screenSize.width > 0, screenSize.height > 0 else { return nil }
        return (Int((p.x * videoSize.width / screenSize.width).rounded()), Int((p.y * videoSize.height / screenSize.height).rounded()))
    }

    private func touch(_ phase: TouchPhase, ratio: CGPoint, via session: ScrcpySession) {
        guard let videoSize else { return }
        let action: Scrcpy.TouchAction = phase == .down ? .down : phase == .up ? .up : .move
        session.send(Scrcpy.touch(action, x: Int(ratio.x * videoSize.width), y: Int(ratio.y * videoSize.height),
                                  width: Int(videoSize.width), height: Int(videoSize.height)))
    }

    func gesture(_ path: [CGPoint], duration: TimeInterval) async throws {
        let serial = try await prepare()
        guard let first = path.first, let last = path.last else { return }
        if let session = await control(), let videoSize {
            func send(_ action: Scrcpy.TouchAction, _ p: CGPoint) {
                guard let v = videoPoint(p) else { return }
                session.send(Scrcpy.touch(action, x: v.x, y: v.y, width: Int(videoSize.width), height: Int(videoSize.height)))
            }
            send(.down, first)
            if path.count == 1 {
                try await Task.sleep(nanoseconds: UInt64(max(duration, 0.02) * 1_000_000_000))
            } else {
                let interval = duration / Double(path.count - 1)
                for point in path.dropFirst() {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    send(.move, point)
                }
            }
            send(.up, last)
            return
        }
        // No live connection: adb's input command, in device pixels.
        func pixels(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale, y: p.y * scale) }
        let command = path.count == 1 && duration < 0.3
            ? Adb.tapCommand(pixels(first))
            : Adb.swipeCommand(from: pixels(first), to: pixels(last), milliseconds: Int(duration * 1000))
        try await Adb.shell(serial, command, timeout: 20, what: "touch the screen")
    }

    /// Text that scrcpy can type key by key; the rest goes through the clipboard.
    static func typeable(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) || $0 == "\n" || $0 == "\t" }
    }

    func type(_ text: String) async throws {
        let serial = try await prepare()
        if let session = await control() {
            if Self.typeable(text) {
                for message in Scrcpy.text(text) { session.send(message) }
            } else {
                session.send(Scrcpy.setClipboard(text, paste: true))
            }
            return
        }
        guard Self.typeable(text), !text.contains("\n") else {
            throw DeviceError.failed("Typing this text needs the live screen connection, which is not available: \(failure ?? "unknown reason").")
        }
        try await Adb.shell(serial, Adb.textCommand(text), timeout: 30, what: "type")
    }

    private func sendKey(_ code: Int32, meta: UInt32 = 0, via session: ScrcpySession) async {
        session.send(Scrcpy.keycode(.down, code, meta: meta))
        try? await Task.sleep(nanoseconds: 20_000_000)
        session.send(Scrcpy.keycode(.up, code, meta: meta))
    }

    func key(_ key: DeviceKey) async throws {
        let serial = try await prepare()
        let (code, ctrl): (Int32, Bool) = switch key {
        case .returnKey: (AndroidKey.enter, false)
        case .delete: (AndroidKey.del, false)
        case .selectAll: (AndroidKey.a, true)
        }
        if let session = await control() {
            await sendKey(code, meta: ctrl ? AndroidKey.metaCtrl : 0, via: session)
        } else {
            try await Adb.shell(serial, Adb.keyCommand(code, meta: ctrl ? [113] : []), what: "press a key")
        }
    }

    func press(_ button: DeviceButton) async throws {
        let serial = try await prepare()
        guard let code = AndroidKey.code(button) else { throw DeviceError.failed("Android has no \(button.rawValue) button.") }
        if let session = await control() {
            await sendKey(code, via: session)
        } else {
            try await Adb.shell(serial, Adb.keyCommand(code), what: "press \(button.rawValue)")
        }
    }

    func install(_ path: String) async throws -> String {
        try await Adb.install(try await prepare(), apk: path)
    }

    func launch(_ app: String, arguments: [String], terminateRunning: Bool) async throws {
        try await Adb.launch(try await prepare(), package: app, arguments: arguments, terminateRunning: terminateRunning)
    }

    func openURL(_ url: String) async throws { try await Adb.openURL(try await prepare(), url) }

    func logs(process: String?, seconds: Int) async throws -> String {
        try await Adb.logs(try await prepare(), process: process, seconds: seconds)
    }

    func settle(afterAction: Bool) async {
        _ = try? await prepare()
        _ = await control()
        guard isStreaming else {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return
        }
        await changes.settle(afterAction: afterAction)
    }

    // MARK: The user's mouse and keyboard

    func userTouch(_ phase: TouchPhase, at ratio: CGPoint) {
        lastUsed = Date()
        guard let session else { readyStream(); return }
        touch(phase, ratio: ratio, via: session)
    }

    func userKey(_ event: NSEvent, down: Bool) {
        // Modifier changes carry no characters (asking for them raises); text arrives with key presses.
        guard event.type == .keyDown || event.type == .keyUp, let session else { return }
        lastUsed = Date()
        let action: Scrcpy.KeyAction = down ? .down : .up
        if let code = AndroidKey.code(macKeyCode: event.keyCode) {
            session.send(Scrcpy.keycode(action, code))
            return
        }
        if event.modifierFlags.contains(.control), let letter = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first,
           ("a"..."z").contains(letter) {
            session.send(Scrcpy.keycode(action, AndroidKey.a + Int32(letter.value - 97), meta: AndroidKey.metaCtrl))
            return
        }
        guard down, let text = event.characters, !text.isEmpty, Self.typeable(text) else { return }
        for message in Scrcpy.text(text) { session.send(message) }
    }

    func userScroll(dx: CGFloat, dy: CGFloat, at ratio: CGPoint, ended: Bool) {
        guard let session, let size = screenSize else { return }
        scroller.scroll(dx: dx, dy: dy, at: ratio, ended: ended, screen: size) { phase, r in touch(phase, ratio: r, via: session) }
    }

    func pasteFromMac() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty, let session else { return }
        session.send(Scrcpy.setClipboard(text, paste: true))
    }

    func pick(at ratio: CGPoint) {
        picking = false
        guard let size = screenSize else { return }
        let point = CGPoint(x: ratio.x * size.width, y: ratio.y * size.height)
        busyNote = "Reading the screen…"
        Task {
            defer { busyNote = nil }
            guard let tree = try? await uiTree(thorough: true), let element = tree.element(at: point) else { return }
            onPick?(element, tree.app)
        }
    }

    private static let imageContext = CIContext()

    private func frameImage() -> CGImage? {
        guard let frame else { return nil }
        let image = CIImage(cvPixelBuffer: frame)
        return Self.imageContext.createCGImage(image, from: image.extent)
    }

    func copyScreenshot() {
        guard let cg = frameImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: cg, size: screenSize ?? CGSize(width: cg.width, height: cg.height))])
    }

    func screenshotPNG() -> Data? {
        guard let cg = frameImage() else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
