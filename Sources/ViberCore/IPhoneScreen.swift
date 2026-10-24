import AVFoundation
import CoreMediaIO
import CoreVideo
import Foundation

/// A USB iPhone's screen as live video, the way QuickTime Player records one: once asked, CoreMediaIO offers connected
/// iPhones as capture devices. Public API, but USB only, and macOS asks for Camera access first. While it streams, the
/// phone sends its sound to the capture instead of its speaker, so the Mac plays it. Callbacks arrive on the main queue.
public final class IPhoneScreen: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// A frame, and whether it differs from the one before.
    public var onFrame: ((CVPixelBuffer, Bool) -> Void)?
    /// The stream ended without `stop()`: the message says why.
    public var onEnd: ((String) -> Void)?

    private let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private let frames = DispatchQueue(label: "viber.iphone-screen.frames", qos: .userInteractive)
    private let control = DispatchQueue(label: "viber.iphone-screen.session")
    private var previous: [UInt8] = []
    private var observers: [NSObjectProtocol] = []
    private var stopped = false

    public init(device: AVCaptureDevice) {
        self.device = device
        super.init()
    }

    /// Lets CoreMediaIO offer iPhones as capture devices. They appear a moment later.
    public static func allowPhones() {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    /// Which of the offered screens is the phone's. Their ids are neither the UDID nor CoreDevice's identifier (macOS 26),
    /// so the phone's name decides, else (`orOnly`) the only screen there is. `screens` are (unique id, name) pairs.
    static func pick(_ screens: [(id: String, name: String)], udid: String?, name: String, orOnly: Bool) -> Int? {
        func plain(_ s: String) -> String { s.replacingOccurrences(of: "-", with: "").lowercased() }
        if let udid, let i = screens.firstIndex(where: { plain($0.id) == plain(udid) }) { return i }
        if let i = screens.firstIndex(where: { $0.name == name }) { return i }
        return orOnly && screens.count == 1 ? 0 : nil
    }

    /// The phone's screen as a capture device, waiting up to `timeout` for CoreMediaIO to offer it. Screens are muxed
    /// (picture and sound), unlike the phone's Continuity Camera, which is offered too. `orOnly` takes the only screen
    /// when the name doesn't match (the phone was renamed); not for a phone devicectl sees on Wi-Fi, whose screen can't be there.
    public static func captureDevice(udid: String?, name: String, timeout: TimeInterval, orOnly: Bool) async -> AVCaptureDevice? {
        allowPhones()
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled {
            let screens = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
            if let i = pick(screens.map { ($0.uniqueID, $0.localizedName) }, udid: udid, name: name, orOnly: orOnly) { return screens[i] }
            if Date() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    /// Camera access, asking when macOS hasn't asked yet. The app's Info.plist needs NSCameraUsageDescription, or asking crashes it.
    public static func cameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    public func start() async throws {
        let input = try AVCaptureDeviceInput(device: device)
        let sound = AVCaptureAudioPreviewOutput()
        sound.volume = 1
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frames)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw DeviceError.failed("macOS would not stream the phone's screen.")
        }
        session.addInput(input)
        session.addOutput(output)
        if session.canAddOutput(sound) { session.addOutput(sound) }
        session.commitConfiguration()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main) { [weak self] _ in
            self?.end("The phone was unplugged.")
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.end("The phone's screen stream stopped" + (error.map { ": \($0.localizedDescription)" } ?? "."))
        })
        // startRunning blocks until the stream is up.
        let session = session
        let running = await withCheckedContinuation { continuation in
            control.async {
                session.startRunning()
                continuation.resume(returning: session.isRunning)
            }
        }
        guard running else {
            stop()
            throw DeviceError.failed("macOS could not start streaming the phone's screen. Unlock it, or unplug it and plug it in again.")
        }
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        let session = session
        control.async { session.stopRunning() }
    }

    private func end(_ message: String) {
        guard !stopped else { return }
        stop()
        onEnd?(message)
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let print = H264Decoder.fingerprint(buffer)
        let changed = print != previous
        previous = print
        DispatchQueue.main.async { [weak self] in self?.onFrame?(buffer, changed) }
    }
}
