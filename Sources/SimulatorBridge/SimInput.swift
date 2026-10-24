import CoreGraphics
import Foundation

public enum SimTouchPhase { case down, move, up }

public enum SimButton: String, CaseIterable {
    case lock, siri, volumeUp, volumeDown
}

/// How touches, buttons and keys reach a simulator. Indigo messages through SimulatorKit's legacy HID client work up to
/// Xcode 26; Xcode 27 ignores them, which needs another transport (idb uses "DTUHID" over XPC).
public protocol SimInput: AnyObject {
    /// `x` and `y` are 0…1 across the screen as the user sees it.
    func touch(_ phase: SimTouchPhase, x: Double, y: Double) throws
    func press(_ button: SimButton, down: Bool) throws
    /// A USB HID keyboard usage (page 7), e.g. 0x04 for A, 0x28 for Return, 0xE1 for left shift.
    func key(usage: UInt32, down: Bool) throws
}

public enum SimInputFactory {
    public static func make(udid: String) throws -> SimInput {
        if let version = SimFrameworks.coreSimulatorVersion, version >= 1155 {
            throw SimBridgeError.unavailable("Touch and key input are not supported with this Xcode's simulator yet (CoreSimulator \(version)). Use Simulator to interact.")
        }
        return try IndigoInput(udid: udid)
    }
}

/// Indigo HID messages sent with `SimDeviceLegacyHIDClient`, the way Simulator.app and idb do.
final class IndigoInput: SimInput {
    private typealias MouseFunc = @convention(c) (UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?, UInt32, Int32, CGFloat, CGFloat, UInt32) -> UnsafeMutableRawPointer?
    private typealias ButtonFunc = @convention(c) (Int32, Int32, Int32) -> UnsafeMutableRawPointer?
    private typealias ArbitraryFunc = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias KeyboardFunc = @convention(c) (UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias SendFunc = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?) -> Void

    private let client: NSObject
    private let sendSelector = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
    private let send: SendFunc
    private let mouse: MouseFunc
    private let button: ButtonFunc?
    private let arbitrary: ArbitraryFunc?
    private let keyboard: KeyboardFunc?

    /// The digitizer, where touches and arbitrary HID buttons go, and the hardware button target.
    private static let digitizer: UInt32 = 0x32
    private static let hardware: Int32 = 0x33

    init(udid: String) throws {
        let device = try SimFrameworks.device(udid: udid)
        func symbol(_ name: String) -> UnsafeMutableRawPointer? { dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) }
        guard let mousePointer = symbol("IndigoHIDMessageForMouseNSEvent") else {
            throw SimBridgeError.unavailable("This Xcode's SimulatorKit has no IndigoHIDMessageForMouseNSEvent.")
        }
        mouse = unsafeBitCast(mousePointer, to: MouseFunc.self)
        button = symbol("IndigoHIDMessageForButton").map { unsafeBitCast($0, to: ButtonFunc.self) }
        arbitrary = symbol("IndigoHIDMessageForHIDArbitrary").map { unsafeBitCast($0, to: ArbitraryFunc.self) }
        keyboard = symbol("IndigoHIDMessageForKeyboardArbitrary").map { unsafeBitCast($0, to: KeyboardFunc.self) }

        guard let hidClass = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") ?? NSClassFromString("SimDeviceLegacyHIDClient") else {
            throw SimBridgeError.unavailable("This Xcode's SimulatorKit has no SimDeviceLegacyHIDClient.")
        }
        let initSelector = NSSelectorFromString("initWithDevice:error:")
        guard let initIMP = class_getMethodImplementation(hidClass, initSelector) else {
            throw SimBridgeError.unavailable("SimDeviceLegacyHIDClient cannot be created on this Xcode.")
        }
        typealias Init = @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
        var error: NSError?
        let made = unsafeBitCast(initIMP, to: Init.self)(hidClass.alloc(), initSelector, device, &error)
        if let error { throw SimBridgeError.failed("Could not connect input to the simulator: \(error.localizedDescription)") }
        guard let client = made as? NSObject, let sendIMP = class_getMethodImplementation(object_getClass(client), sendSelector) else {
            throw SimBridgeError.failed("Could not connect input to the simulator.")
        }
        self.client = client
        send = unsafeBitCast(sendIMP, to: SendFunc.self)
    }

    private func deliver(_ message: UnsafeMutableRawPointer?) throws {
        guard let message else { throw SimBridgeError.failed("SimulatorKit could not build the input event.") }
        send(client, sendSelector, message, ObjCBool(true), nil, nil)
    }

    func touch(_ phase: SimTouchPhase, x: Double, y: Double) throws {
        // The C function takes NSEventType-like values: 1 (down, also used for moves) and 2 (up). A 1×1 size makes the point a ratio.
        var point = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        try deliver(mouse(&point, nil, Self.digitizer, phase == .up ? 2 : 1, 1, 1, 0))
    }

    func press(_ which: SimButton, down: Bool) throws {
        let direction: Int32 = down ? 1 : 2
        switch which {
        case .lock, .siri:
            guard let button else { throw SimBridgeError.unavailable("This Xcode cannot press simulator buttons.") }
            try deliver(button(which == .lock ? 0x1 : 0x400002, direction, Self.hardware))
        case .volumeUp, .volumeDown:
            // Consumer page (0x0C) volume usages, sent to the digitizer like Simulator.app's chrome buttons.
            guard let arbitrary else { throw SimBridgeError.unavailable("This Xcode cannot press simulator buttons.") }
            try deliver(arbitrary(UInt32(Self.digitizer), 0x0C, which == .volumeUp ? 0xE9 : 0xEA, UInt32(direction)))
        }
    }

    func key(usage: UInt32, down: Bool) throws {
        guard let keyboard else { throw SimBridgeError.unavailable("This Xcode cannot send keys to the simulator.") }
        try deliver(keyboard(usage, down ? 1 : 2))
    }
}
