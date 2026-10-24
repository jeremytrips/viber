import Foundation

// Everything in this target talks to Apple's private simulator frameworks through the Objective-C runtime:
// nothing is linked or imported, so a missing or changed Xcode fails with an error instead of at launch.
// The approach follows serve-sim (github.com/EvanBacon/serve-sim, Apache-2.0) and idb (github.com/facebook/idb, MIT).

public enum SimBridgeError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self { case .unavailable(let m), .failed(let m): return m }
    }
}

/// Loads CoreSimulator and SimulatorKit from the active Xcode and finds devices.
public enum SimFrameworks {
    private static let lock = NSLock()
    private static var loaded: Result<Void, SimBridgeError>?
    private static var cachedDeveloperDir: String?

    /// The active Xcode's Developer folder, as `xcode-select -p` would say, read without starting a process
    /// (waiting for one on the main thread spins the run loop, and layout can re-enter Viber meanwhile).
    /// When only the command line tools are selected, the first Xcode in /Applications.
    public static var developerDir: String {
        lock.lock(); defer { lock.unlock() }
        if let cachedDeveloperDir { return cachedDeveloperDir }
        let fm = FileManager.default
        var dir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? (try? fm.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
            ?? "/Applications/Xcode.app/Contents/Developer"
        if !fm.fileExists(atPath: "\(dir)/Library/PrivateFrameworks") && !fm.fileExists(atPath: "\(dir)/../SharedFrameworks"),
           let xcode = (try? fm.contentsOfDirectory(atPath: "/Applications"))?.sorted()
               .first(where: { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }) {
            dir = "/Applications/\(xcode)/Contents/Developer"
        }
        cachedDeveloperDir = dir
        return dir
    }

    /// CoreSimulator's version, e.g. "1051.55". Xcode 27 (1155 and later) stopped accepting Indigo input.
    public static var coreSimulatorVersion: Double? {
        let plist = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/Info.plist"
        guard let info = NSDictionary(contentsOfFile: plist), let version = info["CFBundleVersion"] as? String else { return nil }
        let parts = version.split(separator: ".").prefix(2).joined(separator: ".")
        return Double(parts)
    }

    public static func load() throws {
        let dev = developerDir
        lock.lock(); defer { lock.unlock() }
        if let loaded { return try loaded.get() }
        let result: Result<Void, SimBridgeError>
        if dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW) == nil {
            result = .failure(.unavailable("CoreSimulator is not installed. Install Xcode and open it once to add its components."))
        } else {
            // Xcode 27 moved SimulatorKit from Developer/Library/PrivateFrameworks to Contents/SharedFrameworks.
            let kit = ["\(dev)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
                       "\(dev)/../SharedFrameworks/SimulatorKit.framework/SimulatorKit"]
            if kit.contains(where: { dlopen($0, RTLD_NOW) != nil }) {
                result = .success(())
            } else {
                result = .failure(.unavailable("SimulatorKit was not found in \(dev). Is Xcode (not only the command line tools) selected with xcode-select?"))
            }
        }
        loaded = result
        try result.get()
    }

    /// The `SimDevice` with this UDID, from the default device set.
    public static func device(udid: String) throws -> NSObject {
        try load()
        guard let contextClass = NSClassFromString("SimServiceContext") as? NSObject.Type else {
            throw SimBridgeError.unavailable("This Xcode's CoreSimulator has no SimServiceContext.")
        }
        let shared = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard contextClass.responds(to: shared),
              let context = contextClass.perform(shared, with: developerDir, with: nil)?.takeUnretainedValue() as? NSObject else {
            throw SimBridgeError.unavailable("Could not reach CoreSimulator.")
        }
        let defaultSet = NSSelectorFromString("defaultDeviceSetWithError:")
        guard context.responds(to: defaultSet),
              let set = context.perform(defaultSet, with: nil)?.takeUnretainedValue() as? NSObject,
              let devices = set.value(forKey: "devices") as? [NSObject] else {
            throw SimBridgeError.unavailable("Could not read the simulator device set.")
        }
        guard let device = devices.first(where: { ($0.value(forKey: "UDID") as? NSUUID)?.uuidString == udid }) else {
            throw SimBridgeError.failed("No simulator with id \(udid).")
        }
        return device
    }

    /// Native screen size in pixels and the scale factor, from the device type.
    public static func screen(of device: NSObject) -> (pixels: CGSize, scale: Double)? {
        guard let type = device.value(forKey: "deviceType") as? NSObject else { return nil }
        let sizeSel = NSSelectorFromString("mainScreenSize"), scaleSel = NSSelectorFromString("mainScreenScale")
        guard type.responds(to: sizeSel), type.responds(to: scaleSel) else { return nil }
        // Typed IMPs keep the CGSize and float return ABI right.
        typealias GetSize = @convention(c) (AnyObject, Selector) -> CGSize
        typealias GetFloat = @convention(c) (AnyObject, Selector) -> Float
        let size = unsafeBitCast(type.method(for: sizeSel), to: GetSize.self)(type, sizeSel)
        let scale = unsafeBitCast(type.method(for: scaleSel), to: GetFloat.self)(type, scaleSel)
        guard size.width > 0, size.height > 0, scale > 0 else { return nil }
        return (size, Double(scale))
    }
}
