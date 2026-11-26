// FakeBlackmagicCamera — in-process HTTP + WebSocket server for BlackmagicRESTBackend tests.
// Mirrors FakePTPIPCamera pattern: uses Network.framework NWListener.
//
// Answers the way a PYXIS 12K on Camera 10.1 does: the shutter angle ×100,
// a format that changes only as a whole, 501 for ND and /system/codecFormat, a working set padded with nulls,
// /transports/0/play as a bare boolean. Its WebSocket refuses a subscribe request naming any property it hasn't got,
// answers the rest with their values (all but /camera/power), and pushes only what was subscribed.

import Foundation
import Network
import CameraKitTestSupport
import Testing
import CameraCore
@testable import BlackmagicRESTBackend

// MARK: - Fake camera

public final class FakeBlackmagicCamera: @unchecked Sendable {

    public struct Size: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public init(_ width: Int, _ height: Int) { self.width = width; self.height = height }
        var json: [String: Any] { ["width": width, "height": height] }
    }

    /// One of the recording areas /system/supportedFormats lists.
    public struct FormatEntry: Sendable {
        var description: String
        var group: String
        var aspectRatio: String
        var record: Size
        var sensor: Size
        var frameRates: [String]
        var offSpeed: ClosedRange<Double>
        var codecs: [String]
    }

    static let codecs12K = ["BRaw:Q0", "BRaw:Q1", "BRaw:Q3", "BRaw:Q5", "BRaw:3_1", "BRaw:8_1", "BRaw:12_1", "BRaw:18_1"]
    static let codecs4K = ["BRaw:Q0", "BRaw:Q1", "BRaw:Q3", "BRaw:Q5", "BRaw:3_1", "BRaw:4_1", "BRaw:5_1", "BRaw:6_1"]

    /// Three of the PYXIS 12K's twenty, as it lists them.
    public static let supportedFormats: [FormatEntry] = [
        FormatEntry(description: "12K 17:9", group: "12K", aspectRatio: "17:9", record: Size(12288, 6480),
                    sensor: Size(12288, 6480), frameRates: ["23.98", "24", "25", "29.97", "30", "50"],
                    offSpeed: 12...50, codecs: codecs12K),
        FormatEntry(description: "9K 16:9", group: "9K", aspectRatio: "16:9", record: Size(8688, 4896),
                    sensor: Size(8688, 4896), frameRates: ["23.98", "24", "25", "29.97", "30", "50", "59.94", "60"],
                    offSpeed: 12...65, codecs: codecs12K),
        FormatEntry(description: "4K 16:9", group: "4K", aspectRatio: "16:9", record: Size(4096, 2304),
                    sensor: Size(12288, 6912), frameRates: ["23.98", "24", "25", "29.97", "30", "50", "59.94", "60"],
                    offSpeed: 12...84, codecs: codecs4K),
    ]

    /// An audio input as /audio/channel/{i}/input/description describes it.
    public struct AudioInputSpec: Sendable {
        public var gainRange: ClosedRange<Double>
        public var phantomPower = false
        public var lowCutFilter = false
        public var padAvailable = false
        public var padForced = false
        /// Answers a pad PUT and keeps the pad as it was, as a PYXIS 12K's XLR mic input does.
        public var padKept = false
        public init(gainRange: ClosedRange<Double>, phantomPower: Bool = false, lowCutFilter: Bool = false,
                    padAvailable: Bool = false, padForced: Bool = false, padKept: Bool = false) {
            self.gainRange = gainRange
            self.phantomPower = phantomPower
            self.lowCutFilter = lowCutFilter
            self.padAvailable = padAvailable
            self.padForced = padForced
            self.padKept = padKept
        }
    }

    /// One audio channel (AudioControl): its input, the inputs it can take (in the order it lists them), and its settings.
    public struct AudioChannelState: Sendable {
        public var input: String
        public var inputs: [(name: String, spec: AudioInputSpec)]
        public var gain: Double
        public var phantomPower = false
        public var padding = false
        public var lowCutFilter = false
        public var available = true
        public init(input: String, inputs: [(name: String, spec: AudioInputSpec)], gain: Double) {
            self.input = input
            self.inputs = inputs
            self.gain = gain
        }
        var spec: AudioInputSpec? { inputs.first { $0.name == input }?.spec }
    }

    /// Two channels as the API's documentation names its inputs: an XLR mic input with everything, a line one without.
    public static let twoAudioChannels: [AudioChannelState] = {
        let mic = AudioInputSpec(gainRange: -12...60, phantomPower: true, lowCutFilter: true, padAvailable: true)
        let line = AudioInputSpec(gainRange: -12...12, lowCutFilter: true, padForced: true)
        let camera = AudioInputSpec(gainRange: 0...40, lowCutFilter: true)
        var first = AudioChannelState(input: "XLR1 - Mic",
                                      inputs: [("XLR1 - Mic", mic), ("XLR1 - Line", line), ("Camera - Left", camera)], gain: 30)
        first.phantomPower = true
        let second = AudioChannelState(input: "Camera - Right",
                                       inputs: [("Camera - Right", camera), ("XLR2 - Mic", mic), ("XLR2 - Line", line)],
                                       gain: 20)
        return [first, second]
    }()

    public struct Config {
        public var recording: Bool = false
        public var iso: Int = 800
        /// ×100, as the API carries it: 18000 is 180°.
        public var shutterAngle: Int = 18000
        public var shutterSpeed: Int = 48
        public var shutterMeasurement: String = "ShutterAngle"
        public var kelvin: Int = 5600
        public var tint: Int = 0
        // The format, which only changes as a whole.
        public var codec: String = "BRaw:8_1"
        public var frameRate: String = "24"
        public var offSpeedEnabled: Bool = false
        public var offSpeedFrameRate: Double = 45
        public var recordResolution = Size(8688, 4896)
        public var sensorResolution = Size(8688, 4896)
        public var batteryPercent: Int = 85
        /// Powered through the 2-pin DC input (a power plate, or the mains adapter): no battery data, only the
        /// input's voltage, as a PYXIS reports it.
        public var onDCInput = false
        public var mediaRemainingSecs: Int = 3600
        public var irisStop: Double = 2.8
        /// An electronic lens. A manual one reports "controllable": false and stops of 0.
        public var irisControllable: Bool = true
        /// Auto exposure drives the aperture: a set is refused (403), as the API documents.
        public var irisAuto: Bool = false
        /// Display names served by /monitoring/display
        public var displayNames: [String] = ["LCD", "HDMI"]
        /// displayLUT enabled state per display (keyed by name)
        public var displayLUTEnabled: [String: Bool] = ["LCD": false, "HDMI": false]
        /// falseColor enabled state per display (keyed by name)
        public var falseColorEnabled: [String: Bool] = ["LCD": false, "HDMI": false]
        /// colorBars enabled state
        public var colorBarsEnabled: Bool = false
        /// /camera/tallyStatus: None, Preview or Program.
        public var tallyStatus: String = "None"
        /// /lens/focus/description's `controllable`: an electronic lens the camera can focus. Off, doAutoFocus is a 403.
        public var focusControllable: Bool = true
        /// What POST /transports/0/doStillCapture answers: 204, 404 (no still capture) or 500 (failed, with a reason).
        public var stillCaptureStatus: Int = 204
        /// The audio channels (AudioControl); nil, a camera without the API's audio, whose paths answer 404.
        public var audioChannels: [AudioChannelState]? = nil
        /// Properties whose subscribe request gets no answer at all, not even a refusal.
        public var silentSubscriptions: Set<String> = []
        /// zebra, focusAssist, frameGuide, frameGrids, safeArea and cleanFeed per display, keyed "LCD/zebra".
        public var overlays: [String: Bool] = [:]
        /// Highlight zebra level in percent (75–100).
        public var zebraLevel: Int = 95
        public var frameGuideRatio: String = "2.39:1"
        public var frameGuidePresets: [String] = ["2.40:1", "2.39:1", "2.35:1", "1.85:1", "16:9", "14:9", "1.66:1", "4:3",
                                                  "1:1", "4:5", "9:16", "2:1"]
        public var dynamicRange: String = "Film"
        public var supportedDynamicRanges: [String] = ["Film", "Extended Video", "Video"]
        /// If true: recording state never changes after record command (timeout test)
        public var neverConfirmRec: Bool = false
        // Playback state
        public var playbackMode: String = "InputPreview"  // "InputPreview" or "Output"
        public var playbackSpeed: Double = 0
        public var playbackPosition: Int = 0
        public var clipIndex: Int = 0
        public var clipCount: Int = 5
        /// Where the camera goes by itself just after the first seek into playback, over it: the position it last
        /// played. Once per entry; models a camera that moves back to where it last was instead of holding the seek.
        public var resumesAt: Int? = nil
        /// Clips on the card after the playback list's, which the camera's own list leaves out (taken in another format
        /// than the clips it was built from, as a PYXIS's list did).
        public var clipsOffTimeline: Int = 0
        /// Time of day timecode runs; otherwise it stands at 15:00:00:00 (record run, not recording).
        public var timecodeRunning: Bool = false
        /// Properties the WebSocket refuses to subscribe to, as well as those this camera hasn't got.
        public var refusedSubscriptions: Set<String> = []
        /// A WebSocket that upgrades and then says nothing.
        public var silentWebSocket: Bool = false
        /// Pings go unanswered: a link that stalled with the connection still open.
        public var ignoresPings: Bool = false
        /// The slate for the next clip: its name is the camera letter and reel, the date and time, and the clip number.
        public var slateCamera: String = "A"
        public var slateReel: Int = 1
        /// The livestream, which live view goes through: off, the camera answers as one without it.
        public var livestream: Bool = false
        /// The camera's own streaming platform, and its stream's status, before anything changes them.
        public var activePlatform: [String: String] = ["platform": "YouTube RTMP", "server": "Primary", "quality": "Streaming High"]
        public var streamStatus: String = "Idle"
        /// Custom platform files already on the camera: file name → XML.
        public var customPlatforms: [String: String] = [:]
        /// Remote Control's access API (`/access`), as Camera 10.3.1 has it: one device at a time holds a session, kept
        /// with heartbeats, which streams to a platform file of its own and may stop the stream. Off: 404, as a camera
        /// without it.
        public var remoteAccess = false
        /// How long a session outlives its last heartbeat (a PYXIS: about 8 s).
        public var sessionLapse: TimeInterval = 8
        /// Another device holding the camera's remote control, by name: a request is denied.
        public var sessionHolder: String?
        /// What only a preset carries (`BlackmagicPreset.swift`), by output: status text on, and what it shows (SDI's 3
        /// cinematographer, 4 director; the others' 1 meters, 2 codec and resolution). And the de-squeeze step (0 none).
        /// Presets work only with a PYXIS's four outputs, which its preset lists.
        public var statusText: [String: Bool] = ["LCD": true, "FrontUSBC": true, "RearUSBC": true, "MainSDI": false]
        public var statusTextContent: [String: UInt64] = ["LCD": 1, "FrontUSBC": 1, "RearUSBC": 1, "MainSDI": 3]
        public var desqueeze: Int = 0
        /// Preset files on the camera, by file name.
        public var presets: [String: Data] = [:]
        public var productName = "PYXIS 12K"
        /// Built-in ND, as an URSA Cine 12K LF has (clear, 2, 4 and 6 stops: Blackmagic's tech specs). Nil: none, as
        /// the PYXIS, which answers 501 and refuses the subscription.
        public var ndStops: [Double]? = nil
        public var ndStop: Double = 0
        /// The API is 10.1's either way; presets were taken apart on 10.3.1.
        public var softwareVersion = "10.3.1"
        /// Software whose presets keep the de-squeeze somewhere else (field 93): laid out unlike 10.3.1's.
        public var presetDesqueezeMoved = false
        /// Someone turns on SDI's zebra on the camera as an upload arrives, pushed a moment before the answer.
        public var monitoringChangesOnUpload = false
        /// The next this many saves are written part-way, up to the end of their fifth section: a read the camera
        /// hadn't finished writing.
        public var partWrittenSaves = 0
        /// Answer an upload without naming the preset it became.
        public var unnamedUploads = false
        /// The LUT in use, and the LUTs on the camera: a preset naming another is ignored, as a PYXIS ignores one.
        public var lut = "Blackmagic Gen 5 Film to Extended Video.cube"
        public var lutsOnCamera = ["Blackmagic Gen 5 Film to Extended Video.cube", "Blackmagic Gen 5 Film Look.cube",
                                   "Blackmagic Gen 5 Film to Video.cube"]
        /// A network access login ("user:password"), as a PYXIS with one set: anything without it gets 401, the
        /// WebSocket's opening request included. nil: none.
        public var login: String?
        /// A take starts as an upload arrives (someone pressed REC on the camera), pushed a moment before the answer.
        public var takeStartsOnUpload = false
        public var activePreset = ".cset"
        public init() {}
    }

    public private(set) var config: Config

    public private(set) var port: UInt16 = 0
    public private(set) var recordCommandsReceived = 0
    public private(set) var stopCommandsReceived = 0
    public private(set) var displayLUTPutCount = 0
    /// Every status PUT to /camera/tallyStatus.
    public private(set) var tallyPuts: [String] = []
    /// Every body PUT to /lens/focus/doAutoFocus.
    @Locked public private(set) var autoFocusPuts: [[String: Any]] = []
    /// POSTs to /transports/0/doStillCapture.
    @Locked public private(set) var stillCaptures = 0
    /// Every PUT under /audio, as "0/level".
    public private(set) var audioPuts: [String] = []
    /// The audio channels as the camera has them now.
    public var audio: [AudioChannelState]? { queue.sync { config.audioChannels } }
    /// Someone changes a channel's input on the camera itself.
    public func changeAudioInputOnCamera(_ channel: Int, to input: String) {
        queue.sync {
            config.audioChannels?[channel].input = input
            pushPropertyChanged("/audio/channel/\(channel)/input", value: ["input": input])
        }
    }
    /// The camera's tally changes on its own (a switcher's tally over SDI, say).
    public func setTallyOnCamera(_ status: String) {
        queue.sync {
            config.tallyStatus = status
            pushPropertyChanged("/camera/tallyStatus", value: ["status": status])
        }
    }
    public private(set) var falseColorPutCount = 0
    /// Every PUT to one of `overlayLeaves`, as "LCD/zebra".
    public private(set) var overlayPuts: [String] = []
    /// Every PUT /system/format body, accepted or not.
    public private(set) var formatPuts: [[String: Any]] = []
    // Playback tracking
    public private(set) var playCommandsReceived = 0
    public private(set) var playbackStopCommandsReceived = 0
    public private(set) var playbackPutCount = 0
    private var resumePending = false
    public private(set) var lastPlaybackPut: [String: Any]? = nil
    public private(set) var lastTransportModePut: String? = nil
    /// Every transport mode put, in order.
    public private(set) var transportModePuts: [String] = []
    /// Livestream: starts accepted, and every platform the camera was set to.
    public private(set) var streamStarts = 0
    public private(set) var platformPuts: [[String: String]] = []
    public var activePlatform: [String: String] { queue.sync { config.activePlatform } }
    /// The config as the camera has it now, read on its queue: for a test polling it while requests change it (an
    /// unguarded read mid-change can crash the run, as the PTP-IP fake's once did).
    public var configNow: Config { queue.sync { config } }
    public var streamStatus: String { queue.sync { config.streamStatus } }
    public var customPlatformFiles: [String] { queue.sync { config.customPlatforms.keys.sorted() } }
    /// A custom platform file as put.
    public func customPlatform(_ file: String) -> String? { queue.sync { config.customPlatforms[file] } }
    /// When each custom platform file was put: the camera takes a moment to load one.
    private var platformLoadedAt: [String: Date] = [:]
    /// Remote Control: the session's token, device and platform file, when it last heard a heartbeat, and the session
    /// the running stream was started in.
    private var sessionToken: String?
    private var sessionFile: String?
    private var sessionDevice: [String: String] = [:]
    private var sessionHeardAt = Date.distantPast
    private var streamSession: String?
    public private(set) var accessRequests = 0
    public private(set) var sessionDisconnects = 0
    /// Stops the camera took (only ever inside a session), and the times a stream went to the camera's own platform,
    /// which a real camera broadcasts on: a start with neither Tiles' platform picked nor a session's file loaded, or a
    /// session's stream when the session lapsed.
    public private(set) var streamStops = 0
    public private(set) var ownPlatformStreams = 0
    public var sessionActive: Bool { queue.sync { lapseSessionIfDue(); return sessionToken != nil } }
    /// The address the request being answered came from.
    private var requester: String?
    /// Requests that carried a login (an Authorization header), whether or not the camera has one.
    public private(set) var loginsSeen = 0
    /// Presets loaded (PUT /presets/active), and requests to /presets of any kind.
    public private(set) var presetLoads = 0
    /// The sections of the last preset uploaded; and loads that had an empty section, which reset part of a real
    /// camera's state.
    public private(set) var lastUploadSections: [String] = []
    public private(set) var emptySectionLoads = 0
    public private(set) var presetRequests = 0
    /// When a preset was last loaded: the camera then takes a moment to save its state as a preset.
    private var presetLoadedAt = Date.distantPast
    /// The file name of the request being answered, from its Content-Disposition (a preset upload).
    private var uploadFilename: String?
    /// REST requests answered, and bytes on the wire both ways (REST and WebSocket, headers and frames included).
    public var restRequests: Int { lock.withLock { requestCount } }
    public var traffic: (up: Int, down: Int) { lock.withLock { (bytesUp, bytesDown) } }
    private var requestCount = 0
    private var bytesUp = 0
    private var bytesDown = 0

    private var listener: NWListener?
    private let lock = NSLock()
    private var wsConnections: [NWConnection] = []
    /// What each WebSocket client subscribed to.
    private var subscriptions: [ObjectIdentifier: Set<String>] = [:]
    private let timecodeStart = Date()
    private let queue = DispatchQueue(label: "fake-bm-camera", qos: .userInteractive)

    /// For tests that push events: a push goes only to a client subscribed to it, and the backend reports connected
    /// before its WebSocket has subscribed.
    func subscribed(to property: String, within seconds: Double = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if lock.withLock({ subscriptions.values.contains { $0.contains(property) } }) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        return false
    }

    public init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - Start / Stop

    public func start() async throws {
        // On 127.0.0.1 (LoopbackListener), again if the system says the address is in use.
        try await LoopbackListener.retrying { [self] in
            listener?.cancel()
            try await startListening()
        }
    }

    private func startListening() async throws {
        let params = NWParameters.tcp
        let l = try LoopbackListener.make(params)
        self.listener = l

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let p = l.port?.rawValue { self?.port = p }
                    if !resumed { resumed = true; cont.resume() }
                case .failed(let e), .waiting(let e):
                    // Left waiting (a port it can't have), it would never be ready: fail, not hang.
                    if !resumed { resumed = true; cont.resume(throwing: e) }
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        let connections = lock.withLock {
            defer { wsConnections = []; subscriptions = [:] }
            return wsConnections
        }
        for c in connections { c.cancel() }
    }

    // MARK: - Helpers for tests

    /// Drops every WebSocket client, as a link that went away would.
    public func dropWebSockets() {
        let connections = lock.withLock {
            defer { wsConnections = []; subscriptions = [:] }
            return wsConnections
        }
        for c in connections { c.cancel() }
    }

    public func setRecording(_ value: Bool) {
        config.recording = value
        pushPropertyChanged("/transports/0/record", value: ["recording": value])
    }

    /// A take added to the card and to the playback list: `/clips` and `/timelines/0` have one more, and the list is
    /// pushed as the camera pushes it.
    public func addTake() {
        queue.sync { config.clipCount += 1 }
        pushPropertyChanged("/timelines/0", value: ["clips": (0..<config.clipCount).map { i -> [String: Any] in
            ["clipUniqueId": i + 1, "frameCount": 240, "timelineIn": i * 240]
        }])
    }

    // MARK: - Connection acceptance

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveHTTPRequest(from: conn)
    }

    // MARK: - HTTP request parsing

    /// Reads to the end of the request's headers, which can take more than one read and come with the start of the
    /// body: on a busy machine a preset's upload (binary) arrived in the same read as its headers, the whole read was
    /// taken as text, and the fake dropped the connection ("The network connection was lost", the PresetTests flake).
    private func receiveHTTPRequest(from conn: NWConnection, buffered: Data = Data()) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else { conn.cancel(); return }
            self.count(up: data.count)
            let received = buffered + data
            guard received.range(of: Self.headersEnd) != nil else {
                guard received.count < 65536 else { conn.cancel(); return }
                self.receiveHTTPRequest(from: conn, buffered: received)
                return
            }
            self.parseHTTPHeaders(data: received, conn: conn)
        }
    }

    private static let headersEnd = Data([0x0D, 0x0A, 0x0D, 0x0A])  // \r\n\r\n

    private func count(up: Int = 0, down: Int = 0, request: Bool = false) {
        lock.withLock {
            bytesUp += up
            bytesDown += down
            if request { requestCount += 1 }
        }
    }

    private func parseHTTPHeaders(data: Data, conn: NWConnection) {
        // The headers alone as text: what follows them can be a binary body.
        guard let sepRange = data.range(of: Self.headersEnd),
              let raw = String(data: data[data.startIndex ..< sepRange.upperBound], encoding: .utf8) else { conn.cancel(); return }
        if case .hostPort(let host, _) = conn.endpoint { requester = "\(host)".split(separator: "%").first.map(String.init) }

        // A login, if the camera has one: Basic, as a PYXIS asks for it.
        let authorization = raw.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("authorization:") }
            .map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) }
        if authorization != nil { loginsSeen += 1 }
        if let login = config.login, authorization != "Basic " + Data(login.utf8).base64EncodedString() {
            let body = "<title>401 Unauthorized</title><h1>401 Unauthorized</h1>"
            let response = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"'PYXIS 12K'\", charset=\"UTF-8\"\r\n"
                + "Content-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            count(down: response.utf8.count, request: true)
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            return
        }

        // WebSocket upgrade
        if raw.contains("Upgrade: websocket") || raw.contains("upgrade: websocket") {
            handleWebSocketUpgrade(rawRequest: raw, conn: conn)
            return
        }

        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { conn.cancel(); return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = parts[0]
        let path = parts[1]

        // Extract Content-Length, and a file's name
        var contentLength = 0
        var filename: String?
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("content-length:") {
                let val = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                contentLength = Int(val) ?? 0
            }
            if line.lowercased().hasPrefix("content-disposition:"), let range = line.range(of: "filename=\"") {
                filename = String(line[range.upperBound...].prefix { $0 != "\"" })
            }
        }

        let headerEnd = sepRange.upperBound  // byte index after \r\n\r\n
        let existingBodyData: Data
        if headerEnd < data.endIndex {
            existingBodyData = Data(data[headerEnd...])
        } else {
            existingBodyData = Data()
        }

        let remaining = contentLength - existingBodyData.count
        if remaining > 0 {
            // Read rest of body
            conn.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { [weak self, filename] bodyExtra, _, _, _ in
                guard let self else { return }
                var full = existingBodyData
                if let bodyExtra { full.append(bodyExtra); self.count(up: bodyExtra.count) }
                self.uploadFilename = filename
                let response = self.routeRequest(method: method, path: self.normalizePath(path), bodyData: full)
                self.sendHTTPResponse(response, conn: conn)
            }
        } else {
            uploadFilename = filename
            let response = routeRequest(method: method, path: normalizePath(path), bodyData: existingBodyData)
            sendHTTPResponse(response, conn: conn)
        }
    }

    private func normalizePath(_ path: String) -> String {
        // Strip /control/api/v1 prefix and query string
        var p = path
        if let q = p.firstIndex(of: "?") { p = String(p[..<q]) }
        let prefix = "/control/api/v1"
        if p.hasPrefix(prefix) { p = String(p.dropFirst(prefix.count)) }
        if p.isEmpty { p = "/" }
        return p
    }

    // MARK: - Format

    private var currentEntry: FormatEntry? {
        Self.supportedFormats.first { $0.record == config.recordResolution && $0.sensor == config.sensorResolution }
    }

    private var formatJSON: [String: Any] {
        var f: [String: Any] = [
            "codec": config.codec, "frameRate": config.frameRate,
            "offSpeedEnabled": config.offSpeedEnabled, "offSpeedFrameRate": config.offSpeedFrameRate,
            "recordResolution": config.recordResolution.json, "sensorResolution": config.sensorResolution.json,
        ]
        if let entry = currentEntry {
            f["minOffSpeedFrameRate"] = entry.offSpeed.lowerBound
            f["maxOffSpeedFrameRate"] = entry.offSpeed.upperBound
            f["resolutionDescriptor"] = ["description": entry.description, "group": entry.group,
                                         "aspectRatio": entry.aspectRatio]
        }
        return f
    }

    /// The camera takes a whole, valid format or nothing ("Invalid format").
    private func putFormat(_ body: [String: Any]) -> HTTPResponse {
        formatPuts.append(body)
        func size(_ key: String) -> Size? {
            guard let d = body[key] as? [String: Any], let w = d["width"] as? Int, let h = d["height"] as? Int else { return nil }
            return Size(w, h)
        }
        guard let codec = body["codec"] as? String, let frameRate = body["frameRate"] as? String,
              let offSpeedEnabled = body["offSpeedEnabled"] as? Bool,
              let offSpeedFrameRate = body["offSpeedFrameRate"] as? Double,
              let record = size("recordResolution"), let sensor = size("sensorResolution"),
              let entry = Self.supportedFormats.first(where: { $0.record == record && $0.sensor == sensor }),
              entry.codecs.contains(codec), entry.frameRates.contains(frameRate),
              entry.offSpeed.contains(offSpeedFrameRate)
        else { return HTTPResponse(status: 400, body: "{\"error\": \"Invalid format\"}") }
        config.codec = codec
        config.frameRate = frameRate
        config.offSpeedEnabled = offSpeedEnabled
        config.offSpeedFrameRate = offSpeedFrameRate
        config.recordResolution = record
        config.sensorResolution = sensor
        pushPropertyChanged("/system/format", value: formatJSON)
        return noContent()
    }

    // MARK: - Shutter

    private var shutterJSON: [String: Any] {
        config.shutterMeasurement == "ShutterAngle"
            ? ["continuousShutterAutoExposure": false, "shutterAngle": config.shutterAngle]
            : ["continuousShutterAutoExposure": false, "shutterSpeed": config.shutterSpeed]
    }

    private var projectFPS: Double { Double(config.frameRate) ?? 24 }

    // MARK: - Slate

    /// The next clip's slate names it only "Next Clip", as the PYXIS does.
    private var slateJSON: [String: Any] {
        ["clip": ["clipName": "Next Clip", "reel": config.slateReel, "scene": "1", "take": 1, "shotType": "None",
                         "takeType": "None", "sceneLocation": "Interior", "sceneTime": "Day", "slateFor": "Next Clip"],
                "lens": ["lensType": "", "iris": "", "focalLength": "", "distance": "", "filter": ""],
                "project": ["projectName": "", "director": "", "camera": config.slateCamera, "cameraOperator": ""]]
    }

    /// Partial updates; a field it won't take is a 409 naming it. The reel isn't one it takes at all (the PYXIS keeps it
    /// with the card).
    private func putSlate(_ body: [String: Any]) -> HTTPResponse {
        func refuse(_ field: String, _ message: String) -> HTTPResponse {
            HTTPResponse(status: 409, body: """
                {"error": "Partial set applied, see details for fields that failed to update.", \
                "details": [{"field": "\(field)", "message": "\(message)"}]}
                """)
        }
        if (body["clip"] as? [String: Any])?["reel"] != nil { return refuse("reel", "Reel number is not editable.") }
        if let camera = (body["project"] as? [String: Any])?["camera"] as? String {
            guard camera.count == 1, camera.first?.isUppercase == true else {
                return refuse("camera", "Field 'camera' was not in a valid format.")
            }
            config.slateCamera = camera
        }
        pushPropertyChanged("/slates/nextClip", value: slateJSON)
        return value(slateJSON)
    }

    // MARK: - Monitoring

    /// The per-display overlays besides LUT and false color.
    static let overlayLeaves: Set<String> = ["zebra", "focusAssist", "frameGuide", "frameGrids", "safeArea", "cleanFeed"]

    private var zebraJSON: [String: Any] {
        ["highlight": ["enabled": true, "level": config.zebraLevel], "skinTone": ["enabled": false, "type": "None"]]
    }

    // MARK: - Timecode

    private var timecodeDisplay: String {
        let rate = Int(projectFPS.rounded())
        let start = 15 * 3600 * rate
        let frames = start + (config.timecodeRunning ? Int(Date().timeIntervalSince(timecodeStart) * projectFPS) : 0)
        let seconds = frames / rate
        return String(format: "%02d:%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60, frames % rate)
    }

    // MARK: - Route requests

    private func routeRequest(method: String, path: String, bodyData: Data) -> HTTPResponse {
        let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
        lapseSessionIfDue()
        if path == "/presets" || path.hasPrefix("/presets/") { return routePresets(method: method, path: path, bodyData: bodyData) }
        if path.hasPrefix("/audio/") { return routeAudio(method: method, path: path, body: body) }
        if config.remoteAccess, path.hasPrefix("/access/") { return routeAccess(method: method, path: path, body: body) }
        switch (method, path) {

        case ("GET", "/system/product"):
            return json(["productName": config.productName, "deviceName": config.productName,
                         "softwareVersion": config.softwareVersion])

        case ("GET", "/system/format"):
            return json(formatJSON)

        case ("PUT", "/system/format"):
            return putFormat(body ?? [:])

        case ("GET", "/system/supportedFormats"):
            return json(["supportedFormats": Self.supportedFormats.map { e -> [String: Any] in
                ["codecs": e.codecs, "frameRates": e.frameRates,
                 "minOffSpeedFrameRate": e.offSpeed.lowerBound, "maxOffSpeedFrameRate": e.offSpeed.upperBound,
                 "recordResolution": e.record.json, "sensorResolution": e.sensor.json,
                 "resolutionDescriptor": ["description": e.description, "group": e.group, "aspectRatio": e.aspectRatio]]
            }])

        case (_, "/system/codecFormat"), (_, "/system/supportedCodecFormats"):
            return HTTPResponse(status: 501, body: "{\"error\": \"Not implemented for this device\"}")

        case ("GET", "/video/ndFilter") where config.ndStops != nil:
            return json(["stop": config.ndStop])

        case ("GET", "/video/supportedNDFilters") where config.ndStops != nil:
            return json(["supportedStops": config.ndStops ?? []])  // the key the REST API document gives

        case ("PUT", "/video/ndFilter") where config.ndStops != nil:
            guard let stop = (body?["stop"] as? NSNumber)?.doubleValue, config.ndStops?.contains(stop) == true else {
                return HTTPResponse(status: 400, body: "{\"error\": \"Invalid ND filter stop\"}")
            }
            config.ndStop = stop
            pushPropertyChanged("/video/ndFilter", value: ["stop": stop])
            return noContent()

        case (_, "/video/ndFilter"), (_, "/video/supportedNDFilters"):
            return HTTPResponse(status: 501, body: "{\"error\": \"ND Filter is not supported on this device\"}")

        case ("GET", "/video/iso"):
            return json(["iso": config.iso])

        case ("PUT", "/video/iso"):
            if let iso = body?["iso"] as? Int {
                config.iso = iso
                pushPropertyChanged("/video/iso", value: ["iso": iso])
            }
            return noContent()

        case ("GET", "/video/supportedISOs"):
            return json(["supportedISOs": [125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200]])

        case ("GET", "/video/shutter"):
            return json(shutterJSON)

        case ("PUT", "/video/shutter"):
            // Speed wins when both are given (VideoControl.yaml).
            if let speed = body?["shutterSpeed"] as? Int, config.shutterMeasurement == "ShutterSpeed" {
                config.shutterSpeed = speed
            } else if let angle = body?["shutterAngle"] as? Int, config.shutterMeasurement == "ShutterAngle" {
                config.shutterAngle = angle
            } else {
                return HTTPResponse(status: 400, body: "{\"error\": \"Invalid shutter\"}")
            }
            pushPropertyChanged("/video/shutter", value: shutterJSON)
            return noContent()

        case ("GET", "/video/shutter/measurement"):
            return json(["measurement": config.shutterMeasurement])

        case ("PUT", "/video/shutter/measurement"):
            guard let mode = body?["measurement"] as? String, ["ShutterAngle", "ShutterSpeed"].contains(mode) else {
                return HTTPResponse(status: 400, body: "{\"error\": \"Invalid shutter measurement\"}")
            }
            if mode != config.shutterMeasurement {
                // The exposure carries over: 180° at 24 fps is 1/48, and 1/50 back is 172.8°.
                if mode == "ShutterSpeed" {
                    config.shutterSpeed = Int((projectFPS * 36000 / Double(config.shutterAngle)).rounded())
                } else {
                    config.shutterAngle = Int((projectFPS * 36000 / Double(config.shutterSpeed)).rounded())
                }
                config.shutterMeasurement = mode
                // The camera pushes the new value first, then the measurement.
                pushPropertyChanged("/video/shutter", value: shutterJSON)
                pushPropertyChanged("/video/shutter/measurement", value: ["measurement": mode])
            }
            return noContent()

        case ("GET", "/video/supportedShutters"):
            return json(["shutterAngles": [1125, 1500, 2250, 3000, 3750, 4500, 6000, 7200, 7500, 9000, 10800, 12000,
                                           14400, 15000, 17280, 18000, 21600, 27000, 32400, 36000],
                         "shutterSpeeds": [24, 25, 30, 50, 60, 100, 125, 200, 250, 500, 1000, 2000]])

        case ("GET", "/video/whiteBalance"):
            return json(["whiteBalance": config.kelvin])

        case ("PUT", "/video/whiteBalance"):
            if let k = body?["whiteBalance"] as? Int {
                config.kelvin = k
                pushPropertyChanged("/video/whiteBalance", value: ["whiteBalance": k])
            }
            return noContent()

        case ("PUT", "/video/whiteBalance/doAuto"):
            // The camera measures the middle of the picture and pushes the white balance and tint it set.
            config.kelvin = 4950
            config.tint = 3
            pushPropertyChanged("/video/whiteBalance", value: ["whiteBalance": 4950])
            pushPropertyChanged("/video/whiteBalanceTint", value: ["whiteBalanceTint": 3])
            return noContent()

        case ("GET", "/video/whiteBalance/description"):
            return json(["whiteBalance": ["min": 2500, "max": 10000]])

        case ("GET", "/video/whiteBalanceTint"):
            return json(["whiteBalanceTint": config.tint])

        case ("PUT", "/video/whiteBalanceTint"):
            if let t = body?["whiteBalanceTint"] as? Int {
                config.tint = t
                pushPropertyChanged("/video/whiteBalanceTint", value: ["whiteBalanceTint": t])
            }
            return noContent()

        case ("GET", "/video/whiteBalanceTint/description"):
            return json(["whiteBalanceTint": ["min": -50, "max": 50]])

        case ("GET", "/video/autoExposure"):
            return json(["mode": "Off", "type": ""])

        case ("GET", "/lens/iris"):
            return json(irisJSON)

        case ("PUT", "/lens/iris"):
            guard config.irisControllable, !config.irisAuto else {
                return HTTPResponse(status: 403, body: "{\"error\": \"Lens iris is not controllable\"}")
            }
            if let f = body?["apertureStop"] as? Double {
                config.irisStop = f
                pushPropertyChanged("/lens/iris", value: irisJSON)
            }
            return noContent()

        case ("GET", "/lens/iris/description"):
            return json(irisDescriptionJSON)

        case ("GET", "/lens/focus"):
            return json(["normalised": 0.0])

        case ("GET", "/lens/focus/description"):
            return json(["controllable": config.focusControllable,
                         "focusDistance": ["adjustable": config.focusControllable, "min": 0.0, "max": 10000.0]])

        case ("POST", "/transports/0/doStillCapture"):
            stillCaptures += 1
            switch config.stillCaptureStatus {
            case 204: return noContent()
            case 500: return HTTPResponse(status: 500, body: "{\"error\": \"No media to save the still to\"}")
            default: return HTTPResponse(status: config.stillCaptureStatus, body: "{\"error\": \"Not found\"}")
            }

        case ("PUT", "/lens/focus/doAutoFocus"):
            autoFocusPuts.append(body ?? [:])
            guard config.focusControllable else {
                return HTTPResponse(status: 403, body: "{\"error\": \"Lens focus is not controllable\"}")
            }
            return noContent()

        case ("GET", "/media/workingset"):
            return json(["size": 3, "workingset": [
                ["activeDisk": true, "clipCount": config.clipCount, "deviceName": "nvme1", "index": 0,
                 "remainingRecordTime": config.mediaRemainingSecs, "remainingSpace": 613189943296,
                 "totalSpace": 2048403963904, "volume": "A001"] as [String: Any],
                NSNull(), NSNull(),
            ] as [Any]])

        case ("GET", "/camera/power"):
            if config.onDCInput { return json(["batteries": [] as [Any], "milliVolt": 17900, "source": "AC"]) }
            return json(["batteries": [["chargeRemainingPercent": config.batteryPercent, "milliVolt": 13600,
                                        "statusFlags": ["Battery Is Present", "Battery Is Connected"]] as [String: Any]],
                         "milliVolt": 13600, "source": "AC"])

        // Playback transport
        case ("GET", "/transports/0"):
            return json(["mode": config.playbackMode])

        case ("PUT", "/transports/0"):
            // The switch lands a moment later (most of a second on the PYXIS), and is pushed when it does.
            if let mode = body?["mode"] as? String {
                lastTransportModePut = mode
                transportModePuts.append(mode)
                queue.asyncAfter(deadline: .now() + 0.3) { self.landTransportMode(mode) }
            }
            return noContent()

        case ("GET", "/transports/0/play"):
            return value(config.playbackMode == "Output" && config.playbackSpeed != 0)

        case ("POST", "/transports/0/play"):
            playCommandsReceived += 1
            guard config.playbackMode == "Output" else { return HTTPResponse(status: 400, body: "{\"error\": \"Invalid state\"}") }
            config.playbackSpeed = 1.0
            queue.asyncAfter(deadline: .now() + 0.05) {
                self.pushPropertyChanged("/transports/0/play", value: true)
            }
            return noContent()

        case ("POST", "/transports/0/stop"):
            // Stops whatever the transport is doing: a take, or playback.
            if config.recording {
                stopCommandsReceived += 1
                if !config.neverConfirmRec {
                    config.recording = false
                    queue.asyncAfter(deadline: .now() + 0.05) {
                        self.pushPropertyChanged("/transports/0/record", value: ["recording": false])
                    }
                }
                return noContent()
            }
            playbackStopCommandsReceived += 1
            config.playbackSpeed = 0
            queue.asyncAfter(deadline: .now() + 0.05) {
                self.pushPropertyChanged("/transports/0/play", value: false)
            }
            return noContent()

        case ("GET", "/transports/0/playback"):
            return json(["type": "Play", "loop": false, "singleClip": false,
                         "speed": config.playbackSpeed, "position": config.playbackPosition])

        case ("PUT", "/transports/0/playback"):
            // Any of the fields alone: a position by itself seeks and leaves the speed.
            playbackPutCount += 1
            guard config.playbackMode == "Output" else { return HTTPResponse(status: 400, body: "{\"error\": \"Invalid state\"}") }
            lastPlaybackPut = body
            if let pos = body?["position"] as? Int { config.playbackPosition = pos }
            if resumePending, let resume = config.resumesAt {
                resumePending = false
                queue.asyncAfter(deadline: .now() + 0.1) { self.config.playbackPosition = resume }
            }
            if let spd = body?["speed"] as? Double { config.playbackSpeed = spd }
            return noContent()

        case ("GET", "/transports/0/clipIndex"):
            return json(["clipIndex": config.clipIndex])

        case ("GET", "/clips"):
            // Every clip on the card: the playback list's, then any it left out.
            return json(["clips": (0..<(config.clipCount + config.clipsOffTimeline)).map { i -> [String: Any] in
                ["clipUniqueId": i + 1, "filePath": String(format: "A001_C%03d.braw", i + 1), "frameCount": 240]
            }])

        case ("GET", "/timelines/0"):
            // clipCount clips of 240 frames (10 s at 24 fps)
            return json(["clips": (0..<config.clipCount).map { i -> [String: Any] in
                ["clipUniqueId": i + 1, "frameCount": 240, "timelineIn": i * 240]
            }])

        case ("GET", "/transports/0/record"):
            return json(["recording": config.recording])

        case ("POST", "/transports/0/record"):
            recordCommandsReceived += 1
            if !config.neverConfirmRec {
                config.recording = true
                queue.asyncAfter(deadline: .now() + 0.05) {
                    self.pushPropertyChanged("/transports/0/record", value: ["recording": true])
                }
            }
            return noContent()

        case ("GET", "/transports/0/timecode"):
            return json(["display": timecodeDisplay, "timeline": "00:00:00:00"])

        case ("GET", "/system/dynamicRange"):
            return json(["dynamicRange": config.dynamicRange])

        case ("PUT", "/system/dynamicRange"):
            guard let range = body?["dynamicRange"] as? String, config.supportedDynamicRanges.contains(range) else {
                return HTTPResponse(status: 400, body: "{\"error\": \"Invalid dynamic range\"}")
            }
            // The PYXIS takes the subscription but never pushes this.
            config.dynamicRange = range
            return noContent()

        case ("GET", "/system/supportedDynamicRanges"):
            return json(["supportedDynamicRanges": config.supportedDynamicRanges])

        case ("GET", "/monitoring/zebra"):
            return json(zebraJSON)

        case ("PUT", "/monitoring/zebra"):
            if let level = (body?["highlight"] as? [String: Any])?["level"] as? Int {
                guard [75, 80, 85, 90, 95, 100].contains(level) else {
                    return HTTPResponse(status: 400, body: "{\"error\": \"Invalid zebra level\"}")
                }
                config.zebraLevel = level
            }
            pushPropertyChanged("/monitoring/zebra", value: zebraJSON)
            return noContent()

        case ("GET", "/monitoring/frameGuideRatio"):
            return json(["ratio": config.frameGuideRatio])

        case ("PUT", "/monitoring/frameGuideRatio"):
            guard let ratio = body?["ratio"] as? String, config.frameGuidePresets.contains(ratio) else {
                return HTTPResponse(status: 400, body: "{\"error\": \"Invalid ratio\"}")
            }
            config.frameGuideRatio = ratio
            pushPropertyChanged("/monitoring/frameGuideRatio", value: ["ratio": ratio])
            return noContent()

        case ("GET", "/monitoring/frameGuideRatio/presets"):
            return json(["presets": config.frameGuidePresets])

        case ("GET", "/slates/nextClip"):
            return json(slateJSON)

        case ("PUT", "/slates/nextClip"):
            return putSlate(body ?? [:])

        case ("GET", "/monitoring/display"):
            return json(["displays": config.displayNames])

        case ("GET", "/camera/colorBars"):
            return json(["enabled": config.colorBarsEnabled])

        case ("GET", "/camera/tallyStatus"):
            return json(["status": config.tallyStatus])

        case ("PUT", "/camera/tallyStatus"):
            guard let status = body?["status"] as? String, ["None", "Preview", "Program"].contains(status) else {
                return HTTPResponse(status: 400, body: "{\"error\": \"Invalid tally status\"}")
            }
            tallyPuts.append(status)
            config.tallyStatus = status
            pushPropertyChanged("/camera/tallyStatus", value: ["status": status])
            return noContent()

        case ("PUT", "/camera/colorBars"):
            if let enabled = body?["enabled"] as? Bool {
                config.colorBarsEnabled = enabled
                pushPropertyChanged("/camera/colorBars", value: ["enabled": enabled])
            }
            return noContent()

        case ("GET", "/livestreams/0") where config.livestream:
            return json(["status": config.streamStatus, "bitrate": 0, "cache": 0.0, "effectiveVideoFormat": "1920x1080p24"])

        case ("GET", "/livestreams/0/available") where config.livestream:
            return json(["available": true])

        case ("GET", "/livestreams/0/activePlatform") where config.livestream:
            return json(config.activePlatform)

        case ("PUT", "/livestreams/0/activePlatform") where config.livestream:
            // As the PYXIS: refused while a stream runs, and a platform it hasn't (yet) loaded is an "Invalid server".
            guard config.streamStatus == "Idle" else { return Self.streamControlRefused }
            guard let platform = body?["platform"] as? String, platformServers(platform) != nil else {
                return HTTPResponse(status: 400, body: "{\"error\": \"Invalid server\"}")
            }
            let next = (body ?? [:]).compactMapValues { $0 as? String }
            platformPuts.append(next)
            config.activePlatform = next
            pushPropertyChanged("/livestreams/0/activePlatform", value: next)
            return noContent()

        case ("PUT", "/livestreams/0/start") where config.livestream:
            guard config.playbackMode != "Output" else { return Self.streamControlRefused }
            streamStarts += 1
            if let token = sessionToken, let file = sessionFile, config.customPlatforms[file] != nil,
               (platformLoadedAt[file] ?? .distantPast) <= Date() {
                streamSession = token
            } else {
                // Not to a session's platform: to the camera's active one, Tiles' (put there) or the camera's own.
                streamSession = nil
                if config.activePlatform["platform"] != "Tiles" { ownPlatformStreams += 1 }
            }
            landStreamStatus("Streaming")
            return noContent()

        case ("PUT", "/livestreams/0/stop") where config.livestream:
            // Refused for every stream, unless asked from inside a session whose platform file streams to the device
            // holding it: then whichever stream is going stops, whoever started it (Camera 10.3.1).
            guard config.remoteAccess, sessionToken != nil, let file = sessionFile, let xml = config.customPlatforms[file],
                  let url = Self.element("url", in: xml), URL(string: url)?.host == requester
            else { return Self.streamControlRefused }
            streamStops += 1
            streamSession = nil
            if config.streamStatus != "Idle" { landStreamStatus("Idle") }
            return noContent()

        case (_, let livestream) where config.livestream && livestream.hasPrefix("/livestreams/"):
            return routeLivestream(method: method, path: livestream, bodyData: bodyData)

        default:
            // Per-display monitoring: /monitoring/{displayName}/displayLUT and /monitoring/{displayName}/falseColor
            // Path component is percent-decoded for matching.
            if let (displayName, feature) = parseMonitoringPath(path), config.displayNames.contains(displayName) {
                let encoded = displayName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? displayName
                switch (method, feature) {
                case ("GET", "displayLUT"):
                    return json(["enabled": config.displayLUTEnabled[displayName] ?? false])
                case ("PUT", "displayLUT"):
                    displayLUTPutCount += 1
                    if let enabled = body?["enabled"] as? Bool {
                        config.displayLUTEnabled[displayName] = enabled
                        pushPropertyChanged("/monitoring/\(encoded)/displayLUT", value: ["enabled": enabled])
                    }
                    return noContent()
                case ("GET", "falseColor"):
                    return json(["enabled": config.falseColorEnabled[displayName] ?? false])
                case ("PUT", "falseColor"):
                    falseColorPutCount += 1
                    if let enabled = body?["enabled"] as? Bool {
                        config.falseColorEnabled[displayName] = enabled
                        pushPropertyChanged("/monitoring/\(encoded)/falseColor", value: ["enabled": enabled])
                    }
                    return noContent()
                case ("GET", let overlay) where Self.overlayLeaves.contains(overlay):
                    return json(["enabled": config.overlays["\(displayName)/\(overlay)"] ?? false])
                case ("PUT", let overlay) where Self.overlayLeaves.contains(overlay):
                    overlayPuts.append("\(displayName)/\(overlay)")
                    if let enabled = body?["enabled"] as? Bool {
                        config.overlays["\(displayName)/\(overlay)"] = enabled
                        pushPropertyChanged("/monitoring/\(encoded)/\(overlay)", value: ["enabled": enabled])
                    }
                    return noContent()
                default:
                    break
                }
            }
            return HTTPResponse(status: 404, body: "{\"error\": \"not found\"}")
        }
    }

    // MARK: - Presets

    /// The camera's state as a preset: a PYXIS 12K's (Camera 10.3.1) with this camera's overlays, status text and
    /// de-squeeze.
    private func presetOfState() -> Data? {
        guard let fixture = Self.presetFixture else { return nil }
        // Each output's entry as this camera has it (LUT 1, frame guides 2, false color 4, zebra 5, status text 8,
        // clean feed 9, what status text shows 14), in one pass: saves come one after another while a change lands.
        let values: [[Int: UInt64]] = config.displayNames.filter { $0 != "Stream" }.map { name in
            func on(_ value: Bool?) -> UInt64 { value == true ? 1 : 0 }
            return [1: on(config.displayLUTEnabled[name]), 2: on(config.overlays["\(name)/frameGuide"]),
                    4: on(config.falseColorEnabled[name]), 5: on(config.overlays["\(name)/zebra"]),
                    8: on(config.statusText[name] ?? true), 9: on(config.overlays["\(name)/cleanFeed"]),
                    14: config.statusTextContent[name] ?? 1]
        }
        guard let outputs = Self.settingOutputs(values, of: fixture), var file = try? PresetFile(outputs) else { return nil }
        try? file.setDesqueeze(PresetSettings.desqueezeFactors[config.desqueeze])
        try? file.setLUT(config.lut)
        if config.presetDesqueezeMoved { return Self.renumbering(PresetSettings.desqueezeField, to: 93, inSection: "transport", of: file.data) }
        return file.data
    }

    private static let presetFixture = Bundle.module.url(forResource: "pyxis-10.3.1", withExtension: "cset")
        .flatMap { try? Data(contentsOf: $0) }

    /// `data` with each output's entry in `metering` given `values` (field → number), the rest as it was; nil unless
    /// there's an entry for each.
    static func settingOutputs(_ values: [[Int: UInt64]], of data: Data) -> Data? {
        guard var top = Proto.parse(data) else { return nil }
        for (i, entry) in top.enumerated() where entry.number == 10 {
            guard var parts = Proto.parse(entry.bytes),
                  parts.first(where: { $0.number == 1 }).map({ String(decoding: $0.bytes, as: UTF8.self) }) == "metering",
                  let slot = parts.firstIndex(where: { $0.number == 2 }), var settings = Proto.parse(parts[slot].bytes) else { continue }
            let entries = settings.indices.filter { settings[$0].number == PresetSettings.outputs }
            guard entries.count == values.count else { return nil }
            for (index, wanted) in zip(entries, values) {
                guard var fields = Proto.parse(settings[index].bytes) else { return nil }
                for j in fields.indices where fields[j].wire == 0 {
                    if let value = wanted[fields[j].number] { fields[j].varint = value }
                }
                settings[index].bytes = Proto.serialize(fields)
            }
            parts[slot].bytes = Proto.serialize(settings)
            top[i].bytes = Proto.serialize(parts)
            return Proto.serialize(top)
        }
        return nil
    }

    /// `data` with one field of a section given another number: a preset laid out unlike the fixture's. Nil when the
    /// section hasn't got the field, so a test can't pass on an unchanged preset.
    static func renumbering(_ field: Int, to number: Int, inSection name: String, of data: Data) -> Data? {
        guard var top = Proto.parse(data) else { return nil }
        var renumbered = false
        for (i, entry) in top.enumerated() where entry.number == 10 {
            guard var parts = Proto.parse(entry.bytes),
                  parts.first(where: { $0.number == 1 }).map({ String(decoding: $0.bytes, as: UTF8.self) }) == name,
                  let slot = parts.firstIndex(where: { $0.number == 2 }), var settings = Proto.parse(parts[slot].bytes) else { continue }
            for j in settings.indices where settings[j].number == field {
                settings[j].number = number
                renumbered = true
            }
            parts[slot].bytes = Proto.serialize(settings)
            top[i].bytes = Proto.serialize(parts)
        }
        return renumbered ? Proto.serialize(top) : nil
    }

    /// Loads a preset's status text, what it shows and the de-squeeze, as the camera loads all of it.
    /// As a PYXIS loads one: the sections it has (one without all its transport settings is ignored, as the camera
    /// ignored the de-squeeze alone), the others left alone.
    private func load(_ data: Data) {
        guard let file = try? PresetFile(data) else { return }
        if (Proto.parse(data) ?? []).contains(where: { field in
            field.number == 10 && Proto.parse(field.bytes)?.first(where: { $0.number == 2 })?.bytes.isEmpty != false
        }) {
            emptySectionLoads += 1
        }
        let outputs = config.displayNames.filter { $0 != "Stream" }
        // A LUT the camera hasn't got: its monitoring isn't loaded at all.
        let lut = file.string("metering", [Proto.Step(field: PresetSettings.lutField)])
        let meteringLoads = lut.map { config.lutsOnCamera.contains($0) } ?? true
        if meteringLoads, let lut { config.lut = lut }
        for (index, name) in outputs.enumerated() where meteringLoads {
            let path = [Proto.Step(field: PresetSettings.outputs, index: index)]
            if let on = file.value("metering", path + [Proto.Step(field: PresetSettings.statusTextField)]) { config.statusText[name] = on == 1 }
            if let code = file.value("metering", path + [Proto.Step(field: PresetSettings.contentField)]) { config.statusTextContent[name] = code }
        }
        let transportFields = [30, 31, 40, 60, 80, 90, 92]
        if transportFields.allSatisfy({ file.value("transport", [Proto.Step(field: $0)]) != nil }),
           let step = file.value("transport", [Proto.Step(field: PresetSettings.desqueezeField)]) {
            config.desqueeze = Int(step)
        }
    }

    /// /presets: save the state as one, send, take, load and delete them. Like the camera, a save just after a load is
    /// written a moment after the answer, and a preset loads a moment after it's asked for.
    private func routePresets(method: String, path: String, bodyData: Data) -> HTTPResponse {
        presetRequests += 1
        let name = path.hasPrefix("/presets/") ? String(path.dropFirst("/presets/".count)).removingPercentEncoding ?? "" : ""
        let missing = HTTPResponse(status: 404, body: "{\"error\": \"Preset file \\\"\(name)\\\" not found\"}")
        switch (method, name) {
        case ("GET", ""):
            return json(["presets": config.presets.keys.sorted()])
        case ("POST", ""):
            guard let file = uploadFilename, file.hasSuffix(".cset") else { return HTTPResponse(status: 400, body: "{}") }
            let base = String(file.dropLast(5))
            var added = base
            var n = 0
            while config.presets["\(added).cset"] != nil { n += 1; added = "\(base)\(n)" }
            config.presets["\(added).cset"] = bodyData
            lastUploadSections = (try? PresetFile(bodyData))?.sectionNames ?? []
            if config.monitoringChangesOnUpload {
                config.overlays["MainSDI/zebra"] = true
                pushPropertyChanged("/monitoring/MainSDI/zebra", value: ["enabled": true])
                Thread.sleep(forTimeInterval: 0.2)
            }
            if config.takeStartsOnUpload {
                config.recording = true
                pushPropertyChanged("/transports/0/record", value: ["recording": true])
                Thread.sleep(forTimeInterval: 0.2)
            }
            return config.unnamedUploads ? json([:]) : json(["presetAdded": added])
        case ("GET", "active"):
            return json(["preset": config.activePreset])
        case ("PUT", "active"):
            guard let preset = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any])?["preset"] as? String,
                  let data = config.presets[preset] else { return missing }
            presetLoads += 1
            presetLoadedAt = Date()
            config.activePreset = preset
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.load(data) }
            return noContent()
        case ("PUT", _):
            guard var data = presetOfState() else { return HTTPResponse(status: 500, body: "{}") }
            if config.partWrittenSaves > 0, var fields = Proto.parse(data) {
                config.partWrittenSaves -= 1
                let sixth = fields.indices.filter { fields[$0].number == 10 }.dropFirst(5).first ?? fields.endIndex
                fields.removeSubrange(sixth...)
                data = Proto.serialize(fields)
            }
            if Date().timeIntervalSince(presetLoadedAt) < 0.5 {
                queue.asyncAfter(deadline: .now() + 0.15) { [weak self, data] in self?.config.presets[name] = data }
            } else {
                config.presets[name] = data
            }
            return noContent()
        case ("GET", _):
            return config.presets[name].map { HTTPResponse(status: 200, body: "", data: $0) } ?? missing
        case ("DELETE", _):
            return config.presets.removeValue(forKey: name) != nil ? noContent() : missing
        default:
            return HTTPResponse(status: 405, body: "{}")
        }
    }

    // MARK: - Lens

    private var irisJSON: [String: Any] {
        ["apertureNumber": 2, "apertureStop": config.irisControllable ? config.irisStop : 0.0,
         "continuousApertureAutoExposure": config.irisAuto, "normalised": 0.5]
    }

    private var irisDescriptionJSON: [String: Any] {
        config.irisControllable ? ["apertureStop": ["min": 2.8, "max": 22.0], "controllable": true]
                                : ["apertureStop": ["min": 0.0, "max": 0.0], "controllable": false]
    }

    /// An electronic lens fitted while connected, at `stop`: its aperture is pushed before its description, as the
    /// order isn't promised.
    public func fitLens(stop: Double) {
        queue.sync {
            config.irisControllable = true
            config.irisStop = stop
            pushPropertyChanged("/lens/iris", value: irisJSON)
            pushPropertyChanged("/lens/iris/description", value: irisDescriptionJSON)
        }
    }

    /// Auto exposure takes the aperture over, or gives it back.
    public func setIrisAuto(_ auto: Bool) {
        queue.sync {
            config.irisAuto = auto
            pushPropertyChanged("/lens/iris", value: irisJSON)
        }
    }

    // MARK: - Livestream

    private static let streamControlRefused = HTTPResponse(
        status: 403, body: "{\"error\": \"Stream control cannot be performed: stream is active to a different destination\"}")

    /// Remote Control's sessions: asked for, kept with heartbeats, ended by a disconnect or by going without a heartbeat.
    private func routeAccess(method: String, path: String, body: [String: Any]?) -> HTTPResponse {
        let availability = "control-and-monitor"
        switch (method, path) {
        case ("GET", "/access/status"):
            if let holder = config.sessionHolder {
                return json(["availability": availability, "status": "active",
                             "currentDevice": ["deviceName": holder, "deviceModel": "iPhone"]])
            }
            guard sessionToken != nil else { return json(["availability": availability, "status": "inactive"]) }
            return json(["availability": availability, "status": "active", "currentDevice": sessionDevice])
        case ("POST", "/access/request"):
            accessRequests += 1
            guard config.sessionHolder == nil, sessionToken == nil else {
                return json(["availability": availability, "status": "denied"])
            }
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            sessionToken = token
            sessionFile = body?["streamingXML"] as? String
            sessionDevice = ["deviceName": body?["deviceName"] as? String ?? "", "deviceModel": body?["deviceModel"] as? String ?? ""]
            sessionHeardAt = Date()
            return json(["availability": availability, "status": "accepted", "token": token])
        case ("POST", "/access/heartbeat"):
            guard let token = sessionToken, body?["token"] as? String == token else {
                return json(["availability": availability, "status": "inactive"])
            }
            sessionHeardAt = Date()
            return json(["availability": availability, "status": "accepted"])
        case ("POST", "/access/disconnect"):
            guard let token = sessionToken, body?["token"] as? String == token else {
                return json(["availability": availability, "status": "inactive"])
            }
            sessionDisconnects += 1
            endSession(stopStream: true)
            return json(["availability": availability, "status": "disconnected"])
        default:
            return HTTPResponse(status: 404, body: "{\"error\": \"not found\"}")
        }
    }

    // On the queue.
    private func lapseSessionIfDue() {
        guard sessionToken != nil, Date().timeIntervalSince(sessionHeardAt) > config.sessionLapse else { return }
        endSession(stopStream: false)
    }

    /// A session ends: its platform file goes. A disconnect also stops a stream started in it; after a lapse that stream
    /// carries on to the camera's own platform, the file it went to being gone.
    private func endSession(stopStream: Bool) {
        if let token = sessionToken, streamSession == token, config.streamStatus != "Idle" {
            streamSession = nil
            if stopStream { landStreamStatus("Idle") } else { ownPlatformStreams += 1 }
        }
        sessionToken = nil
        if let file = sessionFile {
            config.customPlatforms.removeValue(forKey: file)
            platformLoadedAt[file] = nil
        }
        sessionFile = nil
        sessionDevice = [:]
    }

    /// Platforms by name (`GET /livestreams/platforms/{name}`) and custom platform files.
    private func routeLivestream(method: String, path: String, bodyData: Data) -> HTTPResponse {
        let platformsPrefix = "/livestreams/platforms/", filesPrefix = "/livestreams/customPlatforms/"
        if method == "GET", path == "/livestreams/platforms" {
            // The built-in platforms, then each custom file's once it's loaded.
            let custom = config.customPlatforms.keys.sorted().compactMap { file -> String? in
                guard (platformLoadedAt[file] ?? .distantPast) <= Date(), let xml = config.customPlatforms[file] else { return nil }
                return Self.element("name", in: xml)
            }
            return value(["YouTube RTMP", "Twitch", "Facebook"] + custom)
        }
        if method == "GET", path.hasPrefix(platformsPrefix) {
            let name = String(path.dropFirst(platformsPrefix.count)).removingPercentEncoding ?? ""
            guard let servers = platformServers(name) else { return HTTPResponse(status: 400, body: "{\"error\": \"Invalid platform\"}") }
            return json(["platform": name, "servers": servers])
        }
        guard path.hasPrefix(filesPrefix) else { return HTTPResponse(status: 404, body: "{\"error\": \"not found\"}") }
        let file = String(path.dropFirst(filesPrefix.count))
        switch method {
        case "GET":
            guard let xml = config.customPlatforms[file] else { return HTTPResponse(status: 404, body: "") }
            return HTTPResponse(status: 200, body: xml)
        case "PUT":
            config.customPlatforms[file] = String(decoding: bodyData, as: UTF8.self)
            platformLoadedAt[file] = Date().addingTimeInterval(0.3)
            return noContent()
        case "DELETE":
            guard let xml = config.customPlatforms.removeValue(forKey: file) else { return HTTPResponse(status: 404, body: "") }
            // The active platform gone, the camera falls back to its first, and a stream running carries on there.
            if Self.element("name", in: xml) == config.activePlatform["platform"] {
                config.activePlatform = ["platform": "YouTube RTMP", "server": "Primary", "quality": "Streaming High"]
                pushPropertyChanged("/livestreams/0/activePlatform", value: config.activePlatform)
            }
            return noContent()
        default:
            return HTTPResponse(status: 404, body: "")
        }
    }

    /// A platform's servers as the camera lists them: built in, or a loaded custom file's.
    private func platformServers(_ name: String) -> [[String: String]]? {
        if ["YouTube RTMP", "Twitch", "Facebook"].contains(name) { return [["server": "Primary"]] }
        for (file, xml) in config.customPlatforms where Self.element("name", in: xml) == name {
            guard (platformLoadedAt[file] ?? .distantPast) <= Date() else { return nil }
            return [["server": Self.element("name", in: xml, after: "<server>") ?? name, "url": Self.element("url", in: xml) ?? ""]]
        }
        return nil
    }

    private static func element(_ tag: String, in xml: String, after marker: String? = nil) -> String? {
        var rest = Substring(xml)
        if let marker, let range = rest.range(of: marker) { rest = rest[range.upperBound...] }
        guard let open = rest.range(of: "<\(tag)>"), let close = rest.range(of: "</\(tag)>", range: open.upperBound ..< rest.endIndex)
        else { return nil }
        return String(rest[open.upperBound ..< close.lowerBound])
    }

    /// The camera switches between live and playback, from its touchscreen: playback stops a stream.
    public func setTransportMode(_ mode: String) { queue.sync { landTransportMode(mode) } }

    /// The stream's status changes on its own (a stream started from the camera, say).
    public func setStreamStatus(_ status: String) { queue.sync { landStreamStatus(status) } }
    /// The camera moves to another platform on its own, a running stream with it (as a Remote Control session's end
    /// does).
    public func setActivePlatform(_ platform: [String: String]) {
        queue.sync {
            config.activePlatform = platform
            pushPropertyChanged("/livestreams/0/activePlatform", value: platform)
        }
    }
    public func setPartWrittenSaves(_ count: Int) { queue.sync { config.partWrittenSaves = count } }
    /// Someone picks a LUT on the camera itself.
    public func useLUTOnCamera(_ name: String) { queue.sync { config.lut = name } }

    // On the queue.
    private func landTransportMode(_ mode: String) {
        config.playbackMode = mode
        pushPropertyChanged("/transports/0", value: ["mode": mode])
        if mode == "Output", config.resumesAt != nil { resumePending = true }
        if mode == "Output", config.livestream, config.streamStatus != "Idle" { landStreamStatus("Idle") }
    }

    private func landStreamStatus(_ status: String) {
        config.streamStatus = status
        pushPropertyChanged("/livestreams/0", value: ["status": status, "bitrate": 0, "cache": 0.0,
                                                      "effectiveVideoFormat": "1920x1080p24"])
    }

    // MARK: - Audio (AudioControl)

    /// /audio/channels and /audio/channel/{i}/…, in the API documentation's shapes.
    private func routeAudio(method: String, path: String, body: [String: Any]?) -> HTTPResponse {
        guard let channels = config.audioChannels else { return HTTPResponse(status: 404, body: "{\"error\": \"not found\"}") }
        if path == "/audio/channels", method == "GET" { return json(["channels": channels.count]) }
        let parts = path.split(separator: "/").map(String.init)  // audio, channel, i, leaf…
        guard parts.count >= 4, parts[1] == "channel", let i = Int(parts[2]), channels.indices.contains(i) else {
            return HTTPResponse(status: 404, body: "{\"error\": \"Channel does not exist\"}")
        }
        let leaf = parts.dropFirst(3).joined(separator: "/")
        let channel = channels[i]
        let spec = channel.spec
        func bad(_ why: String) -> HTTPResponse { HTTPResponse(status: 400, body: "{\"error\": \"\(why)\"}") }
        func set(_ change: (inout AudioChannelState) -> Void, push value: [String: Any]) -> HTTPResponse {
            change(&config.audioChannels![i])
            audioPuts.append("\(i)/\(leaf)")
            pushPropertyChanged(path, value: value)
            return noContent()
        }
        switch (method, leaf) {
        case ("GET", "input"): return json(["input": channel.input])
        case ("PUT", "input"):
            guard let input = body?["input"] as? String, channel.inputs.contains(where: { $0.name == input }) else {
                return bad("Invalid audio input")
            }
            return set({ c in
                c.input = input
                if let range = c.spec?.gainRange { c.gain = min(max(c.gain, range.lowerBound), range.upperBound) }
                if c.spec?.phantomPower != true { c.phantomPower = false }
                if c.spec?.padForced == true { c.padding = true }
            }, push: ["input": input])
        case ("GET", "supportedInputs"):
            return value(channel.inputs.map { ["input": $0.name, "available": true] as [String: Any] })
        case ("GET", "input/description"):
            guard let spec else { return HTTPResponse(status: 404, body: "{}") }
            return json(["description": [
                "gainRange": ["Min": spec.gainRange.lowerBound, "Max": spec.gainRange.upperBound],
                "capabilities": [["PhantomPower": spec.phantomPower], ["LowCutFilter": spec.lowCutFilter],
                                 ["Padding": ["available": spec.padAvailable, "forced": spec.padForced, "value": -20.0]]],
            ] as [String: Any]])
        case ("GET", "level"):
            let range = spec?.gainRange ?? 0...1
            return json(["gain": channel.gain,
                         "normalized": (channel.gain - range.lowerBound) / max(range.upperBound - range.lowerBound, 1)])
        case ("PUT", "level"):
            guard let gain = (body?["gain"] as? NSNumber)?.doubleValue, spec?.gainRange.contains(gain) == true else {
                return bad("Invalid input or value out of range")
            }
            return set({ $0.gain = gain }, push: ["gain": gain])
        case ("GET", "phantomPower"): return json(["enabled": channel.phantomPower])
        case ("PUT", "phantomPower"):
            guard spec?.phantomPower == true, let on = body?["enabled"] as? Bool else {
                return bad("Phantom power is not supported for this input")
            }
            return set({ $0.phantomPower = on }, push: ["enabled": on])
        case ("GET", "padding"): return json(["enabled": channel.padding])
        case ("PUT", "padding"):
            guard spec?.padAvailable == true, spec?.padForced != true, let on = body?["enabled"] as? Bool else {
                return bad("Padding is not supported or is forced for this input")
            }
            if spec?.padKept == true {
                audioPuts.append("\(i)/\(leaf)")
                return noContent()
            }
            return set({ $0.padding = on }, push: ["enabled": on])
        case ("GET", "lowCutFilter"): return json(["enabled": channel.lowCutFilter])
        case ("PUT", "lowCutFilter"):
            guard spec?.lowCutFilter == true, let on = body?["enabled"] as? Bool else {
                return bad("Low cut filter is not supported for this input")
            }
            return set({ $0.lowCutFilter = on }, push: ["enabled": on])
        case ("GET", "available"): return json(["available": channel.available])
        default: return HTTPResponse(status: 404, body: "{\"error\": \"not found\"}")
        }
    }

    // MARK: - WebSocket

    /// What the WebSocket can subscribe to. As on the PYXIS: not ND or /system/codecFormat (it hasn't got them), and
    /// not the Stream display's monitoring, though REST reads it.
    private var subscribable: Set<String> {
        var s: Set<String> = [
            "/transports/0/record", "/transports/0/timecode", "/video/iso", "/video/supportedISOs", "/video/shutter",
            "/video/shutter/measurement", "/video/supportedShutters", "/video/whiteBalance",
            "/video/whiteBalance/description", "/video/whiteBalanceTint", "/video/whiteBalanceTint/description",
            "/system/format", "/lens/iris", "/lens/iris/description", "/lens/focus", "/media/workingset",
            "/camera/power", "/camera/colorBars", "/camera/tallyStatus", "/video/autoExposure", "/transports/0",
            "/transports/0/play", "/lens/focus/description",
            "/transports/0/playback", "/transports/0/clipIndex", "/timelines/0", "/slates/nextClip",
            "/system/dynamicRange", "/system/supportedDynamicRanges", "/monitoring/zebra", "/monitoring/frameGuideRatio",
            "/monitoring/focusAssist", "/monitoring/frameGrids", "/monitoring/safeAreaPercent",
        ]
        if config.livestream { s.formUnion(["/livestreams/0", "/livestreams/0/available", "/livestreams/0/activePlatform"]) }
        for channel in (config.audioChannels ?? []).indices {
            for leaf in ["input", "level", "phantomPower", "padding", "lowCutFilter", "available"] {
                s.insert("/audio/channel/\(channel)/\(leaf)")
            }
        }
        if config.ndStops != nil { s.formUnion(["/video/ndFilter", "/video/supportedNDFilters"]) }
        for name in config.displayNames where name != "Stream" {
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            for leaf in Self.overlayLeaves.union(["displayLUT", "falseColor"]) { s.insert("/monitoring/\(encoded)/\(leaf)") }
        }
        return s.subtracting(config.refusedSubscriptions)
    }

    private func handleWebSocketUpgrade(rawRequest: String, conn: NWConnection) {
        // Extract Sec-WebSocket-Key and send 101 Switching Protocols
        let key = extractWSKey(from: rawRequest) ?? ""
        let accept = webSocketAcceptValue(for: key)
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        count(down: response.utf8.count)
        conn.send(content: response.data(using: .utf8)!, completion: .idempotent)
        if config.silentWebSocket { return }
        lock.withLock { wsConnections.append(conn) }
        sendWSText(["type": "event", "data": ["action": "websocketOpened"]], to: conn)
        receiveWSFrames(from: conn, buffer: Data())
    }

    private func dropWebSocket(_ conn: NWConnection) {
        lock.withLock {
            wsConnections.removeAll { $0 === conn }
            subscriptions[ObjectIdentifier(conn)] = nil
        }
    }

    /// A read can hold several frames (a client sends one subscribe request per property) or part of one.
    private func receiveWSFrames(from conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data); self.count(up: data.count) }
            while let frame = Self.nextWSFrame(buffer) {
                buffer = Data(buffer.dropFirst(frame.length))
                switch frame.opcode {
                case 0x9: if !self.config.ignoresPings { self.sendWSPong(payload: frame.payload, to: conn) }
                case 0x8: self.dropWebSocket(conn); return
                default:
                    if let text = String(data: frame.payload, encoding: .utf8) { self.handleWSMessage(text, conn: conn) }
                }
            }
            if error != nil || isComplete { self.dropWebSocket(conn); return }
            self.receiveWSFrames(from: conn, buffer: buffer)
        }
    }

    private func handleWSMessage(_ text: String, conn: NWConnection) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = obj["data"] as? [String: Any],
              inner["action"] as? String == "subscribe",
              let properties = inner["properties"] as? [String] else { return }

        // A firmware that never answers one: no answer at all.
        if properties.contains(where: config.silentSubscriptions.contains) { return }
        let known = subscribable
        if let missing = properties.first(where: { !known.contains($0) }) {
            sendWSText(["type": "response",
                        "data": ["errorMessage": "Property \"\(missing)\" not found", "success": false]], to: conn)
            return
        }
        lock.withLock { subscriptions[ObjectIdentifier(conn), default: []].formUnion(properties) }
        var values: [String: Any] = [:]
        // The PYXIS answers /camera/power without its value.
        for property in properties where property != "/camera/power" {
            let reply = routeRequest(method: "GET", path: property, bodyData: Data())
            values[property] = try? JSONSerialization.jsonObject(with: Data(reply.body.utf8), options: .fragmentsAllowed)
        }
        sendWSText(["type": "response",
                    "data": ["action": "subscribe", "properties": properties, "success": true, "values": values]], to: conn)
    }

    private func sendWSPong(payload: Data, to conn: NWConnection) {
        var frame = Data()
        frame.append(0x8A)  // FIN + opcode 0xA (pong)
        frame.append(UInt8(min(payload.count, 125)))
        frame.append(payload)
        conn.send(content: frame, completion: .idempotent)
    }

    /// Sends a propertyValueChanged event to each client subscribed to `property`. `value` is an object, or a bare
    /// value for /transports/0/play.
    func pushPropertyChanged(_ property: String, value: Any) {
        let msg: [String: Any] = [
            "type": "event",
            "data": ["action": "propertyValueChanged", "property": property, "value": value] as [String: Any]
        ]
        let subscribed = lock.withLock {
            wsConnections.filter { subscriptions[ObjectIdentifier($0)]?.contains(property) == true }
        }
        for conn in subscribed { sendWSText(msg, to: conn) }
    }

    private func sendWSText(_ obj: [String: Any], to conn: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        let frame = Self.buildWSTextFrame(str)
        count(down: frame.count)
        conn.send(content: frame, completion: .idempotent)
    }

    // MARK: - Monitoring path parser

    /// Parse /monitoring/{displayName}/{feature} → (displayName, feature), percent-decoded.
    private func parseMonitoringPath(_ path: String) -> (String, String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[0] == "monitoring" else { return nil }
        let name = parts[1].removingPercentEncoding ?? parts[1]
        return (name, parts[2])
    }

    // MARK: - HTTP response helpers

    private func json(_ obj: [String: Any]) -> HTTPResponse {
        value(obj)
    }

    /// Any JSON value, a bare boolean included.
    private func value(_ v: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: v, options: .fragmentsAllowed)) ?? Data()
        return HTTPResponse(status: 200, body: String(data: data, encoding: .utf8) ?? "{}")
    }

    private func noContent() -> HTTPResponse {
        HTTPResponse(status: 204, body: "")
    }

    private func sendHTTPResponse(_ resp: HTTPResponse, conn: NWConnection) {
        let bodyData = resp.data ?? resp.body.data(using: .utf8) ?? Data()
        var raw = "HTTP/1.1 \(resp.status) \(statusText(resp.status))\r\n"
        raw += "Content-Type: \(resp.data == nil ? "application/json" : "application/octet-stream")\r\n"
        raw += "Content-Length: \(bodyData.count)\r\n"
        raw += "Connection: close\r\n"
        raw += "\r\n"
        var full = raw.data(using: .utf8)!
        full.append(bodyData)
        count(down: full.count, request: true)
        conn.send(content: full, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 409: return "Conflict"
        case 404: return "Not Found"
        case 501: return "Not Implemented"
        default: return "Error"
        }
    }

    // MARK: - WebSocket frame codec (RFC 6455 minimal — server frames unmasked, client frames masked)

    static func buildWSTextFrame(_ text: String) -> Data {
        let payload = Data(text.utf8)
        var frame = Data([0x81])  // FIN + opcode 1 (text)
        let length = payload.count
        if length < 126 {
            frame.append(UInt8(length))
        } else if length < 65536 {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((length >> shift) & 0xFF)) }
        }
        frame.append(payload)
        return frame
    }

    /// The first whole frame in `data`: its opcode, unmasked payload and length on the wire. Nil until it has all arrived.
    static func nextWSFrame(_ data: Data) -> (opcode: UInt8, payload: Data, length: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let masked = (bytes[1] & 0x80) != 0
        var payloadLen = Int(bytes[1] & 0x7F)
        var offset = 2
        if payloadLen == 126 {
            guard bytes.count >= 4 else { return nil }
            payloadLen = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if payloadLen == 127 {
            guard bytes.count >= 10 else { return nil }
            payloadLen = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }
            offset = 10
        }
        let maskOffset = offset
        offset += masked ? 4 : 0
        guard bytes.count >= offset + payloadLen else { return nil }
        var payload = Array(bytes[offset ..< offset + payloadLen])
        if masked {
            for i in payload.indices { payload[i] ^= bytes[maskOffset + i % 4] }
        }
        return (bytes[0] & 0x0F, Data(payload), offset + payloadLen)
    }

    // MARK: - WebSocket handshake

    private func extractWSKey(from request: String) -> String? {
        let lines = request.components(separatedBy: "\r\n")
        for line in lines {
            if line.lowercased().hasPrefix("sec-websocket-key:") {
                return line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func webSocketAcceptValue(for key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + magic
        let data = Data(combined.utf8)
        let hash = sha1(data)
        return hash.base64EncodedString()
    }

    private func sha1(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: 20)
        data.withUnsafeBytes { ptr in
            var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
            var msg = [UInt8](ptr.bindMemory(to: UInt8.self))
            let origLen = msg.count
            msg.append(0x80)
            while msg.count % 64 != 56 { msg.append(0) }
            let bitLen = UInt64(origLen) * 8
            for i in stride(from: 7, through: 0, by: -1) { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xFF)) }
            func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
            for chunk in stride(from: 0, to: msg.count, by: 64) {
                var w = [UInt32](repeating: 0, count: 80)
                for i in 0..<16 {
                    w[i] = UInt32(msg[chunk + i*4]) << 24 | UInt32(msg[chunk + i*4+1]) << 16 | UInt32(msg[chunk + i*4+2]) << 8 | UInt32(msg[chunk + i*4+3])
                }
                for i in 16..<80 { w[i] = rotl(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1) }
                var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
                for i in 0..<80 {
                    var f: UInt32; var k: UInt32
                    if i < 20 { f = (b & c) | (~b & d); k = 0x5A827999 }
                    else if i < 40 { f = b ^ c ^ d; k = 0x6ED9EBA1 }
                    else if i < 60 { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC }
                    else { f = b ^ c ^ d; k = 0xCA62C1D6 }
                    let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                    e = d; d = c; c = rotl(b, 30); b = a; a = temp
                }
                h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
            }
            for (i, v) in h.enumerated() {
                digest[i*4] = UInt8((v >> 24) & 0xFF); digest[i*4+1] = UInt8((v >> 16) & 0xFF)
                digest[i*4+2] = UInt8((v >> 8) & 0xFF); digest[i*4+3] = UInt8(v & 0xFF)
            }
        }
        return Data(digest)
    }
}

struct HTTPResponse {
    var status: Int
    var body: String
    /// A body that isn't text (a preset file), sent instead of `body`.
    var data: Data? = nil
}
