// SonyCameraBackend — actor conforming to CameraBackend. Implements Architecture rules 1–7.

import Foundation
import Network
import CameraCore
import SSHTunnel

// MARK: - Backend Configuration

public struct SonyBackendConfig: Sendable {
    public var transport: PTPIPTransportConfig = PTPIPTransportConfig()
    public var session: SessionConfig = SessionConfig()
    /// How long to wait for REC confirmation before re-reading state [Architecture rule 6]
    public var recConfirmTimeout: TimeInterval = 5.0
    /// Batch window for coalescing property-changed events before fetching [Architecture rule 5]
    public var eventBatchWindow: TimeInterval = 0.1
    /// Safety-net changed-only fetch. Events (0xC203) do the real work: Sony says they're reliable on 2019+ bodies
    /// as long as the event channel is always read. On a real FX3 every changed-only fetch
    /// costs ~426 B even when nothing moved (ten properties are always reported), and a 0.2 s poll made idle cost
    /// ~1 KB/s. Idle, the FX3 sent one event in 18 s. At 30 s the camera's own 10 s keepalive probes still
    /// maintain the link, so a missed event is caught within 30 s — acceptable for a safety-net fallback.
    public var pollInterval: TimeInterval = 30
    /// How long a tapped ◀◀ / ▶▶ scans before playing on (button-played bodies). 1 s measured +2–3 s on the FX3; its
    /// scan speeds up the longer it runs.
    public var skipScanTime: TimeInterval = 1.5
    /// How a camera on USB is reached: straight over USB (a Mac app may open the device), or through ImageCaptureCore
    /// (the only way on iPhone and iPad).
    public var usbLink: USBLink = .platformDefault
    /// Live view through the camera's own stream (an FX5: `streamsLiveView`). Off in the app until it has worked on a
    /// camera; camctl and the tests turn it on.
    public var streamLiveView = false

    public init() {}
}

public enum USBLink: Sendable {
    case direct
    case imageCapture

    public static var platformDefault: USBLink {
        #if os(macOS)
        .direct
        #else
        .imageCapture
        #endif
    }
}

// MARK: - SonyCameraBackend

/// Actor-based Sony backend, over PTP-IP (a host, with Access Authentication's SSH tunnel or pairing) or, on a Mac,
/// PTP over USB (a host of the form `usb:<serial>`). The transport serializes transactions.
/// This actor owns connection state and CameraState. [Architecture rule 1]
public actor SonyCameraBackend: CameraBackend, LUTImportCapable {

    public nonisolated let updates: AsyncStream<CameraState>
    private nonisolated let continuation: AsyncStream<CameraState>.Continuation

    let host: String
    let config: SonyBackendConfig
    let identityStore: any InitiatorIdentityStore
    private let recorder: (any TrafficRecorder)?
    /// SSH username for Access Authentication; nil = direct (pairing mode).
    private let sshUsername: String?
    /// Password for SSH (Access Auth) or PTP-IP pairing.
    private let password: String?
    /// SSH host key fingerprint trusted by the user; nil = trust-on-first-use.
    private let trustedFingerprint: String?

    var transport: (any PTPTransport)?
    private var session: PTPIPSession?
    var sessionInfo: SessionInfo?
    /// Active SSH tunnel; non-nil when using Access Authentication.
    private var sshForwarder: SSHPortForwarder?

    var state = CameraState()
    /// Keyed by property code so duplicate codes from the camera never trap.
    var rawProps: [UInt16: SDIDevicePropInfo] = [:]
    /// Bumped by every connect() and disconnect(). A connect still in flight when a newer call arrives gives up
    /// without touching state, so overlapping calls can't leave two transports talking to one camera.
    var attempt = 0
    /// True once session.open() has returned (SDIO_Connect phase 3 done). The FX3 doesn't answer a property read
    /// before that: the read holds the transport until it times out (30 s). Over HaLow a prop-changed event can
    /// land mid-setup and its batch fetch would go out first, leaving every tile on "—". Reads wait for this flag;
    /// the first full read after setup covers anything those events reported.
    var sessionReady = false
    var lutNames: [UInt16: String] = [:]   // BaseLook display names
    var baseISONames: [UInt8: Int] = [:]   // Gain Base ISO value → ISO number, type-8 display strings
    /// An FX6's assignable button functions by index, in the camera's short words (display list 0x0B).
    var assignableNames: [UInt16: String] = [:]
    /// The camera's own names for its Subject Recognition AF values (display list 0x15): an FX5's Human, Animal, Bird.
    var subjectNames: [UInt16: String] = [:]
    /// Lens motors driving now: the speed sent and when a held control last renewed it (`drive`).
    var lensDrives: [SDIControlCode: (speed: Int, renewed: ContinuousClock.Instant)] = [:]
    var lensWatchdog: Task<Void, Never>?
    /// Motors that were driving when the session ended, or whose 0 the camera didn't answer: told 0 again as soon as
    /// there's a session.
    var drivesToStop: Set<SDIControlCode> = []
    /// Assignable buttons whose Up the camera didn't answer: let go as soon as there's a session.
    var buttonsToRelease: Set<UInt16> = []
    /// Tracks whether a terminal state (.failed/.disconnected) has been emitted to prevent duplicates.
    private var terminalEmitted = false
    /// The last connection state written to the activity log.
    private var loggedConnection: ConnectionState?

    // Tracks in-flight fetch to avoid concurrent fetches [Architecture rule 5]
    var fetchInFlight: Bool = false
    /// Counts finished property reads, so a caller can wait for one that started after it asked.
    var fetchGeneration = 0
    /// A fetch asked for while one was in flight; it runs as soon as the current one finishes.
    var pendingFetch: FetchKind?
    // Rolling average of recent transaction RTTs (milliseconds)
    var recentLatencies: [Double] = []
    var latencyPublishedAt: Date?
    // Pending event batch timer
    var batchTask: Task<Void, Never>?
    // Fallback poll loop — kept so reconnect can cancel the old loop before starting a new one
    var pollTask: Task<Void, Never>?

    // REC state tracking [Architecture rule 6]
    var recConfirmTask: Task<Void, Never>?
    /// A start asked for while a stop was still being confirmed: sent once the camera has stopped (`handleRec`).
    var startAfterStop = false

    public init(
        host: String,
        identityStore: any InitiatorIdentityStore,
        config: SonyBackendConfig = SonyBackendConfig(),
        recorder: (any TrafficRecorder)? = nil,
        sshUsername: String? = nil,
        password: String? = nil,
        trustedFingerprint: String? = nil
    ) {
        self.host = host
        self.recorder = recorder
        self.config = config
        self.identityStore = identityStore
        self.sshUsername = sshUsername
        self.password = password
        self.trustedFingerprint = trustedFingerprint
        let stream = AsyncStream.makeStream(of: CameraState.self, bufferingPolicy: .bufferingNewest(16))
        self.updates = stream.stream
        self.continuation = stream.continuation
    }

    deinit { continuation.finish() }

    // Stored here for the extensions in SonyCameraBackend+*.swift, which can't hold stored properties.

    /// Pending AsyncStream continuation for the next 0xC214 event. Set by importLUT, consumed by handleEvent.
    var pendingLUTImportStreamContinuation: AsyncStream<LUTImportResult>.Continuation?
    var osdModeOn = false

    // Playback through the camera's own buttons (+Playback).
    /// Button playback commands run one at a time, in order. A double tap on Review or Live has to see the mode the
    /// first tap left, or it presses Playback again and toggles straight back.
    var buttonQueue: Task<Void, Never>?
    var reviewPhase: ReviewPhase = .unknown
    /// A pro body's Review, or a pick from the Clips window, is under way (`openLastTake`, `goToTake`): another tap's
    /// Prev, landing once the first had opened Playback, would step back a take.
    var reviewing = false
    /// The take the Clips window picked (from 1), while it's stepped to: a pick while Review or another pick is still
    /// stepping changes where that one goes. nil: the last take, Review's.
    var clipTarget: UInt32?
    var scanning = false
    /// The camera flips mode within 0.3 s of a Playback press (measured); a read after this sees where it landed.
    let modeFlip: Duration = .milliseconds(450)

    // Live view (+LiveView).
    /// Running total of estimated on-wire PTP-IP bytes (both directions) for live view transactions.
    public internal(set) var liveViewWireBytes: Int = 0
    var liveViewOriginalQuality: UInt8?
    var liveViewObjectInfoFetched = false
    /// Frames since live view started, and the last problem written to the activity log.
    var liveViewFrames = 0
    var liveViewProblem: String?
    /// Live view through the camera's own stream (+LiveStream, an FX5): the receiver it streams to, since when, and the
    /// destination it had picked before, given back after.
    var liveStream: RTMPLiveStream?
    var liveStreamStartedAt: ContinuousClock.Instant?
    var liveStreamRestore: (target: UInt16?, select: UInt8?)?
    /// Counts starts and stops of the stream, so a stop that lands while a start is still setting things up ends it.
    var liveStreamGeneration = 0
    let liveViewObjectHandle: UInt32 = 0xFFFFC002

    // MARK: - CameraBackend conformance

    public func connect() async {
        attempt += 1
        let mine = attempt
        await tearDown()  // whatever a previous session left behind: tasks, transport, tunnel
        guard attempt == mine else { return }
        // A new link has no round trip yet: not the last one's average, nor its samples.
        recentLatencies = []
        latencyPublishedAt = nil
        state.latencyMilliseconds = nil
        state.connection = .connecting
        emit()

        if let serial = USBCameraAddress.serial(in: host) {
            await connectUSB(serial: serial, attempt: mine)
            return
        }

        let guid: UUID
        do {
            guid = try identityStore.guid(for: host)
        } catch {
            fail("Identity store error: \(error)", attempt: mine); return
        }

        // Access Authentication: SSH tunnel wraps PTP-IP [§Connection by SSH]
        var transportConfig = config.transport
        let ptpHost: String
        if let username = sshUsername, !username.isEmpty {
            let forwarder = SSHPortForwarder(host: host, port: 22, username: username, password: password ?? "",
                                             expectedFingerprint: trustedFingerprint)
            do {
                let localPort = try await forwarder.start()
                guard attempt == mine else { forwarder.stop(); return }
                sshForwarder = forwarder
                // Record the observed fingerprint so the store can save it on first use
                state.observedFingerprint = forwarder.observedFingerprint
                transportConfig.port = NWEndpoint.Port(rawValue: localPort)!
                ptpHost = "127.0.0.1"
            } catch SSHTunnelError.fingerprintMismatch(let observed) {
                guard attempt == mine else { return }
                state.connection = .fingerprintChanged(observed)
                emit(); return
            } catch {
                fail("SSH: \(error.localizedDescription)", attempt: mine); return
            }
        } else {
            ptpHost = host
        }

        let transport = makeTransport(host: ptpHost, config: transportConfig)

        // Pairing: the camera holds Init_Command_Request until someone presses OK on the body, so a
        // slow answer without SSH means it's asking. Say "approve on camera" instead of "connecting".
        let approvalHint: Task<Void, Never>? = (sshUsername ?? "").isEmpty ? Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.showAwaitingApprovalIfStillConnecting(attempt: mine)
        } : nil
        do {
            try await transport.connect(guid: guid, friendlyName: identityStore.friendlyName)
            approvalHint?.cancel()
        } catch PTPError.authenticationFailed {
            approvalHint?.cancel()
            guard attempt == mine else { return }
            // Camera is waiting for pairing approval on the body [Architecture rule 4]
            state.connection = .awaitingApproval
            emit()
            await waitForApprovalAndRetry(host: ptpHost, config: transportConfig, guid: guid, attempt: mine)
            return
        } catch {
            approvalHint?.cancel()
            fail(error.localizedDescription, attempt: mine); return
        }
        guard attempt == mine else { return }
        await runSession(transport: transport, attempt: mine)
    }

    /// A PTP-IP transport for this backend.
    func makeTransport(host: String, config: PTPIPTransportConfig) -> PTPIPTransport {
        let transport = PTPIPTransport(host: host, config: config)
        transport.recorder = recorder
        adopt(transport)
        return transport
    }

    /// Makes `transport` this backend's: its events and state changes are routed here, and ignored once it's been
    /// replaced (see `isCurrent`).
    private func adopt(_ transport: any PTPTransport) {
        let id = ObjectIdentifier(transport)
        transport.onEvent = { [weak self] event in
            Task { await self?.handleEvent(event, from: id) }
        }
        transport.onStateChange = { [weak self] newState in
            Task { await self?.handleTransportStateChange(newState, from: id) }
        }
        self.transport = transport
    }

    /// PTP over USB: no pairing, tunnel or identity; the link opens, then the same session as PTP-IP. `identifier`
    /// is the camera's serial number, or on iPhone and iPad its name.
    private func connectUSB(serial identifier: String, attempt mine: Int) async {
        let open: () async throws -> Void
        switch config.usbLink {
        case .direct:
            #if os(macOS)
            let transport = PTPUSBTransport(serial: identifier)
            adopt(transport)
            open = transport.connect
            #else
            fail("A camera on USB connects through ImageCaptureCore here", attempt: mine); return
            #endif
        case .imageCapture:
            #if canImport(ImageCaptureCore)
            let transport = PTPICATransport(identifier: identifier)
            adopt(transport)
            open = transport.connect
            #else
            fail("No ImageCaptureCore here", attempt: mine); return
            #endif
        }
        do {
            try await open()
        } catch {
            fail((error as? LocalizedError)?.errorDescription ?? "\(error)", attempt: mine); return
        }
        guard attempt == mine, let transport else { return }
        await runSession(transport: transport, attempt: mine)
    }

    /// True when the camera is cabled to this Mac, where its frames cost no network.
    var isUSB: Bool { USBCameraAddress.serial(in: host) != nil }

    private func showAwaitingApprovalIfStillConnecting(attempt mine: Int) {
        guard attempt == mine, state.connection == .connecting else { return }
        state.connection = .awaitingApproval
        emit()
    }

    /// Fails this connect attempt, unless a newer connect or a disconnect has taken over.
    func fail(_ message: String, attempt mine: Int) {
        guard attempt == mine else { return }
        state.connection = .failed(message)
        emit()
    }

    func isCurrent(_ transport: ObjectIdentifier) -> Bool {
        self.transport.map(ObjectIdentifier.init) == transport
    }

    /// Stops everything belonging to the current session. A REC still waiting for the camera fails: a take keeps
    /// rolling on the camera, but whether the command landed is unknown until the next read.
    private func tearDown() async {
        // A motor still driving is stopped while there's a session to say so, and again on the next one in case the
        // camera never heard it (`drivesToStop`).
        await stopLensDrives()
        pollTask?.cancel(); pollTask = nil
        batchTask?.cancel(); batchTask = nil
        recConfirmTask?.cancel(); recConfirmTask = nil
        failPendingRec()
        // Restore live view quality if we changed it (best effort; transport may be about to close)
        await stopLiveView()
        let session = self.session, transport = self.transport, forwarder = sshForwarder
        self.session = nil
        self.transport = nil
        self.sshForwarder = nil
        self.sessionInfo = nil
        self.sessionReady = false
        // CloseSession frees the camera, which serves one controller at a time.
        if let session { await session.close() } else { await transport?.disconnect() }
        forwarder?.stop()
    }

    func failPendingRec() {
        guard state.recording.request != nil else { return }
        state.recording.request = nil
        state.recording.failure = RecordingControl.Failure.lost
    }

    public func disconnect() async {
        reviewPhase = .unknown
        scanning = false
        attempt += 1
        let mine = attempt
        await tearDown()
        guard attempt == mine else { return }
        state.connection = .disconnected
        emit()
    }

    public func send(_ command: CameraCommand) async {
        guard state.connection.isControllable else { return }
        switch command {
        case .record(let start):
            await handleRec(start: start)
        case .setISO(let v):
            await setISO(v)
        case .setBaseISO(let v):
            await setBaseISO(v)
        case .setShutterAngle(let v):
            await setShutterAngle(v)
        case .setShutterSpeed(let v):
            await setShutterSpeedCmd(v)
        case .setShutterMode(let v):
            await setShutterModeCmd(v)
        case .setFocusMode(let v):
            await setFocusModeCmd(v)
        case .setNDPreset(let v):
            await setNDPreset(v)
        case .setVariableND(let v):
            await setVariableND(v)
        case .setWhiteBalancePreset(let preset):
            await setWBPreset(preset)
        case .setKelvin(let v):
            await setKelvin(v)
        case .setTint(let v):
            await setTint(v)
        case .setIris(let v):
            await setIris(v)
        case .setFrameRateVariable(let v):
            await setFrameRateVariable(v)
        case .setFrameRate(let v):
            await setFrameRate(v)
        case .setResolution(let v):
            await setResolution(v)
        case .setFileFormat(let v):
            await setFileFormat(v)
        case .setRecordingSetting(let v):
            await setRecordingSetting(v)
        case .setDesqueeze(let v):
            await setDesqueeze(v)
        case .setClipFlag:
            break  // NOT FOUND in PTP 3 [§6.9]
        case .setImageFlip:
            break  // NOT FOUND in PTP 3 [§6.10]
        case .setColorBars:
            break  // FX3 does not expose a color-bars property in PTP 3 — leave nil
        case .setFalseColor(let on) where isProBody:
            // The button set to False Color (StateMapper.mapFX6): whichever it is now, as anyone at the camera can move
            // it, so read first. Pressed only when it isn't already as asked (a press toggles it), and only if it's still
            // False Color when it's pressed.
            guard await readNow() else { return }
            guard let button = state.assignableButtons.first(where: StateMapper.isFalseColor),
                  let isOn = button.isOn, isOn != on else { return }
            await pressAssignable(button.id, expecting: button.function)
        case .setFalseColor:
            break  // FX3 does not expose false-color in PTP 3 — leave nil
        case .setNDMode(let label):
            // ND Filter Switching Setting 0xD073
            if let raw = ["Preset": UInt8(0x01), "Variable": 0x02, "Step": 0x03][label] {
                await setProp(code: SDIPropCode.ndFilterSwitching.rawValue, data: Data([raw]))
            }
        case .setTally(let label):
            // One lamp at most: the other goes off (0x01 OFF, 0x02 ON)
            await setProp(code: SDIPropCode.redTallyLamp.rawValue, data: Data([label == "Red" ? 0x02 : 0x01]))
            await setProp(code: SDIPropCode.greenTallyLamp.rawValue, data: Data([label == "Green" ? 0x02 : 0x01]))
        case .setCall(let on):
            await setProp(code: SDIPropCode.callSetting.rawValue, data: Data([on ? 0x02 : 0x01]))
        case .setColorGamut(let label):
            if let raw = ["S-Gamut3.Cine": UInt8(0x01), "S-Gamut3": 0x02][label] {
                await setProp(code: SDIPropCode.colorGamut.rawValue, data: Data([raw]))
            }
        case .pressCameraButton(let button):
            await pressBodyButton(button)
        case .setLook(let v) where isProBody:
            await setLUTOutputs(v, output: nil)
        case .setLook(let v):
            await setLook(v)
        case .setHDMIInfo(let on):
            await setProp(code: SDIPropCode.monitoringOutputDisplayHDMI.rawValue, data: Data([on ? 0x02 : 0x01]))
        case .setGridLines(let on):
            await setProp(code: SDIPropCode.gridLineDisplay.rawValue, data: Data([on ? 0x02 : 0x01]))
        case .setLUT(let v):
            await setLUTCmd(v)
        case .setClipTitle(let v):
            await setClipNaming(.fileTitleName, data: encodePTPString(v))
        case .setClipCameraID(let v):
            let raw = v.uppercased().unicodeScalars.first.map { UInt8(clamping: Int($0.value) - 64) }
            await setClipNaming(.fileCameraID, data: raw.flatMap { (1...26).contains($0) ? Data([$0]) : nil })
        case .setClipReel(let v):
            var d = Data(); d.appendLE(UInt16(clamping: v))
            await setClipNaming(.fileReelNumber, data: d)
        case .setFrameRateVariableRate(let fps):
            // S&Q Frame Rate 0xD052, UINT16 fps (FX6/BURANO)
            var data = Data(); data.appendLE(UInt16(clamping: Int(fps.rounded())))
            await setProp(code: SDIPropCode.sqFrameRate.rawValue, data: data)
        case .setMonitorOverlay(.lut, let on, let output) where isProBody:
            await setLUTOutputs(on, output: output)
        case .setSteadyShot(let label):
            guard let raw = StateMapper.steadyShotModes.first(where: { $0.value == label })?.key else { return }
            await setProp(code: SDIPropCode.steadyShotMovie.rawValue, data: Data([raw]))
        case .setImagerMode(let label):
            // The camera's own list, by label: a mode it doesn't offer now isn't sent. Not during a take: it changes
            // the picture's size, and can change the resolution with it.
            guard state.recording.state == .idle, state.recording.request == nil,
                  let raw = rawProps[SDIPropCode.imagerMode.rawValue]?.enumCurrentUInt64()
                    .first(where: { StateMapper.imagerModeLabel($0) == label }) else { return }
            var data = Data(); data.appendLE(raw)
            await setProp(code: SDIPropCode.imagerMode.rawValue, data: data)
        case .autoFocus where isProBody && hasProp(.pushAutoFocus):
            await pushAutoFocus()
        case .setSubjectRecognition(let label):
            // By the camera's own list and names, as it's read (StateMapper.subjectRecognition).
            guard let prop = rawProps[SDIPropCode.subjectRecognitionAF.rawValue],
                  let raw = StateMapper.subjectRecognitionValues(prop, names: subjectNames).options
                    .first(where: { $0.label == label })?.raw
            else { return }
            await setProp(code: SDIPropCode.subjectRecognitionAF.rawValue, data: Data([raw]))
        case .setFocusArea(let label):
            guard let raw = StateMapper.focusAreaNames.first(where: { $0.value == label })?.key,
                  rawProps[SDIPropCode.focusArea.rawValue]?.enumCurrentUInt16().contains(raw) == true else { return }
            var data = Data(); data.appendLE(raw)
            await setProp(code: SDIPropCode.focusArea.rawValue, data: data)
        case .setAFTransitionSpeed(let speed):
            await setProp(code: SDIPropCode.afTransitionSpeed.rawValue, data: Data([UInt8(clamping: speed)]))
        case .setAFSubjectShift(let sensitivity):
            await setProp(code: SDIPropCode.afSubjectShiftSens.rawValue, data: Data([UInt8(clamping: sensitivity)]))
        case .setAFAssist(let on):
            await setProp(code: SDIPropCode.afAssist.rawValue, data: Data([on ? 0x02 : 0x01]))
        case .setMonitorOverlay, .setStatusTextContent, .setZebraLevel, .setFrameGuideRatio,
             .setClipCameraPosition, .setTimecodeShowsDuration,
             .setDynamicRange, .autoFocus, .setAudio, .setUserFrameLines, .setFrameLineSet, .setOutputFollows:
            break  // not in PTP 3 on these bodies (or not offered on them yet)
        case .playback(let cmd):
            await sendPlaybackCommand(cmd)
        case .setShootingMode, .setGain, .setBaseSensitivity, .setRecordedLUT, .setProxyRecording, .setECS, .stepECS, .setIrisAuto,
             .setNDAuto, .setISOAuto, .driveFocus, .driveZoom, .pressAssignable:
            await sendFX6(command)
        }
    }

    // MARK: - Raw property snapshot (debugging)

    public var rawProperties: [UInt16: SDIDevicePropInfo] { rawProps }

    /// What the dashboard sees now; for tools.
    public var currentState: CameraState { state }

    /// Raw BaseLook display name map (value → camera display string). Includes empty User slots as "(No Import)".
    /// Use lutDisplayNames() to filter and clean labels for display.
    public var rawLUTNames: [UInt16: String] { lutNames }

    // MARK: - Session run

    func runSession(transport: any PTPTransport, attempt mine: Int) async {
        let session = PTPIPSession(transport: transport, config: config.session)
        self.session = session

        do {
            let info = try await session.open()
            guard attempt == mine else { return }
            self.sessionInfo = info
            self.sessionReady = true
        } catch {
            guard attempt == mine else { return }
            // The FX3 serves one PTP-IP initiator at a time: a second controller gets through Init and is then
            // dropped during session setup. Say so instead of "Session setup failed: disconnected".
            if case PTPError.disconnected = error {
                state.connection = .failed("The camera closed the session. Is another controller connected to it?")
            } else {
                state.connection = .failed("Session setup failed: \(error)")
            }
            emit(); return
        }

        state.connection = .connected
        emit()  // Emit immediately so dashboard and tests see .connected before the first prop fetch
        for control in drivesToStop { await stopMotor(control) }
        for code in buttonsToRelease where await releaseButton(code) { buttonsToRelease.remove(code) }
        let problem = await requestFetch(.full)
        guard attempt == mine else { return }
        if let problem, rawProps.isEmpty {
            // Connected without a single value: every tile would sit on "—" behind a healthy-looking meter, and
            // changed-only polls never fill it in (seen on FX3 over HaLow). Say so; the controller
            // reconnects with backoff, and connect() closes this session first.
            state.connection = .failed("Connected, but couldn't read the camera's settings (\(problem)).")
            emit()
            return
        }
        // Fetch model string after the initial state is ready; non-blocking if it fails.
        if let model = await fetchDeviceModel(transport: transport), attempt == mine {
            state.model = model
            emit()
            // What it adds for an FX6 or FX5 (StateMapper.mapFX6) needs the model, and its buttons' names.
            if isProBody {
                if let names = await fetchDisplayStrings(transport: transport, type: SDIODisplayStringListType.buttonAssignShort) {
                    assignableNames = names
                }
                // Its names for what autofocus looks for, in its own words (an FX5's matched StateMapper's, 11/14).
                if hasProp(.subjectRecognitionAF),
                   let names = await fetchDisplayStrings(transport: transport, type: SDIODisplayStringListType.subjectRecognitionAF) {
                    subjectNames = names
                }
                guard attempt == mine else { return }
                applyProps(Array(rawProps.values))
            }
        }
        // Display names: LUTs as the camera's menu shows them, base ISOs as numbers.
        if let names = await fetchLUTNames(transport: transport), !names.isEmpty { lutNames = names }
        if let names = await fetchBaseISONames(transport: transport), !names.isEmpty { baseISONames = names }
        guard attempt == mine else { return }
        if !lutNames.isEmpty || !baseISONames.isEmpty {
            let mapper = StateMapper(props: Array(rawProps.values))
            state.lut = mapper.lut(lutNames: lutNames)
            state.baseISO = mapper.baseISO(names: baseISONames)
            emit()
        }
        startPollLoop()
    }

    private func fetchDeviceModel(transport: any PTPTransport) async -> String? {
        do {
            let (resp, data) = try await transport.execute(opCode: PTPOpCode.getDeviceInfo.rawValue, params: [])
            guard resp.responseCode == PTPResponseCode.ok.rawValue, data.count > 8 else { return nil }
            let info = parseDeviceInfo(data)
            if let model = info.model {
                ActivityLog.shared.note(host, "\(model), firmware \(info.version ?? "unknown")")
            }
            return info.model
        } catch {
            return nil
        }
    }

    /// The Model and DeviceVersion (its firmware) fields of a PTP GetDeviceInfo response.
    /// Layout [PIMA 15740 §13.3.2]: StandardVersion(2)+VendorExtensionID(4)+VendorExtensionVersion(2)+
    /// VendorExtensionDesc(STR)+FunctionalMode(2)+OperationsSupported(array)+EventsSupported(array)+
    /// DevicePropertiesSupported(array)+CaptureFormats(array)+ImageFormats(array)+
    /// Manufacturer(STR)+Model(STR)+DeviceVersion(STR)+SerialNumber(STR)
    private func parseDeviceInfo(_ data: Data) -> (model: String?, version: String?) {
        var cursor = 0
        func read<T: FixedWidthInteger>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard cursor + size <= data.count else { return nil }
            let v = data.readLE(T.self, at: cursor); cursor += size; return v
        }
        func skipPTPStr() {
            guard let len = read(UInt8.self), len > 0 else { return }
            cursor += Int(len) * 2
        }
        func skipArray<T: FixedWidthInteger>(_ type: T.Type) {
            guard let count = read(UInt32.self) else { return }
            cursor += Int(count) * MemoryLayout<T>.size
        }
        func readPTPStr() -> String? {
            guard let len = read(UInt8.self) else { return nil }
            if len == 0 { return "" }
            guard cursor + Int(len) * 2 <= data.count else { return nil }
            let chars = Data(data[data.startIndex + cursor ..< data.startIndex + cursor + Int(len) * 2])
            cursor += Int(len) * 2
            return String(bytes: chars, encoding: .utf16LittleEndian)?.trimmingCharacters(in: CharacterSet(["\0"]))
        }
        guard read(UInt16.self) != nil else { return (nil, nil) } // StandardVersion
        guard read(UInt32.self) != nil else { return (nil, nil) } // VendorExtensionID
        guard read(UInt16.self) != nil else { return (nil, nil) } // VendorExtensionVersion
        skipPTPStr()                                              // VendorExtensionDesc
        guard read(UInt16.self) != nil else { return (nil, nil) } // FunctionalMode
        skipArray(UInt16.self)                                    // OperationsSupported
        skipArray(UInt16.self)                                    // EventsSupported
        skipArray(UInt16.self)                                    // DevicePropertiesSupported
        skipArray(UInt16.self)                                    // CaptureFormats
        skipArray(UInt16.self)                                    // ImageFormats
        skipPTPStr()                                              // Manufacturer
        let model = readPTPStr()                                  // Model
        return (model, model == nil ? nil : readPTPStr())         // DeviceVersion
    }

    // MARK: - Emit

    func emit() {
        if state.connection != loggedConnection {
            loggedConnection = state.connection
            ActivityLog.shared.note(host, "\(state.connection)")
        }
        switch state.connection {
        case .failed, .disconnected:
            // Only emit the first terminal state; silence duplicates from background tasks.
            if terminalEmitted { return }
            terminalEmitted = true
        case .connecting:
            terminalEmitted = false
        default:
            break
        }
        continuation.yield(state)
    }
}

// The app reaches live view through this protocol (CameraController.liveViewProvider). Without the conformance the
// FX3's tile opened an empty sheet while every test, all on the mock, passed.
extension SonyCameraBackend: LiveViewProvider {}

// Diagnostics (camctl): what the camera declared in SDIO_GetExtDeviceInfo, so a feature the property list doesn't show
// can be checked against the control codes too.
extension SonyCameraBackend {
    public var declaredExtDeviceInfo: SDIExtDeviceInfo? { sessionInfo?.extDeviceInfo }
}

