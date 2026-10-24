import AppKit
import CoreImage
import IOSurface
import Observation
import SimulatorBridge
import ViberCore

/// One iOS simulator shown in Viber: its live screen, the user's mouse and keys, and the device tools' driver.
/// Simulators are machine-wide, so one controller serves every session that shows or drives the same device.
@MainActor @Observable
final class SimulatorController: DeviceController {
    private(set) var device: DeviceInfo
    /// The screen in points, once the stream has a surface.
    private(set) var screenSize: CGSize?
    private(set) var isStreaming = false
    private(set) var booting = false
    /// Why the live screen is not available (an Xcode the bridge doesn't understand, a failed boot…).
    private(set) var failure: String?
    /// Why the user's clicks and keys can't reach the simulator.
    private(set) var inputFailure: String?
    /// Clicking picks an element instead of tapping.
    var picking = false
    /// What Claude is doing on this device, and for which session.
    var activity: String?

    @ObservationIgnored var lastTree: UITree?
    @ObservationIgnored let screenView = DeviceScreenView()
    /// An element the user picked, with the app it is in.
    @ObservationIgnored var onPick: ((UIElement, String?) -> Void)?
    @ObservationIgnored private var screen: SimScreen?
    @ObservationIgnored private var input: SimInput?
    @ObservationIgnored private var lastSeed: UInt32 = 0
    @ObservationIgnored private let changes = ScreenChanges()
    @ObservationIgnored private(set) var lastUsed = Date()
    @ObservationIgnored private var scroller = TouchScroller()
    @ObservationIgnored private var starting = false

    init(device: DeviceInfo) {
        self.device = device
        screenView.controller = self
    }

    /// The hub's latest view of the device.
    func update(_ info: DeviceInfo) {
        let wasBooted = device.isBooted
        device = info
        if wasBooted && !info.isBooted && !booting { stopStream() }
        if !wasBooted && info.isBooted && screenView.window != nil { startStream() }
    }

    var busyNote: String? { nil }
    let toolbarButtons: [DeviceButton] = [.home, .lock]
    let canPowerCycle = true
    let externalApp: String? = "Open in Simulator"
    let homeApp: String? = "SpringBoard"

    func openExternally() {
        let udid = device.id
        Task.detached { Shell.run("open", ["-a", "Simulator", "--args", "-CurrentDeviceUDID", udid]) }
    }

    // MARK: Stream

    func startStream() {
        lastUsed = Date()
        guard screen == nil, device.isBooted, !starting else { return }
        starting = true
        defer { starting = false }
        do {
            let screen = try SimScreen(udid: device.id, queue: .main)
            screen.onSurface = { [weak self] surface in self?.surfaceChanged(surface) }
            screen.onFrame = { [weak self] in self?.frameDrawn() }
            try screen.start()
            self.screen = screen
            isStreaming = true
            failure = nil
            if let surface = screen.surface { surfaceChanged(surface) }
            // Xcode 27's dtuhidd starts on demand and can take seconds; starting it now keeps the first click quick.
            // A failure here stays quiet and shows when input is first used.
            if input == nil { input = try? SimInputFactory.make(udid: device.id) }
        } catch {
            failure = error.localizedDescription
        }
    }

    func stopStream() {
        screen?.stop()
        screen = nil
        isStreaming = false
        screenView.show(nil)
        scroller.lift { phase, r in try? input?.touch(Self.phase(phase), x: r.x, y: r.y) }
    }

    private func surfaceChanged(_ surface: IOSurface) {
        let scale = screen?.native?.scale ?? 3
        screenSize = CGSize(width: Double(IOSurfaceGetWidth(surface)) / scale, height: Double(IOSurfaceGetHeight(surface)) / scale)
        screenView.show(surface)
        changes.lastChange = Date()
    }

    private func frameDrawn() {
        guard let surface = screen?.surface else { return }
        // Frame callbacks also arrive when nothing changed; the surface's seed says whether pixels did.
        let seed = IOSurfaceGetSeed(surface)
        if seed != lastSeed {
            lastSeed = seed
            changes.lastChange = Date()
        }
        screenView.redraw()
    }

    private func readyStream() {
        lastUsed = Date()
        if screen == nil { startStream() }
    }

    private func readyInput() throws -> SimInput {
        if let input { return input }
        do {
            let made = try SimInputFactory.make(udid: device.id)
            input = made
            inputFailure = nil
            return made
        } catch {
            inputFailure = error.localizedDescription
            throw error
        }
    }

    // MARK: Device control

    func boot() async throws {
        lastUsed = Date()
        if !device.isBooted {
            booting = true
            defer { booting = false }
            do {
                try await Simctl.boot(device.id)
            } catch {
                failure = error.localizedDescription
                throw error
            }
            device.state = .booted
        }
        readyStream()
    }

    func shutdown() async {
        stopStream()
        input = nil
        do {
            try await Simctl.shutdown(device.id)
            device.state = .shutdown
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: DeviceDriver

    func screenshot() async throws -> (data: Data, width: Int, height: Int) {
        readyStream()
        if let surface = screen?.surface, let size = screenSize, let image = Self.image(surface, points: size) {
            return try ImageEncoding.jpeg(image, maxWidth: size.width, maxPixels: .greatestFiniteMagnitude)
        }
        // No live stream (the bridge is unavailable): ask simctl, which is slower but public.
        let png = try await Simctl.screenshot(device.id)
        guard let image = NSImage(data: png), let rep = image.representations.first else { throw DeviceError.failed("The screenshot could not be read.") }
        let scale = screen?.native?.scale ?? 3
        let points = screenSize ?? CGSize(width: Double(rep.pixelsWide) / scale, height: Double(rep.pixelsHigh) / scale)
        image.size = points
        return try ImageEncoding.jpeg(image, maxWidth: points.width, maxPixels: .greatestFiniteMagnitude)
    }

    private static let imageContext = CIContext()

    static func image(_ surface: IOSurface, points: CGSize) -> NSImage? {
        let ci = CIImage(ioSurface: surface)
        guard let cg = imageContext.createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(cgImage: cg, size: points)
    }

    func uiTree(thorough: Bool) async throws -> UITree {
        readyStream()
        let udid = device.id
        let node = try await Task.detached { try SimAccessibility.shared.tree(udid: udid, probe: thorough) }.value
        let root = Self.element(node)
        return UITree(root: root, screen: CGRect(origin: .zero, size: screenSize ?? root.frame.size))
    }

    static func element(_ node: SimAccessibility.Node) -> UIElement {
        UIElement(role: node.role, label: node.label, value: node.value, identifier: node.identifier,
                  frame: node.frame, enabled: node.enabled, children: node.children.map(element))
    }

    func gesture(_ path: [CGPoint], duration: TimeInterval) async throws {
        readyStream()
        let input = try readyInput()
        guard let size = screenSize, let first = path.first, let last = path.last else {
            throw DeviceError.failed("The simulator's screen is not available yet.")
        }
        func ratio(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / size.width, y: p.y / size.height) }
        let start = ratio(first)
        try input.touch(.down, x: start.x, y: start.y)
        if path.count == 1 {
            try await Task.sleep(nanoseconds: UInt64(max(duration, 0.02) * 1_000_000_000))
        } else {
            let interval = duration / Double(path.count - 1)
            for point in path.dropFirst() {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                let r = ratio(point)
                try input.touch(.move, x: r.x, y: r.y)
            }
        }
        let end = ratio(last)
        try input.touch(.up, x: end.x, y: end.y)
    }

    func type(_ text: String) async throws {
        let input = try readyInput()
        guard let strokes = HIDKeyboard.strokes(for: text) else {
            // Characters without a key on a US layout: paste them.
            try await Simctl.pbcopy(device.id, text)
            try await chord([HIDKeyboard.leftCommand], HIDKeyboard.v)
            return
        }
        for stroke in strokes {
            if stroke.shift { try input.key(usage: HIDKeyboard.leftShift, down: true) }
            try input.key(usage: stroke.usage, down: true)
            try input.key(usage: stroke.usage, down: false)
            if stroke.shift { try input.key(usage: HIDKeyboard.leftShift, down: false) }
            try await Task.sleep(nanoseconds: 12_000_000)
        }
    }

    func key(_ key: DeviceKey) async throws {
        switch key {
        case .returnKey: try await chord([], HIDKeyboard.returnKey)
        case .delete: try await chord([], HIDKeyboard.delete)
        case .selectAll: try await chord([HIDKeyboard.leftCommand], HIDKeyboard.a)
        }
    }

    private func chord(_ modifiers: [UInt32], _ usage: UInt32) async throws {
        let input = try readyInput()
        for m in modifiers { try input.key(usage: m, down: true) }
        try input.key(usage: usage, down: true)
        try await Task.sleep(nanoseconds: 20_000_000)
        try input.key(usage: usage, down: false)
        for m in modifiers.reversed() { try input.key(usage: m, down: false) }
    }

    func press(_ button: DeviceButton) async throws {
        lastUsed = Date()
        let hold: Double
        let which: SimButton
        switch button {
        case .home:
            // Xcode 26 drops the Indigo home press; bringing SpringBoard forward is what a home press does.
            try await Simctl.launch(device.id, app: "com.apple.springboard", terminateRunning: false)
            return
        case .lock: which = .lock; hold = 0.1
        case .siri: which = .siri; hold = 0.4
        case .volume_up: which = .volumeUp; hold = 0.1
        case .volume_down: which = .volumeDown; hold = 0.1
        case .back, .app_switch: throw DeviceError.failed("iOS has no \(button.rawValue.replacingOccurrences(of: "_", with: " ")) button.")
        }
        let input = try readyInput()
        try input.press(which, down: true)
        try await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
        try input.press(which, down: false)
    }

    func install(_ path: String) async throws -> String { try await Simctl.install(device.id, app: path) }

    func launch(_ app: String, arguments: [String], terminateRunning: Bool) async throws {
        try await Simctl.launch(device.id, app: app, arguments: arguments, terminateRunning: terminateRunning)
    }

    func openURL(_ url: String) async throws { try await Simctl.openURL(device.id, url) }

    func logs(process: String?, seconds: Int) async throws -> String {
        try await Simctl.logs(device.id, process: process, seconds: seconds)
    }

    func settle(afterAction: Bool) async {
        readyStream()
        guard isStreaming else {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return
        }
        await changes.settle(afterAction: afterAction)
    }

    // MARK: The user's mouse and keyboard

    static func phase(_ phase: TouchPhase) -> SimTouchPhase {
        switch phase {
        case .down: return .down
        case .move: return .move
        case .up: return .up
        }
    }

    func userTouch(_ phase: TouchPhase, at ratio: CGPoint) {
        lastUsed = Date()
        userInput { try $0.touch(Self.phase(phase), x: ratio.x, y: ratio.y) }
    }

    func userKey(_ event: NSEvent, down: Bool) {
        guard let usage = HIDKeyboard.usage(macKeyCode: event.keyCode) else { return }
        userInput { try $0.key(usage: usage, down: down) }
    }

    /// Sends one of the user's touches or keys, and says on the screen why it couldn't be sent. Only assigns when
    /// the note changes, so mouse moves don't redraw the overlay.
    private func userInput(_ send: (SimInput) throws -> Void) {
        do {
            try send(readyInput())
            if inputFailure != nil { inputFailure = nil }
        } catch {
            let note = error.localizedDescription
            if inputFailure != note { inputFailure = note }
        }
    }

    /// Mac clipboard text into the simulator, pasted where the cursor is.
    func pasteFromMac() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let udid = device.id
        Task {
            do {
                try await Simctl.pbcopy(udid, text)
                try await chord([HIDKeyboard.leftCommand], HIDKeyboard.v)
            } catch {}
        }
    }

    func userScroll(dx: CGFloat, dy: CGFloat, at ratio: CGPoint, ended: Bool) {
        guard let size = screenSize, let input = try? readyInput() else { return }
        scroller.scroll(dx: dx, dy: dy, at: ratio, ended: ended, screen: size) { phase, r in
            try? input.touch(Self.phase(phase), x: r.x, y: r.y)
        }
    }

    /// The element under a click while picking.
    func pick(at ratio: CGPoint) {
        picking = false
        guard let size = screenSize else { return }
        let point = CGPoint(x: ratio.x * size.width, y: ratio.y * size.height)
        let udid = device.id
        Task {
            let found = try? await Task.detached { () -> (SimAccessibility.Node?, String?) in
                let node = try SimAccessibility.shared.element(at: point, udid: udid)
                let app = try? SimAccessibility.shared.tree(udid: udid, probe: false).label
                return (node, app)
            }.value
            guard let node = found?.0 else { return }
            onPick?(Self.element(node), found?.1)
        }
    }

    func copyScreenshot() {
        guard let surface = screen?.surface, let size = screenSize, let image = Self.image(surface, points: size) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// The screen at full resolution as PNG, for attaching to a message.
    func screenshotPNG() -> Data? {
        guard let surface = screen?.surface else { return nil }
        let ci = CIImage(ioSurface: surface)
        guard let cg = Self.imageContext.createCGImage(ci, from: ci.extent) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
