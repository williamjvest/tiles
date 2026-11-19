import Foundation

/// A MessagePack value: what Sony's Savona API (VENICE, PXW) carries in every WebSocket frame.
///
/// Only what the cameras send: nil, bools, integers, floats, strings, binary, arrays and maps with string keys. Ext types
/// decode to their bytes. Maps keep no order; they encode with sorted keys, so a frame is the same bytes every time.
public enum MPValue: Sendable, Equatable, Hashable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([MPValue])
    case map([String: MPValue])

    // MARK: Reading

    public subscript(key: String) -> MPValue? {
        if case .map(let m) = self { return m[key] }
        return nil
    }

    public subscript(index: Int) -> MPValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .string(let s):
            switch s.lowercased() {
            case "on", "true", "enable", "enabled", "yes", "1": return true  // VENICE 2's menu switches read "0"/"1"
            case "off", "false", "disable", "disabled", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var array: [MPValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var map: [String: MPValue]? {
        if case .map(let m) = self { return m }
        return nil
    }

    public var isNull: Bool { self == .null }

    /// The number in it, however the camera wrote it: an integer, a float, a numeric string with a unit after it
    /// ("800EI", "180.0", "5600K"), a {numerator, denominator} fraction, or any of these under a "cam" key (VENICE nests
    /// some values as {"cam": …}).
    public var number: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .bool(let b): return b ? 1 : 0
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            if let d = Double(t) { return d }
            let prefix = t.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
            return prefix.isEmpty ? nil : Double(prefix)
        case .map(let m):
            if let inner = m["cam"] { return inner.number }
            if let n = m["numerator"]?.number, let d = m["denominator"]?.number, d != 0 { return n / d }
            if let v = m["value"] ?? m["Value"] { return v.number }
            return nil
        default: return nil
        }
    }

    /// The value with a "cam" wrapper taken off, as VENICE nests some.
    public var unwrapped: MPValue {
        // VENICE nests single values under a key: {"cam": 16}, {"main": "B020C005"}, {"sdi1": "Log"}, {"vf": "Look"}.
        if case .map(let m) = self, m.count == 1, let inner = m.first?.value { return inner }
        return self
    }

    public var description: String {
        switch self {
        case .null: return "nil"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return "\"\(s)\""
        case .binary(let d): return "<\(d.count) bytes>"
        case .array(let a): return "[" + a.map(\.description).joined(separator: ", ") + "]"
        case .map(let m):
            return "{" + m.keys.sorted().map { "\"\($0)\": \(m[$0]!.description)" }.joined(separator: ", ") + "}"
        }
    }

    // MARK: Building

    public init(_ s: String) { self = .string(s) }
    public init(_ i: Int) { self = .int(Int64(i)) }
}

extension MPValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(Int64(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: MPValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, MPValue)...) {
        self = .map(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
    public init(floatLiteral value: Double) { self = .double(value) }
}

// MARK: - Encoding

public enum MessagePack {
    public enum DecodeError: Error, Equatable {
        case truncated
        case unsupported(UInt8)
        case nonStringKey
        case badUTF8
    }

    public static func encode(_ value: MPValue) -> Data {
        var out = Data()
        write(value, into: &out)
        return out
    }

    private static func write(_ value: MPValue, into out: inout Data) {
        switch value {
        case .null:
            out.append(0xC0)
        case .bool(let b):
            out.append(b ? 0xC3 : 0xC2)
        case .int(let i):
            writeInt(i, into: &out)
        case .double(let d):
            out.append(0xCB)
            appendBig(d.bitPattern, bytes: 8, into: &out)
        case .string(let s):
            let bytes = Data(s.utf8)
            let n = bytes.count
            if n < 32 {
                out.append(0xA0 | UInt8(n))
            } else if n <= 0xFF {
                out.append(0xD9); out.append(UInt8(n))
            } else if n <= 0xFFFF {
                out.append(0xDA); appendBig(UInt64(n), bytes: 2, into: &out)
            } else {
                out.append(0xDB); appendBig(UInt64(n), bytes: 4, into: &out)
            }
            out.append(bytes)
        case .binary(let d):
            let n = d.count
            if n <= 0xFF {
                out.append(0xC4); out.append(UInt8(n))
            } else if n <= 0xFFFF {
                out.append(0xC5); appendBig(UInt64(n), bytes: 2, into: &out)
            } else {
                out.append(0xC6); appendBig(UInt64(n), bytes: 4, into: &out)
            }
            out.append(d)
        case .array(let a):
            let n = a.count
            if n < 16 {
                out.append(0x90 | UInt8(n))
            } else if n <= 0xFFFF {
                out.append(0xDC); appendBig(UInt64(n), bytes: 2, into: &out)
            } else {
                out.append(0xDD); appendBig(UInt64(n), bytes: 4, into: &out)
            }
            for element in a { write(element, into: &out) }
        case .map(let m):
            let n = m.count
            if n < 16 {
                out.append(0x80 | UInt8(n))
            } else if n <= 0xFFFF {
                out.append(0xDE); appendBig(UInt64(n), bytes: 2, into: &out)
            } else {
                out.append(0xDF); appendBig(UInt64(n), bytes: 4, into: &out)
            }
            for key in m.keys.sorted() {
                write(.string(key), into: &out)
                write(m[key]!, into: &out)
            }
        }
    }

    /// The smallest form, as msgpack's reference encoders write it (a camera's own frames do: fixints, uint8/16/32).
    private static func writeInt(_ i: Int64, into out: inout Data) {
        if i >= 0 {
            let u = UInt64(i)
            if u < 0x80 {
                out.append(UInt8(u))
            } else if u <= 0xFF {
                out.append(0xCC); out.append(UInt8(u))
            } else if u <= 0xFFFF {
                out.append(0xCD); appendBig(u, bytes: 2, into: &out)
            } else if u <= 0xFFFF_FFFF {
                out.append(0xCE); appendBig(u, bytes: 4, into: &out)
            } else {
                out.append(0xCF); appendBig(u, bytes: 8, into: &out)
            }
        } else if i >= -32 {
            out.append(UInt8(bitPattern: Int8(i)))
        } else if i >= Int64(Int8.min) {
            out.append(0xD0); out.append(UInt8(bitPattern: Int8(i)))
        } else if i >= Int64(Int16.min) {
            out.append(0xD1); appendBig(UInt64(UInt16(bitPattern: Int16(i))), bytes: 2, into: &out)
        } else if i >= Int64(Int32.min) {
            out.append(0xD2); appendBig(UInt64(UInt32(bitPattern: Int32(i))), bytes: 4, into: &out)
        } else {
            out.append(0xD3); appendBig(UInt64(bitPattern: i), bytes: 8, into: &out)
        }
    }

    private static func appendBig(_ value: UInt64, bytes: Int, into out: inout Data) {
        for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) {
            out.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    // MARK: - Decoding

    public static func decode(_ data: Data) throws -> MPValue {
        var reader = Reader(bytes: [UInt8](data))
        return try reader.value()
    }

    /// Every value in `data`, in order. VENICE 2 (savona-2.9.4) packs several messages into one WebSocket
    /// frame and can split one across two; `rest` is a split tail to put in front of the next frame. Bytes that aren't
    /// MessagePack end the read and are dropped.
    public static func decodeAll(_ data: Data) -> (values: [MPValue], rest: Data) {
        var reader = Reader(bytes: [UInt8](data))
        var out: [MPValue] = []
        while reader.pos < reader.bytes.count {
            let start = reader.pos
            do {
                out.append(try reader.value())
            } catch DecodeError.truncated {
                return (out, Data(reader.bytes[start...]))
            } catch {
                return (out, Data())
            }
        }
        return (out, Data())
    }

    private struct Reader {
        let bytes: [UInt8]
        var pos = 0

        mutating func byte() throws -> UInt8 {
            guard pos < bytes.count else { throw DecodeError.truncated }
            defer { pos += 1 }
            return bytes[pos]
        }

        mutating func big(_ n: Int) throws -> UInt64 {
            guard pos + n <= bytes.count else { throw DecodeError.truncated }
            var v: UInt64 = 0
            for i in 0..<n { v = (v << 8) | UInt64(bytes[pos + i]) }
            pos += n
            return v
        }

        mutating func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, pos + n <= bytes.count else { throw DecodeError.truncated }
            defer { pos += n }
            return Array(bytes[pos..<pos + n])
        }

        mutating func string(_ n: Int) throws -> MPValue {
            guard var s = String(bytes: try take(n), encoding: .utf8) else { throw DecodeError.badUTF8 }
            while s.hasSuffix("\u{0}") { s.removeLast() }  // VENICE 2 pads some strings ("B020C004\0", "B\0\0\0")
            return .string(s)
        }

        mutating func array(_ n: Int) throws -> MPValue {
            var a: [MPValue] = []
            a.reserveCapacity(min(n, 4096))
            for _ in 0..<n { a.append(try value()) }
            return .array(a)
        }

        mutating func map(_ n: Int) throws -> MPValue {
            var m: [String: MPValue] = [:]
            for _ in 0..<n {
                let key = try value()
                let k: String
                switch key {
                case .string(let s): k = s
                case .int(let i): k = String(i)
                default: throw DecodeError.nonStringKey
                }
                m[k] = try value()
            }
            return .map(m)
        }

        mutating func value() throws -> MPValue {
            let b = try byte()
            switch b {
            case 0x00...0x7F: return .int(Int64(b))
            case 0x80...0x8F: return try map(Int(b & 0x0F))
            case 0x90...0x9F: return try array(Int(b & 0x0F))
            case 0xA0...0xBF: return try string(Int(b & 0x1F))
            case 0xC0: return .null
            case 0xC2: return .bool(false)
            case 0xC3: return .bool(true)
            case 0xC4: return .binary(Data(try take(Int(try big(1)))))
            case 0xC5: return .binary(Data(try take(Int(try big(2)))))
            case 0xC6: return .binary(Data(try take(Int(try big(4)))))
            case 0xC7: let n = Int(try big(1)); _ = try byte(); return .binary(Data(try take(n)))
            case 0xC8: let n = Int(try big(2)); _ = try byte(); return .binary(Data(try take(n)))
            case 0xC9: let n = Int(try big(4)); _ = try byte(); return .binary(Data(try take(n)))
            case 0xCA: return .double(Double(Float(bitPattern: UInt32(try big(4)))))
            case 0xCB: return .double(Double(bitPattern: try big(8)))
            case 0xCC: return .int(Int64(try big(1)))
            case 0xCD: return .int(Int64(try big(2)))
            case 0xCE: return .int(Int64(try big(4)))
            case 0xCF:
                let u = try big(8)
                return u <= UInt64(Int64.max) ? .int(Int64(u)) : .double(Double(u))
            case 0xD0: return .int(Int64(Int8(bitPattern: UInt8(try big(1)))))
            case 0xD1: return .int(Int64(Int16(bitPattern: UInt16(try big(2)))))
            case 0xD2: return .int(Int64(Int32(bitPattern: UInt32(try big(4)))))
            case 0xD3: return .int(Int64(bitPattern: try big(8)))
            case 0xD4: _ = try byte(); return .binary(Data(try take(1)))
            case 0xD5: _ = try byte(); return .binary(Data(try take(2)))
            case 0xD6: _ = try byte(); return .binary(Data(try take(4)))
            case 0xD7: _ = try byte(); return .binary(Data(try take(8)))
            case 0xD8: _ = try byte(); return .binary(Data(try take(16)))
            case 0xD9: return try string(Int(try big(1)))
            case 0xDA: return try string(Int(try big(2)))
            case 0xDB: return try string(Int(try big(4)))
            case 0xDC: return try array(Int(try big(2)))
            case 0xDD: return try array(Int(try big(4)))
            case 0xDE: return try map(Int(try big(2)))
            case 0xDF: return try map(Int(try big(4)))
            case 0xE0...0xFF: return .int(Int64(Int8(bitPattern: b)))
            default: throw DecodeError.unsupported(b)
            }
        }
    }
}
