import CoreGraphics
import Foundation
import IOSurface

/// A booted simulator's screen as a live IOSurface, without Simulator.app.
/// Registering screen callbacks on the framebuffer port's descriptor is what makes SimulatorKit fill `framebufferSurface`;
/// each read of it is an XPC round trip, so the surface is cached and re-read only when the simulator says it changed.
public final class SimScreen {
    public let udid: String
    /// Called on `queue` when the surface is first known or replaced (rotation, resolution change).
    public var onSurface: ((IOSurface) -> Void)?
    /// Called on `queue` whenever the simulator drew a frame into the surface.
    public var onFrame: (() -> Void)?
    public private(set) var surface: IOSurface?
    /// Native screen size in pixels and the point scale, when the device type reports them.
    public let native: (pixels: CGSize, scale: Double)?

    private let queue: DispatchQueue
    private let device: NSObject
    private var descriptors: [NSObject] = []
    private var registrations: [(NSObject, UUID)] = []
    private var chosen: NSObject?

    public init(udid: String, queue: DispatchQueue = .main) throws {
        self.udid = udid
        self.queue = queue
        device = try SimFrameworks.device(udid: udid)
        native = SimFrameworks.screen(of: device)
    }

    deinit { stop() }

    public var isBooted: Bool { (device.value(forKey: "stateString") as? String) == "Booted" }

    public func start() throws {
        stop()
        guard isBooted else { throw SimBridgeError.failed("The simulator is not booted.") }
        guard let io = device.perform(NSSelectorFromString("io"))?.takeUnretainedValue() as? NSObject else {
            throw SimBridgeError.unavailable("This Xcode's SimDevice has no IO client.")
        }
        let update = NSSelectorFromString("updateIOPorts")
        if io.responds(to: update) { io.perform(update) }
        descriptors = try Self.framebufferDescriptors(io)
        for descriptor in descriptors { try register(descriptor) }
        refreshSurface()
    }

    public func stop() {
        let unregister = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
        for (descriptor, uuid) in registrations where descriptor.responds(to: unregister) {
            descriptor.perform(unregister, with: uuid)
        }
        registrations = []
        descriptors = []
        chosen = nil
        surface = nil
    }

    private static func framebufferDescriptors(_ io: NSObject) throws -> [NSObject] {
        guard let ports = io.value(forKey: "deviceIOPorts") as? [NSObject] else {
            throw SimBridgeError.unavailable("Could not list the simulator's IO ports.")
        }
        let portID = NSSelectorFromString("portIdentifier"), descriptorSel = NSSelectorFromString("descriptor")
        let surfaceSel = NSSelectorFromString("framebufferSurface")
        let found = ports.compactMap { port -> NSObject? in
            guard port.responds(to: portID), let id = port.perform(portID)?.takeUnretainedValue(),
                  "\(id)" == "com.apple.framebuffer.display", port.responds(to: descriptorSel),
                  let descriptor = port.perform(descriptorSel)?.takeUnretainedValue() as? NSObject,
                  descriptor.responds(to: surfaceSel) else { return nil }
            return descriptor
        }
        if found.isEmpty { throw SimBridgeError.unavailable("The simulator has no framebuffer display this Viber understands.") }
        return found
    }

    private func register(_ descriptor: NSObject) throws {
        let uuid = UUID()
        let frame: @convention(block) () -> Void = { [weak self, weak descriptor] in
            guard let self, let descriptor else { return }
            if self.chosen == nil || self.chosen === descriptor {
                if self.surface == nil { self.refreshSurface() }
                self.onFrame?()
            }
        }
        let surfacesChanged: @convention(block) () -> Void = { [weak self] in self?.refreshSurface() }
        let propertiesChanged: @convention(block) () -> Void = { [weak self] in self?.refreshSurface() }
        let modern = NSSelectorFromString("registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:")
        if descriptor.responds(to: modern) {
            (descriptor as AnyObject).registerScreenCallbacks(uuid: uuid, callbackQueue: queue, frameCallback: frame,
                                                               surfacesChangedCallback: surfacesChanged,
                                                               propertiesChangedCallback: propertiesChanged)
            registrations.append((descriptor, uuid))
            return
        }
        // Older SimulatorKit: separate surface and damage callbacks, called on CoreSimulator's own queue.
        let legacySurface = NSSelectorFromString("registerCallbackWithUUID:ioSurfacesChangeCallback:")
        let legacyDamage = NSSelectorFromString("registerCallbackWithUUID:damageRectanglesCallback:")
        guard descriptor.responds(to: legacySurface), descriptor.responds(to: legacyDamage) else {
            throw SimBridgeError.unavailable("This Xcode's simulator display has no frame callbacks Viber knows.")
        }
        let queue = self.queue
        let onSurfaces: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, _ in queue.async { surfacesChanged() } }
        let onDamage: @convention(block) (AnyObject?) -> Void = { _ in queue.async { frame() } }
        typealias Register = @convention(c) (AnyObject, Selector, NSUUID, AnyObject) -> Void
        unsafeBitCast(descriptor.method(for: legacySurface), to: Register.self)(descriptor, legacySurface, uuid as NSUUID, onSurfaces as AnyObject)
        unsafeBitCast(descriptor.method(for: legacyDamage), to: Register.self)(descriptor, legacyDamage, uuid as NSUUID, onDamage as AnyObject)
        registrations.append((descriptor, uuid))
    }

    /// Picks the descriptor whose surface matches the device's native screen (Xcode 27 can add a huge
    /// presentation surface), else the largest live one, and caches its surface.
    private func refreshSurface() {
        let surfaceSel = NSSelectorFromString("framebufferSurface")
        let live = descriptors.compactMap { descriptor -> (NSObject, IOSurface)? in
            guard let object = descriptor.perform(surfaceSel)?.takeUnretainedValue() else { return nil }
            let surface = unsafeBitCast(object, to: IOSurface.self)
            guard IOSurfaceGetWidth(surface) > 0, IOSurfaceGetHeight(surface) > 0 else { return nil }
            return (descriptor, surface)
        }
        func matchesNative(_ s: IOSurface) -> Bool {
            guard let px = native?.pixels else { return false }
            let w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s)
            return (w == Int(px.width) && h == Int(px.height)) || (w == Int(px.height) && h == Int(px.width))
        }
        let pick = live.first { matchesNative($0.1) }
            ?? live.max { IOSurfaceGetWidth($0.1) * IOSurfaceGetHeight($0.1) < IOSurfaceGetWidth($1.1) * IOSurfaceGetHeight($1.1) }
        guard let (descriptor, surface) = pick else { return }
        chosen = descriptor
        if self.surface.map({ IOSurfaceGetID($0) }) != IOSurfaceGetID(surface) {
            self.surface = surface
            onSurface?(surface)
        }
    }
}

/// Lets Swift call the block-taking registration selector by name on an `AnyObject`.
@objc private protocol SimScreenDescriptor {
    @objc(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:)
    func registerScreenCallbacks(uuid: UUID, callbackQueue: DispatchQueue,
                                 frameCallback: @convention(block) @escaping () -> Void,
                                 surfacesChangedCallback: @convention(block) @escaping () -> Void,
                                 propertiesChangedCallback: @convention(block) @escaping () -> Void)
}
