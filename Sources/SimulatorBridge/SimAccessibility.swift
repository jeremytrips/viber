import AppKit
import Foundation

/// The accessibility tree of the app in front on a simulator, through the private AccessibilityPlatformTranslation
/// framework. Its `AXPTranslator` asks a delegate to carry each request to the device, which CoreSimulator does with
/// `-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]`. Ported from serve-sim's
/// AccessibilityBridge, itself a port of idb's FBSimulatorAccessibilityCommands.
///
/// Calls block on XPC round trips: never call them on the main thread.
public final class SimAccessibility: NSObject {
    public static let shared = SimAccessibility()

    /// One element: `label`, `value`, `identifier`, `role`, `roleDescription`, `enabled`, `frame` (points) and `children`.
    public struct Node: Sendable {
        public var label: String?
        public var value: String?
        public var identifier: String?
        public var role: String
        public var roleDescription: String?
        public var enabled: Bool
        public var frame: CGRect
        public var children: [Node]
    }

    private static let maxElements = 600
    private static let maxDepth = 80

    private let queue = DispatchQueue(label: "viber.simulator.accessibility", qos: .userInitiated)
    private let lock = NSLock()
    private var devices: [String: NSObject] = [:]
    private var translator: NSObject?

    private override init() { super.init() }

    private func translatorObject() throws -> NSObject {
        lock.lock(); defer { lock.unlock() }
        if let translator { return translator }
        guard dlopen("/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation", RTLD_NOW) != nil,
              let type = NSClassFromString("AXPTranslator") as? NSObject.Type,
              let shared = type.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject else {
            throw SimBridgeError.unavailable("macOS's AccessibilityPlatformTranslation framework is missing, so the simulator's UI tree cannot be read.")
        }
        // Token delegation lets one translator serve several devices at once; idb sets only this delegate.
        shared.setValue(self, forKey: "bridgeTokenDelegate")
        shared.setValue(true, forKey: "supportsDelegateTokens")
        shared.setValue(true, forKey: "accessibilityEnabled")
        translator = shared
        return shared
    }

    /// The frontmost app's tree. Elements that the plain walk misses (some scroll and collection views hide their
    /// children) are found by hit-testing a grid of points, as idb does.
    public func tree(udid: String, probe: Bool = true) throws -> Node {
        let (translator, token) = try begin(udid: udid)
        defer { end(token) }
        let frontmost = NSSelectorFromString("frontmostApplicationWithDisplayId:bridgeDelegateToken:")
        typealias Frontmost = @convention(c) (AnyObject, Selector, UInt32, NSString) -> AnyObject?
        guard translator.responds(to: frontmost),
              let translation = unsafeBitCast(translator.method(for: frontmost), to: Frontmost.self)(translator, frontmost, 0, token as NSString) as? NSObject,
              let root = element(for: translation, translator: translator, token: token) else {
            throw SimBridgeError.failed("The simulator has no app in front yet (it may still be starting).")
        }
        var walk = Walk(token: token)
        guard var node = serialize(root, walk: &walk, depth: 0) else {
            throw SimBridgeError.failed("The simulator returned an empty UI tree.")
        }
        if probe, node.frame.width > 1, node.frame.height > 1 {
            node.children += discover(in: node.frame, translator: translator, walk: &walk)
        }
        return node
    }

    /// The deepest element under `point` (in points), for the element picker.
    public func element(at point: CGPoint, udid: String) throws -> Node? {
        let (translator, token) = try begin(udid: udid)
        defer { end(token) }
        guard let found = hit(point, translator: translator, token: token) else { return nil }
        var walk = Walk(token: token)
        return serialize(found, walk: &walk, depth: Self.maxDepth)
    }

    // MARK: Requests

    private func begin(udid: String) throws -> (NSObject, String) {
        let translator = try translatorObject()
        let device = try SimFrameworks.device(udid: udid)
        guard device.responds(to: NSSelectorFromString("sendAccessibilityRequestAsync:completionQueue:completionHandler:")) else {
            throw SimBridgeError.unavailable("This Xcode's simulator cannot answer accessibility requests.")
        }
        let token = UUID().uuidString
        lock.lock(); devices[token] = device; lock.unlock()
        return (translator, token)
    }

    private func end(_ token: String) {
        lock.lock(); devices[token] = nil; lock.unlock()
    }

    private func element(for translation: NSObject, translator: NSObject, token: String) -> NSObject? {
        translation.setValue(token, forKey: "bridgeDelegateToken")
        let convert = NSSelectorFromString("macPlatformElementFromTranslation:")
        typealias Convert = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
        guard translator.responds(to: convert),
              let element = unsafeBitCast(translator.method(for: convert), to: Convert.self)(translator, convert, translation) as? NSObject else { return nil }
        (element.value(forKey: "translation") as? NSObject)?.setValue(token, forKey: "bridgeDelegateToken")
        return element
    }

    private func hit(_ point: CGPoint, translator: NSObject, token: String) -> NSObject? {
        let atPoint = NSSelectorFromString("objectAtPoint:displayId:bridgeDelegateToken:")
        typealias AtPoint = @convention(c) (AnyObject, Selector, CGPoint, UInt32, NSString) -> AnyObject?
        guard translator.responds(to: atPoint),
              let translation = unsafeBitCast(translator.method(for: atPoint), to: AtPoint.self)(translator, atPoint, point, 0, token as NSString) as? NSObject
        else { return nil }
        return element(for: translation, translator: translator, token: token)
    }

    // MARK: Walking

    private struct Walk {
        var token: String
        var visited = Set<ObjectIdentifier>()
        var remaining = SimAccessibility.maxElements
        /// Frames already described, rounded, so hit-testing skips them.
        var seen = Set<String>()
        var leaves: [CGRect] = []

        static func key(_ r: CGRect) -> String { "\(Int(r.minX.rounded())),\(Int(r.minY.rounded())),\(Int(r.width.rounded())),\(Int(r.height.rounded()))" }
    }

    private func serialize(_ element: NSObject, walk: inout Walk, depth: Int) -> Node? {
        guard walk.remaining > 0, walk.visited.insert(ObjectIdentifier(element)).inserted else { return nil }
        walk.remaining -= 1
        (element.value(forKey: "translation") as? NSObject)?.setValue(walk.token, forKey: "bridgeDelegateToken")
        let ax = element as? NSAccessibilityElement
        let frame = ax?.accessibilityFrame() ?? (element.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
        var role = string(element, "accessibilityRole") ?? ""
        if role.hasPrefix("AX") { role.removeFirst(2) }
        var node = Node(label: string(element, "accessibilityLabel"), value: string(element, "accessibilityValue"),
                        identifier: string(element, "accessibilityIdentifier"), role: role,
                        roleDescription: string(element, "accessibilityRoleDescription"),
                        enabled: (element.value(forKey: "accessibilityEnabled") as? NSNumber)?.boolValue ?? true,
                        frame: frame, children: [])
        if depth < Self.maxDepth {
            let children = ax?.accessibilityChildren() ?? (element.value(forKey: "accessibilityChildren") as? [Any]) ?? []
            for case let child as NSObject in children where walk.remaining > 0 {
                if let childNode = serialize(child, walk: &walk, depth: depth + 1) { node.children.append(childNode) }
            }
        }
        walk.seen.insert(Walk.key(frame))
        // Big or childless-but-large elements stay probe-able: navigation and tab bars hide their content that way.
        if node.children.isEmpty && max(frame.width, frame.height) < 250 { walk.leaves.append(frame) }
        return node
    }

    private func discover(in bounds: CGRect, translator: NSObject, walk: inout Walk) -> [Node] {
        var found: [Node] = []
        let step: CGFloat = 32
        var budget = 600
        var y = bounds.minY + step / 2
        while y < bounds.maxY, budget > 0, walk.remaining > 0 {
            var x = bounds.minX + step / 2
            while x < bounds.maxX, budget > 0, walk.remaining > 0 {
                let point = CGPoint(x: x, y: y)
                x += step
                if walk.leaves.contains(where: { $0.contains(point) }) { continue }
                budget -= 1
                guard let element = hit(point, translator: translator, token: walk.token) else { continue }
                let frame = (element as? NSAccessibilityElement)?.accessibilityFrame() ?? .zero
                if walk.seen.contains(Walk.key(frame)) { continue }
                if abs(frame.width - bounds.width) < 1, abs(frame.height - bounds.height) < 1 {
                    walk.seen.insert(Walk.key(frame))
                    continue
                }
                if let node = serialize(element, walk: &walk, depth: 0) { found.append(node) }
            }
            y += step
        }
        return found
    }

    private func string(_ object: NSObject, _ key: String) -> String? {
        let value = object.value(forKey: key)
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let s = (value as? NSAttributedString)?.string { return s.isEmpty ? nil : s }
        return value.map { String(describing: $0) }
    }

    // MARK: AXPTranslationTokenDelegateHelper (the translator calls these; the selectors must match)

    @objc(accessibilityTranslationDelegateBridgeCallbackWithToken:)
    func bridgeCallback(token: String) -> AnyObject {
        let block: @convention(block) (AnyObject?) -> AnyObject? = { [weak self] request in
            guard let self, let request else { return Self.emptyResponse() }
            self.lock.lock()
            let device = self.devices[token]
            self.lock.unlock()
            guard let device else { return Self.emptyResponse() }
            return self.run(request, on: device)
        }
        return block as AnyObject
    }

    @objc(accessibilityTranslationConvertPlatformFrameToSystem:withToken:)
    func convertFrame(_ rect: NSRect, withToken token: String) -> NSRect { rect }

    @objc(accessibilityTranslationRootParentWithToken:)
    func rootParent(withToken token: String) -> AnyObject? { nil }

    /// The translator wants each answer synchronously, so wait for CoreSimulator's async reply.
    private func run(_ request: AnyObject, on device: NSObject) -> AnyObject? {
        let selector = NSSelectorFromString("sendAccessibilityRequestAsync:completionQueue:completionHandler:")
        final class Box { var value: AnyObject? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let completion: @convention(block) (AnyObject?) -> Void = { response in
            box.value = response
            done.signal()
        }
        typealias Send = @convention(c) (AnyObject, Selector, AnyObject, DispatchQueue, AnyObject) -> Void
        unsafeBitCast(device.method(for: selector), to: Send.self)(device, selector, request, queue, completion as AnyObject)
        if done.wait(timeout: .now() + 5) == .timedOut { return Self.emptyResponse() }
        return box.value ?? Self.emptyResponse()
    }

    private static func emptyResponse() -> AnyObject? {
        guard let type = NSClassFromString("AXPTranslatorResponse") as? NSObject.Type else { return nil }
        return type.perform(NSSelectorFromString("emptyResponse"))?.takeUnretainedValue()
    }
}
