import Foundation
import Observation
import ViberCore

/// Every device Viber knows and the live controllers for the ones in use. Devices are machine-wide, so sessions share
/// controllers: two sessions showing the same iPhone or Pixel see one stream.
@MainActor @Observable
final class DeviceHub {
    private(set) var devices: [DeviceInfo] = []
    private(set) var listError: String?
    private(set) var controllers: [String: any DeviceController] = [:]
    @ObservationIgnored private var listedAt = Date.distantPast
    @ObservationIgnored private var listing: Task<[DeviceInfo], Error>?

    /// The device list, re-read unless the last read is younger than `maxAge` seconds.
    @discardableResult
    func refresh(maxAge: TimeInterval = 0) async throws -> [DeviceInfo] {
        if Date().timeIntervalSince(listedAt) < maxAge, listError == nil { return devices }
        if let listing { return try await listing.value }
        let task = Task { () throws -> [DeviceInfo] in
            // Android listing never throws: a Mac without the SDK simply has no Android devices.
            async let android = Adb.devices()
            do {
                return DeviceCatalog.sorted(try await Simctl.devices() + (await android))
            } catch {
                let others = await android
                if others.isEmpty { throw error }
                return DeviceCatalog.sorted(others)
            }
        }
        listing = task
        defer { listing = nil }
        do {
            let list = try await task.value
            if list != devices { devices = list }
            listedAt = Date()
            listError = nil
            for device in list { controllers[device.id]?.update(device) }
            return list
        } catch {
            listError = error.localizedDescription
            throw error
        }
    }

    func device(_ id: String) -> DeviceInfo? { devices.first { $0.id == id } }

    func existingController(_ id: String) -> (any DeviceController)? { controllers[id] }

    func controller(for device: DeviceInfo) -> any DeviceController {
        if let controller = controllers[device.id] {
            controller.update(device)
            return controller
        }
        let controller: any DeviceController = device.platform == .android ? AndroidController(device: device) : SimulatorController(device: device)
        controllers[device.id] = controller
        return controller
    }

    /// Stops streams nobody has looked at or used for a minute. The simulators keep running.
    func reap() {
        for controller in controllers.values where !controller.isAttached && controller.activity == nil
            && Date().timeIntervalSince(controller.lastUsed) > 60 {
            controller.stopStream()
        }
    }
}
