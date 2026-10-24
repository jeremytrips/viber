import CoreMedia
import CoreVideo
import Darwin
import Foundation
import VideoToolbox

/// One scrcpy server on an Android device: its H.264 video, decoded into IOSurface-backed frames, and its control socket.
/// Sockets are read on their own threads; every callback arrives on the main queue.
public final class ScrcpySession: @unchecked Sendable {
    public let serial: String
    /// A new capture size (the first, or after a rotation), in video pixels.
    public var onSize: ((CGSize) -> Void)?
    /// A decoded frame, and whether it differs from the one before.
    public var onFrame: ((CVPixelBuffer, Bool) -> Void)?
    /// The stream ended; the message says why, unless `stop()` ended it.
    public var onEnd: ((String?) -> Void)?

    private let lock = NSLock()
    private var stopped = false
    private var videoFD: Int32 = -1
    private var controlFD: Int32 = -1
    private var port: Int?
    private var server: Process?
    private let controlQueue = DispatchQueue(label: "viber.scrcpy.control")
    private let log: URL

    public init(serial: String) {
        self.serial = serial
        log = FileManager.default.temporaryDirectory.appendingPathComponent("viber-scrcpy-\(serial).log")
    }

    /// The server jar Viber ships: in the app bundle, at VIBER_SCRCPY_SERVER, or in `.build/scrcpy/` for builds run from the repo.
    public static func serverJar() -> String? {
        let fm = FileManager.default
        if let bundled = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil), fm.fileExists(atPath: bundled.path) { return bundled.path }
        if let path = ProcessInfo.processInfo.environment["VIBER_SCRCPY_SERVER"], fm.fileExists(atPath: path) { return path }
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<4 {
            guard let current = dir else { break }
            let candidate = current.appendingPathComponent("scrcpy/scrcpy-server-v\(Scrcpy.version)")
            if fm.fileExists(atPath: candidate.path) { return candidate.path }
            dir = current.deletingLastPathComponent()
        }
        return nil
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// Pushes and starts the server, connects, and returns the first video size.
    public func start(jar: String) async throws -> CGSize {
        try await Adb.push(serial, jar, to: Scrcpy.devicePath)
        let scid = Scrcpy.randomSCID()
        let port = try await Adb.forward(serial, toSocket: Scrcpy.socketName(scid: scid))
        self.port = port
        guard let shell = Adb.shellInvocation(serial, Scrcpy.serverCommand(scid: scid, maxSize: 1600)) else {
            throw DeviceError.failed("adb was not found.")
        }
        let server = try Shell.spawn(shell.tool, shell.arguments, environment: shell.environment, output: log)
        self.server = server
        do {
            let size = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGSize, Error>) in
                Thread.detachNewThread { [self] in
                    do { continuation.resume(returning: try handshake(port: port, server: server)) } catch { continuation.resume(throwing: error) }
                }
            }
            let video = Thread { [self] in readVideo() }
            video.qualityOfService = .userInteractive
            video.start()
            Thread.detachNewThread { [self] in drainControl() }
            return size
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        // Unblocks the reader threads, which close their sockets as they leave.
        for fd in [videoFD, controlFD] where fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
        lock.unlock()
        guard !wasStopped else { return }
        if server?.isRunning == true { server?.terminate() }
        if let port {
            let serial = serial
            Task.detached { await Adb.removeForward(serial, port: port) }
        }
    }

    /// Sends a control message; dropped silently when the connection is gone.
    public func send(_ message: Data) {
        controlQueue.async { [self] in
            lock.lock(); let fd = controlFD; let done = stopped; lock.unlock()
            guard fd >= 0, !done else { return }
            _ = try? Socket.write(fd, message)
        }
    }

    // MARK: Threads

    /// Connects until the server answers with its dummy byte (adb accepts the connection before the server listens),
    /// then the control socket, then reads the device name, codec and first session packet.
    private func handshake(port: Int, server: Process) throws -> CGSize {
        let deadline = Date().addingTimeInterval(15)
        var video: Int32 = -1
        while video < 0 {
            if isStopped { throw CancellationError() }
            if !server.isRunning {
                throw DeviceError.failed("The screen server stopped: " + Shell.tail(log, lines: 6))
            }
            let fd = try Socket.connect(port: port)
            Socket.setReadTimeout(fd, seconds: 2)
            if (try? Socket.read(fd, 1)) != nil {
                video = fd
            } else {
                close(fd)
                if Date() >= deadline { throw DeviceError.failed("The screen server did not answer. " + Shell.tail(log, lines: 6)) }
                usleep(150_000)
            }
        }
        let control = try Socket.connect(port: port)
        lock.lock(); videoFD = video; controlFD = control; lock.unlock()
        Socket.setReadTimeout(video, seconds: 10)
        _ = try Socket.read(video, Scrcpy.deviceNameLength)
        let codec = try Socket.read(video, 4)
        guard Scrcpy.u32(codec) == Scrcpy.h264CodecID else { throw DeviceError.failed("The screen server sent an unexpected codec.") }
        guard case .session(let width, let height)? = Scrcpy.header(try Socket.read(video, Scrcpy.headerLength)) else {
            throw DeviceError.failed("The screen server sent no screen size.")
        }
        Socket.setReadTimeout(video, seconds: 0)
        return CGSize(width: width, height: height)
    }

    private func readVideo() {
        let decoder = H264Decoder()
        var waitingForKeyFrame = true
        var previous: [UInt8] = []
        decoder.onFrame = { [weak self] buffer in
            let print = H264Decoder.fingerprint(buffer)
            let changed = print != previous
            previous = print
            DispatchQueue.main.async { self?.onFrame?(buffer, changed) }
        }
        lock.lock(); let fd = videoFD; lock.unlock()
        reading: while !isStopped {
            guard let header = try? Socket.read(fd, Scrcpy.headerLength), let packet = Scrcpy.header(header) else { break }
            switch packet {
            case .session(let width, let height):
                waitingForKeyFrame = true
                DispatchQueue.main.async { [weak self] in self?.onSize?(CGSize(width: width, height: height)) }
            case .media(let config, let keyFrame, _, let size):
                guard let bytes = try? Socket.read(fd, size) else { break reading }
                let payload = Data(bytes)
                if config {
                    decoder.configure(payload)
                    continue
                }
                if keyFrame {
                    decoder.configure(payload)  // some encoders repeat SPS/PPS before key frames
                    waitingForKeyFrame = false
                } else if waitingForKeyFrame {
                    continue
                }
                if !decoder.decode(payload) {
                    // Without a key frame (scrcpy sends one every 10 s) the picture would stay broken: ask for one now.
                    waitingForKeyFrame = true
                    send(Scrcpy.resetVideo())
                }
            }
        }
        decoder.invalidate()
        lock.lock(); videoFD = -1; close(fd); lock.unlock()
        let message = isStopped ? nil : "The connection to the device's screen ended."
        stop()
        DispatchQueue.main.async { [weak self] in self?.onEnd?(message) }
    }

    /// The server writes clipboard messages on the control socket; read and drop them so it never blocks.
    private func drainControl() {
        lock.lock(); let fd = controlFD; lock.unlock()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !isStopped, Darwin.read(fd, &buffer, buffer.count) > 0 {}
        controlQueue.sync {
            lock.lock(); controlFD = -1; close(fd); lock.unlock()
        }
    }
}

/// H.264 to BGRA pixel buffers backed by IOSurfaces, which Core Animation shows directly.
final class H264Decoder {
    var onFrame: ((CVPixelBuffer) -> Void)?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var parameterSets: (sps: Data, pps: Data)?

    /// Takes the SPS/PPS in a config packet (or a key frame that repeats them). A new format gets a new session when
    /// the current one can't take it.
    func configure(_ packet: Data) {
        guard let sets = H264.parameterSets(packet) else { return }
        if let parameterSets, parameterSets.sps == sets.sps, parameterSets.pps == sets.pps, session != nil { return }
        var description: CMVideoFormatDescription?
        let status = sets.sps.withUnsafeBytes { sps in
            sets.pps.withUnsafeBytes { pps in
                let pointers = [sps.bindMemory(to: UInt8.self).baseAddress!, pps.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sets.sps.count, sets.pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                                                                           parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                           nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { return }
        parameterSets = sets
        format = description
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: description) { return }
        invalidate()
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
        ]
        var created: VTDecompressionSession?
        if VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description, decoderSpecification: nil,
                                        imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                        decompressionSessionOut: &created) == noErr {
            session = created
        }
    }

    /// Decodes one frame; false when it could not be.
    func decode(_ packet: Data) -> Bool {
        guard let session, let format else { return false }
        let avcc = H264.avcc(packet)
        guard !avcc.isEmpty else { return true }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return false }
        let copied = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        guard copied == noErr else { return false }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return false }
        var ok = true
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard status == noErr, let image else { ok = false; return }
            self?.onFrame?(image)
        }
        return status == noErr && ok
    }

    func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    /// A coarse brightness sample of the frame: equal for repeated frames, different when something visible changed.
    static func fingerprint(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return [] }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        let columns = 64, rows = 128
        var samples = [UInt8](repeating: 0, count: columns * rows)
        for j in 0..<rows {
            let y = (2 * j + 1) * height / (2 * rows)
            for i in 0..<columns {
                let p = base + y * row + (2 * i + 1) * width / (2 * columns) * 4
                samples[j * columns + i] = UInt8((Int(p[0]) + 2 * Int(p[1]) + Int(p[2])) / 4)
            }
        }
        return samples
    }
}

/// Blocking TCP to adb's forwarded port on localhost.
enum Socket {
    static func connect(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DeviceError.failed("Could not open a socket.") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            close(fd)
            throw DeviceError.failed("Could not connect to the device's screen server (port \(port)).")
        }
        return fd
    }

    /// 0 seconds: wait forever.
    static func setReadTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Exactly `count` bytes, or an error at the end of the stream.
    static func read(_ fd: Int32, _ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, count - got) }
            if n <= 0 { throw DeviceError.failed("The device's screen stream ended.") }
            got += n
        }
        return bytes
    }

    static func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { throw DeviceError.failed("The device's control connection closed.") }
                sent += n
            }
        }
    }
}
