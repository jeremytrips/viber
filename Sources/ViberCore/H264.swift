import Foundation

/// H.264 as Android's encoder sends it (Annex B: NAL units after 00 00 01 or 00 00 00 01 start codes),
/// and as VideoToolbox wants it (AVCC: each NAL unit after its 4-byte length, parameter sets kept apart).
public enum H264 {
    public static let sps: UInt8 = 7
    public static let pps: UInt8 = 8
    public static let accessUnitDelimiter: UInt8 = 9
    public static let idr: UInt8 = 5

    /// The NAL units of an Annex B stream, without their start codes.
    public static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(start: Int, payload: Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                let start = i > 0 && bytes[i - 1] == 0 ? i - 1 : i
                starts.append((start, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        return starts.indices.compactMap { n in
            let end = n + 1 < starts.count ? starts[n + 1].start : bytes.count
            let payload = starts[n].payload
            return payload < end ? Data(bytes[payload..<end]) : nil
        }
    }

    public static func type(_ nal: Data) -> UInt8 { (nal.first ?? 0) & 0x1F }

    /// The first SPS and PPS in a config packet (or a frame that repeats them).
    public static func parameterSets(_ data: Data) -> (sps: Data, pps: Data)? {
        let units = nalUnits(data)
        guard let sps = units.first(where: { type($0) == sps }), let pps = units.first(where: { type($0) == pps }) else { return nil }
        return (sps, pps)
    }

    /// The frame's NAL units with 4-byte big-endian lengths, leaving out parameter sets and delimiters,
    /// which VideoToolbox takes from the format description instead.
    public static func avcc(_ data: Data) -> Data {
        var out = Data()
        for nal in nalUnits(data) where ![sps, pps, accessUnitDelimiter].contains(type(nal)) {
            let n = UInt32(nal.count)
            out.append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
            out.append(nal)
        }
        return out
    }
}
