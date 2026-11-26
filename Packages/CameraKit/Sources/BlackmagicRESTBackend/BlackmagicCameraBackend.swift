import CameraCore
import Foundation

/// Blackmagic camera backend via the REST + WebSocket API.
///
/// HTTPS/TLS: self-signed cert, trust-on-first-use. Fingerprint surfaced via `CameraState.observedFingerprint`.
/// On mismatch, state becomes `.fingerprintChanged(observed)` — same UI path as Sony SSH TOFU.
///
/// Connect: a few reads over REST (identity, and what can't be subscribed to), then one subscribe request per property
/// over the WebSocket. Each answer carries the property's value, so the state arrives in one burst rather than a round
/// trip per read: about 28 of those took several seconds over HaLow.
///
/// Monitoring: each output's overlays are subscribed after connect, so nothing about them can hold a connection up.
/// An output's overlays are the ones its subscriptions answered: the PYXIS's stream output answers none, so it isn't
/// shown or written to. Look and false color are the display LUT and false color on every output.
///
/// Latency: a WebSocket ping every 10 s, its round trip averaged over the last four. No pong in 5 s means the link has
/// gone (a stalled mesh hop can leave TCP open with nothing behind it): the connection fails and the app reconnects.
///
/// Timecode: the camera pushes it every other frame over the WebSocket, so it isn't subscribed: a local
/// TimecodeClock runs from GET /transports/0/timecode, read on connect (twice, to see whether it's running), once a
/// minute after, and when REC starts or stops.
///
/// Checked on a PYXIS 12K (Camera 10.1) over HaLow: docs/pyxis-controls.md.
public actor BlackmagicCameraBackend: CameraBackend {
    public nonisolated let updates: AsyncStream<CameraState>
    private nonisolated let continuation: AsyncStream<CameraState>.Continuation

    let restClient: BlackmagicRESTClient
    private let wsClient: BlackmagicWebSocketClient
    /// Which camera this is: the address it's saved with, or `usb:<serial>` for one on a cable. The Activity Log's key.
    let host: String
    /// Where the camera is reached: `host`, or where `findAddress` last found it.
    private(set) var address: String
    /// For a camera that isn't at a saved address (on a USB cable): finds it at each connect, giving its address with
    /// its port, or throwing what's wrong, which the connection fails with.
    private let findAddress: (@Sendable () async throws -> String)?
    /// Counts connects and disconnects: a connect still finding its camera gives way to a newer one.
    private var connectAttempt = 0
    /// What the clients point at until a camera on a cable has been found: a name that never resolves.
    static let notFoundYet = "camera-not-found-yet.invalid"
    private let tlsDelegate: BlackmagicTLSDelegate?

    var state = CameraState()
    private var wsTask: Task<Void, Never>?
    /// Display names from GET /monitoring/display. Look and false color are set on all of them and read from the first.
    private var displayNames: [String] = []
    /// The WebSocket on connect: whether it has opened (or ended), the subscribe answers still owed, and the values in
    /// them. Until the state is built (`collecting`), a push replaces its property's value here.
    private var wsOpened = false
    private var wsEnded = false
    private var awaitingAnswers = 0
    private var answers: [String: Any] = [:]
    private var subscribed: Set<String> = []
    private var refused: [String] = []
    private var collecting = false
    /// Which event loop is current: one left over from an earlier connection must not touch this one's flags.
    private var wsGeneration = 0
    /// What each output reported for each overlay, by the camera's output name.
    private var overlays: [String: [MonitorOverlay: Bool]] = [:]
    /// Subscribe answers still owed for the monitoring subscriptions sent after connect.
    private var awaitingMonitoring = 0
    private var monitoringLoaded = false
    /// Subscribe answers still owed for tally, the lens's focus and the audio, subscribed once the monitoring is in.
    private var awaitingExtras = 0
    /// What's been said in the Activity Log on this connection about something not read, so a minute's poll says it once.
    private var noted: Set<String> = []
    /// Each audio channel's reports, by the camera's index (`BlackmagicAudio`), and whether they're all in.
    private var audio: [Int: AudioReport] = [:]
    private var audioLoaded = false
    /// Tally answered over REST but not as a subscription, so it isn't pushed: read once a minute and after a change.
    private var tallyPolled = false
    /// /lens/focus/description has been heard from (a subscription's answer or a push).
    private var focusDescribed = false
    /// What the camera's presets hold of the settings its API hasn't got (`BlackmagicPreset.swift`): read after connect,
    /// once a minute and after a change; nil until then, or on a camera whose presets can't be read.
    private var preset: PresetSettings?
    /// The sections of the fullest preset read since connecting (`isWhole`).
    private var presetLayout: [String]?
    /// The camera's software (/system/product): presets are only touched on one whose fields were checked.
    private var softwareVersion: String?
    /// The camera answered a still with 404 (or 501): no Grab Still tile on it again this run.
    private var noStillCapture = false
    /// Monitoring changes the camera has pushed since connecting (a value that changed, not one pushed again): one during
    /// a change through a preset means the monitoring section it copied may be out of date.
    private var monitoringPushes = 0
    /// Changes on their way through a preset, shown meanwhile as `Choice.pending` (a change takes a second or two to
    /// land): status text and what it shows by output, and the de-squeeze.
    private var pendingStatusText: [String: Bool] = [:]
    private var pendingContent: [String: StatusTextContent] = [:]
    private var pendingDesqueeze: String?
    private var pendingLUT: String?
    /// The LUTs this camera has been seen using, now and on earlier connections (`CameraProfile.luts`, handed back at
    /// init): the LUT picker's options. A preset names only the LUT in use, so this is how Tiles learns the rest.
    private var knownLUTs: [String]
    /// A preset is being saved or loaded: one at a time, or one change's save could undo another's.
    private var presetBusy = false
    /// Changes started and not finished: what's pending goes once they all have.
    private var presetChanges = 0
    private var zebraHighlightEnabled: Bool?
    private var zebraLevel: Int?
    private var frameGuideRatio: String?
    private var frameGuidePresets: [String] = []
    /// Last-read timeline clips, kept for next/previous clip math.
    private var lastTimelineClips: [TimelineClip] = []
    /// Last-read clip index (0-based).
    private var lastClipIndex: Int?
    /// The card's clips' names by clipUniqueId (`GET /clips`, their files'): the playback list only has ids.
    private var clipFiles: [Int: String] = [:]
    private var readingClipFiles = false
    /// Counts playback commands: a Review or a pick from the Clips window still seeking stops once another command
    /// comes, so two quick picks can't leave the camera on the first.
    private var playbackCommandCount = 0
    /// Frame rate as a Double derived from the format, for position → seconds conversion.
    private var fps: Double = 24
    /// The camera's format as last read or pushed: a format change is this with one field replaced.
    private var currentFormat: FormatResponse?
    /// GET /system/supportedFormats: every recording area, with its codecs and frame rates.
    private var supportedFormats: [SupportedFormat] = []
    /// Re-reads the timecode while connected (see the type's note).
    private var timecodeTask: Task<Void, Never>?
    /// Pings the WebSocket while connected, and the last few round trips in milliseconds.
    private var pingTask: Task<Void, Never>?
    private var recentLatencies: [Double] = []
    /// The connect reads came too close together to see a running timecode move (a USB-C link connects in 50 ms).
    private var timecodeUndecided = false
    /// /transports/0 "InputPreview" (live) or "Output" (playback), as last read or pushed.
    var transportMode: String?
    /// Live view (`BlackmagicLiveView.swift`): the livestream's status and availability as the camera pushes them, the
    /// stream Tiles started and at what quality, the camera's own platform to put back, and a stop held for a take.
    var liveStreamStatus: String?
    /// The camera's streaming platform's name, as last reported.
    var liveStreamPlatform: String?
    var liveStreamAvailable: Bool?
    var liveStream: BlackmagicLiveStream?
    var liveStreamQuality: LiveViewQuality?
    var savedPlatform: Data?
    var liveStreamStopPending = false
    /// Live view is open: `startLiveView` until `stopLiveView`.
    var liveStreamWanted = false
    /// The camera-side stop waiting out the linger (`scheduleStreamFinish`).
    var liveStreamFinish: Task<Void, Never>?
    /// A finish found no connection: it runs after the next one (`liveStreamConnected`).
    var liveStreamFinishOnConnect = false
    var liveStreamRestartedAt: ContinuousClock.Instant?
    /// Starting or finishing live view's stream: no restart of its own meanwhile.
    var liveStreamBusy = false
    /// How long the camera's stream outlives live view: a page change, a dropout or the app in the background picks it
    /// up again, rather than a stop (which shows playback on the camera's outputs) and a start.
    var liveStreamLinger: Duration = .seconds(60)
    /// Whether the camera has Remote Control on, which stops live view's stream without showing
    /// (`BlackmagicRemoteControl.swift`): nil until asked on this connection.
    var remoteControl: Bool?
    /// Off for tools comparing the two stops: the stream is then stopped the documented way, as without Remote Control.
    public private(set) var stopsThroughRemoteControl = true
    public func setStopsThroughRemoteControl(_ on: Bool) { stopsThroughRemoteControl = on }
    /// The linger on a camera with Remote Control (tools try others).
    public private(set) var remoteControlLinger: Duration = .seconds(15)
    public func setRemoteControlLinger(_ linger: Duration) { remoteControlLinger = linger }
    /// Since when the camera should be reaching this device, and whether the stall check has spoken for it
    /// (`noteStalledStart`, after `stalledStartAfter`: over HaLow a healthy start takes about 4.5 s to its first picture).
    var liveStreamStartedAt: ContinuousClock.Instant?
    var liveStreamStallNoted = false
    var stalledStartAfter: Duration = .seconds(8)
    func setStalledStartAfter(_ after: Duration) { stalledStartAfter = after }
    /// `liveViewStep`'s turns.
    var liveViewStepBusy = false
    var liveViewStepWaiters: [CheckedContinuation<Void, Never>] = []
    /// Where the camera should stream to, when it isn't this device's own address toward it (a test through a relay).
    public private(set) var liveViewStreamAddress: String?
    public func setLiveViewStreamAddress(_ address: String?) { liveViewStreamAddress = address }
    /// The camera's address without a port, for working out which of this device's addresses reaches it.
    var hostAddress: String {
        address.hasPrefix("[") ? String(address.dropFirst().prefix { $0 != "]" })
            : String(address.split(separator: ":").first ?? Substring(address))
    }
    /// The last shutter value, measurement and supported values: the camera sends each on its own, and the shutter
    /// state needs all three.
    private var shutter: ShutterResponse?
    private var shutterMeasurement: ShutterMeasurementResponse?
    private var supportedShutters: SupportedShuttersResponse?

    /// REC confirm timeout: how long to wait for the camera to push the new recording state.
    public var recConfirmTimeout: TimeInterval = 5

    public func setRecConfirmTimeout(_ t: TimeInterval) { recConfirmTimeout = t }

    /// How long connect waits for the WebSocket to open, and then for every subscribe answer: room for a slow mesh.
    public var eventTimeout: TimeInterval = 10

    public func setEventTimeout(_ t: TimeInterval) { eventTimeout = t }

    /// How often the WebSocket is pinged, and how long a pong may take.
    public private(set) var pingInterval: Duration = .seconds(10)
    public private(set) var pongTimeout: Duration = .seconds(5)

    public func setPing(every interval: Duration, timeout: Duration) {
        pingInterval = interval
        pongTimeout = timeout
    }

    /// Plain HTTP/WS init (no TLS). `login` when the camera has one; `findAddress` for a camera found at each connect.
    public init(host: String, urlSession: URLSession = .shared, login: BlackmagicLogin? = nil, knownLUTs: [String] = [],
                findAddress: (@Sendable () async throws -> String)? = nil) {
        self.host = host
        address = findAddress == nil ? host : Self.notFoundYet
        self.findAddress = findAddress
        self.knownLUTs = Self.lutList(knownLUTs)
        self.tlsDelegate = nil
        let stream = AsyncStream.makeStream(of: CameraState.self, bufferingPolicy: .bufferingNewest(16))
        updates = stream.stream
        continuation = stream.continuation
        restClient = BlackmagicRESTClient(host: address, useHTTPS: false, session: urlSession, login: login)
        wsClient = BlackmagicWebSocketClient(host: address, useHTTPS: false, session: urlSession, login: login)
    }

    /// HTTPS/WSS init. The `tlsSession` must be configured with `delegate` pointing at `delegate`.
    public init(host: String, useHTTPS: Bool, tlsSession: URLSession, delegate: BlackmagicTLSDelegate,
                login: BlackmagicLogin? = nil, knownLUTs: [String] = [],
                findAddress: (@Sendable () async throws -> String)? = nil) {
        self.host = host
        address = findAddress == nil ? host : Self.notFoundYet
        self.findAddress = findAddress
        self.knownLUTs = Self.lutList(knownLUTs)
        self.tlsDelegate = delegate
        let stream = AsyncStream.makeStream(of: CameraState.self, bufferingPolicy: .bufferingNewest(16))
        updates = stream.stream
        continuation = stream.continuation
        restClient = BlackmagicRESTClient(host: address, useHTTPS: useHTTPS, session: tlsSession, login: login)
        wsClient = BlackmagicWebSocketClient(host: address, useHTTPS: useHTTPS, session: tlsSession, login: login)
    }

    /// The backend for a saved connection, as the app makes it (and `camctl`, so a check runs the app's own path): its
    /// login, with Remote Control's user name and port; HTTPS with the camera's certificate pinned once it's been seen;
    /// and the LUTs the camera has been seen using, as it only ever names the one in use. A camera on a USB cable is
    /// found on it at each connect.
    public static func make(_ connection: BlackmagicConnection, password: String?, knownLUTs: [String] = []) -> BlackmagicCameraBackend {
        let login = connection.user.map { BlackmagicLogin(user: $0, password: password ?? "") }
        var findAddress: (@Sendable () async throws -> String)?
        if let serial = USBCameraAddress.serial(in: connection.host) {
            findAddress = {
                let found = try await BlackmagicUSBLink.address(serial: serial)
                return connection.address(at: found)
            }
        }
        let host = findAddress == nil ? connection.address : connection.host
        guard connection.secure else {
            return BlackmagicCameraBackend(host: host, login: login, knownLUTs: knownLUTs, findAddress: findAddress)
        }
        let delegate = BlackmagicTLSDelegate()
        delegate.pinnedFingerprint = connection.pinnedCertificateFingerprint.map { normalisedFingerprint($0) }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        return BlackmagicCameraBackend(host: host, useHTTPS: true, tlsSession: session, delegate: delegate,
                                       login: login, knownLUTs: knownLUTs, findAddress: findAddress)
    }

    // MARK: - CameraBackend

    public func connect() async {
        // A new link has no round trip yet: not the last one's average, nor its samples.
        recentLatencies = []
        state.latencyMilliseconds = nil
        await setConnection(.connecting)

        // Wire up TLS fingerprint callbacks before any network activity.
        if let delegate = tlsDelegate {
            delegate.onFingerprintObserved = { [weak self] fp in
                Task { await self?.handleFingerprintObserved(fp) }
            }
            delegate.onFingerprintMismatch = { [weak self] fp in
                Task { await self?.handleFingerprintMismatch(fp) }
            }
        }

        if let findAddress {
            connectAttempt += 1
            let attempt = connectAttempt
            let found: String
            do {
                found = try await findAddress()
            } catch {
                guard attempt == connectAttempt else { return }
                await setConnection(.failed(readableReason(error)))
                return
            }
            guard attempt == connectAttempt else { return }  // a newer connect, or a disconnect, took over
            if found != address { await repoint(to: found) }
        }

        do {
            var initial = try await fetchInitialState()
            // A first-use certificate is reported while fetchInitialState runs: its first request does the handshake,
            // and the delegate then pins it, so later handshakes stay quiet. Carry it over or this assignment drops it.
            initial.observedFingerprint = state.observedFingerprint
            state = initial
            collecting = false
            clipFiles = [:]
            applyClipList()
            emit()
            Task { await self.subscribeMonitoring() }
            Task { await self.readClipFiles() }
        } catch {
            collecting = false
            await stopEvents()
            // If a fingerprint mismatch already set fingerprintChanged, don't overwrite it.
            if case .fingerprintChanged = state.connection { return }
            await setConnection(.failed(((error as? BlackmagicError) ?? .transportError(error)).description))
            return
        }

        // If TLS TOFU just fired and we haven't connected yet, stop here — the state is already emitted.
        if case .fingerprintChanged = state.connection { return }

        if timecodeUndecided { Task { await self.syncTimecode() } }
        timecodeTask?.cancel()
        timecodeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.syncTimecode()
                await self?.readDynamicRange()
                await self?.readPreset()
                await self?.pollTally()
            }
        }
        recentLatencies = []
        pingTask?.cancel()
        pingTask = Task { [weak self, pingInterval] in
            while !Task.isCancelled {
                guard await self?.ping() == true else { return }
                try? await Task.sleep(for: pingInterval)
            }
        }
    }

    public func disconnect() async {
        connectAttempt += 1
        timecodeTask?.cancel()
        timecodeTask = nil
        pingTask?.cancel()
        pingTask = nil
        await stopEvents()
        await setConnection(.disconnected)
    }

    /// One ping: its round trip goes into the latency shown; no pong fails the connection. False when there's no
    /// connection to ping any more.
    private func ping() async -> Bool {
        guard state.connection == .connected else { return false }
        let roundTrip: Duration
        switch await wsClient.ping(timeout: pongTimeout) {
        case .pong(let time):
            roundTrip = time
        case .closed:
            return state.connection == .connected  // the event loop reports a closed socket
        case .noAnswer:
            guard state.connection == .connected, !Task.isCancelled else { return false }
            await stopEvents()
            await setConnection(.failed(BlackmagicError.noAnswer.description))
            return false
        }
        guard state.connection == .connected else { return false }
        recentLatencies.append(Double(roundTrip.components.attoseconds) / 1e15 + Double(roundTrip.components.seconds) * 1000)
        if recentLatencies.count > 4 { recentLatencies.removeFirst() }
        state.latencyMilliseconds = Int((recentLatencies.reduce(0, +) / Double(recentLatencies.count)).rounded())
        emit()
        return true
    }

    /// Points the REST and WebSocket clients at where the camera was found, once nothing of the last link uses them.
    private func repoint(to found: String) async {
        timecodeTask?.cancel()
        timecodeTask = nil
        pingTask?.cancel()
        pingTask = nil
        await stopEvents()
        address = found
        await restClient.setHost(found)
        await wsClient.setHost(found)
        ActivityLog.shared.note(host, "found on its cable at \(found)")
    }

    /// Closes the WebSocket; its event loop ends without marking anything.
    private func stopEvents() async {
        wsGeneration += 1
        wsTask?.cancel()
        wsTask = nil
        await wsClient.disconnect()
    }

    public func send(_ command: CameraCommand) async {
        do {
            try await dispatch(command)
        } catch BlackmagicError.forbidden(_) {
            // Camera refused (e.g. ISO while AE active) — not an error worth surfacing
        } catch BlackmagicError.notImplemented {
            // Body doesn't have this control — ignore
        } catch {
            state.warnings = ["\(command): \(error.localizedDescription)"]
            emit()
        }
    }

    // MARK: - TLS fingerprint handling

    private func handleFingerprintObserved(_ fingerprint: String) {
        // Trust-on-first-use: accept and report via observedFingerprint so the store saves it.
        state.observedFingerprint = fingerprint
        emit()
    }

    private func handleFingerprintMismatch(_ observed: String) {
        // Stop and surface the mismatch — same state as Sony SSH TOFU flow.
        state.connection = .fingerprintChanged(observed)
        emit()
    }

    // MARK: - Initial state fetch

    private func fetchInitialState() async throws -> CameraState {
        var payload = BlackmagicRESTStateMapper.InitialPayload()

        // system/product is required — bail early if the camera is unreachable
        payload.product = try await restClient.get("system/product", as: ProductResponse.self)
        softwareVersion = payload.product?.softwareVersion

        // The timecode now and again at the end: whether it moved says whether it's running.
        let firstTimecode = await readTimecode()
        let firstTimecodeAt = Date()
        payload.supportedFormats = await tryGet("system/supportedFormats", as: SupportedFormatsResponse.self)?.supportedFormats ?? []
        displayNames = await tryGet("monitoring/display", as: MonitoringDisplayResponse.self)?.displays ?? []

        let firstDisplay = displayNames.first.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
        var properties = BlackmagicWebSocketClient.baseSubscribeProperties
        if let firstDisplay {
            properties += ["/monitoring/\(firstDisplay)/displayLUT", "/monitoring/\(firstDisplay)/falseColor"]
        }
        try await subscribe(properties)
        if !refused.isEmpty { ActivityLog.shared.note(host, "not on this camera: \(refused.joined(separator: ", "))") }
        // An answer can come without its value (/camera/power on a PYXIS, pushed only when the voltage moves).
        for property in subscribed where answers[property] == nil {
            if let data = try? await restClient.get(String(property.dropFirst())),
               let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
                answers[property] = answers[property] ?? value
            }
        }

        // A body whose format has no codec names it at /system/codecFormat, with the choices only over REST.
        if answers["/system/codecFormat"] != nil {
            payload.supportedCodecFormats = await tryGet("system/supportedCodecFormats", as: SupportedCodecFormatsResponse.self)
        }
        let secondTimecode = await readTimecode()
        let secondTimecodeAt = Date()

        // The answers as they stand now: a push since an answer has replaced its value.
        payload.fill(from: answers, firstDisplay: firstDisplay)
        overlays = [:]
        preset = nil
        presetLayout = nil
        presetsMatchLayout = false
        awaitingMonitoring = 0
        monitoringLoaded = false
        audio = [:]
        audioLoaded = false
        tallyPolled = false
        focusDescribed = false
        awaitingExtras = 0
        noted = []
        zebraHighlightEnabled = nil
        zebraLevel = nil
        frameGuideRatio = nil
        frameGuidePresets = []
        if let first = displayNames.first {
            overlays[first, default: [:]][.lut] = payload.displayLUT?.enabled
            overlays[first, default: [:]][.falseColor] = payload.falseColor?.enabled
        }
        lastTimelineClips = payload.timeline?.clips ?? []
        lastClipIndex = payload.clipIndex?.clipIndex
        transportMode = payload.transport?.mode
        if let fr = payload.format?.frameRate { fps = parseFPS(fr) }
        currentFormat = payload.format
        supportedFormats = payload.supportedFormats
        shutter = payload.shutter
        shutterMeasurement = payload.shutterMeasurement
        supportedShutters = payload.supportedShutters
        // What it runs decides whether its presets are used, and a report should say.
        note("software", "\(payload.product?.productName ?? "Blackmagic camera"), Camera \(softwareVersion ?? "software unknown")")

        var built = BlackmagicRESTStateMapper.buildInitialState(from: payload)
        applyMonitoring(to: &built)
        // Offered until the camera says it has none: the API has no way to ask first.
        built.canGrabStill = !noStillCapture
        timecodeUndecided = false
        if let first = firstTimecode, let second = secondTimecode {
            built.timecode = clock(second, earlier: first, readAt: secondTimecodeAt)
            // Under a quarter second apart, a standing clock may only be a quick link: connect() looks again.
            timecodeUndecided = second == first && secondTimecodeAt.timeIntervalSince(firstTimecodeAt) < 0.25
        }
        return built
    }

    /// Opens the WebSocket, sends one subscribe request per property, and waits for every answer. The values land in
    /// `answers`; a refusal (a property this body hasn't got) in `refused`.
    private func subscribe(_ properties: [String]) async throws {
        await stopEvents()
        let generation = wsGeneration
        wsOpened = false
        wsEnded = false
        answers = [:]
        subscribed = []
        refused = []
        collecting = true
        await wsClient.connect()
        wsTask = Task { await runEventLoop(generation: generation) }
        try await wait { wsOpened || wsEnded }
        guard !wsEnded else { throw BlackmagicError.noEvents }
        awaitingAnswers = properties.count
        try await wsClient.subscribe(properties)
        try await wait { awaitingAnswers == 0 || wsEnded }
        guard awaitingAnswers == 0 else { throw BlackmagicError.noEvents }
    }

    /// Checks `condition` every 20 ms for up to `eventTimeout`.
    private func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(eventTimeout)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw BlackmagicError.noEvents }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - WebSocket event loop

    private func runEventLoop(generation: Int) async {
        for await event in await wsClient.receiveEvents() {
            guard !Task.isCancelled, generation == wsGeneration else { return }
            switch event {
            case .opened:
                wsOpened = true
            case .subscribeResult(let success, let error, let properties, let values):
                if awaitingAnswers > 0 {
                    subscribed.formUnion(properties)
                    answers.merge(values) { _, answer in answer }
                    // `Property "/video/ndFilter" not found` → /video/ndFilter
                    if !success { refused.append(error?.split(separator: "\"").dropFirst().first.map(String.init) ?? error ?? "?") }
                    awaitingAnswers -= 1
                } else if awaitingMonitoring > 0 {
                    // The monitoring subscribed after connect. A refusal is an overlay that output can't report.
                    for (property, value) in values { apply(property: property, value: value) }
                    awaitingMonitoring -= 1
                } else if awaitingExtras > 0 {
                    // Tally, focus and audio, subscribed once the monitoring was in (`subscribeExtras`).
                    for (property, value) in values { apply(property: property, value: value) }
                    awaitingExtras -= 1
                } else {
                    // An answer after its burst stopped waiting: its values are still the camera's.
                    for (property, value) in values { apply(property: property, value: value) }
                }
            case .propertyChanged(let property, let value):
                if collecting {
                    answers[property] = value
                    break
                }
                if property == "/transports/0/record" {
                    // A take starting or stopping can start or stop the timecode (record run), so read it again.
                    Task { await self.syncTimecode() }
                    // And a live view stop held for the take can run.
                    if (value as? [String: Any])?["recording"] as? Bool == false { Task { await self.recordingEnded() } }
                }
                apply(property: property, value: value)
            }
        }
        guard generation == wsGeneration else { return }
        wsEnded = true
        // Without it no change reaches the app: fail, and CameraController reconnects.
        if state.connection == .connected {
            await setConnection(.failed(BlackmagicError.eventsClosed.description))
        }
    }

    /// After connect: every output's overlays, the zebra level and the guide ratio, in one burst. Each answer adds what
    /// it reports; nothing here can fail the connection.
    private func subscribeMonitoring() async {
        guard state.connection == .connected else { return }
        // A connection that drops while this runs leaves the next one's monitoring alone.
        let generation = wsGeneration
        let first = displayNames.first
        var properties: [String] = []
        for name in displayNames {
            for overlay in MonitorOverlay.allCases where overlay.isREST && !(name == first && (overlay == .lut || overlay == .falseColor)) {
                properties.append("/" + monitoringPath(name, overlay.restLeaf))
            }
        }
        properties += ["/monitoring/zebra", "/monitoring/frameGuideRatio"]
        // The livestream, which live view goes through: whether the camera has one, what it's doing, and where to.
        properties += ["/livestreams/0", "/livestreams/0/available", "/livestreams/0/activePlatform"]
        awaitingMonitoring = properties.count
        if (try? await wsClient.subscribe(properties)) == nil { awaitingMonitoring = 0 }
        // Not subscribable: read while the answers come in.
        let presets = (try? await restClient.get("monitoring/frameGuideRatio/presets", as: FrameGuidePresetsResponse.self))?.presets
        guard generation == wsGeneration else { return }
        frameGuidePresets = presets ?? []
        // Answers that never come leave those overlays unknown, not the rest.
        try? await wait { awaitingMonitoring == 0 }
        guard generation == wsGeneration else { return }
        awaitingMonitoring = 0
        // All of it at once: no state with the outputs but not the guide ratios.
        monitoringLoaded = true
        applyMonitoring(to: &state)
        emit()
        // Tally, autofocus and audio, in a burst and a task of their own: none has met a camera yet, and one it never
        // answered would hold up whatever waited for it (connect's burst fails, the monitoring's waits its timeout).
        Task { await self.subscribeExtras(generation: generation) }
        // What the API hasn't got, from a preset of the camera's state.
        await readPreset()
        // A live view stream a dropout or an earlier run left going.
        await liveStreamConnected()
    }

    /// Tally, the lens's focus and every audio channel's settings, subscribed once the monitoring is in: never beside
    /// another burst (an answer goes to whichever burst is still owed one), and waited for here alone. Then whatever came
    /// without a value is read over REST.
    private func subscribeExtras(generation: Int) async {
        let channels = await audioChannelCount()
        guard generation == wsGeneration, state.connection == .connected else { return }
        var properties = ["/camera/tallyStatus", "/lens/focus/description"]
        for channel in 0..<channels { properties += BlackmagicAudio.leaves.map { BlackmagicAudio.path(channel, $0) } }
        awaitingExtras = properties.count
        if (try? await wsClient.subscribe(properties)) == nil { awaitingExtras = 0 }
        try? await wait { awaitingExtras == 0 }
        guard generation == wsGeneration else { return }
        if awaitingExtras > 0 { note("extras", "\(awaitingExtras) of tally, focus and audio unanswered: read over REST") }
        awaitingExtras = 0
        await readWhatSubscriptionsLeft(channels: channels, generation: generation)
    }

    /// Something not read, in the Activity Log once a connection: "empty" mustn't pass for "nothing there".
    private func note(_ key: String, _ message: String) {
        guard noted.insert(key).inserted else { return }
        ActivityLog.shared.note(host, message)
    }

    /// A REST read for something optional: nil when it fails, and why, said once (`note`).
    private func read<T: Decodable & Sendable>(_ path: String, as type: T.Type) async -> T? {
        do { return try await restClient.get(path, as: type) } catch {
            note(path, "/\(path) not read: \(error.localizedDescription)")
            return nil
        }
    }

    /// The same for a property read as JSON, to apply as a push would be.
    private func readJSON(_ path: String) async -> Any? {
        do {
            let data = try await restClient.get(path)
            return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        } catch {
            note(path, "/\(path) not read: \(error.localizedDescription)")
            return nil
        }
    }

    /// After the burst: tally, the lens's focus and the audio channels' settings that came without a value (refused, or
    /// answered empty), read over REST; and each channel's input choices and description, which only REST has.
    private func readWhatSubscriptionsLeft(channels: Int, generation: Int) async {
        // Each read is awaited: a connection that dropped (and maybe came back) meanwhile isn't this one's to fill.
        if state.tally == nil, let status = await read("camera/tallyStatus", as: TallyStatusResponse.self)?.status {
            guard generation == wsGeneration else { return }
            tallyPolled = true
            apply(property: "/camera/tallyStatus", value: ["status": status])
        }
        if !focusDescribed, let description = await readJSON("lens/focus/description") {
            guard generation == wsGeneration else { return }
            apply(property: "/lens/focus/description", value: description)
        }
        for channel in 0..<channels {
            for leaf in BlackmagicAudio.leaves where !audioReported(channel, leaf) {
                guard generation == wsGeneration else { return }
                await readAudio(channel, leaf)
            }
            guard generation == wsGeneration else { return }
            await readAudioInput(channel)
        }
        guard generation == wsGeneration else { return }
        audioLoaded = true
        applyAudio()
    }

    /// GET /audio/channels, at most eight (each channel is six subscriptions); 0 on a camera without the API's audio.
    private func audioChannelCount() async -> Int {
        let count = await read("audio/channels", as: AudioChannelsResponse.self)?.channels ?? 0
        return min(max(count, 0), 8)
    }

    private func audioReported(_ channel: Int, _ leaf: String) -> Bool {
        guard let report = audio[channel] else { return false }
        switch leaf {
        case "input": return report.input != nil
        case "level": return report.gain != nil
        case "phantomPower": return report.phantomPower != nil
        case "padding": return report.padding != nil
        case "lowCutFilter": return report.lowCutFilter != nil
        case "available": return report.available != nil
        default: return true
        }
    }

    /// One of a channel's settings over REST, applied as a push would be (not into a connection that has since been
    /// replaced).
    private func readAudio(_ channel: Int, _ leaf: String) async {
        let generation = wsGeneration
        let path = BlackmagicAudio.path(channel, leaf)
        guard let value = await readJSON(String(path.dropFirst())), generation == wsGeneration else { return }
        apply(property: path, value: value)
    }

    /// A channel's input choices and its input's description (gain range, phantom power, low cut, pad): read, as the
    /// API has no notification for either; again whenever the channel's input changes.
    private func readAudioInput(_ channel: Int) async {
        let generation = wsGeneration
        let base = "audio/channel/\(channel)/"
        let inputs = await read(base + "supportedInputs", as: [AudioSupportedInput].self)
        let description = await read(base + "input/description", as: AudioInputDescriptionResponse.self)
        guard generation == wsGeneration else { return }
        var report = audio[channel] ?? AudioReport()
        if let inputs { report.inputs = inputs }
        if let described = description?.description { report.description = described }
        audio[channel] = report
        if audioLoaded { applyAudio() }
    }

    /// `audioChannels` from the reports: once they're all in, then on every change.
    private func applyAudio() {
        let channels = audio.keys.sorted().compactMap { id in audio[id].flatMap { BlackmagicAudio.channel(id, $0) } }
        guard channels != state.audioChannels else { return }
        state.audioChannels = channels
        emit()
    }

    /// One audio setting, read back after: the camera's word, pushed or not.
    private func setAudio(_ channel: Int, _ setting: AudioSetting) async throws {
        let base = "audio/channel/\(channel)/"
        switch setting {
        case .input(let input):
            try await restClient.put(base + "input", body: AudioInputBody(input: input))
            await readAudio(channel, "input")  // a new input is described again (`apply`)
            // It comes with its own gain, switches and availability.
            for leaf in BlackmagicAudio.leaves where leaf != "input" { await readAudio(channel, leaf) }
        case .gain(let gain):
            try await restClient.put(base + "level", body: AudioGainBody(gain: gain))
            await readAudio(channel, "level")
        case .phantomPower(let on):
            try await restClient.put(base + "phantomPower", body: MonitoringEnabledBody(enabled: on))
            await readAudio(channel, "phantomPower")
            noteIfKept(channel, "48 V", audio[channel]?.phantomPower, wanted: on)
        case .lowCut(let on):
            try await restClient.put(base + "lowCutFilter", body: MonitoringEnabledBody(enabled: on))
            await readAudio(channel, "lowCutFilter")
            noteIfKept(channel, "low cut", audio[channel]?.lowCutFilter, wanted: on)
        case .pad(let on):
            try await restClient.put(base + "padding", body: MonitoringEnabledBody(enabled: on))
            await readAudio(channel, "padding")
            noteIfKept(channel, "pad", audio[channel]?.padding, wanted: on)
        }
    }

    /// A switch the camera answered the request for but left as it was. A PYXIS 12K does that with an XLR mic input's
    /// pad: the tile shows what the camera reads back, and the Activity Log says why it didn't move.
    private func noteIfKept(_ channel: Int, _ name: String, _ now: Bool?, wanted: Bool) {
        guard let now, now != wanted else { return }
        ActivityLog.shared.note(host, "audio channel \(channel + 1): the camera kept its \(name) \(now ? "on" : "off")")
    }

    /// `monitoring` from what the outputs reported, and look and false color as those overlays on every output.
    private func applyMonitoring(to state: inout CameraState) {
        // Through a preset only between takes: loading one during a take hasn't been tried.
        let idle = state.recording.state == .idle
        state.desqueeze = preset?.desqueeze.map {
            Choice($0, options: PresetSettings.desqueezeFactors, isWritable: idle, pending: pendingDesqueeze)
        }
        // The LUT in use, out of the ones this camera has been seen using.
        state.lut = preset?.lut.map { Choice($0, options: knownLUTs, isWritable: idle, pending: pendingLUT) }
        // The preset lists the outputs the API reports, in its order; only when they tally are its settings theirs.
        let names = presetOutputs
        let fromPreset = preset.flatMap { $0.statusText.count == names.count ? $0 : nil }
        let outputs = displayNames.compactMap { name -> MonitorOutput? in
            guard let reported = overlays[name], !reported.isEmpty else { return nil }
            var output = MonitorOutput(id: name, name: BlackmagicRESTStateMapper.outputName(name),
                                       overlays: reported.mapValues { Choice($0, options: [false, true]) })
            if let fromPreset, let index = names.firstIndex(of: name) {
                output.overlays[.statusText] = Choice(fromPreset.statusText[index], options: [false, true], isWritable: idle,
                                                      pending: pendingStatusText[name])
                output.statusTextContent = fromPreset.statusTextContent[index].map {
                    Choice($0, options: $0.pair, isWritable: idle, pending: pendingContent[name])
                }
            }
            return output
        }
        guard !outputs.isEmpty else {
            state.monitoring = nil
            return
        }
        var monitoring = MonitoringState(outputs: outputs)
        if let level = zebraLevel { monitoring.zebraLevel = Choice(level, options: [75, 80, 85, 90, 95, 100]) }
        if let ratio = frameGuideRatio {
            monitoring.frameGuideRatio = Choice(ratio, options: frameGuidePresets.contains(ratio) ? frameGuidePresets : [ratio] + frameGuidePresets)
        }
        state.monitoring = monitoring
        state.look = monitoring.onEverywhere(.lut)
        state.falseColor = monitoring.onEverywhere(.falseColor)
    }

    /// /monitoring/{output}/{leaf}, /monitoring/zebra and /monitoring/frameGuideRatio. True when it was one of them.
    private func applyMonitoringValue(property: String, value: Any) -> Bool {
        let parts = property.split(separator: "/").map(String.init)
        guard parts.first == "monitoring" else { return false }
        // What it was, to tell a change from the same value pushed again.
        let before = (overlays, zebraHighlightEnabled, zebraLevel, frameGuideRatio)
        if parts.count == 3, let overlay = MonitorOverlay.allCases.first(where: { $0.restLeaf == parts[2] }) {
            let output = parts[1].removingPercentEncoding ?? parts[1]
            guard let enabled = (value as? [String: Any])?["enabled"] as? Bool else { return true }
            overlays[output, default: [:]][overlay] = enabled
        } else if property == "/monitoring/zebra" {
            let zebra = BlackmagicRESTStateMapper.decode(value, as: ZebraResponse.self)
            zebraHighlightEnabled = zebra?.highlight?.enabled
            zebraLevel = zebra?.highlight?.level
        } else if property == "/monitoring/frameGuideRatio" {
            frameGuideRatio = BlackmagicRESTStateMapper.decode(value, as: FrameGuideRatioResponse.self)?.ratio
        } else {
            return false
        }
        // While the monitoring comes in, the state goes out once, at the end (`subscribeMonitoring`).
        if monitoringLoaded {
            if before != (overlays, zebraHighlightEnabled, zebraLevel, frameGuideRatio) { monitoringPushes += 1 }
            applyMonitoring(to: &state)
            emit()
        }
        return true
    }

    /// One property's value, pushed or in a subscription's answer.
    private func apply(property: String, value: Any) {
        if applyMonitoringValue(property: property, value: value) { return }
        if let (channel, leaf) = BlackmagicAudio.parse(property) {
            var report = audio[channel] ?? AudioReport()
            let input = report.input
            guard BlackmagicAudio.apply(leaf, value, to: &report) else { return }
            audio[channel] = report
            // Another input has its own gain range, switches and choices.
            if audioLoaded, leaf == "input", report.input != input { Task { await self.readAudioInput(channel) } }
            if audioLoaded { applyAudio() }
            return
        }
        if property == "/lens/focus/description" { focusDescribed = true }
        switch property {
        case "/livestreams/0":
            let status = (value as? [String: Any])?["status"] as? String
            if status != liveStreamStatus, liveStreamWanted || liveStreamFinish != nil, let status {
                ActivityLog.shared.note(host, "live view: stream \(status)")
            }
            liveStreamStatus = status
            return
        case "/livestreams/0/activePlatform":
            liveStreamPlatform = (value as? [String: Any])?["platform"] as? String
            return
        case "/livestreams/0/available":
            // Answered at all: the camera has a livestream, so live view can go through it.
            liveStreamAvailable = (value as? [String: Any])?["available"] as? Bool
            if !state.hasLiveView {
                state.hasLiveView = true
                emit()
            }
            return
        case "/system/format":
            guard var format = BlackmagicRESTStateMapper.decode(value, as: FormatResponse.self) else { return }
            // After playback a PYXIS pushes its format without the sensor window, which a format change must carry.
            if format.sensorResolution == nil {
                format.sensorResolution = SupportedFormat.matching(format, in: supportedFormats)?.sensorResolution
                    ?? currentFormat?.sensorResolution
            }
            currentFormat = format
            if let fr = format.frameRate { fps = parseFPS(fr) }
            BlackmagicRESTStateMapper.applyFormat(format, supported: supportedFormats, to: &state)
            emit()
            return
        case "/video/shutter":
            shutter = BlackmagicRESTStateMapper.decode(value, as: ShutterResponse.self) ?? shutter
            applyShutter()
            return
        case "/video/shutter/measurement":
            shutterMeasurement = BlackmagicRESTStateMapper.decode(value, as: ShutterMeasurementResponse.self) ?? shutterMeasurement
            applyShutter()
            return
        case "/video/supportedShutters":
            supportedShutters = BlackmagicRESTStateMapper.decode(value, as: SupportedShuttersResponse.self) ?? supportedShutters
            applyShutter()
            return
        default:
            break
        }
        if property == "/transports/0", let mode = (value as? [String: Any])?["mode"] as? String {
            let wasPlayback = transportMode == "Output"
            if mode != transportMode, liveStreamWanted { ActivityLog.shared.note(host, "live view: camera in \(mode)") }
            transportMode = mode
            // Back in live from playback, which stopped live view's stream: start it again now.
            if wasPlayback, mode != "Output", liveStreamWanted { Task { await self.restartStreamIfStopped() } }
            // And what presets hold, which isn't read during playback.
            if wasPlayback, mode != "Output" { Task { await self.readPreset() } }
            // Into playback with a clip the Clips window can't name yet (the read on connect failed): its names.
            if !wasPlayback, mode == "Output", clipUnnamed { Task { await self.readClipFiles() } }
        }
        if property == "/transports/0/clipIndex", let dict = value as? [String: Any] {
            lastClipIndex = dict["clipIndex"] as? Int
        }
        if property == "/timelines/0", let dict = value as? [String: Any],
           let clips = dict["clips"] as? [[String: Any]] {
            lastTimelineClips = clips.compactMap { d in
                guard let id = d["clipUniqueId"] as? Int else { return nil }
                return TimelineClip(uniqueId: id,
                                    frameCount: d["frameCount"] as? Int,
                                    timelineIn: d["timelineIn"] as? Int)
            }
            // The list changed while Review says it lacks the latest take: asked again.
            if state.playback?.latestTakeMissing == true { Task { await self.checkLatestTakeListed() } }
            // A take added: its file's name, for the Clips window.
            if clipUnnamed { Task { await self.readClipFiles() } }
        }
        let hadIris = state.iris != nil
        BlackmagicRESTStateMapper.applyEvent(property: property, value: value, to: &state)
        if property == "/timelines/0" || property == "/transports/0/clipIndex" { applyClipList() }
        // The settings set through a preset gray for a take, and come back after it, read again: a camera that was
        // rolling when Tiles connected hasn't had them read at all.
        if property == "/transports/0/record", monitoringLoaded {
            applyMonitoring(to: &state)
            if state.recording.state == .idle { Task { await self.readPreset() } }
        }
        emit()
        // A lens the camera can drive was just fitted: its aperture may have been pushed before its description said
        // so (and dropped then), so read it.
        if property == "/lens/iris/description", !hadIris, state.iris != nil { Task { await self.lensFitted() } }
    }

    private func lensFitted() async {
        guard let iris = try? await restClient.get("lens/iris", as: IrisResponse.self), let stop = iris.apertureStop else { return }
        apply(property: "/lens/iris", value: ["apertureStop": stop,
                                              "continuousApertureAutoExposure": iris.continuousApertureAutoExposure ?? false])
    }

    private func applyShutter() {
        BlackmagicRESTStateMapper.applyShutter(to: &state, shutter: shutter, measurement: shutterMeasurement,
                                               supported: supportedShutters)
        emit()
    }

    /// Re-anchors the local timecode clock: two reads half a second apart say where it is and whether it's running.
    private func syncTimecode() async {
        guard state.connection == .connected, let first = await readTimecode() else { return }
        try? await Task.sleep(for: .milliseconds(500))
        guard let second = await readTimecode(), let clock = clock(second, earlier: first, readAt: Date()) else { return }
        state.timecode = clock
        emit()
    }

    /// GET /system/dynamicRange: the camera takes a subscription to it but never pushes a change, so it's read after
    /// Tiles sets it and once a minute (a change made on the camera shows within a minute).
    private func readDynamicRange() async {
        guard state.dynamicRange != nil,
              let range = try? await restClient.get("system/dynamicRange", as: DynamicRangeResponse.self).dynamicRange,
              range != state.dynamicRange?.value else { return }
        apply(property: "/system/dynamicRange", value: ["dynamicRange": range])
    }

    /// Once a minute on a camera that answers tally over REST and not as a subscription.
    private func pollTally() async {
        if tallyPolled { await readTally() }
    }

    /// GET /camera/tallyStatus after Tiles sets it: the camera's word, whether or not it pushes the change (unchecked on a
    /// camera; a push and this read agree).
    private func readTally() async {
        guard let status = await read("camera/tallyStatus", as: TallyStatusResponse.self)?.status else { return }
        apply(property: "/camera/tallyStatus", value: ["status": status])
    }

    /// GET /transports/0/timecode: "15:08:53:05", or "…;05" drop frame.
    private func readTimecode() async -> String? {
        try? await restClient.get("transports/0/timecode", as: TimecodeResponse.self).display
    }

    /// A clock at `display`, read at `readAt`: running if it differs from the `earlier` read.
    private func clock(_ display: String, earlier: String, readAt: Date) -> TimecodeClock? {
        let parts = display.split(whereSeparator: { $0 == ":" || $0 == ";" }).compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        let rate = Int(fps.rounded())
        let frames = ((parts[0] * 60 + parts[1]) * 60 + parts[2]) * rate + parts[3]
        return TimecodeClock(frames: frames, anchor: readAt, rate: rate, fps: fps, isRunning: display != earlier)
    }

    // MARK: - Command dispatch

    private func dispatch(_ command: CameraCommand) async throws {
        switch command {

        case .record(let start):
            try await sendRecord(start)

        case .setISO(let iso):
            try await restClient.put("video/iso", body: ISOBody(iso: iso))

        case .setShutterAngle(let angle):
            // The API's shutter angle is ×100: 18000 is 180°.
            try await restClient.put("video/shutter", body: ShutterAngleBody(shutterAngle: Int((angle * 100).rounded())))

        case .setShutterSpeed(let label):
            if let denom = parseShutterSpeedLabel(label) {
                try await restClient.put("video/shutter", body: ShutterSpeedBody(shutterSpeed: denom))
            }

        case .setShutterMode(let mode):
            try await restClient.put("video/shutter/measurement",
                                     body: ShutterMeasurementBody(measurement: mode == .angle ? "ShutterAngle" : "ShutterSpeed"))

        case .setKelvin(let k):
            try await restClient.put("video/whiteBalance", body: WBBody(whiteBalance: Int(k)))

        case .setTint(let t):
            try await restClient.put("video/whiteBalanceTint", body: WBTintBody(whiteBalanceTint: Int(t)))

        case .setWhiteBalancePreset(let preset):
            // Auto takes the white balance from the middle of the picture, once; a preset is its Kelvin ("5600K").
            if preset == "Auto" {
                try await restClient.put("video/whiteBalance/doAuto", body: EmptyBody())
            } else if preset.hasSuffix("K"), let kelvin = Int(preset.dropLast()) {
                try await restClient.put("video/whiteBalance", body: WBBody(whiteBalance: kelvin))
            }

        case .setIris(let fstop):
            try await restClient.put("lens/iris", body: IrisBody(apertureStop: fstop))

        case .setNDPreset(let label):
            guard let stop = Stops.ndStops(label) else { return }
            try await restClient.put("video/ndFilter", body: NDBody(stop: stop))

        case .setFrameRate(let fr):
            try await changeFormat { $0.frameRate = fr }

        case .setFrameRateVariable(let on):
            try await changeFormat { $0.offSpeedEnabled = on }

        case .setFileFormat(let label):
            if let format = currentFormat, format.codec != nil {
                // "BRAW 8:1" back to the camera's "BRaw:8_1".
                let codecs = SupportedFormat.matching(format, in: supportedFormats)?.codecs ?? []
                guard let raw = codecs.first(where: { BlackmagicRESTStateMapper.codecLabel($0) == label }) else { break }
                try await changeFormat { $0.codec = raw }
            } else {
                // A camera with its own codec endpoint: "codec / container".
                let parts = label.components(separatedBy: " / ")
                if parts.count == 2 {
                    try await restClient.put("system/codecFormat", body: CodecBody(codec: parts[0], container: parts[1]))
                }
            }

        case .setResolution(let label):
            // A recording area keeps the frame rate and codec where it allows them, else takes the nearest it has.
            guard let entry = supportedFormats.first(where: { $0.label == label }) else { break }
            try await changeFormat { format in
                format.recordResolution = entry.recordResolution
                format.sensorResolution = entry.sensorResolution
                format.frameRate = format.frameRate.flatMap { SupportedFormat.nearestFrameRate(to: $0, in: entry.frameRates) }
                format.codec = format.codec.flatMap { SupportedFormat.nearestCodec(to: $0, in: entry.codecs) }
                if let off = format.offSpeedFrameRate, let low = entry.minOffSpeedFrameRate, let high = entry.maxOffSpeedFrameRate {
                    format.offSpeedFrameRate = min(max(off, low), high)
                }
            }

        case .setBaseISO:
            // UNVERIFIED ON HARDWARE: dual native ISO may not be switchable via REST.
            // The REST API only has PUT /video/iso with an absolute value.
            break

        case .setLUT(let name):
            // Not in the API (it switches the LUT on and off, not which): through a preset, by the LUT's file name.
            try await setLUT(name)

        case .setDesqueeze(let factor):
            // Not in the API: through a preset.
            pendingDesqueeze = factor
            try await changePreset { file, _ in try file.setDesqueeze(factor) }

        case .setClipCameraID(let letter):
            try await changeSlate(SlateUpdate(project: .init(camera: letter)))

        case .setClipReel(let reel):
            try await changeSlate(SlateUpdate(clip: .init(reel: reel)))

        case .setClipCameraPosition, .setTimecodeShowsDuration:
            break  // a VENICE's: the Blackmagic REST API has neither
        case .setClipTitle:
            break  // a Blackmagic clip name has no title

        case .setFocusMode:
            // No dedicated focus mode toggle confirmed. UNVERIFIED ON HARDWARE.
            break

        case .setFalseColor(let on):
            try await setOverlay(.falseColor, on, output: nil)

        case .setLook(let on):
            try await setOverlay(.lut, on, output: nil)

        case .setMonitorOverlay(.statusText, let on, let output):
            try await setStatusText(on, output: output)

        case .setMonitorOverlay(let overlay, let on, let output):
            try await setOverlay(overlay, on, output: output)

        case .setStatusTextContent(let content, let output):
            pendingContent[output] = content
            try await changePreset { file, outputs in
                guard let index = outputs.firstIndex(of: output) else { throw PresetError.unexpected }
                try file.setStatusTextContent(content, output: index)
            }

        case .setZebraLevel(let level):
            // The highlight zebra goes back whole, with its on/off as last reported: unknown, it isn't sent at all, so
            // a level can't switch zebra on.
            guard let enabled = zebraHighlightEnabled else { break }
            try await restClient.put("monitoring/zebra", body: ZebraBody(highlight: .init(enabled: enabled, level: level)))

        case .setFrameGuideRatio(let ratio):
            try await restClient.put("monitoring/frameGuideRatio", body: FrameGuideRatioBody(ratio: ratio))

        case .setDynamicRange(let range):
            try await restClient.put("system/dynamicRange", body: DynamicRangeBody(dynamicRange: range))
            await readDynamicRange()

        case .setFrameRateVariableRate(let rate):
            try await changeFormat { $0.offSpeedFrameRate = rate }

        case .setColorBars(let on):
            try await restClient.put("camera/colorBars", body: MonitoringEnabledBody(enabled: on))

        case .setImageFlip, .setClipFlag, .setRecordingSetting, .setVariableND, .setHDMIInfo, .setGridLines:
            break

        case .playback(let cmd):
            try await dispatchPlayback(cmd)

        case .setTally(let value):
            guard let status = BlackmagicRESTStateMapper.tallyStatuses[value] else {
                ActivityLog.shared.note(host, "tally \(value) not sent: it's Off, Green or Red")
                break
            }
            try await restClient.put("camera/tallyStatus", body: TallyBody(status: status))
            await readTally()

        case .autoFocus:
            try await restClient.put("lens/focus/doAutoFocus", body: AutoFocusBody())

        case .grabStill:
            await grabStill()

        case .setAudio(let channel, let setting):
            try await setAudio(channel, setting)

        case .setNDMode, .setCall, .setColorGamut, .pressCameraButton, .setUserFrameLines, .setFrameLineSet,
             .setShootingMode, .setGain, .setBaseSensitivity, .setRecordedLUT, .setProxyRecording, .setECS, .stepECS, .setIrisAuto,
             .setNDAuto, .setISOAuto, .driveFocus, .driveZoom, .pressAssignable, .setOutputFollows, .setSteadyShot, .setImagerMode,
             .setSubjectRecognition, .setFocusArea, .setAFTransitionSpeed, .setAFSubjectShift, .setAFAssist:
            break  // a BURANO's, a VENICE's, an FX6's or an FX5's: the Blackmagic REST API has none of them
        }
    }

    // MARK: - Still

    /// A still to the card: POST transports/0/doStillCapture (the REST API from camera 10.1: 204 started, 404 no still
    /// capture on this device, 500 failed with the reason). What came is `lastStill`; a 404 or 501 takes the tile away.
    /// A PYXIS on 10.2 is said to answer this with an error while its own still button works.
    func grabStill() async {
        do {
            try await restClient.post("transports/0/doStillCapture")
            state.lastStill = StillGrab(saved: true)
            ActivityLog.shared.note(host, "still: saved to the card")
        } catch BlackmagicError.http(404, _), BlackmagicError.notImplemented {
            noStillCapture = true
            state.canGrabStill = false
            state.lastStill = StillGrab(saved: false, message: "This camera takes no still over the network")
            ActivityLog.shared.note(host, "still: none on this camera (404)")
        } catch {
            let reason: String
            switch error {
            case BlackmagicError.http(_, let text), BlackmagicError.forbidden(let text): reason = text
            default: reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            state.lastStill = StillGrab(saved: false, message: reason.isEmpty ? "The camera didn't save it" : reason)
            ActivityLog.shared.note(host, "still: not saved: \(reason)")
        }
        emit()
    }

    // MARK: - Playback commands (REST API)

    private func dispatchPlayback(_ cmd: PlaybackCommand) async throws {
        playbackCommandCount += 1
        let command = playbackCommandCount
        switch cmd {
        case .play:
            // Switch to Output mode if needed, then start playing
            try await ensureOutputMode()
            try await restClient.post("transports/0/play")

        case .pause:
            // In Output mode, stop pauses at the current position.
            try await restClient.post("transports/0/stop")

        case .togglePlay:
            if state.playback?.isPlaying == true {
                try await restClient.post("transports/0/stop")
            } else {
                try await ensureOutputMode()
                try await restClient.post("transports/0/play")
            }

        case .stop:
            try await restClient.post("transports/0/stop")

        case .live:
            try await restClient.put("transports/0", body: TransportModeBody(mode: "InputPreview"))

        case .review:
            // Not during a take: the tile holds its switch back then too. Then the last take, playing: Review is for
            // checking what was just shot.
            guard state.recording.state == .idle else { break }
            try await ensureOutputMode()
            let take = try await goToLastClip(command)
            guard command == playbackCommandCount else { break }
            try await restClient.post("transports/0/play")
            if let take { try await keepOn(take, command) }
            await checkLatestTakeListed()

        case .next:
            try await ensureOutputMode()   // seeking from live goes into playback first
            guard let idx = lastClipIndex else { break }
            let nextIdx = idx + 1
            guard nextIdx < lastTimelineClips.count else { break }
            try await seek(to: lastTimelineClips[nextIdx].timelineIn ?? 0)

        case .previous:
            try await ensureOutputMode()   // seeking from live goes into playback first
            guard let idx = lastClipIndex else { break }
            let currentPos = await playbackPosition()
            let clipStart = lastTimelineClips[safe: idx]?.timelineIn ?? 0
            let oneSec = Int((fps).rounded())
            // If more than 1 s into the current clip, go to its start; otherwise go to previous clip start
            if currentPos > clipStart + oneSec, let start = lastTimelineClips[safe: idx]?.timelineIn {
                try await seek(to: start)
            } else if idx > 0 {
                try await seek(to: lastTimelineClips[safe: idx - 1]?.timelineIn ?? 0)
            }

        case .skip(let seconds):
            try await ensureOutputMode()   // seeking from live goes into playback first
            let currentPos = await playbackPosition()
            let totalFrames = lastTimelineClips.reduce(0) { $0 + ($1.frameCount ?? 0) }
            let delta = Int((seconds * fps).rounded())
            let newPos = min(max(0, currentPos + delta), max(0, totalFrames - 1))
            try await seek(to: newPos)

        case .goToClip(let index):
            // The clip the Clips window picked, playing from its start. Found again by its id in a fresh read of the
            // playback list, so a take added meanwhile doesn't move it. Not during a take, as Review.
            guard state.recording.state == .idle else { break }
            let id = lastTimelineClips[safe: index]?.clipUniqueId
            try await ensureOutputMode()
            let take = try await goToClip("Clips", command) { clips in
                id.flatMap { id in clips.firstIndex { $0.clipUniqueId == id } } ?? (clips.indices.contains(index) ? index : nil)
            }
            guard let take, command == playbackCommandCount else { break }
            try await restClient.post("transports/0/play")
            try await keepOn(take, command)

        case .fastForward, .rewind, .recReview, .scan, .endScan:
            break  // not supported on Blackmagic
        }
    }

    /// A clip on the playback list that `clipFiles` hasn't a name for.
    private var clipUnnamed: Bool {
        lastTimelineClips.contains { $0.clipUniqueId.map { clipFiles[$0] == nil } ?? false }
    }

    /// The playback list as the Clips window shows it (`PlaybackState.clips`): the timeline's clips in its order, named
    /// by their files (`clipFiles`) and timed at the project's rate; and the open clip's name on the Playback tile.
    private func applyClipList() {
        guard state.playback != nil else { return }
        let clips = lastTimelineClips.enumerated().map { i, clip in
            PlaybackClip(id: i, name: clip.clipUniqueId.flatMap { clipFiles[$0] },
                         seconds: clip.frameCount.map { Double($0) / max(fps, 1) })
        }
        let open = state.playback?.clipNumber.flatMap { clips[safe: $0 - 1]?.name }
        state.playback?.clips = clips
        state.playback?.clipName = open
    }

    /// The names of the card's clips (`GET /clips`): read once connected, and when the playback list has a clip it
    /// hasn't named (a take added, or a read that failed) as it changes or playback starts. One read at a time. No card,
    /// no names: the Clips window numbers them.
    private func readClipFiles() async {
        guard !readingClipFiles else { return }
        readingClipFiles = true
        defer { readingClipFiles = false }
        guard let data = try? await restClient.get("clips"),
              let clips = (try? JSONDecoder().decode(ClipList.self, from: data))?.clips else { return }
        clipFiles = Dictionary(clips.compactMap { clip in
            clip.clipUniqueId.flatMap { id in clip.filePath.flatMap(ClipList.clipName).map { (id, $0) } }
        }, uniquingKeysWith: { first, _ in first })
        applyClipList()
        emit()
    }

    /// PUT /system/format with the current format and one change: the camera refuses a single field, or a format
    /// without its sensor window ("Invalid format").
    private func changeFormat(_ change: (inout FormatRequest) -> Void) async throws {
        guard let format = currentFormat else { return }
        var request = FormatRequest(format)
        change(&request)
        try await restClient.put("system/format", body: request)
    }

    /// To the last clip of the camera's playback list, read afresh rather than as it was last pushed, and checked: a seek
    /// the camera doesn't keep is sent again, up to three times. A PYXIS 12K over HaLow played the clip last pulled
    /// up rather than the latest take — the camera moved back to where it last was, over the seek or instead of it.
    /// Returns the clip's frames, for `keepOn`.
    private func goToLastClip(_ command: Int) async throws -> Range<Int>? {
        try await goToClip("Review", command) { $0.isEmpty ? nil : $0.count - 1 }
    }

    /// To the clip `pick` chooses from the playback list, read afresh, as `goToLastClip` (`what`: whose, for the Activity
    /// Log). It stops, nil, once a later playback command has come (`command`, `playbackCommandCount`). Returns the
    /// clip's frames, for `keepOn`.
    private func goToClip(_ what: String, _ command: Int, _ pick: ([TimelineClip]) -> Int?) async throws -> Range<Int>? {
        if let data = try? await restClient.get("timelines/0"),
           let clips = (try? JSONDecoder().decode(TimelineResponse.self, from: data))?.clips, !clips.isEmpty {
            lastTimelineClips = clips
            applyClipList()
        }
        guard let index = pick(lastTimelineClips), let clip = lastTimelineClips[safe: index],
              let start = clip.timelineIn else { return nil }
        let take = start..<(start + max(clip.frameCount ?? 1, 1))
        for _ in 0..<3 {
            guard command == playbackCommandCount else { return nil }
            try await seek(to: start)
            try? await Task.sleep(for: .milliseconds(350))
            if take.contains(await playbackPosition()) { return take }
        }
        guard command == playbackCommandCount else { return nil }
        let which = index == lastTimelineClips.count - 1 ? "the last clip" : "clip \(index + 1)"
        ActivityLog.shared.note(host, "\(what): the camera didn't stay on \(which) of its list (sent frame \(start), "
            + "it's at \(await playbackPosition()))")
        return take
    }

    /// Once playing, still on `take`: a camera that moved back to where it last was after the seek is sent to the take
    /// again (the seek keeps the speed), unless another playback command has come since (`command`).
    private func keepOn(_ take: Range<Int>, _ command: Int) async throws {
        try? await Task.sleep(for: .milliseconds(500))
        let at = await playbackPosition()
        // Playing on into the take, or just past its end at a fast speed, is where it should be. A later playback
        // command (another pick, Live) has the camera now.
        guard command == playbackCommandCount, !take.contains(at),
              !(take.upperBound..<(take.upperBound + 48)).contains(at) else { return }
        ActivityLog.shared.note(host, "Playback: the camera moved to frame \(at) after the seek to its clip (\(take.lowerBound)); sent again")
        try await seek(to: take.lowerBound)
    }

    /// Whether the latest take on the card (the highest `clipUniqueId` in `/clips`) is on the list the camera plays from
    /// (`/timelines/0`). The camera keeps that list itself and a PYXIS won't let it be changed (501): one built from
    /// clips in another format leaves later takes off it, so Review shows an older clip, while the camera's own Play
    /// button shows the latest (docs/pyxis-controls.md, Playback). Said in the Playback tile and the Activity Log.
    func checkLatestTakeListed() async {
        guard !lastTimelineClips.isEmpty, let data = try? await restClient.get("clips"),
              let latest = (try? JSONDecoder().decode(ClipList.self, from: data))?.clips?.compactMap(\.clipUniqueId).max()
        else { return }
        let missing = !lastTimelineClips.contains { $0.clipUniqueId == latest }
        guard state.playback?.inReview == true || !missing, state.playback?.latestTakeMissing != missing else { return }
        state.playback?.latestTakeMissing = missing
        if missing {
            ActivityLog.shared.note(host, "Review: the camera's playback list doesn't have the latest take on its card, so "
                + "it plays an older clip; Play on the camera itself shows the latest")
        }
        emit()
    }

    /// PUT /slates/nextClip with one field. The camera pushes the new slate; a value it won't take comes back with its
    /// reason, shown in the Naming sheet.
    private func changeSlate(_ update: SlateUpdate) async throws {
        if state.fileNaming?.failure != nil {
            state.fileNaming?.failure = nil
            emit()
        }
        do {
            try await restClient.put("slates/nextClip", body: update)
        } catch BlackmagicError.http(_, let reason) {
            state.fileNaming?.failure = reason
            emit()
        }
    }

    /// One overlay on one output, or on every output that reported it (not one the camera can't report, like the
    /// PYXIS's stream output) and can show it: an output on clean feed is left as it is, as `onEverywhere` leaves it
    /// out. Right after connect it waits for the outputs to answer. One output that refuses doesn't stop the rest.
    private func setOverlay(_ overlay: MonitorOverlay, _ on: Bool, output: String?) async throws {
        if output == nil, !monitoringLoaded { try? await wait { monitoringLoaded } }
        let targets = output.map { [$0] } ?? displayNames.filter { name in
            guard let reported = overlays[name], reported[overlay] != nil else { return false }
            return !(overlay.hiddenByCleanFeed && reported[.cleanFeed] == true)
        }
        var firstError: Error?
        for name in targets {
            do { try await restClient.put(monitoringPath(name, overlay.restLeaf), body: MonitoringEnabledBody(enabled: on)) }
            catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }

    // MARK: - Settings through a preset (BlackmagicPreset.swift)

    /// The presets Tiles reads the camera's state through and loads changes from, each deleted after use.
    private static let readPresetName = "TilesRead.cset", changePresetName = "TilesChange.cset"

    /// The outputs a preset lists, in its order: those the API reports overlays for (not the PYXIS's stream output).
    private var presetOutputs: [String] { displayNames.filter { overlays[$0]?.isEmpty == false } }

    /// The model whose presets were taken apart. Another could keep something else in the same fields, so its presets
    /// are left alone.
    private var isPYXIS: Bool { state.model?.localizedCaseInsensitiveContains("PYXIS") == true }

    /// Software whose presets were checked on the camera, field by field (scripts/cset/csetprobe.py).
    static let checkedSoftware: Set<String> = ["10.3.1"]
    /// `checkedSoftware`, or none when camctl asks for what other software gets (`useLayoutCheck`).
    private var checkedSoftware = BlackmagicCameraBackend.checkedSoftware
    /// Other software's presets have been found laid out as checked software's on this connection
    /// (`PresetFile.layoutMismatch`): the layout is the software's, so once is enough.
    private var presetsMatchLayout = false

    /// Whether Tiles goes through this camera's presets: a PYXIS on software they were checked on, or on other software
    /// whose presets are laid out the same. Blackmagic puts out new camera software every few weeks, mostly for other
    /// models, and a list of versions alone would turn these settings off on each update.
    private var presetsKnown: Bool {
        isPYXIS && (checkedSoftware.contains(softwareVersion ?? "") || presetsMatchLayout)
    }

    /// For camctl: the check other software gets, on a camera running software Tiles has checked.
    public func useLayoutCheck() { checkedSoftware = [] }

    /// The camera's state now, as a preset: saved under Tiles' name, read, and deleted again. The camera answers the save
    /// before it has written the file, and takes longer just after loading a preset (a read then got the previous file,
    /// and the file came back after it was deleted: PYXIS 12K, Camera 10.3.1), so the read waits for this one.
    private func savePreset() async throws -> PresetFile {
        let path = "presets/\(Self.readPresetName)"
        try? await restClient.delete(path)
        try await restClient.putEmpty(path)
        let deadline = ContinuousClock.now + .seconds(3)
        var data: Data?
        while data == nil {
            do {
                data = try await restClient.get(path)
            } catch BlackmagicError.http(404, _) where ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try? await restClient.delete(path)
        return try PresetFile(data ?? Data())
    }

    /// Whether a preset read is the whole file. The camera writes it after answering the save, so a read can catch it
    /// part-written, and loading a part of the camera's state could reset the rest. A file cut inside a field doesn't
    /// parse; one cut between sections does, so a read must have every section the fullest read so far had.
    private func isWhole(_ file: PresetFile) -> Bool {
        let names = file.sectionNames
        guard let known = presetLayout else {
            presetLayout = names
            return true
        }
        if names == known { return true }
        if names.count > known.count, Array(names.prefix(known.count)) == known {
            presetLayout = names
            return true
        }
        return false
    }

    /// Reads what the API hasn't got from a preset of the camera's state: after connect, once a minute (a change made on
    /// the camera shows within a minute), after each take, on leaving playback and after Tiles changes it. Not during a
    /// take or playback.
    /// On software Tiles hasn't checked, the preset must be laid out as checked software's first, and the Activity Log
    /// says which way it went: the one report a tester can send when De-squeeze or status text isn't there.
    private func readPreset() async {
        // Not during playback either: a save there hasn't been tried. Leaving playback reads it (`apply(property:)`).
        guard state.connection == .connected, monitoringLoaded, isPYXIS, state.recording.state != .recording,
              transportMode != "Output", !presetBusy else { return }
        presetBusy = true
        defer { presetBusy = false }
        let file: PresetFile
        do {
            file = try await savePreset()
        } catch {
            note("presetRead", "no preset of the camera's state, so no De-squeeze, status text or LUT yet: \(error)")
            return
        }
        guard isWhole(file) else { return }
        if !presetsKnown {
            let software = "Camera \(softwareVersion ?? "software unknown")"
            let outputs = presetOutputs.map { (name: BlackmagicRESTStateMapper.outputName($0), overlays: overlays[$0] ?? [:]) }
            // Each reason once: an overlay changed on the camera between the API's report and the preset can fail a
            // check that the next one passes, and the log shouldn't read as a verdict.
            if let mismatch = file.layoutMismatch(outputs: outputs) {
                note("presetLayout " + mismatch, "\(software): its presets don't match 10.3.1's layout (\(mismatch)); "
                     + "De-squeeze, status text and the LUT stay off, checked again each minute")
                return
            }
            presetsMatchLayout = true
            note("presetLayoutMatched", "\(software): its presets match 10.3.1's layout; De-squeeze, status text and "
                 + "the LUT go through them")
        }
        applyPreset(PresetSettings(file))
    }

    private func applyPreset(_ settings: PresetSettings) {
        guard settings != preset else { return }
        preset = settings
        if let lut = settings.lut, !knownLUTs.contains(lut) { knownLUTs = Self.lutList(knownLUTs + [lut]) }
        applyMonitoring(to: &state)
        emit()
    }

    /// Changes settings the API hasn't got: the camera's state saved as a preset, changed there, and loaded back, so only
    /// that changes. The camera loads it a moment after answering, so the state is read until the change shows (as REC
    /// waits for the camera), and the preset deleted after. Between takes only. `change` gets the outputs in the preset's
    /// order.
    private func changePreset(_ change: (inout PresetFile, [String]) throws -> Void) async throws {
        // What's on its way shows straight away, and goes when the camera's state has been read back after the last
        // change, landed or not.
        presetChanges += 1
        applyMonitoring(to: &state)
        emit()
        defer {
            presetChanges -= 1
            if presetChanges == 0 {
                pendingStatusText = [:]
                pendingContent = [:]
                pendingDesqueeze = nil
                pendingLUT = nil
            }
            applyMonitoring(to: &state)
            emit()
        }
        guard state.recording.state == .idle else { throw BlackmagicError.forbidden("Not during a take") }
        let outputs = presetOutputs
        guard presetsKnown, let preset, preset.statusText.count == outputs.count else { throw BlackmagicError.notImplemented }
        // One at a time: a change saved before the last one landed would load the state without it.
        while presetBusy { try await Task.sleep(for: .milliseconds(50)) }
        presetBusy = true
        defer { presetBusy = false }
        // The state the change goes on: the whole of it, or the camera would load part of its state (three tries).
        let pushesAtCopy = monitoringPushes
        var base: PresetFile?
        for _ in 0..<3 where base == nil {
            if let file = try? await savePreset(), isWhole(file) { base = file }
        }
        guard let original = base else { throw PresetError.unreadable }
        var file = original
        try change(&file, outputs)
        let wanted = PresetSettings(file)
        // Only the section the change is in goes back, whole: the camera leaves the rest of its state alone.
        let changed = file.sectionsChanged(from: original)
        guard !changed.isEmpty else { return }
        let answer = try await restClient.upload("presets", data: try file.only(changed).data, filename: Self.changePresetName)
        // The camera names an upload after the file, or that with a number if it has one of that name. Only the name
        // it gave is loaded: any other could be an old state left on the camera.
        guard let added = (try? JSONDecoder().decode(PresetAddedResponse.self, from: answer))?.presetAdded else {
            throw PresetError.unexpected
        }
        var read: PresetSettings?
        do {
            // A take started since the change was asked for (on the camera, or REC here): it isn't loaded mid-take.
            guard state.recording.state == .idle, state.recording.request == nil else {
                throw BlackmagicError.forbidden("Not during a take")
            }
            // Monitoring changed on the camera since the copy was made: loading the copy would undo that.
            guard !changed.contains("metering") || monitoringPushes == pushesAtCopy else {
                ActivityLog.shared.note(host, "monitoring changed on the camera during a change through a preset; not loaded")
                throw BlackmagicError.forbidden("Monitoring changed meanwhile")
            }
            try await restClient.put("presets/active", body: ActivePresetBody(preset: "\(added).cset"))
            let deadline = ContinuousClock.now + .seconds(4)
            while read != wanted, ContinuousClock.now < deadline, state.recording.state == .idle {
                if let now = try? await savePreset(), isWhole(now) { read = PresetSettings(now) }
                if read != wanted { try? await Task.sleep(for: .milliseconds(100)) }
            }
        } catch {
            try? await restClient.delete("presets/\(added).cset")
            throw error
        }
        try? await restClient.delete("presets/\(added).cset")
        if let read { applyPreset(read) }
        if read != wanted, state.recording.state == .idle {
            ActivityLog.shared.note(host, "a change through a preset didn't show in the camera's state")
        }
    }

    /// The LUT in use, by name. The camera ignores a name it hasn't got (one deleted since, say): the change doesn't
    /// show, and the name comes off the list until the camera is seen using it again.
    private func setLUT(_ name: String) async throws {
        guard !name.isEmpty else { return }
        pendingLUT = name
        try await changePreset { file, _ in try file.setLUT(name) }
        guard state.recording.state == .idle, preset?.lut != name, let index = knownLUTs.firstIndex(of: name) else { return }
        knownLUTs.remove(at: index)
        ActivityLog.shared.note(host, "the camera hasn't got the LUT \(name); taken off the list")
        applyMonitoring(to: &state)
        emit()
    }

    /// LUT names, each once and in order ("Film Look" before "Film to Video"), none empty.
    static func lutList(_ names: [String]) -> [String] {
        Array(Set(names.filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Status text on one output, or on every output that can show it (one on clean feed is left out, as `onEverywhere`
    /// leaves it out), in one preset.
    private func setStatusText(_ on: Bool, output: String?) async throws {
        let targets = output.map { [$0] } ?? presetOutputs.filter { overlays[$0]?[.cleanFeed] != true }
        for name in targets { pendingStatusText[name] = on }
        try await changePreset { file, outputs in
            for name in targets {
                guard let index = outputs.firstIndex(of: name) else { throw PresetError.unexpected }
                try file.setStatusText(on, output: index)
            }
        }
    }

    /// Where playback is, in timeline frames. Read when a command needs it: the camera pushes it every frame.
    private func playbackPosition() async -> Int {
        (try? await restClient.get("transports/0/playback", as: PlaybackResponse.self).position) ?? 0
    }

    /// Into playback. The switch takes most of a second, and play or a seek before it lands is "Invalid state", so
    /// this waits for the camera to push the new mode.
    private func ensureOutputMode() async throws {
        if transportMode == "Output" { return }
        try await restClient.put("transports/0", body: TransportModeBody(mode: "Output"))
        let deadline = ContinuousClock.now + .seconds(3)
        while transportMode != "Output", ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// PUT /transports/0/playback with the position alone, which leaves the speed as it is.
    private func seek(to framePos: Int) async throws {
        try await restClient.put("transports/0/playback", body: SeekBody(position: framePos))
    }

    private func parseFPS(_ fr: String) -> Double {
        switch fr {
        case "23.98": return 24000.0 / 1001.0
        case "29.97": return 30000.0 / 1001.0
        case "47.95": return 48000.0 / 1001.0
        case "59.94": return 60000.0 / 1001.0
        default: return Double(fr) ?? 24
        }
    }

    // MARK: - REC

    private func sendRecord(_ start: Bool) async throws {
        // REC is absolute: if already in the target state, do nothing (architecture rule).
        let current = state.recording.state
        if start && current == .recording { return }
        if !start && current == .idle { return }

        state.recording.request = start ? .start : .stop
        emit()

        // POST both: the PUT forms are deprecated in Camera 10.1's TransportControl.yaml, "will be removed".
        try await restClient.post(start ? "transports/0/record" : "transports/0/stop")

        // Wait for WS confirmation (camera pushes /transports/0/record)
        await waitForRecordConfirmation(start: start)
    }

    private func waitForRecordConfirmation(start: Bool) async {
        // The WebSocket push for /transports/0/record clears the request (`apply`). Checked on the
        // actor's own state every 50 ms: a Task.yield loop here spun a core for the whole timeout.
        let deadline = ContinuousClock.now + .seconds(recConfirmTimeout)
        while ContinuousClock.now < deadline {
            if state.recording.request == nil { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Timeout: re-read from REST rather than resending
        if let rec = try? await restClient.get("transports/0/record", as: RecordResponse.self) {
            state.recording.state = rec.recording ? .recording : .idle
        }
        if state.recording.request != nil {
            state.recording.request = nil
            state.recording.failure = RecordingControl.Failure.notConfirmed(start: start)
        }
        emit()
    }

    // MARK: - Helpers

    private func tryGet<T: Decodable & Sendable>(_ path: String, as type: T.Type) async -> T? {
        try? await restClient.get(path, as: type)
    }

    /// Build a monitoring path with percent-encoded display name.
    private func monitoringPath(_ name: String, _ leaf: String) -> String {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return "monitoring/\(encoded)/\(leaf)"
    }

    private func setConnection(_ conn: ConnectionState) async {
        state.connection = conn
        emit()
    }

    private func emit() {
        continuation.yield(state)
    }

    private func parseShutterSpeedLabel(_ label: String) -> Int? {
        // "1/50" → 50
        let parts = label.components(separatedBy: "/")
        guard parts.count == 2, let denom = Int(parts[1]) else { return nil }
        return denom
    }

}

// MARK: - PUT/POST body types

private struct TransportModeBody: Encodable { let mode: String }

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

private struct ISOBody: Encodable { let iso: Int }
private struct ShutterAngleBody: Encodable { let shutterAngle: Int }
private struct ShutterSpeedBody: Encodable { let shutterSpeed: Int }
private struct ShutterMeasurementBody: Encodable { let measurement: String }
private struct SeekBody: Encodable { let position: Int }
private struct WBBody: Encodable { let whiteBalance: Int }
private struct WBTintBody: Encodable { let whiteBalanceTint: Int }
private struct IrisBody: Encodable { let apertureStop: Double }
private struct NDBody: Encodable { let stop: Double }
private struct CodecBody: Encodable { let codec: String; let container: String }
private struct MonitoringEnabledBody: Encodable { let enabled: Bool }
private struct ZebraBody: Encodable {
    struct Highlight: Encodable { let enabled: Bool; let level: Int }
    let highlight: Highlight
}
private struct FrameGuideRatioBody: Encodable { let ratio: String }
private struct DynamicRangeBody: Encodable { let dynamicRange: String }
private struct TallyBody: Encodable { let status: String }
private struct ActivePresetBody: Encodable { let preset: String }
private struct PresetAddedResponse: Decodable { let presetAdded: String }

extension MonitorOverlay {
    /// The API has it: everything but status text, which goes through a preset, and audio meters (a VENICE's).
    var isREST: Bool { self != .statusText && self != .audioMeters }
}



