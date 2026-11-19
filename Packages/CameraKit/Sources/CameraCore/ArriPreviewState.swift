import Foundation

/// An ARRI camera over its Web Remote (`ArriWebRemote/ArriCameraBackend`): the ALEXA Mini first, and the Mini LF,
/// ALEXA 35 and AMIRA, which serve the same interface. No login: the Web Remote has none.
public struct ArriConnection: Codable, Hashable, Sendable {
    public var host: String

    public init(host: String) {
        self.host = host
    }
}

/// Lists for ARRI cameras that the camera doesn't send itself, or that the demos need. Built from ARRI's
/// published specifications (EI, ND filters, shutter and frame-rate ranges per body) before Tiles met a camera; a
/// connected camera's own lists always win (`ArriWebRemote` reads them off it).
public enum ArriTables {
    /// Tiles' white balance steps, as on every camera (`WhiteBalancePresets`; the preset tile sets Kelvin and CC 0);
    /// any Kelvin in range can be dialled.
    public static let whiteBalancePresets = WhiteBalancePresets.kelvin.map { "\($0)K" }

    /// Shutter angles offered (the camera takes any angle in its range, to a tenth).
    public static let shutterAngles: [Double] = [5, 11.2, 22.5, 45, 90, 135, 144, 172.8, 180, 216, 270, 300, 330, 356]

    /// Shutter times offered: the same shutter as an angle at the current frame rate.
    public static let shutterSpeeds = ["1/24", "1/25", "1/30", "1/32", "1/40", "1/48", "1/50", "1/60", "1/96", "1/100",
                                       "1/120", "1/125", "1/192", "1/200", "1/250", "1/500", "1/1000", "1/2000"]

    /// Sensor frame rates offered, inside the range the camera allows for its format (it takes any rate in it).
    public static let frameRates: [Double] = [12, 23.976, 24, 25, 29.97, 30, 47.952, 48, 50, 59.94, 60, 72, 75, 90, 96,
                                              100, 120, 150, 200]

    /// "1/48" for 172.8° at 24 fps: the exposure time as one over a whole number.
    public static func speedLabel(angle: Double, fps: Double) -> String {
        guard angle > 0, fps > 0 else { return "—" }
        let denominator = 360 * fps / angle
        let rounded = denominator.rounded()
        return abs(denominator - rounded) < 0.05 ? "1/\(Int(rounded))" : String(format: "1/%.1f", denominator)
    }

    public static func seconds(_ label: String) -> Double? {
        let parts = label.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0 { return n / d }
        return Double(label.filter { $0.isNumber || $0 == "." })
    }

    /// The angle that gives a shutter time at a frame rate: 1/50 at 25 fps is 180°.
    public static func angle(forSpeed label: String, fps: Double) -> Double? {
        guard let t = seconds(label), t > 0, fps > 0 else { return nil }
        return (360 * fps * t * 10).rounded() / 10
    }

    /// EI per body: 160–3200 (ALEXA Mini, Mini LF, AMIRA); 160–6400 (ALEXA 35), in thirds of a stop.
    public static func exposureIndexes(model: String?) -> [Int] {
        let mini = [160, 200, 250, 320, 400, 500, 640, 800, 1000, 1280, 1600, 2000, 2560, 3200]
        return isAlexa35(model) ? mini + [4000, 5120, 6400] : mini
    }

    /// The built-in ND filters per body: Mini and AMIRA 0.6 / 1.2 / 2.1; Mini LF 0.6 / 1.2 / 1.8; ALEXA 35 adds 2.4.
    public static func ndFilters(model: String?) -> [String] {
        let m = model?.uppercased() ?? ""
        if isAlexa35(model) { return ["Clear", "0.6", "1.2", "1.8", "2.4"] }
        if m.contains("LF") { return ["Clear", "0.6", "1.2", "1.8"] }
        return ["Clear", "0.6", "1.2", "2.1"]
    }

    /// The highest sensor rate per body (its fastest format): Mini 200 (HD ProRes), Mini LF 90, ALEXA 35 120.
    public static func maxFrameRate(model: String?) -> Double {
        let m = model?.uppercased() ?? ""
        if isAlexa35(model) { return 120 }
        if m.contains("LF") { return 90 }
        return 200
    }

    /// The outputs whose overlays the camera sets one by one: SDI 1 and 2 and the viewfinder, and a MON out on the Mini
    /// LF and ALEXA 35.
    public static func outputs(model: String?) -> [(id: String, name: String)] {
        let base = [("Sdi1", "SDI 1"), ("Sdi2", "SDI 2"), ("Evf", "EVF")]
        let m = model?.uppercased() ?? ""
        return isAlexa35(model) || m.contains("LF") ? base + [("Mon", "MON")] : base
    }

    /// Sensor modes for the demos (illustrative: a camera lists its own, which depend on its licenses).
    public static func sensorModes(model: String?) -> [String] {
        let m = model?.uppercased() ?? ""
        if isAlexa35(model) { return ["4.6K 3:2 Open Gate", "4.6K 16:9", "4K 16:9", "4K 2:1", "3.8K 16:9 UHD", "3.3K 6:5", "2K 16:9 S16"] }
        if m.contains("LF") { return ["LF Open Gate", "LF 3:2", "LF 16:9", "LF 2.39:1", "S35 2.8K 16:9"] }
        return ["3.4K Open Gate", "4:3 2.8K", "16:9 3.2K", "16:9 2.8K", "16:9 HD", "4K UHD", "6:5 2.8K Ana"]
    }

    public static func codecs(model: String?) -> [String] {
        let base = ["ARRIRAW", "ProRes 4444 XQ", "ProRes 4444", "ProRes 422 HQ"]
        let m = model?.uppercased() ?? ""
        return isAlexa35(model) || m.contains("LF") ? base : base + ["ProRes 422", "ProRes 422 LT"]
    }

    public static let desqueezeRatios = ["Off", "1.25x", "1.3x", "1.5x", "1.65x", "1.8x", "2x"]

    static func isAlexa35(_ model: String?) -> Bool {
        guard let m = model?.uppercased() else { return false }
        return m.contains("35")
    }

    /// The model a Web Remote names by number in `SystemCameraType`: the ALEXA Mini's own page script reads 1 as an
    /// AMIRA and 2 as an ALEXA Mini (SUP 6.1.2). Other numbers aren't known yet.
    public static func modelName(cameraType: Int) -> String? {
        [1: "AMIRA", 2: "ALEXA Mini"][cameraType]
    }

    /// An ARRI model name: ALEXA, AMIRA.
    public static func isArri(_ model: String?) -> Bool {
        guard let m = model?.uppercased() else { return false }
        return m.contains("ALEXA") || m.contains("AMIRA")
    }
}

extension MockCameraBackend {
    /// An ARRI body as the Web Remote backend means to read one, for Test Mode, the demos and edit mode's stand-in.
    /// Built from ARRI's published specs before Tiles met an ARRI camera: EI 160–3200 (6400 on the ALEXA 35) with 800 the base, the
    /// body's ND filters, 5–356° shutter, Kelvin 2000–11000 with CC ±16, a sensor frame rate inside the format's range,
    /// the look with a switch per output, frame lines, false color, zebra, peaking and overlays per output, and the
    /// lens's iris read off LDS (read-only: the Web Remote doesn't drive the lens). No live view: the Web Remote has none.
    /// `label`: the camera's letter, its clip names' camera index.
    public static func arriSampleState(body: MockBody = .alexaMini, label: String = "A", now: Date = Date()) -> CameraState {
        let model = body.rawValue
        var s = CameraState()
        s.connection = .connected
        s.make = .arri
        s.model = model
        s.recording = RecordingControl(state: .idle)
        s.timecode = TimecodeClock(frames: (14 * 3600 + 22 * 60) * 24, anchor: now, rate: 24, fps: 24, isRunning: false)
        s.iso = Choice(800, options: ArriTables.exposureIndexes(model: model))
        s.nativeISOs = [800]
        s.shutterMode = Choice(.angle, options: [.angle, .speed])
        s.shutterAngle = Choice(172.8, options: ArriTables.shutterAngles)
        s.shutterSpeed = Choice("1/50", options: ArriTables.shutterSpeeds.filter {
            ArriTables.angle(forSpeed: $0, fps: 24).map { $0 >= 5 && $0 <= 356 } ?? false
        })
        s.nd = NDState(preset: Choice("0.6", options: ArriTables.ndFilters(model: model)))
        s.whiteBalance = WhiteBalanceState(
            preset: Choice("5600K", options: ArriTables.whiteBalancePresets),
            kelvin: Level(5600, range: 2000...11000, step: 10),
            tint: Level(0, range: -16...16, step: 0.1))
        let rates = ArriTables.frameRates.filter { $0 <= ArriTables.maxFrameRate(model: model) }.map(Self.rateLabel)
        s.frameRate = FrameRateState(project: Choice("24", options: rates), variableName: "Sensor FPS")
        let modes = ArriTables.sensorModes(model: model)
        s.resolution = Choice(modes[0], options: modes)
        s.fileFormat = Choice("ARRIRAW", options: ArriTables.codecs(model: model))
        s.recordingFormat = "\(modes[0]) · ARRIRAW"
        s.desqueeze = Choice("Off", options: ArriTables.desqueezeRatios)
        s.iris = Choice(2.8, options: [2.8], isWritable: false)
        s.lut = Choice("ARRI 709", options: ["ARRI 709", "Toldwell Show Look", "Day Ext Warm", "Night Int"])
        s.offersFalseColorLUTSwap = false  // its own false color; the look reaches every output
        // The look on every output; frame lines on all of them; overlays on SDI 2 and the viewfinder, not the clean SDI 1.
        let overlays: [MonitorOverlay] = [.lut, .frameGuides, .statusText, .falseColor, .zebra, .focusAssist]
        s.monitoring = MonitoringState(outputs: ArriTables.outputs(model: model).map { output in
            let on: Set<MonitorOverlay> = output.id == "Sdi1" ? [.lut, .frameGuides] : [.lut, .frameGuides, .statusText]
            return MonitorOutput(id: output.id, name: output.name, overlays: Dictionary(uniqueKeysWithValues: overlays.map {
                ($0, Choice(on.contains($0), options: [false, true]))
            }))
        })
        s.look = s.monitoring?.onEverywhere(.lut)
        s.falseColor = s.monitoring?.onEverywhere(.falseColor)
        s.fileNaming = FileNaming(cameraID: Choice(Self.cameraID(label), options: (65...90).map { String(UnicodeScalar(UInt8($0))) }),
                                  reel: Level(4, range: 1...999, step: 1))
        s.clipName = "\(Self.cameraID(label))004C012_261022_R1AB"
        s.webRemoteURL = URL(string: "http://\(body == .alexaMini ? "mini" : "alexa")-12345.local/")
        s.playback = PlaybackState(isPlaying: false, inReview: false, clipName: "\(Self.cameraID(label))004C011_261022_R1AB", clipNumber: nil,
                                   clipCount: 11,
                                   capabilities: PlaybackCapabilities(playPause: true, stop: true, nextPrevious: true,
                                                                      seek: false, fastForwardRewind: true,
                                                                      recReview: false, live: true, review: true))
        s.batteryPercent = 82
        s.mediaRemainingMinutes = 38
        s.latencyMilliseconds = 9
        return s
    }

    static func rateLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", rate)
    }
}

extension DashboardStore {
    /// An ARRI body for Test Mode and edit mode, like `previewState(_:lastSeen:)`'s VENICE branch.
    static func isArri(_ saved: SavedCamera, lastSeen: CameraProfile?) -> Bool {
        saved.connection.arri != nil || saved.connection.demoBody?.isArri == true || lastSeen?.make == .arri
            || ArriTables.isArri(lastSeen?.model)
    }
}
