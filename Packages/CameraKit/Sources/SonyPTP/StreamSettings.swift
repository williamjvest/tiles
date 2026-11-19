import Foundation

/// The camera's stream destinations, as SDIO_GetStreamSettingList (0x9241) gives them and SDIO_SetStreamSettingList
/// (0x9242) takes them: on an FX5 RTMP/RTMPS 1–3 and SRT-Caller
/// 1–3, numbered as Video Stream 1–6. Both wrap the list in an SDIStreamSettingList dataset: its offset and size, then
/// the list. Strings carry their null, and their lengths count it.
public struct StreamSettingList: Equatable, Sendable {
    /// The list's data version (100× the value), echoed back in a set.
    public var version: UInt16
    public var streams: [StreamSetting]

    public init(version: UInt16, streams: [StreamSetting]) {
        self.version = version
        self.streams = streams
    }

    public struct StreamSetting: Equatable, Sendable {
        /// Bit 0 RTMP, bit 1 SRT.
        public var protocolBits: UInt8
        /// Which protocols this destination may use (a get's only).
        public var permission: UInt8?
        public var url: String
        public var port: UInt32?
        public var key: String?
        public var latency: UInt16?
        public var ttl: UInt8?
        public var cipherType: UInt8?
        public var cipherKey: String?
        public var mode: UInt8?

        public init(protocolBits: UInt8, permission: UInt8? = nil, url: String, port: UInt32? = nil, key: String? = nil,
                    latency: UInt16? = nil, ttl: UInt8? = nil, cipherType: UInt8? = nil, cipherKey: String? = nil,
                    mode: UInt8? = nil) {
            self.protocolBits = protocolBits
            self.permission = permission
            self.url = url
            self.port = port
            self.key = key
            self.latency = latency
            self.ttl = ttl
            self.cipherType = cipherType
            self.cipherKey = cipherKey
            self.mode = mode
        }

        public static let rtmp: UInt8 = 0x01
        public static let srt: UInt8 = 0x02
        public var isRTMP: Bool { protocolBits & Self.rtmp != 0 }
    }

    public enum ParseError: Error, Equatable {
        case short(Int)
    }

    /// From a get's dataset (`permissions`: each destination's permission byte, which a set's hasn't).
    public static func parse(_ data: Data, permissions: Bool = true) throws -> StreamSettingList {
        let b = [UInt8](data)
        var at = 0
        func need(_ n: Int) throws { if at + n > b.count { throw ParseError.short(at) } }
        func u8() throws -> UInt8 { try need(1); defer { at += 1 }; return b[at] }
        func u16() throws -> UInt16 { try need(2); defer { at += 2 }; return UInt16(b[at]) | UInt16(b[at + 1]) << 8 }
        func u32() throws -> UInt32 {
            try need(4); defer { at += 4 }
            return UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
        }
        func string(_ length: Int) throws -> String {
            try need(length); defer { at += length }
            let bytes = b[at ..< at + length].prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        let offset = Int(try u32())
        _ = try u32() // the list's size
        at = offset
        let version = try u16()
        at += 2 // reserved
        let count = Int(try u32())
        var streams: [StreamSetting] = []
        for _ in 0 ..< count {
            var s = StreamSetting(protocolBits: try u8(), url: "")
            if permissions { s.permission = try u8() }
            s.url = try string(Int(try u16()))
            if try u8() != 0 { s.port = try u32() }
            if try u8() != 0 { s.key = try string(Int(try u16())) }
            if try u8() != 0 { s.latency = try u16() }
            if try u8() != 0 { s.ttl = try u8() }
            if try u8() != 0 {
                s.cipherType = try u8()
                s.cipherKey = try string(Int(try u8()))
            }
            if try u8() != 0 { s.mode = try u8() }
            streams.append(s)
        }
        return StreamSettingList(version: version, streams: streams)
    }

    /// A set's dataset: these destinations, in the set's form (no permission); `permissions`, a get's.
    public func encoded(permissions: Bool = false) -> Data {
        var list = Data()
        func u16(_ v: UInt16) { list.append(UInt8(v & 0xFF)); list.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { list.append(UInt8(v >> UInt32(shift) & 0xFF)) } }
        func cString(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }
        u16(version)
        list.append(contentsOf: [0, 0])
        u32(UInt32(streams.count))
        for s in streams {
            list.append(s.protocolBits)
            if permissions { list.append(s.permission ?? s.protocolBits) }
            let url = cString(s.url)
            u16(UInt16(url.count)); list.append(contentsOf: url)
            list.append(s.port == nil ? 0 : 1); if let port = s.port { u32(port) }
            list.append(s.key == nil ? 0 : 1)
            if let key = s.key { let k = cString(key); u16(UInt16(k.count)); list.append(contentsOf: k) }
            list.append(s.latency == nil ? 0 : 1); if let latency = s.latency { u16(latency) }
            list.append(s.ttl == nil ? 0 : 1); if let ttl = s.ttl { list.append(ttl) }
            list.append(s.cipherType == nil ? 0 : 1)
            if let type = s.cipherType {
                let k = cString(s.cipherKey ?? "")
                list.append(type); list.append(UInt8(k.count)); list.append(contentsOf: k)
            }
            list.append(s.mode == nil ? 0 : 1); if let mode = s.mode { list.append(mode) }
        }
        var data = Data()
        data.appendLE(UInt32(8))
        data.appendLE(UInt32(list.count))
        return data + list
    }
}
