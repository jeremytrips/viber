import CoreGraphics
import Foundation
import XPC

public enum SimTouchPhase { case down, move, up }

public enum SimButton: String, CaseIterable {
    case lock, siri, volumeUp, volumeDown
}

/// How touches, buttons and keys reach a simulator: up to Xcode 26 as Indigo messages through SimulatorKit's legacy
/// HID client, from Xcode 27 as the same events in XPC dictionaries to the guest's `dtuhidd`.
public protocol SimInput: AnyObject {
    /// `x` and `y` are 0…1 across the screen as the user sees it.
    func touch(_ phase: SimTouchPhase, x: Double, y: Double) throws
    func press(_ button: SimButton, down: Bool) throws
    /// A USB HID keyboard usage (page 7), e.g. 0x04 for A, 0x28 for Return, 0xE1 for left shift.
    func key(usage: UInt32, down: Bool) throws
}

public enum SimInputFactory {
    public static func make(udid: String) throws -> SimInput {
        // No falling back to Indigo: where dtuhidd exists, the guest drops Indigo keys and buttons and most touches.
        if SimFrameworks.usesDTUHID(SimFrameworks.coreSimulatorVersion) { return try DTUHIDInput(udid: udid) }
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

/// Xcode 27's input: XPC dictionaries to the guest's `dtuhidd`, the way idb does
/// (FBSimulatorControl/HID/SimulatorDTUHIDConnection.swift and SimulatorDigitizerHIDTransport.swift).
/// `dtuhidd` is launched on demand, and launchd hands out its port even when it can't run, so a connection only
/// counts once the daemon has answered a barrier. Everything runs on one serial queue: events sent while the daemon
/// starts wait behind that probe and arrive in order, and the caller's thread never waits.
final class DTUHIDInput: SimInput {
    static let service = "com.apple.coredevice.feature.remote.hid.digitizer"

    private typealias EndpointFunc = @convention(c) (mach_port_t, UInt64, UInt64) -> Unmanaged<AnyObject>?
    private typealias EnableSim2HostFunc = @convention(c) (xpc_connection_t) -> Void
    private typealias LookupFunc = @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> mach_port_t

    /// How long a cold `dtuhidd` gets to answer, the pause while it opens its device after answering, and the wait
    /// before trying again (launchd throttles a daemon that crashed early in boot for about that long).
    private static let probeTimeout = 4.0, openTail = 0.2, retryDelay = 4.0

    private let device: NSObject
    private let makeEndpoint: EndpointFunc
    private let enableSim2Host: EnableSim2HostFunc
    private let queue = DispatchQueue(label: "viber.simulator.dtuhid")
    /// Only touched on `queue`.
    private var connection: xpc_connection_t?
    /// Only touched on `queue`: the daemon answered since the connection was made or interrupted.
    private var ready = false
    /// Why input isn't reaching the simulator, and when to try again. Read on the caller's thread.
    private let lock = NSLock()
    private var failure: (message: String, retryAfter: Date)?

    init(udid: String) throws {
        device = try SimFrameworks.device(udid: udid)
        func symbol(_ name: String) -> UnsafeMutableRawPointer? { dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) }
        guard let endpointPointer = symbol("xpc_endpoint_create_mach_port_4sim"),
              let enablePointer = symbol("xpc_connection_enable_sim2host_4sim") else {
            throw SimBridgeError.unavailable("This macOS cannot send input into Xcode 27's simulators (no xpc_endpoint_create_mach_port_4sim).")
        }
        makeEndpoint = unsafeBitCast(endpointPointer, to: EndpointFunc.self)
        enableSim2Host = unsafeBitCast(enablePointer, to: EnableSim2HostFunc.self)
        // Connecting is quick and says whether the service exists; the probe can take seconds, so it doesn't block.
        try queue.sync { try connect() }
        queue.async { [self] in _ = ensureReady() }
    }

    deinit {
        // Queued work holds `self`, so nothing else uses the connection by now.
        if let connection { xpc_connection_cancel(connection) }
    }

    func touch(_ phase: SimTouchPhase, x: Double, y: Double) throws { try send(Self.touchMessage(phase, x: x, y: y)) }
    func press(_ button: SimButton, down: Bool) throws { try send(Self.buttonMessage(button, down: down)) }
    func key(usage: UInt32, down: Bool) throws { try send(Self.keyMessage(usage: usage, down: down)) }

    /// Queues `message`, or throws why the last attempt to reach the daemon failed. The event is dropped then rather
    /// than sent late, so a gesture the caller gave up on can't leave a finger down.
    private func send(_ message: xpc_object_t) throws {
        lock.lock()
        let failed = failure
        let retry = failed.map { Date() >= $0.retryAfter } ?? false
        // One retry at a time: the attempt sets the next time, or clears the failure.
        if retry { failure?.retryAfter = .distantFuture }
        lock.unlock()
        if let failed {
            if retry { queue.async { [self] in _ = ensureReady() } }
            throw SimBridgeError.failed(failed.message)
        }
        queue.async { [self] in
            guard ensureReady(), let connection else { return }
            xpc_connection_send_message(connection, message)
        }
    }

    /// On `queue`: connects and probes as needed. False when the daemon can't be reached, with the reason recorded.
    private func ensureReady() -> Bool {
        do {
            if connection == nil { try connect() }
            if !ready { try probe() }
            return true
        } catch {
            if let connection { xpc_connection_cancel(connection) }
            connection = nil
            ready = false
            lock.lock(); failure = (error.localizedDescription, Date() + Self.retryDelay); lock.unlock()
            return false
        }
    }

    /// On `queue`: looks up the guest's HID service and opens a connection to it.
    private func connect() throws {
        guard (device.value(forKey: "stateString") as? String) == "Booted" else {
            throw SimBridgeError.failed("The simulator is not booted.")
        }
        let lookup = NSSelectorFromString("lookup:error:")
        guard device.responds(to: lookup) else { throw SimBridgeError.unavailable("This Xcode's SimDevice has no lookup:error:.") }
        var error: NSError?
        let port = unsafeBitCast(device.method(for: lookup), to: LookupFunc.self)(device, lookup, Self.service as NSString, &error)
        guard port != MACH_PORT_NULL else {
            throw SimBridgeError.failed("Could not reach the simulator's input service\(error.map { ": \($0.localizedDescription)" } ?? ".")")
        }
        // The endpoint takes over the lookup's send right.
        guard let endpoint = makeEndpoint(port, 0, 0)?.takeRetainedValue() as? xpc_endpoint_t else {
            throw SimBridgeError.failed("Could not connect input to the simulator.")
        }
        let made = xpc_connection_create_from_endpoint(endpoint)
        // Without this the daemon sees the connection but never a message.
        enableSim2Host(made)
        xpc_connection_set_target_queue(made, queue)
        let id = ObjectIdentifier(made)
        xpc_connection_set_event_handler(made) { [weak self] event in
            guard let self, let current = self.connection, ObjectIdentifier(current) == id else { return }
            // Interrupted: dtuhidd exited (it does when idle) and the next send relaunches it, so probe first.
            // Invalid: the simulator shut down or rebooted, so look the service up again.
            if event === XPC_ERROR_CONNECTION_INVALID { self.connection = nil }
            self.ready = false
        }
        xpc_connection_resume(made)
        connection = made
        ready = false
    }

    /// On `queue`: sends a barrier the daemon has to answer and waits for the answer.
    private func probe() throws {
        guard let connection else { return }
        let answered = DispatchSemaphore(value: 0)
        var reply: xpc_object_t?
        xpc_connection_send_message_with_reply(connection, Self.barrierMessage(), .global()) { object in
            reply = object
            answered.signal()
        }
        guard answered.wait(timeout: .now() + Self.probeTimeout) == .success, let reply, xpc_get_type(reply) != XPC_TYPE_ERROR else {
            throw SimBridgeError.failed("The simulator's input service (dtuhidd) is not answering. Viber keeps trying; Simulator works meanwhile.")
        }
        // dtuhidd opens its HID device after answering; events before that are lost.
        Thread.sleep(forTimeInterval: Self.openTail)
        ready = true
        lock.lock(); failure = nil; lock.unlock()
    }

    // MARK: Messages

    /// The envelope dtuhidd decodes, around one event.
    static func message(_ type: String, _ payload: xpc_object_t, barrier: Bool = false) -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "messageType", type)
        xpc_dictionary_set_bool(message, "isBarrier", barrier)
        xpc_dictionary_set_string(message, "featureIdentifier", service)
        xpc_dictionary_set_value(message, "payload", payload)
        return message
    }

    /// dtuhidd decodes these fields as `uint64` only.
    private static func numbers(_ fields: KeyValuePairs<String, UInt64>) -> xpc_object_t {
        let dictionary = xpc_dictionary_create(nil, nil, 0)
        for (key, value) in fields { xpc_dictionary_set_uint64(dictionary, key, value) }
        return dictionary
    }

    /// One finger, from the top left. Edge 0 is a contact that didn't start at a screen edge; target 0 the main display.
    static func touchMessage(_ phase: SimTouchPhase, x: Double, y: Double) -> xpc_object_t {
        let eventType: UInt64
        switch phase {
        case .down: eventType = 0
        case .move: eventType = 1
        case .up: eventType = 2
        }
        let point = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_double(point, "x", min(max(x, 0), 1))
        xpc_dictionary_set_double(point, "y", min(max(y, 0), 1))
        let payload = numbers(["eventType": eventType, "edge": 0, "target": 0])
        xpc_dictionary_set_value(payload, "pointOne", point)
        return message("IndigoDigitizerEvent", payload)
    }

    /// Buttons as HID Consumer page (0x0C) usages: Power, Voice Command, Volume Increment and Decrement.
    static func buttonMessage(_ button: SimButton, down: Bool) -> xpc_object_t {
        let usage: UInt64
        switch button {
        case .lock: usage = 0x30
        case .siri: usage = 0xCF
        case .volumeUp: usage = 0xE9
        case .volumeDown: usage = 0xEA
        }
        return message("IndigoButtonEvent", numbers(["usagePage": 0x0C, "usageCode": usage, "state": down ? 1 : 2]))
    }

    static func keyMessage(usage: UInt32, down: Bool) -> xpc_object_t {
        message("IndigoKeyboardButtonEvent", numbers(["usageCode": UInt64(usage), "state": down ? 1 : 2]))
    }

    /// A key-up of usage 0 ("no event"): the daemon answers it without the guest seeing a key.
    static func barrierMessage() -> xpc_object_t {
        message("IndigoKeyboardButtonEvent", numbers(["usageCode": 0, "state": 2]), barrier: true)
    }
}
