import CameraCore
import Foundation

/// What a Blackmagic camera has said over Bluetooth, parameter by parameter, and the dashboard state that makes.
///
/// The protocol carries values, not menus: no parameter lists the ISOs, shutters or frame rates a camera offers. So the
/// option lists here are the usual ones, with whatever the camera reports always among them, and the camera clamps what
/// it can't take (the camera clamps each element to its valid range). Nothing is shown until the
/// camera has reported it: a body without ND (a PYXIS) never sends 1.16, so it gets no ND tile.
public struct CameraControlState: Sendable, Equatable {
    /// The last value each parameter was set to, by the camera or by us.
    public private(set) var values: [BMParameter: BMMessage] = [:]
    /// Which shutter parameter the camera reported last: the one its shutter measurement setting is on.
    public private(set) var shutterMode: ShutterMode?

    public init() {}

    /// Takes in one message. Offsets aren't applied: the camera answers them with the value they came to.
    public mutating func apply(_ message: BMMessage) {
        guard message.operation == .assign, !message.data.isEmpty || message.type == .void else { return }
        values[message.parameter] = message
        if message.parameter == .shutterAngle { shutterMode = .angle }
        if message.parameter == .shutterSpeed { shutterMode = .speed }
    }

    public subscript(_ parameter: BMParameter) -> BMMessage? { values[parameter] }

    // MARK: - The dashboard's view

    /// Fills in what the camera has reported; leaves the rest of `state` alone.
    public func map(into state: inout CameraState) {
        if let mode = self[.transportMode]?.int8s.first {
            state.recording.state = mode == 2 ? .recording : .idle
        }
        if let iso = self[.iso]?.int32s.first {
            state.iso = Choice(Int(iso), options: Self.withCurrent(Self.isoOptions, Int(iso)))
        }
        if let raw = self[.shutterAngle]?.int32s.first {
            let degrees = Double(raw) / 100
            state.shutterAngle = Choice(degrees, options: Self.withCurrent(Self.shutterAngles, degrees))
        }
        if let speed = self[.shutterSpeed]?.int32s.first, speed > 0 {
            let label = "1/\(speed)"
            state.shutterSpeed = Choice(label, options: Self.withCurrent(Self.shutterSpeeds, label, by: Self.speedValue))
        }
        // The protocol has no shutter measurement parameter: show the one the camera last reported, not as a switch.
        if let shutterMode { state.shutterMode = Choice(shutterMode, options: [shutterMode], isWritable: false) }
        if let wb = self[.manualWhiteBalance]?.int16s, wb.count >= 2 {
            let kelvin = Int(wb[0]), tint = Double(wb[1])
            state.whiteBalance = WhiteBalanceState(
                preset: Choice("\(kelvin)K", options: WhiteBalancePresets.labels(within: 2500...10000) + ["Auto"]),
                kelvin: Level(Double(kelvin), range: 2500...10000, step: 50),
                tint: Level(tint, range: -50...50, step: 1))
        }
        if let av = self[.apertureFStop]?.fixed16s.first, (-1...16).contains(av) {
            state.iris = Choice(Self.fNumber(av: av), options: Self.fNumbers)
        }
        if let stop = self[.ndFilter]?.fixed16s.first {
            let label = Stops.ndLabel(stop)
            state.nd = NDState(preset: Choice(label, options: Self.withCurrent(Self.ndStops.map(Stops.ndLabel), label, by: { Stops.ndStops($0) ?? 0 })))
        }
        if let format = self[.recordingFormat]?.int16s, format.count >= 5 {
            let flags = UInt16(bitPattern: format[4])
            let project = Self.frameRateLabel(fps: Int(format[0]), mRate: flags & 0x01 != 0)
            let offSpeed = flags & 0x04 != 0
            let sensor = Double(format[1] > 0 ? format[1] : format[0])
            state.frameRate = FrameRateState(
                project: Choice(project, options: Self.withCurrent(Self.frameRates, project, by: { Double($0) ?? 0 })),
                variable: Choice(offSpeed, options: [false, true]),
                variableRate: Choice(sensor, options: Self.withCurrent(Self.offSpeedRates, sensor)),
                variableName: "Off-speed")
            if format[2] > 0, format[3] > 0 {
                let resolution = "\(format[2])x\(format[3])"
                state.resolution = Choice(resolution, options: [resolution], isWritable: false)
            }
        }
        if let codec = self[.codec]?.int8s, codec.count >= 2 {
            let label = Self.codecLabel(basic: codec[0], variant: codec[1])
            let family = Self.codecs.filter { $0.basic == codec[0] }.map(\.label)
            state.fileFormat = Choice(label, options: family.contains(label) ? family : family + [label])
        }
        if let codec = state.fileFormat?.value { state.recordingFormat = state.resolution.map { "\($0.value) · \(codec)" } ?? codec }
        if let range = self[.dynamicRange]?.int8s.first, Self.dynamicRanges.indices.contains(Int(range)) {
            state.dynamicRange = Choice(Self.dynamicRanges[Int(range)], options: Self.dynamicRanges)
        }
        if let lut = self[.displayLUT]?.int8s, lut.count >= 2 {
            let selected = Int(lut[0])
            state.look = Choice(lut[1] != 0, options: [false, true], isWritable: selected != 0)
            if Self.luts.indices.contains(selected) { state.lut = Choice(Self.luts[selected], options: Self.luts) }
        }
        if let bars = self[.colorBars]?.int8s.first { state.colorBars = Choice(bars > 0, options: [false, true]) }
        if let monitoring = monitoring() {
            state.monitoring = monitoring
            state.falseColor = monitoring.onEverywhere(.falseColor)
        }
    }

    /// The overlays as one output, "All outputs": the protocol switches them for a set of displays at once, and its
    /// reports carry one set of flags.
    func monitoring() -> MonitoringState? {
        var overlays: [MonitorOverlay: Choice<Bool>] = [:]
        if let flags = self[.overlayEnables]?.bitFields.first {
            overlays[.statusText] = Choice(flags & 0x1 != 0, options: [false, true])
            overlays[.frameGuides] = Choice(flags & 0x2 != 0, options: [false, true])
            overlays[.cleanFeed] = Choice(flags & 0x4 != 0, options: [false, true])
        }
        if let tools = self[.exposureAndFocusTools]?.bitFields.first {
            overlays[.zebra] = Choice(tools & 0x1 != 0, options: [false, true])
            overlays[.focusAssist] = Choice(tools & 0x2 != 0, options: [false, true])
            overlays[.falseColor] = Choice(tools & 0x4 != 0, options: [false, true])
        }
        let zebra = self[.zebraLevel]?.fixed16s.first.map { Int(($0 * 100).rounded()) }
        let guides = self[.overlays]?.int8s.first.flatMap { Self.frameGuideStyles.indices.contains(Int($0)) ? Self.frameGuideStyles[Int($0)] : nil }
        guard !overlays.isEmpty || zebra != nil || guides != nil else { return nil }
        return MonitoringState(
            outputs: overlays.isEmpty ? [] : [MonitorOutput(id: Self.allOutputs, name: "All outputs", overlays: overlays)],
            zebraLevel: zebra.map { Choice($0, options: Self.withCurrent(Array(stride(from: 50, through: 100, by: 5)), $0)) },
            frameGuideRatio: guides.map { Choice($0, options: Self.frameGuideStyles) })
    }

    public static let allOutputs = "All"

    // MARK: - The usual lists

    static let isoOptions = [100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200]
    static let shutterAngles: [Double] = [11.25, 15, 22.5, 30, 37.5, 45, 60, 72, 75, 90, 108, 120, 144, 150, 172.8, 180,
                                          216, 270, 324, 360]
    static let shutterSpeeds = ["1/24", "1/25", "1/30", "1/48", "1/50", "1/60", "1/96", "1/100", "1/120", "1/125",
                                "1/250", "1/500", "1/1000", "1/2000"]
    static let frameRates = ["23.98", "24", "25", "29.97", "30", "47.95", "48", "50", "59.94", "60"]
    static let offSpeedRates: [Double] = [12, 15, 18, 20, 24, 25, 30, 36, 40, 45, 48, 50, 60, 72, 75, 80, 90, 96, 100,
                                          110, 120]
    /// Clear, 2, 4 and 6 stops: the URSA Mini Pro's and URSA Cine's IR NDs (Blackmagic's tech specs).
    static let ndStops: [Double] = [0, 2, 4, 6]
    static let dynamicRanges = ["Film", "Video", "Extended Video"]
    static let luts = ["None", "Custom", "Film to Video", "Film to Extended Video"]
    static let frameGuideStyles = ["Off", "2.4:1", "2.39:1", "2.35:1", "1.85:1", "16:9", "14:9", "4:3", "2:1", "4:5", "1:1"]
    /// The iris's choices, third stops from f/1.0 (AV 0) to f/22 (AV 9): Bluetooth doesn't say the lens's range.
    static let fNumbers = Stops.fNumbers.filter { $0 <= 22 }

    struct Codec { let basic: Int8; let variant: Int8; let label: String }
    /// Basic codec and variant as the protocol numbers them, named the way the camera's menu writes them.
    static let codecs: [Codec] = [
        Codec(basic: 3, variant: 0, label: "BRAW Q0"), Codec(basic: 3, variant: 7, label: "BRAW Q1"),
        Codec(basic: 3, variant: 8, label: "BRAW Q3"), Codec(basic: 3, variant: 1, label: "BRAW Q5"),
        Codec(basic: 3, variant: 2, label: "BRAW 3:1"), Codec(basic: 3, variant: 3, label: "BRAW 5:1"),
        Codec(basic: 3, variant: 4, label: "BRAW 8:1"), Codec(basic: 3, variant: 5, label: "BRAW 12:1"),
        Codec(basic: 2, variant: 0, label: "ProRes 422 HQ"), Codec(basic: 2, variant: 1, label: "ProRes 422"),
        Codec(basic: 2, variant: 2, label: "ProRes 422 LT"), Codec(basic: 2, variant: 3, label: "ProRes Proxy"),
        Codec(basic: 2, variant: 4, label: "ProRes 4444"), Codec(basic: 2, variant: 5, label: "ProRes 4444 XQ"),
        Codec(basic: 0, variant: 0, label: "CinemaDNG RAW"), Codec(basic: 0, variant: 1, label: "CinemaDNG 3:1"),
        Codec(basic: 0, variant: 2, label: "CinemaDNG 4:1"),
    ]

    static func codecLabel(basic: Int8, variant: Int8) -> String {
        codecs.first { $0.basic == basic && $0.variant == variant }?.label ?? "Codec \(basic).\(variant)"
    }

    // MARK: - Conversions

    /// f-number from aperture value (f = sqrt(2^AV)), as the third stop it is.
    static func fNumber(av: Double) -> Double {
        let index = Int((av * 3).rounded())
        if fNumbers.indices.contains(index) { return fNumbers[index] }
        return (pow(2, av / 2) * 10).rounded() / 10
    }

    /// The aperture value to send for a marked f-number: a third stop is exact (f/5.6 is AV 5, not 2·log2 5.6).
    static func av(fNumber: Double) -> Double {
        if let index = fNumbers.firstIndex(of: fNumber) { return Double(index) / 3 }
        return 2 * log2(fNumber)
    }

    /// "23.98" for 24 at an M-rate (the NTSC 1000/1001 rates), else the integer.
    static func frameRateLabel(fps: Int, mRate: Bool) -> String {
        guard mRate else { return "\(fps)" }
        switch fps {
        case 24: return "23.98"
        case 30: return "29.97"
        case 48: return "47.95"
        case 60: return "59.94"
        case 120: return "119.88"
        default: return String(format: "%.2f", Double(fps) * 1000 / 1001)
        }
    }

    /// A frame rate label back to the protocol's integer and M-rate flag.
    static func frameRateValue(_ label: String) -> (fps: Int16, mRate: Bool)? {
        switch label {
        case "23.98": return (24, true)
        case "29.97": return (30, true)
        case "47.95": return (48, true)
        case "59.94": return (60, true)
        case "119.88": return (120, true)
        default: return Int16(label).map { ($0, false) }
        }
    }

    static func speedValue(_ label: String) -> Double {
        Double(label.split(separator: "/").last ?? "") ?? 0
    }

    static func withCurrent<T: Comparable>(_ options: [T], _ current: T) -> [T] {
        options.contains(current) ? options : (options + [current]).sorted()
    }

    static func withCurrent<T: Equatable>(_ options: [T], _ current: T, by key: (T) -> Double) -> [T] {
        options.contains(current) ? options : (options + [current]).sorted { key($0) < key($1) }
    }
}

