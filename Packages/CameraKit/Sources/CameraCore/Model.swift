import Foundation

/// Color that identifies a camera everywhere on the dashboard (A red, B blue, C yellow, D green, …).
public enum SlotColor: String, CaseIterable, Sendable, Codable, Hashable {
    case red, blue, yellow, green, orange, purple, teal, pink
}

/// One camera position on the dashboard and how to reach it.
public struct CameraSlot: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var label: String
    public var color: SlotColor
    /// A color picked for this camera instead of one of the eight: drawn in place of `color`
    /// wherever the camera's color shows. `color` stays as it was, for what needs one of the eight.
    public var customColor: AppearanceSettings.RGB?
    /// IP address or hostname, e.g. `192.0.2.23` or `camera.local`.
    public var host: String

    public init(id: UUID = UUID(), label: String, color: SlotColor, customColor: AppearanceSettings.RGB? = nil, host: String) {
        self.id = id
        self.label = label
        self.color = color
        self.customColor = customColor
        self.host = host
    }
}

/// A button on the camera body the app can press for it, so its menu can be worked without its own screen: the BURANO
/// lets the network press MENU, Home, Back, Display, Clips and the multi-selector (Camera Button Function); a VENICE its
/// MENU, Home, Cancel (Back here), the up and down arrows and Set (Enter here).
public enum CameraBodyButton: String, Sendable, Hashable, CaseIterable, Codable {
    case menu, home, back, display, clips, up, down, left, right, enter
}

/// One of a camera's audio channels, as its API lets them be set (a Blackmagic camera's `/audio/channel/{i}/…`).
public struct AudioChannel: Sendable, Equatable, Identifiable {
    /// The camera's index for it, from 0.
    public var id: Int
    /// What it records, as the camera names it ("XLR1 - Mic", "Camera - Left"); the options are the inputs it can
    /// switch to now.
    public var input: Choice<String>?
    /// Its gain in dB, within the input's range.
    public var gain: Level?
    /// 48 V on the input, a low-cut filter, and a pad: each only where the input has it. A pad the input forces is on
    /// and can't be changed.
    public var phantomPower: Choice<Bool>?
    public var lowCut: Choice<Bool>?
    public var pad: Choice<Bool>?
    /// Something is plugged into the input: the camera mutes a channel whose input isn't there.
    public var isAvailable: Bool

    public init(id: Int, input: Choice<String>? = nil, gain: Level? = nil, phantomPower: Choice<Bool>? = nil,
                lowCut: Choice<Bool>? = nil, pad: Choice<Bool>? = nil, isAvailable: Bool = true) {
        self.id = id
        self.input = input
        self.gain = gain
        self.phantomPower = phantomPower
        self.lowCut = lowCut
        self.pad = pad
        self.isAvailable = isAvailable
    }

    /// "CH1", as cameras number them.
    public var name: String { "CH\(id + 1)" }
}

/// One audio channel's setting (`CameraCommand.setAudio`).
public enum AudioSetting: Sendable, Equatable {
    case input(String)
    /// dB.
    case gain(Double)
    case phantomPower(Bool)
    case lowCut(Bool)
    case pad(Bool)
}

/// A VENICE's two sets of frame lines, Line A and Line B: each output shows one of them.
public enum FrameLineSet: String, Sendable, Hashable, CaseIterable, Codable {
    case a = "A", b = "B"

    public var title: String { "Line \(rawValue)" }
}

/// What a frame line set shows of the camera's two user frame lines (`CameraState.userFrameLinesA`): none, the first, the
/// second or both, the four states Sony's "Line A: User Frame Disp." button steps through (CineAlta workflow guide),
/// listed in its order: both, the first, the second, none, and round again.
public enum UserFrameLines {
    public static let off = "Off"
    public static let options = ["1 + 2", "1", "2", "Off"]
    /// A camera with one user frame line.
    public static let single = ["Off", "On"]

    /// The state after `current`, as the camera's button steps them: a tap on the User Frame tile, a deck's `cycle`.
    public static func next(after current: String, in options: [String]) -> String? {
        guard let i = options.firstIndex(of: current), options.count > 1 else { return options.first }
        return options[(i + 1) % options.count]
    }

    /// What `lines` shows: whether user frame line 1 and 2 are on. Nil for a label that isn't one.
    public static func boxes(_ label: String) -> (first: Bool, second: Bool)? {
        switch label {
        case "Off": (false, false)
        case "1", "On": (true, false)
        case "2": (false, true)
        case "1 + 2": (true, true)
        default: nil
        }
    }

    /// The label for the two lines' switches; `second` nil on a camera without a second one.
    public static func label(first: Bool, second: Bool?) -> String {
        guard let second else { return first ? "On" : "Off" }
        switch (first, second) {
        case (false, false): return "Off"
        case (true, false): return "1"
        case (false, true): return "2"
        case (true, true): return "1 + 2"
        }
    }
}

public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    /// The camera is showing our friendly name and waiting for someone to approve it on the body.
    case awaitingApproval
    /// The camera presented a different SSH host key fingerprint from the one saved on first connect.
    /// Could be a reset or replaced camera, or something impersonating it, so we stop and ask.
    case fingerprintChanged(String)
    case connected
    /// Was connected, but values aren't trusted until a full resync finishes (e.g. after the app was backgrounded).
    case stale
    case failed(String)

    /// Controls are only live once the camera has been fully read.
    public var isControllable: Bool { self == .connected }
}

/// A value picked from a list the camera offers (ISO, shutter angle, ND preset, …).
public struct Choice<Value: Sendable & Hashable>: Sendable, Equatable {
    /// Last value the camera reported.
    public var value: Value
    /// Value we asked for that the camera hasn't confirmed yet.
    public var pending: Value?
    public var options: [Value]
    public var isWritable: Bool
    /// Options the camera can only switch to by restarting (the UI warns before sending them).
    public var restartRequired: Set<Value>

    public init(_ value: Value, options: [Value] = [], isWritable: Bool = true, pending: Value? = nil, restartRequired: Set<Value> = []) {
        self.value = value
        self.options = options
        self.isWritable = isWritable
        self.pending = pending
        self.restartRequired = restartRequired
    }

    /// What the UI shows: the request in flight, otherwise the camera's value.
    public var shown: Value { pending ?? value }

    /// The option `offset` steps away from the shown value, or nil at either end of the list.
    public func option(offsetBy offset: Int) -> Value? {
        guard let index = options.firstIndex(of: shown) else { return nil }
        let target = min(max(index + offset, 0), options.count - 1)
        return target == index ? nil : options[target]
    }
}

/// A continuous value inside a range (Kelvin, tint, iris, variable ND).
public struct Level: Sendable, Equatable {
    public var value: Double
    public var pending: Double?
    public var range: ClosedRange<Double>
    public var step: Double
    public var isWritable: Bool

    public init(_ value: Double, range: ClosedRange<Double>, step: Double, isWritable: Bool = true, pending: Double? = nil) {
        self.value = value
        self.range = range
        self.step = step
        self.isWritable = isWritable
        self.pending = pending
    }

    public var shown: Double { pending ?? value }

    /// Where the shown value sits in the range, 0...1.
    public var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((shown - range.lowerBound) / span, 0), 1)
    }

    /// One `step` as a fraction of the range; nil without a step.
    public var stepFraction: Double? {
        let span = range.upperBound - range.lowerBound
        return span > 0 && step > 0 ? step / span : nil
    }

    /// Where `value` sits in the range, 0...1.
    public func fraction(for value: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    /// The value at a 0...1 position, snapped to `step` and clamped to the range.
    public func value(atFraction fraction: Double) -> Double {
        let raw = range.lowerBound + min(max(fraction, 0), 1) * (range.upperBound - range.lowerBound)
        let snapped = step > 0 ? (raw / step).rounded() * step : raw
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}

public enum RecordingState: Sendable, Equatable {
    /// Not read yet. REC stays disabled until the camera has told us what it's doing.
    case unknown
    case idle
    case recording
}

/// REC is never optimistic: a request stays pending until the camera reports the new state, or it fails loudly.
public struct RecordingControl: Sendable, Equatable {
    public enum Request: Sendable, Equatable { case start, stop }

    public var state: RecordingState
    public var request: Request?
    public var failure: String?

    public init(state: RecordingState = .unknown, request: Request? = nil, failure: String? = nil) {
        self.state = state
        self.request = request
        self.failure = failure
    }
}

extension RecordingControl {
    /// Why REC failed, said the same way for every camera: the REC tile shows it under its button. Each backend had its
    /// own words for the same thing ("REC confirmation timed out", "camera didn't confirm", "Camera did not confirm
    /// REC start", a raw error), which didn't matter while only the Activity Log showed them (the 11/16 UI audit).
    public enum Failure {
        /// The camera never said it had started (or stopped): a stop not confirmed may have left it rolling.
        public static func notConfirmed(start: Bool) -> String {
            start ? "The camera didn't confirm the start" : "The camera didn't confirm the stop"
        }
        public static let notReported = "The camera hasn't said whether it's recording"
        /// The command didn't get there, or the camera answered it with an error (the Activity Log has which).
        public static let notSent = "REC didn't reach the camera"
        public static let refused = "The camera refused REC"
        public static let lost = "Lost the camera before it confirmed REC"
        public static let noCommand = "This camera has no REC command"
    }
}

public struct NDState: Sendable, Equatable {
    public var preset: Choice<String>
    /// Electronic variable ND, where the body has it.
    public var variable: Level?

    public init(preset: Choice<String>, variable: Level? = nil) {
        self.preset = preset
        self.variable = variable
    }
}

/// The white balance presets Tiles offers on every camera, so one camera's 5600 is another's: warm
/// practicals, tungsten, fluorescent and mixed light, LED and studio daylight, daylight, overcast and shade. Each camera
/// keeps those inside its own range, then adds Auto or a one-push where it has one, and a VENICE its own saved presets.
public enum WhiteBalancePresets {
    public static let kelvin = [2800, 3200, 4300, 5000, 5600, 6500]

    /// As the White Balance tile lists them ("5600K"), inside `range`.
    public static func labels(within range: ClosedRange<Double>) -> [String] {
        kelvin.filter { range.contains(Double($0)) }.map { "\($0)K" }
    }
}

public struct WhiteBalanceState: Sendable, Equatable {
    public var preset: Choice<String>
    public var kelvin: Level
    public var tint: Level?

    public init(preset: Choice<String>, kelvin: Level, tint: Level? = nil) {
        self.preset = preset
        self.kelvin = kelvin
        self.tint = tint
    }
}

/// A still the camera was asked for: saved to its card, or why not, in the camera's words.
public struct StillGrab: Sendable, Equatable {
    public var at: Date
    public var saved: Bool
    public var message: String?

    public init(at: Date = Date(), saved: Bool, message: String? = nil) {
        self.at = at
        self.saved = saved
        self.message = message
    }
}

public struct FrameRateState: Sendable, Equatable {
    /// Recording frame rate as the camera labels it, e.g. "23.98", "24", "59.94".
    public var project: Choice<String>
    /// Slow & Quick (Sony) or off-speed (Blackmagic) on/off, where the body exposes it.
    public var variable: Choice<Bool>?
    /// The frame rate the sensor runs at while `variable` is on, in frames per second.
    public var variableRate: Choice<Double>?
    /// What the camera calls the variable mode: "S&Q", or "Off-speed".
    public var variableName: String

    public init(project: Choice<String>, variable: Choice<Bool>? = nil, variableRate: Choice<Double>? = nil,
                variableName: String = "S&Q") {
        self.project = project
        self.variable = variable
        self.variableRate = variableRate
        self.variableName = variableName
    }
}

/// What a monitoring output can draw over the picture. Status text is the camera's own information along the edges
/// (a Blackmagic camera's, set through a preset: `BlackmagicPreset.swift`).
public enum MonitorOverlay: String, CaseIterable, Codable, Sendable {
    case lut, falseColor, zebra, focusAssist, frameGuides, frameGrids, safeArea, cleanFeed, statusText, audioMeters

    public var title: String {
        switch self {
        case .lut: "LUT"
        case .falseColor: "False Color"
        case .zebra: "Zebra"
        case .focusAssist: "Focus Assist"
        case .frameGuides: "Frame Guides"
        case .frameGrids: "Grids"
        case .safeArea: "Safe Area"
        case .cleanFeed: "Clean Feed"
        case .statusText: "Status Text"
        case .audioMeters: "Audio Meters"
        }
    }

    /// Whether clean feed hides it. Clean feed turns off "all status text and overlays for an output, except the
    /// record tally" (PYXIS manual); the LUT still applies, since it's the picture rather than drawn over it (on a
    /// PYXIS: LUT changes show on SDI with clean feed on; false color, guides and zebra don't).
    public var hiddenByCleanFeed: Bool { self != .lut && self != .cleanFeed }
}

/// What an output's status text shows: along the bottom of the LCD and the USB-C monitors, the meters or the codec and
/// resolution; on SDI, what a cinematographer wants (ISO, white balance, aperture) or a director (frame rate, camera,
/// reel, scene, take, duration): Blackmagic's "Display status text for".
public enum StatusTextContent: String, CaseIterable, Codable, Sendable {
    case meters, codecAndResolution, cinematographer, director

    public var title: String {
        switch self {
        case .meters: "Meters"
        case .codecAndResolution: "Codec & Res"
        case .cinematographer: "Cinematographer"
        case .director: "Director"
        }
    }

    /// For a switch too narrow for `title`.
    public var shortTitle: String {
        switch self {
        case .meters: "Meters"
        case .codecAndResolution: "Codec"
        case .cinematographer: "Cine"
        case .director: "Director"
        }
    }

    /// The two an output chooses between.
    public var pair: [StatusTextContent] {
        self == .meters || self == .codecAndResolution ? [.meters, .codecAndResolution] : [.cinematographer, .director]
    }
}

/// One of the camera's monitoring outputs (a Blackmagic camera's LCD, USB-C monitors, SDI), with the overlays it
/// reported and whether each is on.
public struct MonitorOutput: Sendable, Equatable, Identifiable {
    /// The camera's name for it, e.g. "MainSDI".
    public var id: String
    /// As shown, e.g. "SDI".
    public var name: String
    public var overlays: [MonitorOverlay: Choice<Bool>]
    /// What its status text shows, where the camera says (`StatusTextContent.pair` are the options).
    public var statusTextContent: Choice<StatusTextContent>?
    /// The `id` of the output this one shows the same as, where the camera links them (a VENICE's SDI 3/4 or HDMI
    /// "Same as Monitor"): its overlays are that output's, and change there.
    public var follows: String?
    /// A camera setting that makes this output follow another by cloning it (an ALEXA Mini's SDI 2: clone SDI 1,
    /// `SDI2IsSDI1Clone`). Present whether the clone is on or off, so the user can turn it off and set SDI 2
    /// independently. `nil` where the camera has no such switch for this output.
    public var sameAsSwitch: Choice<Bool>?
    /// Which of the camera's frame line sets it shows, where it has two (a VENICE's Line A and Line B).
    public var frameLines: Choice<FrameLineSet>?

    public init(id: String, name: String, overlays: [MonitorOverlay: Choice<Bool>],
                statusTextContent: Choice<StatusTextContent>? = nil, follows: String? = nil,
                frameLines: Choice<FrameLineSet>? = nil, sameAsSwitch: Choice<Bool>? = nil) {
        self.id = id
        self.name = name
        self.overlays = overlays
        self.statusTextContent = statusTextContent
        self.follows = follows
        self.frameLines = frameLines
        self.sameAsSwitch = sameAsSwitch
    }

    /// What its status text shows, as it can be changed now: grayed while clean feed hides the status text.
    public var statusTextShows: Choice<StatusTextContent>? {
        guard var choice = statusTextContent else { return nil }
        if isCleanFeed { choice.isWritable = false }
        return choice
    }

    /// Clean feed is on, as the camera reports it: the output shows none of its overlays but the LUT.
    public var isCleanFeed: Bool { overlays[.cleanFeed]?.value == true }

    /// Whether clean feed keeps `overlay` off this output now.
    public func hides(_ overlay: MonitorOverlay) -> Bool { isCleanFeed && overlay.hiddenByCleanFeed }

    /// `overlay`'s switch as it can be used now: grayed while clean feed hides it, so nothing is changed where it can't
    /// be seen. It shows as it's set once clean feed is off.
    public func setting(_ overlay: MonitorOverlay) -> Choice<Bool>? {
        guard var choice = overlays[overlay] else { return nil }
        if hides(overlay) { choice.isWritable = false }
        return choice
    }
}

/// What each monitoring output shows, set output by output: clean feed only makes sense on one, and the operator's
/// LCD and the client's SDI often want different overlays.
public struct MonitoringState: Sendable, Equatable {
    /// In the camera's order. Only outputs that reported an overlay: one the camera can't report (a PYXIS's
    /// stream output) isn't here, and isn't written to.
    public var outputs: [MonitorOutput]
    /// Highlight zebra level, in percent.
    public var zebraLevel: Choice<Int>?
    /// Frame guide aspect ratio, e.g. "2.39:1".
    public var frameGuideRatio: Choice<String>?

    public init(outputs: [MonitorOutput], zebraLevel: Choice<Int>? = nil, frameGuideRatio: Choice<String>? = nil) {
        self.outputs = outputs
        self.zebraLevel = zebraLevel
        self.frameGuideRatio = frameGuideRatio
    }

    /// `overlay` on every output that has it, as one switch: on only when all of them show it, so turning it on
    /// reaches the ones that don't. An output on clean feed can't show it, so it doesn't count and isn't written to
    /// (the backend leaves it alone too); with every output on clean feed the switch is grayed, not gone. Nil when no
    /// output has it.
    public func onEverywhere(_ overlay: MonitorOverlay) -> Choice<Bool>? {
        let having = outputs.filter { $0.overlays[overlay] != nil }
        guard !having.isEmpty else { return nil }
        let states = having.filter { !$0.hides(overlay) }.compactMap { $0.overlays[overlay] }
        guard !states.isEmpty else { return Choice(false, options: [false, true], isWritable: false) }
        return Choice(states.allSatisfy(\.value), options: [false, true], isWritable: states.contains(where: \.isWritable))
    }
}

/// Extended Clear Scan: on or off, and the frequency the shutter scans at.
public struct ECSState: Sendable, Equatable {
    public var on: Choice<Bool>
    /// In Hz, while it's on.
    public var frequency: Double?
    /// Whether the frequency steps up and down now (`CameraCommand.stepECS`).
    public var canStep: Bool

    public init(on: Choice<Bool>, frequency: Double? = nil, canStep: Bool = false) {
        self.on = on
        self.frequency = frequency
        self.canStep = canStep
    }
}

/// A lens motor the camera drives at a signed speed until it's told to stop: the focus near and far, the zoom wide
/// and tele.
public struct LensDrive: Sendable, Equatable {
    /// The fastest speed either way (the camera's own range).
    public var maxSpeed: Int
    /// Where it is, from 0 to 1, where the camera says.
    public var position: Double?
    /// The focus distance in meters, where the lens says.
    public var distance: Double?
    public var isWritable: Bool

    public init(maxSpeed: Int, position: Double? = nil, distance: Double? = nil, isWritable: Bool = true) {
        self.maxSpeed = maxSpeed
        self.position = position
        self.distance = distance
        self.isWritable = isWritable
    }
}

/// One of the camera's assignable buttons.
public struct AssignableButton: Sendable, Equatable, Identifiable {
    /// The lens's button's `id`.
    public static let lensID = 10

    /// Its number on the body, 1 to 9, or `lensID` for the lens's.
    public var id: Int
    /// What it's set to do, in the camera's own short words.
    public var function: String
    /// Lit while what it switches is on, where the camera says.
    public var isOn: Bool?
    /// Whether Tiles presses it: only a function checked on a camera.
    public var isPressable: Bool

    public init(id: Int, function: String, isOn: Bool? = nil, isPressable: Bool) {
        self.id = id
        self.function = function
        self.isOn = isOn
        self.isPressable = isPressable
    }

    /// "Lens" for the lens's button, else its number.
    public var name: String { id == Self.lensID ? "Lens" : "\(id)" }
}

/// How the camera expresses shutter: as an angle (cinema style) or a speed (1/50).
public enum ShutterMode: String, Sendable, Hashable, CaseIterable {
    case angle, speed
}

public enum ClipFlag: String, Sendable, Hashable, CaseIterable {
    case none, ok, ng, keep
}

/// The parts of its clip names a camera lets you set: a title prefix, a camera ID letter and a reel number (Sony's
/// File Settings). Which of them a clip's name uses is the camera menu's file name format, which isn't reachable
/// over the network, so the camera's own name for the next clip (`CameraState.clipName`) is the one to show.
public struct FileNaming: Sendable, Equatable {
    public var title: Choice<String>?
    /// "A" to "Z".
    public var cameraID: Choice<String>?
    public var reel: Level?
    /// Camera Position in the clip's metadata: "C", "L" or "R" (VENICE's Clip Naming, for stereo and side cameras).
    public var position: Choice<String>?
    /// The camera's answer to the last change it refused, e.g. a title with characters it doesn't take.
    public var failure: String?

    /// The longest title the FX3 takes (38 characters and up it refuses).
    public static let titleLimit = 37

    /// What a title may be typed as: letters, digits, "_" and "-", which every card and edit system takes. The camera
    /// takes more, but a "/" splits the file name and "*" isn't a legal file name character on the card.
    public static func isValidTitle(_ title: String) -> Bool {
        (1...titleLimit).contains(title.count)
            && title.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
    }

    public init(title: Choice<String>? = nil, cameraID: Choice<String>? = nil, reel: Level? = nil, failure: String? = nil) {
        self.title = title
        self.cameraID = cameraID
        self.reel = reel
        self.failure = failure
    }
}

/// Everything the dashboard knows about one camera. A nil field means the body doesn't have that control
/// (or hasn't reported it), and the tile for it is disabled rather than guessed.
public struct CameraState: Sendable, Equatable {
    public var connection: ConnectionState = .disconnected
    /// Sony model string as reported, e.g. `ILME-FX3`, `MPC-2610`.
    public var model: String?
    public var timecode: TimecodeClock?
    public var recording = RecordingControl()
    public var nd: NDState?
    public var shutterAngle: Choice<Double>?
    /// Shutter speed as the camera labels it, e.g. "1/48", "1/50".
    public var shutterSpeed: Choice<String>?
    /// Which of the two the camera is using; the shutter tiles follow it.
    public var shutterMode: Choice<ShutterMode>?
    public var frameRate: FrameRateState?
    /// Who made the camera, for what differs by maker beyond its controls (a Blackmagic camera's own default page).
    public var make: ProfileCameraType?
    public var iso: Choice<Int>?
    /// The ISOs the sensor is native at, where its maker states them for the model (a PYXIS 12K: 800); the ISO list
    /// marks them "(base)". Empty where unknown. Not Sony's base ISO switch, which is `baseISO`.
    public var nativeISOs: [Int] = []
    public var baseISO: Choice<Int>?
    public var whiteBalance: WhiteBalanceState?
    /// Focus mode as the camera labels it, e.g. "AF-C", "MF". The dashboard shows it as an AF/MF switch.
    public var focusMode: Choice<String>?
    /// Aperture as the f-numbers the camera offers for the mounted lens (third stops), e.g. 2.8, 3.2, 3.5, 4.0.
    public var iris: Choice<Double>?
    public var clipFlag: Choice<ClipFlag>?
    public var imageFlip: Choice<Bool>?
    /// The camera's info over the picture on its HDMI output; off is a clean feed (a Sony's Monitoring Output Display
    /// HDMI). And its grid lines (Sony).
    public var hdmiInfo: Choice<Bool>?
    public var gridLines: Choice<Bool>?
    public var webRemoteURL: URL?
    /// The name the camera will give the next clip, e.g. `mm0556`, as the camera reports it.
    public var clipName: String?
    /// Title, camera ID and reel for clip names, where the camera lets them be set.
    public var fileNaming: FileNaming?
    /// Human-readable recording format, `"main · detail"`, e.g. `3840x2160 · XAVC S-I 4K`.
    public var recordingFormat: String?
    /// Round trip to the camera as measured by the backend, so a struggling link is visible.
    public var latencyMilliseconds: Int?
    /// Recording resolution, e.g. "3840x2160".
    public var resolution: Choice<String>?
    /// Recording file format / codec family, e.g. "XAVC S-I 4K".
    public var fileFormat: Choice<String>?
    /// Bitrate and sampling within the file format, e.g. "240M 4:2:2 10bit".
    public var recordingSetting: Choice<String>?
    /// Anamorphic de-squeeze on the camera's displays, e.g. "Off", "1.3x", "2.0x".
    public var desqueeze: Choice<String>?
    public var colorBars: Choice<Bool>?
    /// How the ND moves, where the camera switches it over the network: "Step" or "Variable" (the BURANO).
    public var ndMode: Choice<String>?
    /// The camera's tally lamps, lit from the app: "Off", "Green" or "Red" (the BURANO; a Blackmagic camera's None,
    /// Preview and Program).
    public var tally: Choice<String>?
    /// CALL on the camera's own display, to get the operator's attention (the BURANO).
    public var call: Choice<Bool>?
    /// The color gamut the camera records, e.g. "S-Gamut3.Cine" (the BURANO).
    public var colorGamut: Choice<String>?
    /// The camera's shooting mode: an FX6's Custom, Cine EI, Cine EI Quick or Flexible ISO. Each mode brings its own
    /// white balance, look and exposure, so the tile asks first.
    public var shootingMode: Choice<String>?
    /// Gain in dB, where the camera works in dB rather than ISO (an FX6 in Custom). The ISO tile shows it.
    public var gain: Choice<Int>?
    /// The base sensitivity where the camera works in dB, "Low" or "High" (an FX6 in Custom), as `baseISO` is in ISO.
    public var baseSensitivity: Choice<String>?
    /// The camera's image stabilisation (Sony's SteadyShot): "Off", "Standard", "Active", "Dynamic Active" (an FX5).
    public var steadyShot: Choice<String>?
    /// Which part of the sensor records, and at what size: "FF 5K 16:9", "S35 3.2K 16:9" (an FX5's Imager Mode).
    public var imagerMode: Choice<String>?
    /// The LUT baked into what's recorded (an FX6's Monitor LUT for Internal Rec). Only its own tile sets it, never
    /// a monitoring switch, and not during a take.
    public var recordedLUT: Choice<Bool>?
    /// Proxy recording on or off.
    public var proxyRecording: Choice<Bool>?
    /// What the proxy recorder says while proxy recording is on: "Standby", "Recording".
    public var proxyStatus: String?
    /// Extended Clear Scan: the shutter at a frequency matched to a screen in shot (an FX6's).
    public var ecs: ECSState?
    /// The iris on Auto: the camera sets the f-number, which reads but can't be set meanwhile.
    public var irisAuto: Choice<Bool>?
    /// The ND on Auto (an FX6's Auto ND): the camera sets the density, which reads but can't be set meanwhile.
    public var ndAuto: Choice<Bool>?
    /// The gain on Auto (an FX6's AGC): the camera sets the ISO, which reads but can't be set meanwhile.
    public var isoAuto: Choice<Bool>?
    /// The lens's focal length in mm, where it reports one.
    public var focalLength: Double?
    /// The focus, driven near and far by the camera (`CameraCommand.driveFocus`).
    public var focusDrive: LensDrive?
    /// The zoom, driven wide and tele, where the lens has a power zoom (`CameraCommand.driveZoom`).
    public var zoomDrive: LensDrive?
    /// The camera's assignable buttons, numbered as on the body, with what each is set to do.
    public var assignableButtons: [AssignableButton] = []
    /// The camera's buttons the app can press for it (`CameraBodyButton`); empty where it can't.
    public var cameraButtons: [CameraBodyButton] = []
    /// One-shot autofocus: a Blackmagic camera with a lens it can focus (on the middle of the picture), or a Sony pro
    /// body with Push Auto Focus (an FX5: autofocus for a moment while focus is manual).
    public var canAutoFocus = false
    /// The camera writes a still to its card when asked (`CameraCommand.grabStill`): a Blackmagic camera, through
    /// its REST API's still capture, until it answers that it has none.
    public var canGrabStill = false
    /// What the last Grab Still came to, as the camera answered it.
    public var lastStill: StillGrab?
    /// The camera is focusing by itself (AF on, or held), as it reports it: on an FX5 what focus is actually doing, so a
    /// lens switched to MF reads manual even with AF / MF on AF.
    public var focusIsAuto = false
    /// A push autofocus would do something now: the camera has one, isn't focusing by itself, and its AF / MF (where it
    /// reads) is on MF. With AF on, an FX5's push is Push MF instead (autofocus stops while it's held), and with the
    /// lens's own switch at MF it takes no push at all (Sony's FX5 help guide, focus_push_af.html).
    public var canPushAutoFocus: Bool {
        canAutoFocus && !focusIsAuto && !(focusMode.map { Self.isAutofocusMode($0.value) } ?? false)
    }
    /// An AF / MF value that's autofocus: AF, AF-C, AF-S, AF-A… and DMF (AF, the ring touching it up).
    public static func isAutofocusMode(_ label: String) -> Bool { label.hasPrefix("AF") || label == "DMF" }
    /// What autofocus looks for (a Sony's Subject Recognition AF): "Face/Eye Priority AF" and the like on an FX6, "Human
    /// Priority AF" … "Bird Priority AF" on an FX5, or "Off".
    public var subjectRecognition: Choice<String>?
    /// Where autofocus looks (Focus Area): "Wide", "Zone", "Flexible Spot"…
    public var focusArea: Choice<String>?
    /// How quickly autofocus moves to a new subject, 1 (slow) to 7 (fast): AF Transition Speed.
    public var afTransitionSpeed: Choice<Int>?
    /// How readily autofocus leaves the subject it's on for another, 1 (locked on) to 5 (responsive): AF Subj. Shift
    /// Sens.
    public var afSubjectShift: Choice<Int>?
    /// The focus ring taking over from autofocus while it's turned: AF Assist.
    public var afAssist: Choice<Bool>?
    /// Why False Color can't be switched from here, shown on its tile: an FX5 whose False Color is only a button function
    /// and no button is set to it ("Assign a button"). nil when it can, or the camera has none.
    public var falseColorHint: String?
    /// Any of the autofocus settings above: the AF Settings tile.
    public var hasAFSettings: Bool {
        subjectRecognition != nil || focusArea != nil || afTransitionSpeed != nil || afSubjectShift != nil || afAssist != nil
    }
    /// The audio channels the camera lets the network set, in its order (Blackmagic).
    public var audioChannels: [AudioChannel] = []
    /// How many audio meters the camera reports (a VENICE's four); 0 for none. Their levels are `audioMeters`.
    public var audioMeterCount = 0
    /// The meters' levels, 0…1, channel by channel. They change several times a second, so `CameraController` keeps them
    /// out of its `state` (`CameraController.audioMeters`): only the Audio tile redraws with them.
    public var audioMeters: [Double]?
    /// The camera records no sound now (a VENICE in S&Q): its meters gray out, as on its own page.
    public var audioMetersMuted = false
    /// What a VENICE's frame line sets A and B show of its user frame lines (`UserFrameLines`).
    public var userFrameLinesA: Choice<String>?
    public var userFrameLinesB: Choice<String>?
    /// False color on the monitor output (a Blackmagic camera: on every output, from `monitoring`).
    public var falseColor: Choice<Bool>?
    /// View assist / monitor LUT on or off (on FX3: Gamma Display Assist; a Blackmagic camera: the display LUT on every
    /// output, from `monitoring`).
    public var look: Choice<Bool>?
    /// Overlays output by output, where the camera sets them that way (Blackmagic).
    public var monitoring: MonitoringState?
    /// The gamma the camera records and shows, e.g. "Film" or "Video" (Blackmagic's dynamic range).
    public var dynamicRange: Choice<String>?
    /// Which look/LUT is selected, as the camera names it: built-ins like "s709" or "709(800%)", or a
    /// user LUT slot with its name, e.g. "User 1: TW Show LUT". Toldwell mostly shoots with custom LUTs.
    public var lut: Choice<String>?
    /// Whether the LUT tile's False Color switch may swap the LUT for a false color one in `lut`'s list (an FX3's
    /// only false color). Off on a VENICE and an ARRI: they have their own, and their look reaches every output that
    /// shows it, SDI to the client and a ProRes recording included. A new backend whose LUT reaches its outputs or its
    /// recording turns it off.
    public var offersFalseColorLUTSwap = true
    public var batteryPercent: Int?
    /// The camera's own time display: its timecode, or the clip's duration (VENICE: TC/Media > Time Data Display).
    /// When true the camera reports the duration where the timecode was.
    public var timecodeShowsDuration: Choice<Bool>?
    /// The battery in volts, for a camera whose display reads volts rather than a percentage (VENICE 2: 14.6 V).
    public var batteryVolts: Double?
    /// Minutes of battery left, for a camera set to show its battery that way (a BURANO's or an FX6's Battery Remain
    /// Display Unit at minutes), where it has no percentage to give.
    public var batteryMinutes: Int?
    /// What's powering the camera where it isn't simply its battery, shown on the Battery tile: "USB" (an FX5 on USB-C
    /// power with its battery flat read 0%), "DC", "AC", "PoE", "Fiber", or "Ext" (a battery the camera can't read: a
    /// dummy battery on external power). nil on its own battery, or where the camera doesn't say.
    public var powerSource: String?
    public var mediaRemainingMinutes: Int?
    /// Wall-clock time at which the current take began, confirmed by the camera reporting RecordingState.recording.
    /// nil when not recording or before the first confirmed start. Drive take-runtime display from this, not
    /// from a local estimate: the FX3 does not expose 0xD120 Recording Duration over PTP [fixtures/fx3-tc-battery-2026-10-09.txt].
    public var takeStartedAt: Date?
    /// Playback state. Non-nil only when the camera's protocol exposes playback controls.
    /// nil = no playback tile for this camera.
    public var playback: PlaybackState?
    public var warnings: [String] = []
    /// What the camera itself is warning about, as its own screen would: it's overheating, a card is in trouble. The
    /// first shows in red on the camera's Label tile in place of its model, and each goes in the Activity Log. (A
    /// command's own trouble is `warnings`, which only camctl prints.)
    public var alerts: [String] = []
    /// SSH host key fingerprint seen on this connection (Access Authentication cameras). Saved
    /// automatically the first time; only a later change needs the user.
    public var observedFingerprint: String?
    /// The camera advertises a live view stream (0xD278 present and non-empty). The tile is available
    /// for manual add; it is never in the default templates (too much bandwidth for default-on).
    public var hasLiveView: Bool = false

    public init() {}

    /// Short display name: `ILME-FX3` → `FX3`, `MPC-2610` → `BURANO`, `MPC-3628` → `VENICE 2`.
    public var modelName: String? { model.map(Self.modelName) }

    /// A Sony model string's short name, as `modelName`.
    public static func modelName(_ model: String) -> String {
        if model == "MPC-2610" { return "BURANO" }
        if model == "MPC-3628" || model == "MPC-3626" { return "VENICE 2" }  // the 8.6K and the 6K sensor
        if model == "MPC-3610" { return "VENICE" }
        if let dash = model.firstIndex(of: "-") { return String(model[model.index(after: dash)...]) }
        return model
    }
}

/// A false color LUT: "False Color" in its name, or FC as its own word ("GK_SLOG3_Log_FC"). The LUT tile's False
/// Color switch swaps to it, and back to `CameraController.lutBeforeFalseColor`.
public func isFalseColorLUT(_ name: String) -> Bool {
    name.localizedCaseInsensitiveContains("false")
        || name.range(of: #"(^|[^A-Za-z])FC([^A-Za-z]|$)"#, options: .regularExpression) != nil
}

/// An error as a person reads it, for a failed connection's reason (the Label tile's ⓘ, the connection menu): its own
/// description where it has one, the system's for a network error ("Could not connect to the server."), else what it
/// is. `String(describing:)` gave "URLError(_nsError: Error Domain=NSURLErrorDomain Code=-1004 …)".
public func readableReason(_ error: Error) -> String {
    if let described = (error as? LocalizedError)?.errorDescription { return described }
    let ns = error as NSError
    if [NSURLErrorDomain, NSPOSIXErrorDomain, NSCocoaErrorDomain].contains(ns.domain) { return ns.localizedDescription }
    return String(String(describing: error).prefix(120))
}
