import AppKit
import ViberCore

enum TouchPhase { case down, move, up }

/// One device shown in the panel: its live screen and the user's mouse and keys, on top of what the device tools need.
/// Devices are machine-wide, so one controller serves every session that shows or drives the same device.
@MainActor
protocol DeviceController: DeviceDriver {
    var isStreaming: Bool { get }
    var booting: Bool { get }
    /// Why the live screen is not available.
    var failure: String? { get }
    /// Why the user's clicks and keys can't reach the device.
    var inputFailure: String? { get }
    /// Clicking picks an element instead of tapping.
    var picking: Bool { get set }
    /// Something slow the device is doing for the user, such as reading the screen for a pick.
    var busyNote: String? { get }
    /// What Claude is doing on this device. The hub doesn't stop a stream while it is set.
    var activity: String? { get set }
    var screenView: DeviceScreenView { get }
    /// An element the user picked, with the app it is in.
    var onPick: ((UIElement, String?) -> Void)? { get set }
    var lastUsed: Date { get }
    /// The hardware buttons the panel's toolbar offers.
    var toolbarButtons: [DeviceButton] { get }
    /// Whether the panel offers to boot and shut it down (not for USB phones).
    var canPowerCycle: Bool { get }
    /// The menu title for opening the device in its platform's own app, if there is one.
    var externalApp: String? { get }

    /// The hub's latest view of the device.
    func update(_ info: DeviceInfo)
    func startStream()
    func stopStream()
    func shutdown() async
    func openExternally()

    func userTouch(_ phase: TouchPhase, at ratio: CGPoint)
    /// Key down and up, and modifier changes (`flagsChanged`, with `down` saying whether the modifier is now held).
    func userKey(_ event: NSEvent, down: Bool)
    func userScroll(dx: CGFloat, dy: CGFloat, at ratio: CGPoint, ended: Bool)
    /// Mac clipboard text into the device, pasted where the cursor is.
    func pasteFromMac()
    /// The element under a click while picking.
    func pick(at ratio: CGPoint)
    func copyScreenshot()
    /// The screen at full resolution as PNG, for attaching to a message.
    func screenshotPNG() -> Data?
}

extension DeviceController {
    var isAttached: Bool { screenView.window != nil }
}

/// When the screen last changed, and waiting for it to stop changing.
@MainActor
final class ScreenChanges {
    var lastChange = Date.distantPast

    /// Waits until the screen has not changed for 300 ms, at most 3 s. After an action, first waits up to 600 ms for
    /// the screen to start changing, so a slow response is not mistaken for none.
    func settle(afterAction: Bool) async {
        let start = Date()
        try? await Task.sleep(nanoseconds: 100_000_000)
        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= 3 { break }
            let changedSince = lastChange > start
            if afterAction && !changedSince && elapsed < 0.6 {
                // Nothing yet: keep waiting for the first change.
            } else if Date().timeIntervalSince(lastChange) >= 0.3 {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

/// A scroll wheel or trackpad pan as a finger drag, since phones have no scroll wheel. Re-anchors near the edges.
struct TouchScroller {
    private var anchor: CGPoint?
    private var finger = CGPoint.zero

    var isDragging: Bool { anchor != nil }

    /// `touch` gets the finger's position as a fraction of the screen.
    mutating func scroll(dx: CGFloat, dy: CGFloat, at ratio: CGPoint, ended: Bool, screen size: CGSize, touch: (TouchPhase, CGPoint) -> Void) {
        if ended {
            lift(touch)
            return
        }
        guard dx != 0 || dy != 0, size.width > 0, size.height > 0 else { return }
        if anchor == nil {
            anchor = ratio
            finger = ratio
            touch(.down, ratio)
        }
        guard let anchor else { return }
        var next = CGPoint(x: finger.x + dx / size.width, y: finger.y + dy / size.height)
        if next.x < 0.05 || next.x > 0.95 || next.y < 0.05 || next.y > 0.95 {
            touch(.up, finger)
            finger = anchor
            touch(.down, finger)
            next = CGPoint(x: finger.x + dx / size.width, y: finger.y + dy / size.height)
        }
        finger = CGPoint(x: min(max(next.x, 0.05), 0.95), y: min(max(next.y, 0.05), 0.95))
        touch(.move, finger)
    }

    /// Lifts the finger if a drag is under way.
    mutating func lift(_ touch: (TouchPhase, CGPoint) -> Void) {
        if anchor != nil { touch(.up, finger) }
        anchor = nil
    }
}
