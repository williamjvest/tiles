import Foundation

// Blackmagic's camera control protocol, the messages a Blackmagic camera takes and sends over Bluetooth LE: the same
// bytes as the SDI Camera Control Protocol (version 1.6.2). The BLE and SDI wire formats are identical (Blackmagic's
// published Camera Control document).
//
// A message: destination (255 = every device), the command's length (not counting this header or the padding),
// command id (0 = change configuration), a reserved zero; then category, parameter, data type, operation and the data,
// zero-padded to a 32-bit boundary.

/// One parameter: a category and a parameter number, written as Blackmagic's table does (ISO is 1.14).
public struct BMParameter: Hashable, Sendable, CustomStringConvertible {
    public let category: UInt8
    public let parameter: UInt8

    public init(_ category: UInt8, _ parameter: UInt8) {
        self.category = category
        self.parameter = parameter
    }

    public var description: String { "\(category).\(parameter)" }

    // Lens
    /// fixed16, 0.0 near … 1.0 far.
    public static let focus = BMParameter(0, 0)
    /// void: focus once, now.
    public static let instantaneousAutofocus = BMParameter(0, 1)
    /// fixed16 aperture value AV, -1 … 16, where the f-number is sqrt(2^AV).
    public static let apertureFStop = BMParameter(0, 2)
    /// fixed16, 0.0 smallest … 1.0 largest.
    public static let apertureNormalised = BMParameter(0, 3)
    /// void: set the iris once, now.
    public static let instantaneousAutoAperture = BMParameter(0, 5)

    // Video
    /// int8 ×5: frame rate, M-rate, dimensions, interlaced, color space.
    public static let videoMode = BMParameter(1, 0)
    /// int16 ×2: color temperature 2500 … 10000 K, tint -50 … 50.
    public static let manualWhiteBalance = BMParameter(1, 2)
    /// void: measure and set white balance.
    public static let setAutoWhiteBalance = BMParameter(1, 3)
    /// int8 enum: 0 film, 1 video, 2 extended video.
    public static let dynamicRange = BMParameter(1, 7)
    /// int16 ×5: file frame rate, sensor frame rate (when off-speed), width, height, flags (bit 0 file M-rate, 1 sensor
    /// M-rate, 2 sensor off-speed, 3 interlaced, 4 windowed).
    public static let recordingFormat = BMParameter(1, 9)
    /// int32: shutter angle in degrees × 100, 100 … 36000.
    public static let shutterAngle = BMParameter(1, 11)
    /// int32: shutter speed as 1/x (50 is 1/50 s).
    public static let shutterSpeed = BMParameter(1, 12)
    /// int8: gain in dB.
    public static let gain = BMParameter(1, 13)
    /// int32: ISO.
    public static let iso = BMParameter(1, 14)
    /// int8 ×2: selected LUT (0 none, 1 custom, 2 film to video, 3 film to extended video), enabled.
    public static let displayLUT = BMParameter(1, 15)
    /// fixed16 ×2: filter power in stops 0 … 15; display mode (0 stop, 1 density, 2 transmittance).
    public static let ndFilter = BMParameter(1, 16)

    // Output and display
    /// uint16 ×2: overlays (bit 0 status, 1 frame guides, 2 clean feed); the displays they're for (bit 0 LCD, 1 HDMI,
    /// 2 EVF, 3 main SDI, 4 front SDI). Note: some cameras treat frame guides and status as a single toggle.
    public static let overlayEnables = BMParameter(3, 0)
    /// int8 ×4 (Camera 4.0 on): frame guide style (0 off, 1 2.4:1, 2 2.39:1, 3 2.35:1, 4 1.85:1, 5 16:9, 6 14:9,
    /// 7 4:3, 8 2:1, 9 4:5, 10 1:1), guide opacity 0 … 100, safe area percent (0 off), grid (bit 0 thirds, 1 cross
    /// hairs, 2 center dot, 3 horizon).
    public static let overlays = BMParameter(3, 3)
    /// uint16 ×2: tools (bit 0 zebra, 1 focus assist, 2 false color); the displays they're for, as for 3.0.
    public static let exposureAndFocusTools = BMParameter(4, 1)
    /// fixed16, 0.0 … 1.0.
    public static let zebraLevel = BMParameter(4, 2)
    /// int8: 0 bars off, 1 … 30 bars on for that many seconds.
    public static let colorBars = BMParameter(4, 4)

    // Media
    /// int8 ×2: basic codec (0 CinemaDNG, 1 DNxHD, 2 ProRes, 3 Blackmagic RAW), variant.
    public static let codec = BMParameter(10, 0)
    /// int8 ×5: mode (0 preview, 1 play, 2 record), speed, flags, slot 1 medium, slot 2 medium.
    public static let transportMode = BMParameter(10, 1)
    /// int8: 0 previous clip, 1 next.
    public static let playbackControl = BMParameter(10, 2)
}

/// How a message's data is typed.
public enum BMDataType: UInt8, Sendable {
    case void = 0      // and boolean: one byte, 0 false
    case int8 = 1
    case int16 = 2
    case int32 = 3
    case int64 = 4
    case string = 5    // UTF-8, no terminator
    case fixed16 = 128 // signed 5.11: the value × 2048, -16.0 … 15.9995

    /// Bytes per element (a string is one per byte).
    public var size: Int {
        switch self {
        case .void, .int8, .string: 1
        case .int16, .fixed16: 2
        case .int32: 4
        case .int64: 8
        }
    }
}

/// What a message does to the parameter.
public enum BMOperation: UInt8, Sendable {
    /// Set it (each element clamped to its range). A void parameter is "assigned" nothing, which triggers it.
    case assign = 0
    /// Add to it; any non-zero offset toggles a boolean.
    case offset = 1
}

/// One change-configuration message (command 0).
public struct BMMessage: Equatable, Sendable, CustomStringConvertible {
    public var destination: UInt8
    public var parameter: BMParameter
    public var type: BMDataType
    public var operation: BMOperation
    public var data: Data

    public init(destination: UInt8 = 255, parameter: BMParameter, type: BMDataType, operation: BMOperation = .assign,
                data: Data = Data()) {
        self.destination = destination
        self.parameter = parameter
        self.type = type
        self.operation = operation
        self.data = data
    }

    public var description: String {
        "\(parameter) \(type) \(operation == .assign ? "=" : "+=") \(data.map { String(format: "%02x", $0) }.joined())"
    }

    // MARK: Building

    /// A void parameter's action (autofocus, auto white balance).
    public static func trigger(_ parameter: BMParameter, destination: UInt8 = 255) -> BMMessage {
        BMMessage(destination: destination, parameter: parameter, type: .void)
    }

    public static func assign(_ parameter: BMParameter, int8 values: [Int8]) -> BMMessage {
        BMMessage(parameter: parameter, type: .int8, data: Data(values.map { UInt8(bitPattern: $0) }))
    }

    public static func assign(_ parameter: BMParameter, int16 values: [Int16]) -> BMMessage {
        var d = Data()
        for v in values { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian, Array.init)) }
        return BMMessage(parameter: parameter, type: .int16, data: d)
    }

    public static func assign(_ parameter: BMParameter, int32 values: [Int32]) -> BMMessage {
        var d = Data()
        for v in values { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian, Array.init)) }
        return BMMessage(parameter: parameter, type: .int32, data: d)
    }

    public static func assign(_ parameter: BMParameter, fixed16 values: [Double]) -> BMMessage {
        var d = Data()
        for v in values { d.append(contentsOf: withUnsafeBytes(of: Self.fixed16(v).littleEndian, Array.init)) }
        return BMMessage(parameter: parameter, type: .fixed16, data: d)
    }

    public static func assign(_ parameter: BMParameter, bool value: Bool) -> BMMessage {
        BMMessage(parameter: parameter, type: .void, data: Data([value ? 1 : 0]))
    }

    /// A real number as 5.11 fixed point, clamped to what it can hold.
    public static func fixed16(_ value: Double) -> Int16 {
        Int16(max(-32768, min(32767, (value * 2048).rounded())))
    }

    // MARK: Reading

    public var int8s: [Int8] { data.map { Int8(bitPattern: $0) } }
    public var int16s: [Int16] { elements(Int16.self) }
    public var int32s: [Int32] { elements(Int32.self) }
    public var int64s: [Int64] { elements(Int64.self) }
    /// Fixed-point elements as real numbers.
    public var fixed16s: [Double] { elements(Int16.self).map { Double($0) / 2048 } }
    /// A 16-bit field read as bits (3.0, 4.1: "uint16 bit field", sent as 16-bit elements).
    public var bitFields: [UInt16] { elements(Int16.self).map { UInt16(bitPattern: $0) } }
    public var string: String? { type == .string ? String(data: data, encoding: .utf8) : nil }
    public var bool: Bool? { data.first.map { $0 != 0 } }

    private func elements<T: FixedWidthInteger>(_: T.Type) -> [T] {
        let size = MemoryLayout<T>.size
        return stride(from: 0, to: data.count - size + 1, by: size).map { offset in
            data[data.startIndex + offset ..< data.startIndex + offset + size].reversed().reduce(T.zero) { $0 << 8 | T($1) }
        }
    }

    // MARK: Wire

    /// The message as sent: header, command, data, padding to 32 bits.
    public var encoded: Data {
        let length = 4 + data.count
        var bytes = Data([destination, UInt8(length), 0, 0, parameter.category, parameter.parameter, type.rawValue, operation.rawValue])
        bytes.append(data)
        while bytes.count % 4 != 0 { bytes.append(0) }
        return bytes
    }

    /// The change-configuration messages in `bytes`, which may hold several back to back. Other commands, and
    /// anything too short to be a message, are skipped by their length, as a receiver should.
    public static func decode(_ bytes: Data) -> [BMMessage] {
        let b = [UInt8](bytes)
        var messages: [BMMessage] = []
        var i = 0
        while i + 4 <= b.count {
            let destination = b[i], length = Int(b[i + 1]), command = b[i + 2]
            let end = i + 4 + length
            guard end <= b.count else { break }
            if command == 0, length >= 4, let type = BMDataType(rawValue: b[i + 6]), let operation = BMOperation(rawValue: b[i + 7]) {
                messages.append(BMMessage(destination: destination, parameter: BMParameter(b[i + 4], b[i + 5]), type: type,
                                          operation: operation, data: Data(b[(i + 8)..<end])))
            }
            i = (end + 3) & ~3  // past the padding
        }
        return messages
    }
}

