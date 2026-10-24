import Foundation

/// The parts of scrcpy's protocol Viber speaks: starting the pinned server, reading its video stream, and writing
/// control messages. See doc/develop.md and app/src/control_msg.c at the v5.0.1 tag.
public enum Scrcpy {
    /// The server version Viber ships. The server refuses to start for any other version argument;
    /// Scripts/fetch-scrcpy-server.sh pins the same one.
    public static let version = "5.0.1"
    /// Where the server goes on the device. Viber's own name, so a scrcpy the user runs doesn't overwrite it.
    public static let devicePath = "/data/local/tmp/viber-scrcpy-server.jar"
    /// "h264" as the u32 codec id the video socket starts with.
    public static let h264CodecID: UInt32 = 0x6832_3634
    /// The device name the first socket sends after the dummy byte.
    public static let deviceNameLength = 64

    /// A client id for the device-side socket name. The server reads it as a Java int.
    public static func randomSCID() -> UInt32 { UInt32.random(in: 1...0x7FFF_FFFF) }

    public static func socketName(scid: UInt32) -> String { "scrcpy_" + String(format: "%08x", scid) }

    /// The remote command that runs the server: video and control over a forward tunnel, no audio.
    /// `maxSize` caps the longer side of the video.
    public static func serverCommand(scid: UInt32, maxSize: Int) -> String {
        let options = [
            "scid=" + String(format: "%08x", scid), "log_level=info", "tunnel_forward=true", "audio=false", "control=true",
            "video_codec=h264", "max_size=\(maxSize)", "clipboard_autosync=false", "power_on=true", "cleanup=true",
        ]
        return (["CLASSPATH=\(devicePath)", "app_process", "/", "com.genymobile.scrcpy.Server", version] + options).joined(separator: " ")
    }

    // MARK: Video stream

    public enum Packet: Equatable, Sendable {
        /// A new capture session (the first, or after a rotation): the video's size in pixels.
        case session(width: Int, height: Int)
        /// Encoded video: `config` packets carry the parameter sets (SPS/PPS), the others frames.
        case media(config: Bool, keyFrame: Bool, pts: UInt64, size: Int)
    }

    public static let headerLength = 12

    /// The 12-byte header before every packet. The most significant bit tells session packets from media packets.
    public static func header(_ bytes: [UInt8]) -> Packet? {
        guard bytes.count >= headerLength else { return nil }
        if bytes[0] & 0x80 != 0 {
            return .session(width: Int(u32(bytes, 4)), height: Int(u32(bytes, 8)))
        }
        var pts: UInt64 = 0
        for i in 0..<8 { pts = pts << 8 | UInt64(bytes[i]) }
        pts &= (1 << 61) - 1
        return .media(config: bytes[0] & 0x40 != 0, keyFrame: bytes[0] & 0x20 != 0, pts: pts, size: Int(u32(bytes, 8)))
    }

    public static func u32(_ bytes: [UInt8], _ at: Int = 0) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }

    // MARK: Control messages

    public enum MessageType: UInt8 {
        case injectKeycode = 0, injectText = 1, injectTouch = 2, injectScroll = 3, backOrScreenOn = 4
        case setClipboard = 9, resetVideo = 17
    }

    public enum KeyAction: UInt8 { case down = 0, up = 1 }
    public enum TouchAction: UInt8 { case down = 0, up = 1, move = 2 }

    /// A finger on the touchscreen, as opposed to the mouse (-1).
    public static let fingerPointerID = UInt64(bitPattern: -2)
    /// Most UTF-8 bytes one text message may carry.
    public static let textLimit = 300

    public static func keycode(_ action: KeyAction, _ keycode: Int32, repeat count: UInt32 = 0, meta: UInt32 = 0) -> Data {
        var m = Message(.injectKeycode)
        m.u8(action.rawValue); m.u32(UInt32(bitPattern: keycode)); m.u32(count); m.u32(meta)
        return m.data
    }

    /// Text as one or more messages of at most `textLimit` bytes, split between characters.
    public static func text(_ text: String) -> [Data] {
        var messages: [Data] = [], chunk = ""
        func flush() {
            guard !chunk.isEmpty else { return }
            var m = Message(.injectText)
            m.string(chunk)
            messages.append(m.data)
            chunk = ""
        }
        for character in text {
            if chunk.utf8.count + String(character).utf8.count > textLimit { flush() }
            chunk.append(character)
        }
        flush()
        return messages
    }

    /// A touch at `x`, `y` in the video's pixels; `width` and `height` must be the current video size or the server drops it.
    public static func touch(_ action: TouchAction, x: Int, y: Int, width: Int, height: Int, pointer: UInt64 = fingerPointerID) -> Data {
        var m = Message(.injectTouch)
        m.u8(action.rawValue); m.u64(pointer)
        m.u32(UInt32(bitPattern: Int32(clamping: x))); m.u32(UInt32(bitPattern: Int32(clamping: y)))
        m.u16(UInt16(clamping: width)); m.u16(UInt16(clamping: height))
        m.u16(action == .up ? 0 : 0xFFFF)  // pressure
        m.u32(0); m.u32(0)  // action button, buttons: none for a finger
        return m.data
    }

    /// Sets the device's clipboard; `paste` also pastes it where the cursor is. Sequence 0 asks for no acknowledgement.
    public static func setClipboard(_ text: String, paste: Bool, sequence: UInt64 = 0) -> Data {
        var m = Message(.setClipboard)
        m.u64(sequence); m.u8(paste ? 1 : 0); m.string(text)
        return m.data
    }

    /// Asks the encoder for a fresh key frame, after a decoding error.
    public static func resetVideo() -> Data { Message(.resetVideo).data }

    struct Message {
        var data: Data
        init(_ type: MessageType) { data = Data([type.rawValue]) }
        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }
        mutating func u32(_ v: UInt32) { for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8(v >> UInt32(shift) & 0xFF)) } }
        mutating func u64(_ v: UInt64) { for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(v >> UInt64(shift) & 0xFF)) } }
        mutating func string(_ s: String) {
            let bytes = Array(s.utf8)
            u32(UInt32(bytes.count))
            data.append(contentsOf: bytes)
        }
    }
}

/// Android key codes (android.view.KeyEvent) Viber sends.
public enum AndroidKey {
    public static let home: Int32 = 3
    public static let back: Int32 = 4
    public static let volumeUp: Int32 = 24
    public static let volumeDown: Int32 = 25
    public static let power: Int32 = 26
    public static let a: Int32 = 29
    public static let enter: Int32 = 66
    public static let del: Int32 = 67
    public static let appSwitch: Int32 = 187
    /// META_CTRL_ON | META_CTRL_LEFT_ON
    public static let metaCtrl: UInt32 = 0x3000

    public static func code(_ button: DeviceButton) -> Int32? {
        switch button {
        case .home: return home
        case .back: return back
        case .app_switch: return appSwitch
        case .lock: return power
        case .volume_up: return volumeUp
        case .volume_down: return volumeDown
        case .siri: return nil
        }
    }

    /// Keys on a Mac keyboard that don't type text, by virtual key code. Printable keys go over as text instead.
    public static func code(macKeyCode: UInt16) -> Int32? {
        [0x24: enter, 0x4C: enter, 0x33: del, 0x75: 112 /* FORWARD_DEL */, 0x30: 61 /* TAB */, 0x35: 111 /* ESCAPE */,
         0x7B: 21, 0x7C: 22, 0x7D: 20, 0x7E: 19 /* DPAD left, right, down, up */,
         0x73: 122, 0x77: 123 /* MOVE_HOME, MOVE_END */, 0x74: 92, 0x79: 93 /* PAGE_UP, PAGE_DOWN */][macKeyCode]
    }
}
