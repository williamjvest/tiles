import Foundation

// MARK: - FieldValue

/// A value that can be a bool, int, double, or string — used for command values and field values.
enum FieldValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    var jsonValue: AnyCodable {
        switch self {
        case .bool(let b): AnyCodable(b)
        case .int(let i): AnyCodable(i)
        case .double(let d): AnyCodable(d)
        case .string(let s): AnyCodable(s)
        }
    }

    static func from(_ a: AnyCodable) -> FieldValue? {
        if let b = a.value as? Bool { return .bool(b) }
        if let i = a.value as? Int { return .int(i) }
        if let d = a.value as? Double { return .double(d) }
        if let s = a.value as? String { return .string(s) }
        return nil
    }
}

// MARK: - AnyCodable

/// Type-erased Codable for JSON values that can be any scalar.
public struct AnyCodable: Codable, @unchecked Sendable, Equatable {
    let value: Any

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        if let l = lhs.value as? Bool, let r = rhs.value as? Bool { return l == r }
        if let l = lhs.value as? Int, let r = rhs.value as? Int { return l == r }
        if let l = lhs.value as? Double, let r = rhs.value as? Double { return l == r }
        if let l = lhs.value as? String, let r = rhs.value as? String { return l == r }
        return false
    }

    init(_ b: Bool) { value = b }
    init(_ i: Int) { value = i }
    init(_ d: Double) { value = d }
    init(_ s: String) { value = s }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { value = b; return }
        if let i = try? c.decode(Int.self) { value = i; return }
        if let d = try? c.decode(Double.self) { value = d; return }
        if let s = try? c.decode(String.self) { value = s; return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unsupported type"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let b = value as? Bool { try c.encode(b) }
        else if let i = value as? Int { try c.encode(i) }
        else if let d = value as? Double { try c.encode(d) }
        else if let s = value as? String { try c.encode(s) }
    }
}

// MARK: - Field shapes

/// Field shape for a choice (discrete options list).
public struct APIFieldChoice: Codable, Sendable, Equatable {
    public var value: AnyCodable
    public var options: [AnyCodable]
    public var writable: Bool
    public var pending: AnyCodable?
}

/// Field shape for a level (continuous range).
public struct APIFieldLevel: Codable, Sendable, Equatable {
    public var value: Double
    public var min: Double
    public var max: Double
    public var step: Double
    public var writable: Bool
    public var pending: Double?
}

/// Field shape for recording control.
public struct APIFieldRecord: Codable, Sendable, Equatable {
    public var value: String // "idle" | "recording" | "unknown"
    public var writable: Bool
    public var startedAt: String?
    public var request: String?  // "start" | "stop"
    public var failure: String?
}

// MARK: - APIFieldAny

/// Type-erased field value that can encode as choice/level/record.
public enum APIFieldAny: Codable, Sendable, Equatable {
    case choice(APIFieldChoice)
    case level(APIFieldLevel)
    case record(APIFieldRecord)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .choice(let c): try c.encode(to: encoder)
        case .level(let l): try l.encode(to: encoder)
        case .record(let r): try r.encode(to: encoder)
        }
    }

    public init(from decoder: Decoder) throws {
        // Detect by presence of distinguishing keys
        let container = try decoder.container(keyedBy: DynamicCodingKeys.self)
        if container.contains(.init("options")) {
            self = .choice(try APIFieldChoice(from: decoder))
        } else if container.contains(.init("min")) {
            self = .level(try APIFieldLevel(from: decoder))
        } else {
            self = .record(try APIFieldRecord(from: decoder))
        }
    }

    struct DynamicCodingKeys: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { self.stringValue = s }
        init?(stringValue s: String) { self.stringValue = s }
        init?(intValue _: Int) { nil }
    }

    /// Build the full field dictionary from a CameraState, including offline behavior.
    static func fields(from state: CameraState) -> [String: APIFieldAny] {
        let connected = state.connection.isControllable
        var f: [String: APIFieldAny] = [:]

        // record — always present (writable: false when not connected; unknown when not connected)
        let recValue: String
        if !connected {
            recValue = "unknown"
        } else {
            recValue = state.recording.state.apiString
        }
        let recField = APIFieldRecord(
            value: recValue,
            writable: connected,
            startedAt: state.takeStartedAt.map { iso8601.string(from: $0) },
            request: state.recording.request.map { $0 == .start ? "start" : "stop" },
            failure: state.recording.failure
        )
        f["record"] = .record(recField)

        func choice<V: Hashable & Sendable>(
            _ ch: Choice<V>?, toValue: (V) -> AnyCodable
        ) -> APIFieldAny? {
            guard let ch else { return nil }
            return .choice(APIFieldChoice(
                value: toValue(ch.value),
                options: ch.options.map(toValue),
                writable: connected && ch.isWritable,
                pending: ch.pending.map(toValue)
            ))
        }

        func level(_ lv: Level?) -> APIFieldAny? {
            guard let lv else { return nil }
            return .level(APIFieldLevel(
                value: lv.value,
                min: lv.range.lowerBound,
                max: lv.range.upperBound,
                step: lv.step,
                writable: connected && lv.isWritable,
                pending: lv.pending
            ))
        }

        if let v = choice(state.iso, toValue: { AnyCodable($0) }) { f["iso"] = v }
        if let v = choice(state.baseISO, toValue: { AnyCodable($0) }) { f["baseISO"] = v }
        if let v = choice(state.shutterMode, toValue: { AnyCodable($0.rawValue) }) { f["shutterMode"] = v }
        if let v = choice(state.shutterAngle, toValue: { AnyCodable($0) }) { f["shutterAngle"] = v }
        if let v = choice(state.shutterSpeed, toValue: { AnyCodable($0) }) { f["shutterSpeed"] = v }
        if let wb = state.whiteBalance {
            if let v = choice(Optional(wb.preset), toValue: { AnyCodable($0) }) { f["wbPreset"] = v }
            if let v = level(wb.kelvin) { f["kelvin"] = v }
            if let v = level(wb.tint) { f["tint"] = v }
        }
        if let v = choice(state.iris, toValue: { AnyCodable($0) }) { f["iris"] = v }
        if let nd = state.nd {
            if let v = choice(Optional(nd.preset), toValue: { AnyCodable($0) }) { f["ndPreset"] = v }
            if let v = level(nd.variable) { f["variableND"] = v }
        }
        if let fr = state.frameRate {
            if let v = choice(Optional(fr.project), toValue: { AnyCodable($0) }) { f["frameRate"] = v }
            if let v = choice(fr.variable, toValue: { AnyCodable($0) }) { f["frameRateVariable"] = v }
            if let v = choice(fr.variableRate, toValue: { AnyCodable($0) }) { f["offSpeedRate"] = v }
        }
        if let v = choice(state.dynamicRange, toValue: { AnyCodable($0) }) { f["dynamicRange"] = v }
        if let monitoring = state.monitoring {
            for overlay in ControlFields.everyOutputOverlays {
                if let v = choice(monitoring.onEverywhere(overlay), toValue: { AnyCodable($0) }) { f[overlay.rawValue] = v }
            }
            if let v = choice(monitoring.zebraLevel, toValue: { AnyCodable($0) }) { f["zebraLevel"] = v }
            if let v = choice(monitoring.frameGuideRatio, toValue: { AnyCodable($0) }) { f["frameGuideRatio"] = v }
        }
        if let v = choice(state.resolution, toValue: { AnyCodable($0) }) { f["resolution"] = v }
        if let v = choice(state.fileFormat, toValue: { AnyCodable($0) }) { f["codec"] = v }
        if let v = choice(state.recordingSetting, toValue: { AnyCodable($0) }) { f["bitrate"] = v }
        if let v = choice(state.desqueeze, toValue: { AnyCodable($0) }) { f["desqueeze"] = v }
        if let v = choice(state.lut, toValue: { AnyCodable($0) }) { f["lut"] = v }
        if let v = choice(state.look, toValue: { AnyCodable($0) }) { f["look"] = v }
        if let v = choice(state.falseColor, toValue: { AnyCodable($0) }) { f["falseColor"] = v }
        if let v = choice(state.focusMode, toValue: { AnyCodable($0) }) { f["focusMode"] = v }
        if let v = choice(state.colorBars, toValue: { AnyCodable($0) }) { f["colorBars"] = v }
        if let v = choice(state.imageFlip, toValue: { AnyCodable($0) }) { f["imageFlip"] = v }
        if let v = choice(state.hdmiInfo, toValue: { AnyCodable($0) }) { f["hdmiInfo"] = v }
        if let v = choice(state.gridLines, toValue: { AnyCodable($0) }) { f["gridLines"] = v }
        if let v = choice(state.ndMode, toValue: { AnyCodable($0) }) { f["ndMode"] = v }
        if let v = choice(state.tally, toValue: { AnyCodable($0) }) { f["tally"] = v }
        if let v = choice(state.call, toValue: { AnyCodable($0) }) { f["call"] = v }
        if let v = choice(state.colorGamut, toValue: { AnyCodable($0) }) { f["colorGamut"] = v }
        if let v = choice(state.shootingMode, toValue: { AnyCodable($0) }) { f["shootingMode"] = v }
        if let v = choice(state.gain, toValue: { AnyCodable($0) }) { f["gain"] = v }
        if let v = choice(state.baseSensitivity, toValue: { AnyCodable($0) }) { f["baseSensitivity"] = v }
        if let v = choice(state.steadyShot, toValue: { AnyCodable($0) }) { f["steadyShot"] = v }
        if let v = choice(state.imagerMode, toValue: { AnyCodable($0) }) { f["imagerMode"] = v }
        if let v = choice(state.subjectRecognition, toValue: { AnyCodable($0) }) { f["subjectRecognition"] = v }
        if let v = choice(state.focusArea, toValue: { AnyCodable($0) }) { f["focusArea"] = v }
        if let v = choice(state.afTransitionSpeed, toValue: { AnyCodable($0) }) { f["afTransitionSpeed"] = v }
        if let v = choice(state.afSubjectShift, toValue: { AnyCodable($0) }) { f["afSubjectShift"] = v }
        if let v = choice(state.afAssist, toValue: { AnyCodable($0) }) { f["afAssist"] = v }
        if let v = choice(state.recordedLUT, toValue: { AnyCodable($0) }) { f["recordedLUT"] = v }
        if let v = choice(state.proxyRecording, toValue: { AnyCodable($0) }) { f["proxy"] = v }
        if let v = choice(state.ecs?.on, toValue: { AnyCodable($0) }) { f["ecs"] = v }
        if let v = choice(state.irisAuto, toValue: { AnyCodable($0) }) { f["irisAuto"] = v }
        if let v = choice(state.ndAuto, toValue: { AnyCodable($0) }) { f["ndAuto"] = v }
        if let v = choice(state.isoAuto, toValue: { AnyCodable($0) }) { f["isoAuto"] = v }
        if let v = choice(state.userFrameLinesA, toValue: { AnyCodable($0) }) { f["userFrameA"] = v }
        if let v = choice(state.userFrameLinesB, toValue: { AnyCodable($0) }) { f["userFrameB"] = v }
        if let v = choice(state.clipFlag, toValue: { AnyCodable($0.rawValue) }) { f["clipFlag"] = v }
        if let v = choice(state.timecodeShowsDuration, toValue: { AnyCodable($0) }) { f["timecodeDuration"] = v }
        if let v = choice(state.apiPlaybackMode, toValue: { AnyCodable($0) }) { f["playbackMode"] = v }
        if let v = choice(state.apiPlaying, toValue: { AnyCodable($0) }) { f["playing"] = v }

        return f
    }

    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Field names shared by the published state and the commands that set it.
enum ControlFields {
    /// Overlays the API sets on every output at once, by their raw names ("zebra", "cleanFeed"). LUT and false color
    /// are `look` and `falseColor`.
    static let everyOutputOverlays = MonitorOverlay.allCases.filter { $0 != .lut && $0 != .falseColor }
}

// MARK: - APICameraFull

/// One camera's full API representation.
public struct APICameraFull: Codable, Sendable {
    public var id: String
    public var label: String
    public var model: String?
    public var color: String
    public var demo: Bool
    public var connection: String
    public var latencyMs: Int?
    public var battery: Int?
    public var mediaMinutes: Int?
    public var fields: [String: APIFieldAny]
    /// The camera's clip and transport, on a camera that plays back (docs/control-api.md, Playback).
    public var playback: APIPlayback?

    @MainActor
    public init(from cam: CameraController) {
        self.id = cam.id.uuidString
        self.label = cam.slot.label
        self.model = cam.state.model
        self.color = cam.slot.color.rawValue
        self.demo = cam.isDemo
        self.connection = cam.state.connection.apiString
        self.latencyMs = cam.state.latencyMilliseconds
        self.battery = cam.state.batteryPercent
        self.mediaMinutes = cam.state.mediaRemainingMinutes
        self.fields = APIFieldAny.fields(from: cam.state)
        self.playback = APIPlayback(cam.state)
    }
}

// MARK: - Playback

/// A camera's playback as the API gives it: the clip, where it is, and the transport commands it takes now.
public struct APIPlayback: Codable, Sendable, Equatable {
    public var clip: String?
    public var clipNumber: Int?
    public var clipCount: Int?
    /// Seconds.
    public var position: Double?
    public var duration: Double?
    public var commands: [String]

    /// nil on a camera that doesn't play back. Offline, a camera takes no commands.
    init?(_ state: CameraState) {
        guard let pb = state.playback else { return nil }
        clip = pb.clipName
        clipNumber = pb.clipNumber
        clipCount = pb.clipCount
        position = pb.position
        duration = pb.duration
        commands = Self.commands(state)
    }

    /// The commands a camera takes now: none offline. A VENICE sends InsideClips (its clip list) for an `endScan` it
    /// has no key for, so it's offered no held scan until that's resolved; its ◀◀ ▶▶ presses are fine.
    static func commands(_ state: CameraState) -> [String] {
        guard let pb = state.playback, state.connection.isControllable else { return [] }
        return commands(pb, recordingIdle: state.recordingIsIdle, heldScan: !CameraProfile.isVenice(state.model))
    }

    /// What the Playback tile lets you press, by name. A camera that has to be put into review first takes the clip
    /// commands only there, and Review only while it isn't recording. Play and pause are offered on their own only
    /// where the camera says whether it's playing: on some the button is a toggle, so the server needs to know.
    static func commands(_ pb: PlaybackState, recordingIdle: Bool, heldScan: Bool = true) -> [String] {
        let caps = pb.capabilities
        let inReview = pb.inReview == true
        var c: [String] = []
        if !caps.review || inReview {
            if caps.playPause {
                c.append("togglePlay")
                if pb.isPlaying != nil { c += ["play", "pause"] }
            }
            if caps.stop { c.append("stop") }
            if caps.nextPrevious { c += ["next", "previous"] }
            if caps.fastForwardRewind {
                c += ["fastForward", "rewind"]
                // The tile's held ◀◀ ▶▶, on a camera played through its own buttons.
                if caps.review && heldScan { c += ["scanForward", "scanBackward", "endScan"] }
            }
            if caps.seek { c.append("skip") }
        }
        // Rec Review plays the last take from the live picture.
        if caps.recReview && !inReview { c.append("recReview") }
        if caps.review {
            if inReview { c.append("live") } else if recordingIdle { c.append("review") }
        } else if caps.live {
            c.append("live")
        }
        return c
    }
}

extension CameraState {
    /// Not recording, and no REC on its way.
    var recordingIsIdle: Bool { recording.state == .idle && recording.request == nil }

    /// The `playbackMode` field: Live or Review on a camera that has to be put into playback first (its Live | Review
    /// switch). No way into review while recording; the switch and the backends refuse it too.
    var apiPlaybackMode: Choice<String>? {
        guard let pb = playback, pb.capabilities.review, let inReview = pb.inReview else { return nil }
        return Choice(inReview ? "review" : "live", options: ["live", "review"], isWritable: inReview || recordingIsIdle)
    }

    /// The `playing` field: only where the camera says whether it's playing, writable where it takes the clip commands.
    var apiPlaying: Choice<Bool>? {
        guard let pb = playback, pb.capabilities.playPause, let playing = pb.isPlaying else { return nil }
        return Choice(playing, options: [false, true], isWritable: !pb.capabilities.review || pb.inReview == true)
    }
}

extension PlaybackCommand {
    /// The command a `playback` name stands for (docs/control-api.md, Playback). nil for a name it doesn't know, and
    /// for `skip` without its seconds.
    init?(apiName: String, by: Double?) {
        switch apiName {
        case "togglePlay": self = .togglePlay
        case "play": self = .play
        case "pause": self = .pause
        case "stop": self = .stop
        case "next": self = .next
        case "previous": self = .previous
        case "fastForward": self = .fastForward
        case "rewind": self = .rewind
        case "scanForward": self = .scan(forward: true)
        case "scanBackward": self = .scan(forward: false)
        case "endScan": self = .endScan
        case "skip":
            guard let by, by.isFinite, by != 0 else { return nil }
            self = .skip(by)
        case "recReview": self = .recReview
        case "review": self = .review
        case "live": self = .live
        default: return nil
        }
    }
}

// MARK: - APIPageEntry

/// Page API representation.
public struct APIPageEntry: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var cameras: [String]
    public var linking: Bool
    public var links: [String]
    public var current: Bool

    /// `cameras`: who the page shows, from `DashboardStore.cameras(on:)`. The page's own `cameraIDs` is empty for an
    /// All page and stale for a customized one, so a client resolving "current page" from it found no camera there.
    public init(from page: CameraPage, cameras: [UUID], currentPageID: UUID? = nil) {
        self.id = page.id.uuidString
        self.name = page.name
        self.cameras = cameras.map(\.uuidString)
        self.linking = page.isLinking
        // In the app's fixed order: `links` is a Set, whose iteration order differs between instances, so the same page
        // encoded differently each time and every observer tick sent a spurious `pages` message.
        self.links = LinkKind.allCases.filter { page.links.contains($0) }.map(\.rawValue)
        self.current = currentPageID == page.id
    }

    public init(id: String, name: String, cameras: [String], linking: Bool, links: [String], current: Bool) {
        self.id = id; self.name = name; self.cameras = cameras
        self.linking = linking; self.links = links; self.current = current
    }
}

// MARK: - CameraChangesUpdate

/// The update payload of a `changes` message.
/// Encodes as `{"latencyMs":41,"fields":{"iso":{"value":1600,"pending":null}}}`.
public struct CameraChangesUpdate: Sendable {
    public var connection: String?
    public var latencyMs: Int?
    public var battery: Int?
    public var mediaMinutes: Int?
    public var fields: [String: FieldFragment]?
    /// The playback changed: `playback` goes out whole, or as `null` when the camera no longer has it.
    public var playbackChanged = false
    public var playback: APIPlayback?

    public init(connection: String? = nil, latencyMs: Int? = nil, battery: Int? = nil,
                mediaMinutes: Int? = nil, fields: [String: FieldFragment]? = nil) {
        self.connection = connection; self.latencyMs = latencyMs
        self.battery = battery; self.mediaMinutes = mediaMinutes; self.fields = fields
    }

    public var isEmpty: Bool {
        connection == nil && latencyMs == nil && battery == nil && mediaMinutes == nil
            && (fields == nil || fields!.isEmpty) && !playbackChanged
    }
}

extension CameraChangesUpdate: Codable {
    enum CodingKeys: String, CodingKey {
        case connection, latencyMs, battery, mediaMinutes, fields, playback
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(connection, forKey: .connection)
        try c.encodeIfPresent(latencyMs, forKey: .latencyMs)
        try c.encodeIfPresent(battery, forKey: .battery)
        try c.encodeIfPresent(mediaMinutes, forKey: .mediaMinutes)
        if let f = fields, !f.isEmpty { try c.encode(f, forKey: .fields) }
        if playbackChanged {
            if let playback { try c.encode(playback, forKey: .playback) } else { try c.encodeNil(forKey: .playback) }
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connection = try c.decodeIfPresent(String.self, forKey: .connection)
        latencyMs = try c.decodeIfPresent(Int.self, forKey: .latencyMs)
        battery = try c.decodeIfPresent(Int.self, forKey: .battery)
        mediaMinutes = try c.decodeIfPresent(Int.self, forKey: .mediaMinutes)
        fields = try c.decodeIfPresent([String: FieldFragment].self, forKey: .fields)
        playbackChanged = c.contains(.playback)
        playback = try c.decodeIfPresent(APIPlayback.self, forKey: .playback)
    }
}

// MARK: - FieldFragment

/// A fragment of a field — only the keys that changed.
/// `pending: null` signals that the pending value was cleared.
public struct FieldFragment: Codable, Sendable {
    public var value: AnyCodable?
    /// true = pending key is present in output; pendingValue = nil → encodes as null
    public var hasPending: Bool = false
    public var pendingValue: AnyCodable?
    public var writable: Bool?
    public var startedAt: String?
    public var request: String?
    public var failure: String?

    public init() {}

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: FragKey.self)
        try c.encodeIfPresent(value, forKey: .value)
        if hasPending {
            if let p = pendingValue { try c.encode(p, forKey: .pending) }
            else { try c.encodeNil(forKey: .pending) }
        }
        try c.encodeIfPresent(writable, forKey: .writable)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(request, forKey: .request)
        try c.encodeIfPresent(failure, forKey: .failure)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FragKey.self)
        value = try c.decodeIfPresent(AnyCodable.self, forKey: .value)
        writable = try c.decodeIfPresent(Bool.self, forKey: .writable)
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        request = try c.decodeIfPresent(String.self, forKey: .request)
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        hasPending = c.contains(.pending)
        pendingValue = hasPending ? (try? c.decode(AnyCodable.self, forKey: .pending)) : nil
    }

    enum FragKey: String, CodingKey {
        case value, pending, writable, startedAt, request, failure
    }
}

// MARK: - Radio types

/// Radio status.
public struct RadioStatus: Codable, Sendable, Equatable {
    public var bars: Double
    public var haLow: [HaLowNodeEntry]?
}

public struct HaLowNodeEntry: Codable, Sendable, Equatable {
    public var name: String
    public var signalDBm: Int?
    public var state: String
}

// MARK: - WireResultEntry

/// One entry in a result message.
public struct WireResultEntry: Codable, Sendable {
    public var camera: String
    public var status: String
    public var field: String?
    public var value: AnyCodable?
    public var error: String?
}

// MARK: - WireMessage (server → client)

public enum WireMessage: Codable, Sendable {
    /// `locked`: the app's controls are locked (the padlock), in `hello` and `snapshot`; a change is `lock`.
    case hello(requestID: String?, api: Int, app: String, appVersion: String,
               cameras: [APICameraFull], pages: [APIPageEntry], currentPageID: String?,
               radio: RadioStatus?, locked: Bool?)
    case snapshot(cameras: [APICameraFull], pages: [APIPageEntry], currentPageID: String?,
                  radio: RadioStatus?, locked: Bool?)
    case lock(locked: Bool)
    case changes(camera: String, cameraID: String, update: CameraChangesUpdate,
                 removed: [String]?)
    case cameras(cameras: [APICameraFull])
    case pages(pages: [APIPageEntry], currentPageID: String?)
    case radio(radio: RadioStatus)
    case result(requestID: String?, results: [WireResultEntry])
    case error(requestID: String?, code: String, message: String)
    case pong(requestID: String?)

    enum CodingKeys: String, CodingKey {
        case type, id, api, app, appVersion, cameras, pages, currentPageID, radio, locked
        case camera, cameraID, update, removed
        case results, code, message
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hello(rid, api, app, ver, cams, pgs, cpID, radio, locked):
            try c.encode("hello", forKey: .type)
            try c.encodeIfPresent(rid, forKey: .id)
            try c.encode(api, forKey: .api)
            try c.encode(app, forKey: .app)
            try c.encode(ver, forKey: .appVersion)
            try c.encode(cams, forKey: .cameras)
            try c.encode(pgs, forKey: .pages)
            try c.encodeIfPresent(cpID, forKey: .currentPageID)
            try c.encodeIfPresent(radio, forKey: .radio)
            try c.encodeIfPresent(locked, forKey: .locked)
        case let .snapshot(cams, pgs, cpID, radio, locked):
            try c.encode("snapshot", forKey: .type)
            try c.encode(cams, forKey: .cameras)
            try c.encode(pgs, forKey: .pages)
            try c.encodeIfPresent(cpID, forKey: .currentPageID)
            try c.encodeIfPresent(radio, forKey: .radio)
            try c.encodeIfPresent(locked, forKey: .locked)
        case let .lock(locked):
            try c.encode("lock", forKey: .type)
            try c.encode(locked, forKey: .locked)
        case let .changes(cam, camID, update, removed):
            try c.encode("changes", forKey: .type)
            try c.encode(cam, forKey: .camera)
            try c.encode(camID, forKey: .cameraID)
            try c.encode(update, forKey: .update)
            try c.encodeIfPresent(removed, forKey: .removed)
        case let .cameras(cams):
            try c.encode("cameras", forKey: .type)
            try c.encode(cams, forKey: .cameras)
        case let .pages(pgs, cpID):
            try c.encode("pages", forKey: .type)
            try c.encode(pgs, forKey: .pages)
            try c.encodeIfPresent(cpID, forKey: .currentPageID)
        case let .radio(radio):
            try c.encode("radio", forKey: .type)
            try c.encode(radio, forKey: .radio)
        case let .result(rid, results):
            try c.encode("result", forKey: .type)
            try c.encodeIfPresent(rid, forKey: .id)
            try c.encode(results, forKey: .results)
        case let .error(rid, code, msg):
            try c.encode("error", forKey: .type)
            try c.encodeIfPresent(rid, forKey: .id)
            try c.encode(code, forKey: .code)
            try c.encode(msg, forKey: .message)
        case let .pong(rid):
            try c.encode("pong", forKey: .type)
            try c.encodeIfPresent(rid, forKey: .id)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = try c.decode(String.self, forKey: .type)
        switch t {
        case "hello":
            self = .hello(requestID: try c.decodeIfPresent(String.self, forKey: .id),
                          api: try c.decode(Int.self, forKey: .api),
                          app: try c.decode(String.self, forKey: .app),
                          appVersion: try c.decode(String.self, forKey: .appVersion),
                          cameras: try c.decode([APICameraFull].self, forKey: .cameras),
                          pages: try c.decode([APIPageEntry].self, forKey: .pages),
                          currentPageID: try c.decodeIfPresent(String.self, forKey: .currentPageID),
                          radio: try c.decodeIfPresent(RadioStatus.self, forKey: .radio),
                          locked: try c.decodeIfPresent(Bool.self, forKey: .locked))
        case "snapshot":
            self = .snapshot(cameras: try c.decode([APICameraFull].self, forKey: .cameras),
                             pages: try c.decode([APIPageEntry].self, forKey: .pages),
                             currentPageID: try c.decodeIfPresent(String.self, forKey: .currentPageID),
                             radio: try c.decodeIfPresent(RadioStatus.self, forKey: .radio),
                             locked: try c.decodeIfPresent(Bool.self, forKey: .locked))
        case "lock":
            self = .lock(locked: try c.decode(Bool.self, forKey: .locked))
        case "result":
            self = .result(requestID: try c.decodeIfPresent(String.self, forKey: .id),
                           results: try c.decode([WireResultEntry].self, forKey: .results))
        case "pong":
            self = .pong(requestID: try c.decodeIfPresent(String.self, forKey: .id))
        default:
            self = .error(requestID: try c.decodeIfPresent(String.self, forKey: .id),
                          code: (try? c.decode(String.self, forKey: .code)) ?? t,
                          message: (try? c.decode(String.self, forKey: .message)) ?? t)
        }
    }
}

// MARK: - Wire message (client → server)

/// The outer envelope for any client message.
struct WireClientEnvelope: Codable, Sendable {
    var type: String
    var id: String?
    var token: String?
    // command fields
    var target: WireTarget?
    var link: WireLink?
    var command: WireCommandOp?
    // app fields
    var action: String?
    var pageID: String?
    var enabled: Bool?
    var group: String?
    // wait (HTTP only)
    var wait: Bool?

    enum CodingKeys: String, CodingKey {
        case type, id, token, target, link, command, action, pageID, enabled, group, wait
    }
}

// MARK: - WireTarget

/// Target specification for a command.
enum WireTarget: Codable, Sendable, Equatable {
    case cameraID(String)
    case camera(String)
    case pageID(String)
    case currentPage
    case all

    enum CodingKeys: String, CodingKey { case cameraID, camera, pageID, currentPage, all }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cameraID(let id): try c.encode(id, forKey: .cameraID)
        case .camera(let label): try c.encode(label, forKey: .camera)
        case .pageID(let id): try c.encode(id, forKey: .pageID)
        case .currentPage: try c.encode(true, forKey: .currentPage)
        case .all: try c.encode(true, forKey: .all)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(String.self, forKey: .cameraID) { self = .cameraID(id); return }
        if let label = try c.decodeIfPresent(String.self, forKey: .camera) { self = .camera(label); return }
        if let id = try c.decodeIfPresent(String.self, forKey: .pageID) { self = .pageID(id); return }
        if (try? c.decodeIfPresent(Bool.self, forKey: .currentPage)) == true { self = .currentPage; return }
        if (try? c.decodeIfPresent(Bool.self, forKey: .all)) == true { self = .all; return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                               debugDescription: "unrecognised target"))
    }
}

// MARK: - WireCommandOp

/// The command operation (set/step/toggle/cycle).
enum WireCommandOp: Codable, Sendable {
    case set(String, FieldValue)
    case step(String, Double)
    case toggle(String)
    case cycle(String)
    /// A transport command by name (`PlaybackCommand(apiName:by:)`), with `by` seconds for `skip`.
    case playback(String, Double?)
    /// A lens motor ("focus", "zoom") at a signed speed for a time: `{"drive": "focus", "speed": -2, "seconds": 0.5}`.
    /// The time is capped at a second and the server stops the motor at its end: there is no drive without a stop.
    case drive(String, Int, Double)
    /// One of the camera's buttons by number, `{"press": "assignable", "button": 1}`, or push autofocus,
    /// `{"press": "autofocus"}`, which has no number.
    case press(String, Int?)

    enum CodingKeys: String, CodingKey { case set, step, toggle, cycle, playback, by, value, drive, speed, seconds, press, button }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .set(let field, let val):
            try c.encode(field, forKey: .set)
            try c.encode(val.jsonValue, forKey: .value)
        case .step(let field, let by):
            try c.encode(field, forKey: .step)
            try c.encode(by, forKey: .by)
        case .toggle(let field): try c.encode(field, forKey: .toggle)
        case .cycle(let field): try c.encode(field, forKey: .cycle)
        case .playback(let name, let by):
            try c.encode(name, forKey: .playback)
            try c.encodeIfPresent(by, forKey: .by)
        case .drive(let motor, let speed, let seconds):
            try c.encode(motor, forKey: .drive)
            try c.encode(speed, forKey: .speed)
            try c.encode(seconds, forKey: .seconds)
        case .press(let what, let button):
            try c.encode(what, forKey: .press)
            try c.encodeIfPresent(button, forKey: .button)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let field = try c.decodeIfPresent(String.self, forKey: .set) {
            let val = try c.decode(AnyCodable.self, forKey: .value)
            let fv = FieldValue.from(val)
            self = .set(field, fv ?? .string(""))
            return
        }
        if let field = try c.decodeIfPresent(String.self, forKey: .step) {
            let by = (try? c.decode(Double.self, forKey: .by)) ?? 1.0
            self = .step(field, by)
            return
        }
        if let field = try c.decodeIfPresent(String.self, forKey: .toggle) {
            self = .toggle(field); return
        }
        if let field = try c.decodeIfPresent(String.self, forKey: .cycle) {
            self = .cycle(field); return
        }
        if let name = try c.decodeIfPresent(String.self, forKey: .playback) {
            self = .playback(name, try? c.decode(Double.self, forKey: .by)); return
        }
        if let motor = try c.decodeIfPresent(String.self, forKey: .drive) {
            self = .drive(motor, try c.decode(Int.self, forKey: .speed), (try? c.decode(Double.self, forKey: .seconds)) ?? 0.5)
            return
        }
        if let what = try c.decodeIfPresent(String.self, forKey: .press) {
            self = .press(what, try c.decodeIfPresent(Int.self, forKey: .button)); return
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                               debugDescription: "unrecognised command op"))
    }
}

// MARK: - WireLink

/// `"link": "app"` follows the app's link settings; `"link": false` is this camera only (contract: Client → server).
/// Decoded from either, so a client sending `false` isn't rejected as malformed.
struct WireLink: Codable, Sendable, Equatable {
    var followsApp: Bool

    init(followsApp: Bool) { self.followsApp = followsApp }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let flag = try? c.decode(Bool.self) {
            followsApp = flag
        } else {
            followsApp = try c.decode(String.self) == "app"
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if followsApp { try c.encode("app") } else { try c.encode(false) }
    }
}

// MARK: - WireCommandRequest / WireAppRequest

/// Full command request (used for both WS and HTTP).
struct WireCommandRequest: Codable, Sendable {
    var id: String?
    var token: String?
    var target: WireTarget?
    var link: WireLink?
    var command: WireCommandOp
    var wait: Bool?

    enum CodingKeys: String, CodingKey { case id, token, target, link, command, wait }
}

/// App action request.
struct WireAppRequest: Codable, Sendable {
    var id: String?
    var action: String
    var pageID: String?
    var enabled: Bool?
    var group: String?
    var token: String?
}

// MARK: - ConnectionState / RecordingState API strings

extension ConnectionState {
    var apiString: String {
        switch self {
        case .connected: "connected"
        case .connecting: "connecting"
        case .disconnected: "disconnected"
        case .stale: "stale"
        case .failed: "failed"
        case .awaitingApproval: "awaitingApproval"
        case .fingerprintChanged: "fingerprintChanged"
        }
    }
}

extension RecordingState {
    var apiString: String {
        switch self {
        case .idle: "idle"
        case .recording: "recording"
        case .unknown: "unknown"
        }
    }
}
