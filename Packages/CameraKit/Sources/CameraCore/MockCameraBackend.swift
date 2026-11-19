import Foundation

/// Bodies the mock can pretend to be. The values in `sampleState` are illustrative only; the real ones
/// come from the camera's property dump.
public enum MockBody: String, Sendable, CaseIterable, Codable, Hashable {
    case fx3 = "ILME-FX3"
    case fx30 = "ILME-FX30"
    case fx2 = "ILME-FX2"
    case fx6 = "ILME-FX6"
    case burano = "MPC-2610"
    case venice = "MPC-3610"
    case venice2 = "MPC-3628"
    case pyxis12K = "PYXIS 12K"
    case alexaMini = "ALEXA Mini"
    case alexaMiniLF = "ALEXA Mini LF"
    case alexa35 = "ALEXA 35"

    public var displayName: String {
        switch self {
        case .fx3: "FX3"
        case .fx30: "FX30"
        case .fx2: "FX2"
        case .fx6: "FX6"
        case .burano: "BURANO"
        case .venice: "VENICE"
        case .venice2: "VENICE 2"
        case .pyxis12K: "PYXIS 12K"
        case .alexaMini: "ALEXA Mini"
        case .alexaMiniLF: "ALEXA Mini LF"
        case .alexa35: "ALEXA 35"
        }
    }

    var isCinemaLine: Bool { self == .fx6 || self == .burano }
    var isVenice: Bool { self == .venice || self == .venice2 }
    public var isArri: Bool { self == .alexaMini || self == .alexaMiniLF || self == .alexa35 }
    public var isBlackmagic: Bool { self == .pyxis12K }

    var baseISOs: [Int] {
        switch self {
        case .burano: [800, 3200]
        case .fx30: [800, 2500]
        default: [800, 12800]
        }
    }
}

/// A fake camera with network-ish latency, so the UI can be built and tested without hardware.
public actor MockCameraBackend: CameraBackend, LUTImportCapable, LiveViewProvider {
    public nonisolated let updates: AsyncStream<CameraState>
    private nonisolated let continuation: AsyncStream<CameraState>.Continuation

    private let body: MockBody
    private let label: String
    private let latency: Duration
    private let connectDelay: Duration
    private let heartbeatInterval: Duration?
    /// What it connects as instead of `sampleState(body:)`: a real camera's demo of itself (Test Mode), Blackmagic
    /// ones included.
    private let startState: CameraState?
    private var state = CameraState()
    private var heartbeat: Task<Void, Never>?
    /// A demo with audio meters moves them, as a camera hearing a room would. Off with the heartbeat (tests).
    private var meterTask: Task<Void, Never>?

    /// - Parameter heartbeat: how often to jitter the reported link latency; nil turns it off (tests).
    public init(
        body: MockBody,
        label: String = "A",
        latency: Duration = .milliseconds(150),
        connectDelay: Duration = .milliseconds(400),
        heartbeat: Duration? = .seconds(2)
    ) {
        self.init(body: body, label: label, latency: latency, connectDelay: connectDelay, heartbeat: heartbeat, startState: nil)
    }

    /// A demo that starts from `state` (a camera's `DashboardStore.previewState`), connected at once: Test Mode's
    /// stand-in for a camera that isn't connected.
    public init(state: CameraState, label: String = "A", latency: Duration = .milliseconds(150),
                heartbeat: Duration? = .seconds(2)) {
        self.init(body: state.model.flatMap(MockBody.init(rawValue:)) ?? .fx3, label: label, latency: latency,
                  connectDelay: .zero, heartbeat: heartbeat, startState: state)
    }

    private init(body: MockBody, label: String, latency: Duration, connectDelay: Duration, heartbeat: Duration?,
                 startState: CameraState?) {
        let stream = AsyncStream.makeStream(of: CameraState.self, bufferingPolicy: .bufferingNewest(8))
        self.updates = stream.stream
        self.continuation = stream.continuation
        self.body = body
        self.label = label
        self.latency = latency
        self.connectDelay = connectDelay
        self.heartbeatInterval = heartbeat
        self.startState = startState
    }

    deinit {
        heartbeat?.cancel()
        meterTask?.cancel()
        continuation.finish()
    }

    // MARK: - LUTImportCapable

    /// The demo's User slots: the first few named, the rest empty.
    private var lutSlotNames: [Int: String] = [1: "TW Show LUT", 2: "s709 Clean", 3: "Day Exterior", 4: "GK SLog3 False Color"]

    /// Simulated LUT slot list: 16 slots, first few named to match the mock lut options.
    public func lutSlots() async throws -> [LUTSlot] {
        guard state.connection.isControllable else { throw LUTImportError.notConnected }
        // Give the mock plausible names for User1–User4, rest empty.
        return (1...16).map { LUTSlot(index: $0, name: lutSlotNames[$0]) }
    }

    /// Simulated import: waits like the real camera would, then adds the LUT to the lut options.
    public func importLUT(data: Data, name: String, slot: Int) async throws {
        guard state.connection.isControllable else { throw LUTImportError.notConnected }
        guard slot >= 1, slot <= 16 else { throw LUTImportError.other("Slot \(slot) out of range (1–16)") }
        // Simulate upload time proportional to file size.
        let delay = Duration.milliseconds(200 + min(data.count / 1000, 800))
        try? await Task.sleep(for: delay)
        lutSlotNames[slot] = name
        // The slot's entry in the picker takes the new name, as in the camera's list after an import. Importing never
        // changes the active LUT, unless the slot overwritten was the active one.
        if var lut = state.lut {
            let prefix = "User \(slot): "
            let label = prefix + name
            if let i = lut.options.firstIndex(where: { $0.hasPrefix(prefix) }) {
                if lut.value == lut.options[i] { lut.value = label }
                lut.options[i] = label
            } else {
                lut.options.append(label)
            }
            state.lut = lut
            emit()
        }
    }

    public func connect() async {
        // A camera's own demo is there at once: its tiles already show these values.
        if var start = startState {
            start.connection = .connected
            state = start
            emit()
            startHeartbeat()
            startMeters()
            return
        }
        state.connection = .connecting
        emit()
        try? await Task.sleep(for: connectDelay)
        state = Self.sampleState(body: body, label: label, now: Date())
        emit()
        startHeartbeat()
        startMeters()
    }

    public func disconnect() async {
        heartbeat?.cancel()
        heartbeat = nil
        meterTask?.cancel()
        meterTask = nil
        state.connection = .disconnected
        emit()
    }

    public func send(_ command: CameraCommand) async {
        guard state.connection.isControllable else { return }
        switch command {
        case .record(let start):
            guard state.recording.request == nil, state.recording.state != .unknown else { return }
            state.recording.request = start ? .start : .stop
            state.recording.failure = nil
            emit()
            try? await Task.sleep(for: latency * 2)
            state.recording.state = start ? .recording : .idle
            state.recording.request = nil
            state.takeStartedAt = start ? Date() : nil
            emit()
        case .setISO(let value): await settle(value, get: { $0.iso }, set: { $0.iso = $1 })
        case .setBaseISO(let value):
            await settle(value, get: { $0.baseISO }, set: { $0.baseISO = $1 })
            // Like the real bodies: switching base ISO moves the ISO to the new base and shifts its range.
            if state.iso != nil {
                let options = CameraProfile.isVenice(state.model) ? VeniceTables.eiOptions(base: value)
                    : Self.isoOptions(base: value)
                state.iso = Choice(value, options: options)
                emit()
            }
            veniceListsFollow()  // a VENICE's high base takes nothing under 8 FPS
        case .setShutterAngle(let value): await settle(value, get: { $0.shutterAngle }, set: { $0.shutterAngle = $1 })
        case .setShutterSpeed(let value): await settle(value, get: { $0.shutterSpeed }, set: { $0.shutterSpeed = $1 })
        case .setShutterMode(let value):
            await settle(value, get: { $0.shutterMode }, set: { $0.shutterMode = $1 })
            // Like the real FX3: shutter speed only exists in speed mode (it read 1/50 there), and the angle turns
            // display-only. The cinema-line demos, and a Blackmagic camera's, keep both.
            if !body.isCinemaLine && state.make != .blackmagic && state.make != .arri {
                state.shutterSpeed = value == .speed
                    ? Choice("1/50", options: ["1/24", "1/25", "1/30", "1/48", "1/50", "1/60", "1/100", "1/120"])
                    : nil
                state.shutterAngle?.isWritable = value == .angle
                emit()
            } else if body == .fx6 {
                // An FX6 keeps both, the one its mode doesn't use read-only.
                state.shutterAngle?.isWritable = value == .angle
                state.shutterSpeed?.isWritable = value == .speed
                emit()
            }
        case .setNDPreset(let value): await settle(value, get: { $0.nd?.preset }, set: { $0.nd?.preset = $1 })
        case .setVariableND(let value): await settle(level: value, get: { $0.nd?.variable }, set: { $0.nd?.variable = $1 })
        case .setWhiteBalancePreset(let value):
            await settle(value, get: { $0.whiteBalance?.preset }, set: { $0.whiteBalance?.preset = $1 })
            if value.hasSuffix("K"), let kelvin = Double(value.dropLast()) {
                await settle(level: kelvin, get: { $0.whiteBalance?.kelvin }, set: { $0.whiteBalance?.kelvin = $1 })
                // A preset is a Kelvin-and-tint pair (VENICE's carry +8 tint); bodies without tint skip this.
                if state.whiteBalance?.tint != nil {
                    await settle(level: 0, get: { $0.whiteBalance?.tint }, set: { $0.whiteBalance?.tint = $1 })
                }
            }
        case .setKelvin(let value): await settle(level: value, get: { $0.whiteBalance?.kelvin }, set: { $0.whiteBalance?.kelvin = $1 })
        case .setTint(let value): await settle(level: value, get: { $0.whiteBalance?.tint }, set: { $0.whiteBalance?.tint = $1 })
        case .setIris(let value): await settle(value, get: { $0.iris }, set: { $0.iris = $1 })
        case .setFrameRateVariable(let value):
            await settle(value, get: { $0.frameRate?.variable }, set: { $0.frameRate?.variable = $1 })
        case .setClipFlag(let value): await settle(value, get: { $0.clipFlag }, set: { $0.clipFlag = $1 })
        case .setImageFlip(let value): await settle(value, get: { $0.imageFlip }, set: { $0.imageFlip = $1 })
        case .setHDMIInfo(let value): await settle(value, get: { $0.hdmiInfo }, set: { $0.hdmiInfo = $1 })
        case .setGridLines(let value): await settle(value, get: { $0.gridLines }, set: { $0.gridLines = $1 })
        case .setColorBars(let value): await settle(value, get: { $0.colorBars }, set: { $0.colorBars = $1 })
        case .setNDMode(let value): await settle(value, get: { $0.ndMode }, set: { $0.ndMode = $1 })
        case .setTally(let value): await settle(value, get: { $0.tally }, set: { $0.tally = $1 })
        case .setCall(let value): await settle(value, get: { $0.call }, set: { $0.call = $1 })
        case .setColorGamut(let value): await settle(value, get: { $0.colorGamut }, set: { $0.colorGamut = $1 })
        case .setShootingMode(let value): await settle(value, get: { $0.shootingMode }, set: { $0.shootingMode = $1 })
        case .setGain(let value): await settle(value, get: { $0.gain }, set: { $0.gain = $1 })
        case .setBaseSensitivity(let value): await settle(value, get: { $0.baseSensitivity }, set: { $0.baseSensitivity = $1 })
        case .setSteadyShot(let value): await settle(value, get: { $0.steadyShot }, set: { $0.steadyShot = $1 })
        case .setImagerMode(let value): await settle(value, get: { $0.imagerMode }, set: { $0.imagerMode = $1 })
        case .setSubjectRecognition(let value):
            await settle(value, get: { $0.subjectRecognition }, set: { $0.subjectRecognition = $1 })
        case .setFocusArea(let value): await settle(value, get: { $0.focusArea }, set: { $0.focusArea = $1 })
        case .setAFTransitionSpeed(let value):
            await settle(value, get: { $0.afTransitionSpeed }, set: { $0.afTransitionSpeed = $1 })
        case .setAFSubjectShift(let value): await settle(value, get: { $0.afSubjectShift }, set: { $0.afSubjectShift = $1 })
        case .setAFAssist(let value): await settle(value, get: { $0.afAssist }, set: { $0.afAssist = $1 })
        case .setRecordedLUT(let value): await settle(value, get: { $0.recordedLUT }, set: { $0.recordedLUT = $1 })
        case .setProxyRecording(let value):
            await settle(value, get: { $0.proxyRecording }, set: { $0.proxyRecording = $1 })
            state.proxyStatus = value ? "Standby" : nil
            emit()
        case .setECS(let value):
            await settle(value, get: { $0.ecs?.on }, set: { $0.ecs?.on = $1 })
            state.ecs?.frequency = value ? 60 : nil
            state.ecs?.canStep = value
            emit()
        case .stepECS(let by):
            // The FX6 steps finer low down than high up: a percent a step will do for the demo.
            guard let ecs = state.ecs, ecs.canStep, let hz = ecs.frequency else { return }
            state.ecs?.frequency = ((hz * pow(1.01, Double(by))) * 100).rounded() / 100
            emit()
        case .setIrisAuto(let value): await settle(value, get: { $0.irisAuto }, set: { $0.irisAuto = $1 })
        case .setNDAuto(let value): await settle(value, get: { $0.ndAuto }, set: { $0.ndAuto = $1 })
        case .setISOAuto(let value): await settle(value, get: { $0.isoAuto }, set: { $0.isoAuto = $1 })
        case .driveFocus(let speed):
            guard let drive = state.focusDrive, drive.isWritable, let at = drive.position else { return }
            state.focusDrive?.position = min(max(at + Double(speed) * 0.004, 0), 1)
            emit()
        case .driveZoom(let speed):
            guard let drive = state.zoomDrive, drive.isWritable, let at = drive.position else { return }
            state.zoomDrive?.position = min(max(at + Double(speed) * 0.004, 0), 1)
            emit()
        case .pressAssignable(let id):
            guard let i = state.assignableButtons.firstIndex(where: { $0.id == id }),
                  state.assignableButtons[i].isPressable else { return }
            state.assignableButtons[i].isOn = state.assignableButtons[i].isOn.map { !$0 }
            emit()
        case .pressCameraButton, .autoFocus: break  // the demo has no menu to work, nor a lens to focus
        case .setAudio(let channel, let setting): await setAudio(channel, setting)
        case .setUserFrameLines(let set, let value):
            if set == .a {
                await settle(value, get: { $0.userFrameLinesA }, set: { $0.userFrameLinesA = $1 })
            } else {
                await settle(value, get: { $0.userFrameLinesB }, set: { $0.userFrameLinesB = $1 })
            }
        // A camera with monitoring outputs (a Blackmagic one's demo) switches them on its outputs, as the camera does.
        case .setFalseColor(let value) where state.monitoring != nil:
            await send(.setMonitorOverlay(.falseColor, value, output: nil))
        case .setLook(let value) where state.monitoring != nil:
            await send(.setMonitorOverlay(.lut, value, output: nil))
        case .setFalseColor(let value): await settle(value, get: { $0.falseColor }, set: { $0.falseColor = $1 })
        case .setLook(let value): await settle(value, get: { $0.look }, set: { $0.look = $1 })
        case .setFrameRate(let value):
            await settle(value, get: { $0.frameRate?.project }, set: { $0.frameRate?.project = $1 })
            veniceListsFollow()
        case .setResolution(let value):
            await settle(value, get: { $0.resolution }, set: { $0.resolution = $1 })
            veniceListsFollow()
        case .setFileFormat(let value):
            await settle(value, get: { $0.fileFormat }, set: { $0.fileFormat = $1 })
            veniceListsFollow()
        case .setRecordingSetting(let value): await settle(value, get: { $0.recordingSetting }, set: { $0.recordingSetting = $1 })
        case .setDesqueeze(let value): await settle(value, get: { $0.desqueeze }, set: { $0.desqueeze = $1 })
        case .setLUT(let value): await settle(value, get: { $0.lut }, set: { $0.lut = $1 })
        case .setFocusMode(let value): await settle(value, get: { $0.focusMode }, set: { $0.focusMode = $1 })
        case .setClipTitle(let value):
            await settle(value, get: { $0.fileNaming?.title }, set: { $0.fileNaming?.title = $1 })
            // The demo names clips by title, like an FX3 set to Title.
            if let title = state.fileNaming?.title?.value { state.clipName = title + "0007" }
            emit()
        case .setClipCameraID(let value): await settle(value, get: { $0.fileNaming?.cameraID }, set: { $0.fileNaming?.cameraID = $1 })
        // Blackmagic controls: only a Blackmagic camera's demo of itself has them (Test Mode).
        case .setFrameRateVariableRate(let value):
            await settle(value, get: { $0.frameRate?.variableRate }, set: { $0.frameRate?.variableRate = $1 })
        case .setDynamicRange(let value): await settle(value, get: { $0.dynamicRange }, set: { $0.dynamicRange = $1 })
        case .setZebraLevel(let value):
            await settle(value, get: { $0.monitoring?.zebraLevel }, set: { $0.monitoring?.zebraLevel = $1 })
        case .setFrameGuideRatio(let value):
            await settle(value, get: { $0.monitoring?.frameGuideRatio }, set: { $0.monitoring?.frameGuideRatio = $1 })
        case .setMonitorOverlay(let overlay, let on, let output):
            try? await Task.sleep(for: latency)
            guard var monitoring = state.monitoring else { return }
            for index in monitoring.outputs.indices where output == nil || monitoring.outputs[index].id == output {
                // Every output's switch leaves one on clean feed alone, as the camera's backend does.
                guard var choice = monitoring.outputs[index].overlays[overlay], choice.isWritable,
                      output != nil || !monitoring.outputs[index].hides(overlay) else { continue }
                choice.value = on
                monitoring.outputs[index].overlays[overlay] = choice
            }
            setMonitoring(monitoring)
        case .setStatusTextContent(let content, let output):
            try? await Task.sleep(for: latency)
            guard var monitoring = state.monitoring,
                  let index = monitoring.outputs.firstIndex(where: { $0.id == output }),
                  var choice = monitoring.outputs[index].statusTextContent, choice.isWritable else { return }
            choice.value = content
            monitoring.outputs[index].statusTextContent = choice
            setMonitoring(monitoring)
        case .setFrameLineSet(let set, let output):
            try? await Task.sleep(for: latency)
            guard var monitoring = state.monitoring,
                  let index = monitoring.outputs.firstIndex(where: { $0.id == output }),
                  var choice = monitoring.outputs[index].frameLines, choice.isWritable else { return }
            choice.value = set
            monitoring.outputs[index].frameLines = choice
            setMonitoring(monitoring)
        case .setOutputFollows(let on, let output):
            try? await Task.sleep(for: latency)
            guard var monitoring = state.monitoring,
                  let index = monitoring.outputs.firstIndex(where: { $0.id == output }),
                  var sw = monitoring.outputs[index].sameAsSwitch, sw.isWritable else { return }
            sw.value = on
            monitoring.outputs[index].sameAsSwitch = sw
            if !on {
                monitoring.outputs[index].follows = nil
            }
            setMonitoring(monitoring)
        case .setClipReel(let value):
            await settle(level: Double(value), get: { $0.fileNaming?.reel }, set: { $0.fileNaming?.reel = $1 })
        case .setClipCameraPosition(let value):
            await settle(value, get: { $0.fileNaming?.position }, set: { $0.fileNaming?.position = $1 })
        case .setTimecodeShowsDuration(let value):
            await settle(value, get: { $0.timecodeShowsDuration }, set: { $0.timecodeShowsDuration = $1 })
        case .playback(let cmd):
            guard var pb = state.playback else { return }
            switch cmd {
            case .play:
                pb.isPlaying = true
            case .pause, .stop:
                pb.isPlaying = false
            case .togglePlay:
                // The FX3 doesn't say whether it's reviewing; a camera that does plays only while it is.
                if !pb.capabilities.review || pb.inReview == true { pb.isPlaying = !(pb.isPlaying ?? false) }
            case .live:
                pb.isPlaying = false
                if pb.capabilities.review { pb.isPlaying = nil; pb.inReview = false }
            case .review:
                // The last take, playing, as the cameras do.
                pb.inReview = true
                pb.isPlaying = true
                if let total = pb.clipCount { pb.clipNumber = total }
            case .next:
                if let n = pb.clipNumber, let total = pb.clipCount, n < total { pb.clipNumber = n + 1 }
            case .previous:
                if let n = pb.clipNumber, n > 1 { pb.clipNumber = n - 1 }
            case .skip(let secs):
                pb.position = max(0, (pb.position ?? 0) + secs)
            case .goToClip(let index):
                guard let clip = pb.clipListing?.first(where: { $0.id == index }) else { break }
                if pb.capabilities.review { pb.inReview = true }
                pb.isPlaying = true
                pb.clipNumber = index + 1
                pb.clipName = clip.name ?? pb.clipName
            case .fastForward, .rewind, .recReview, .scan, .endScan:
                break
            }
            state.playback = pb
            emit()
        }
    }

    /// Optimistic write: show the request as pending, then settle to it after the simulated round trip.
    /// (Closures rather than key paths because optional-chained key paths aren't writable.)
    private func settle<Value: Sendable & Hashable>(
        _ value: Value,
        get: (CameraState) -> Choice<Value>?,
        set: (inout CameraState, Choice<Value>) -> Void
    ) async {
        guard var choice = get(state), choice.isWritable else { return }
        choice.pending = value
        set(&state, choice)
        emit()
        try? await Task.sleep(for: latency)
        guard var latest = get(state) else { return }
        latest.value = value
        latest.pending = nil
        set(&state, latest)
        emit()
    }

    /// One audio channel's setting, as the other settings settle.
    private func setAudio(_ channel: Int, _ setting: AudioSetting) async {
        func get<T>(_ path: KeyPath<AudioChannel, T?>) -> (CameraState) -> T? {
            { $0.audioChannels.first { $0.id == channel }?[keyPath: path] }
        }
        func put<T>(_ path: WritableKeyPath<AudioChannel, T?>) -> (inout CameraState, T) -> Void {
            { state, value in
                if let index = state.audioChannels.firstIndex(where: { $0.id == channel }) {
                    state.audioChannels[index][keyPath: path] = value
                }
            }
        }
        switch setting {
        case .input(let input): await settle(input, get: get(\.input), set: put(\.input))
        case .gain(let gain): await settle(level: gain, get: get(\.gain), set: put(\.gain))
        case .phantomPower(let on): await settle(on, get: get(\.phantomPower), set: put(\.phantomPower))
        case .lowCut(let on): await settle(on, get: get(\.lowCut), set: put(\.lowCut))
        case .pad(let on): await settle(on, get: get(\.pad), set: put(\.pad))
        }
    }

    private func settle(level value: Double, get: (CameraState) -> Level?, set: (inout CameraState, Level) -> Void) async {
        guard var level = get(state), level.isWritable else { return }
        let clamped = min(max(value, level.range.lowerBound), level.range.upperBound)
        level.pending = clamped
        set(&state, level)
        emit()
        try? await Task.sleep(for: latency)
        guard var latest = get(state) else { return }
        latest.value = clamped
        latest.pending = nil
        set(&state, latest)
        emit()
    }

    private func startHeartbeat() {
        guard let interval = heartbeatInterval else { return }
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.jitterLatency()
            }
        }
    }

    /// The meters of a demo that has them (a VENICE's four), about seven times a second, as the camera sends them: the
    /// first two a voice that comes and goes, the others the room.
    private func startMeters() {
        guard heartbeatInterval != nil, state.audioMeterCount > 0 else { return }
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            var t = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(140))
                t += 0.14
                await self?.moveMeters(at: t)
            }
        }
    }

    private func moveMeters(at t: Double) {
        guard state.connection == .connected, state.audioMeterCount > 0 else { return }
        let voice = max(0, sin(t * 0.9)) * (0.55 + 0.15 * sin(t * 7.3))
        state.audioMeters = (0..<state.audioMeterCount).map { channel in
            let level = channel < 2 ? 0.2 + voice + Double.random(in: -0.03...0.03) : 0.12 + Double.random(in: 0...0.05)
            return min(max(level, 0), 1)
        }
        emit()
    }

    private func jitterLatency() {
        guard state.connection == .connected else { return }
        state.latencyMilliseconds = Int.random(in: 24...62)
        emit()
    }

    /// A VENICE demo's lists follow its imager mode, project rate, format and base ISO, as the camera's do (Sony's
    /// tables, `VeniceTables`): what each mode allows, never more.
    private func veniceListsFollow() {
        guard CameraProfile.isVenice(state.model), let imager = state.resolution?.value else { return }
        let model = state.model
        let project = state.frameRate?.project.value
        let codec = state.fileFormat?.value
        let highBase = (state.baseISO?.value ?? 0) == state.baseISO?.options.max()
        state.frameRate?.project.options = VeniceTables.projectFrameRates(imager: imager, model: model)
        state.frameRate?.variableRate?.options = VeniceTables.selectFPS(imager: imager, model: model, codec: codec,
                                                                        highBase: highBase, projectRate: project)
        state.fileFormat?.options = VeniceTables.recordingFormats(imager: imager, model: model, projectRate: project)
        state.desqueeze?.options = VeniceDesqueeze.options(forImager: imager, model: model, codec: codec)
        state.shutterSpeed?.options = VeniceTables.shutterSpeeds(projectRate: project)
        emit()
    }

    private func emit() {
        continuation.yield(state)
    }

    /// New overlay settings, and the switches that read them: LUT and False Color are on only where every output is.
    private func setMonitoring(_ monitoring: MonitoringState) {
        state.monitoring = monitoring
        state.look = monitoring.onEverywhere(.lut)
        state.falseColor = monitoring.onEverywhere(.falseColor)
        emit()
    }

    // MARK: - LiveViewProvider

    public var liveViewAvailable: Bool { state.connection == .connected }

    /// Returns a minimal valid JPEG so the live view tile can be exercised without hardware.
    public func liveViewFrame() async throws -> Data {
        guard state.connection == .connected else { throw LiveViewError.disconnected }
        try? await Task.sleep(for: latency)
        return MockCameraBackend.syntheticJPEG
    }

    public func startLiveView(quality: LiveViewQuality) async throws {}
    public func stopLiveView() async {}

    /// A 2×2 pixel gray JPEG, ~300 B, synthesised once at startup.
    static let syntheticJPEG: Data = {
        // Minimal JFIF: SOI + APP0 + SOF0 + DHT + SOS + EOI, 2×2 gray.
        // Pre-encoded so there's no dependency on ImageIO in CameraCore.
        let bytes: [UInt8] = [
            0xFF,0xD8,0xFF,0xE0,0x00,0x10,0x4A,0x46,0x49,0x46,0x00,0x01,0x01,0x00,0x00,0x01,
            0x00,0x01,0x00,0x00,0xFF,0xDB,0x00,0x43,0x00,0x08,0x06,0x06,0x07,0x06,0x05,0x08,
            0x07,0x07,0x07,0x09,0x09,0x08,0x0A,0x0C,0x14,0x0D,0x0C,0x0B,0x0B,0x0C,0x19,0x12,
            0x13,0x0F,0x14,0x1D,0x1A,0x1F,0x1E,0x1D,0x1A,0x1C,0x1C,0x20,0x24,0x2E,0x27,0x20,
            0x22,0x2C,0x23,0x1C,0x1C,0x28,0x37,0x29,0x2C,0x30,0x31,0x34,0x34,0x34,0x1F,0x27,
            0x39,0x3D,0x38,0x32,0x3C,0x2E,0x33,0x34,0x32,0xFF,0xC0,0x00,0x0B,0x08,0x00,0x02,
            0x00,0x02,0x01,0x01,0x11,0x00,0xFF,0xC4,0x00,0x1F,0x00,0x00,0x01,0x05,0x01,0x01,
            0x01,0x01,0x01,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x02,0x03,0x04,
            0x05,0x06,0x07,0x08,0x09,0x0A,0x0B,0xFF,0xC4,0x00,0xB5,0x10,0x00,0x02,0x01,0x03,
            0x03,0x02,0x04,0x03,0x05,0x05,0x04,0x04,0x00,0x00,0x01,0x7D,0x01,0x02,0x03,0x00,
            0x04,0x11,0x05,0x12,0x21,0x31,0x41,0x06,0x13,0x51,0x61,0x07,0x22,0x71,0x14,0x32,
            0x81,0x91,0xA1,0x08,0x23,0x42,0xB1,0xC1,0x15,0x52,0xD1,0xF0,0x24,0x33,0x62,0x72,
            0x82,0x09,0x0A,0x16,0x17,0x18,0x19,0x1A,0x25,0x26,0x27,0x28,0x29,0x2A,0x34,0x35,
            0x36,0x37,0x38,0x39,0x3A,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x4A,0x53,0x54,0x55,
            0x56,0x57,0x58,0x59,0x5A,0x63,0x64,0x65,0x66,0x67,0x68,0x69,0x6A,0x73,0x74,0x75,
            0x76,0x77,0x78,0x79,0x7A,0x83,0x84,0x85,0x86,0x87,0x88,0x89,0x8A,0x93,0x94,0x95,
            0x96,0x97,0x98,0x99,0x9A,0xA2,0xA3,0xA4,0xA5,0xA6,0xA7,0xA8,0xA9,0xAA,0xB2,0xB3,
            0xB4,0xB5,0xB6,0xB7,0xB8,0xB9,0xBA,0xC2,0xC3,0xC4,0xC5,0xC6,0xC7,0xC8,0xC9,0xCA,
            0xD2,0xD3,0xD4,0xD5,0xD6,0xD7,0xD8,0xD9,0xDA,0xE1,0xE2,0xE3,0xE4,0xE5,0xE6,0xE7,
            0xE8,0xE9,0xEA,0xF1,0xF2,0xF3,0xF4,0xF5,0xF6,0xF7,0xF8,0xF9,0xFA,0xFF,0xDA,0x00,
            0x08,0x01,0x01,0x00,0x00,0x3F,0x00,0xFB,0xD5,0xBF,0xFF,0xD9
        ]
        return Data(bytes)
    }()

    /// Third-stop ISO ladder from half the base to eight times it, roughly what a dual-base body offers.
    static func isoOptions(base: Int) -> [Int] {
        let ladder = [100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000,
                      6400, 8000, 10000, 12800, 16000, 20000, 25600, 32000, 40000, 51200, 64000, 80000, 102400]
        return ladder.filter { $0 * 2 >= base && $0 <= base * 8 }
    }

    /// A connected camera with plausible settings for `body`.
    /// A believable camera for demos and renders. FX3, FX30 and FX2 mirror what a real FX3 reported over the
    /// network (docs/fx3-controls.md, fixtures/fx3-propinfo-full.bin): the same controls, the same option lists,
    /// the same read-only fields, and nothing the protocol doesn't offer them. The FX6 and BURANO demos predate
    /// their measurements (docs/fx6-controls.md, docs/burano-controls.md): plausible within what Sony's PTP 3 tables
    /// list for them, not yet mirrored.
    public static func sampleState(body: MockBody, label: String = "A", now: Date = Date()) -> CameraState {
        if body.isVenice {
            return veniceSampleState(label: label, now: now)
        }
        if body.isArri {
            return arriSampleState(body: body, label: label, now: now)
        }
        if body.isBlackmagic {
            var state = pyxisSampleState(now: now)
            if state.fileNaming?.cameraID?.options.contains(label) == true { state.fileNaming?.cameraID?.value = label }
            return state
        }
        var state = CameraState()
        state.connection = .connected
        state.make = .sony
        // Live view as the network gives it: the FX3 family sends it; the FX6 and BURANO don't over the network, so
        // they're watched on their SDI/HDMI instead.
        state.hasLiveView = !body.isCinemaLine
        // FX3: playback through its own buttons; into review first, no play/pause reporting. FX30 untested.
        // Cinema bodies (FX6, BURANO): full playback controls.
        if body == .fx3 {
            state.playback = PlaybackState(
                inReview: false,
                capabilities: PlaybackCapabilities(playPause: true, stop: false, nextPrevious: true, seek: false,
                                                   fastForwardRewind: true, recReview: false, review: true)
            )
        } else if body == .fx6 || body == .burano {
            // Live | Review as the BURANO's: Play from the live picture, Stop back (StateMapper.playback).
            state.playback = PlaybackState(
                isPlaying: false, inReview: false, clipName: "\(label)001C003", clipNumber: 3, clipCount: 12,
                capabilities: PlaybackCapabilities(playPause: true, stop: true, nextPrevious: true, seek: false,
                                                   fastForwardRewind: true, recReview: true, review: true)
            )
        }
        if body == .fx6 {
            // What an FX6 lets the network set (docs/fx6-controls.md), as the one measured had it.
            state.ndMode = Choice("Variable", options: ["Preset", "Variable"])
            state.colorGamut = Choice("S-Gamut3.Cine", options: ["S-Gamut3.Cine", "S-Gamut3"])
            state.shootingMode = Choice("Flexible ISO", options: ["Custom", "Flexible ISO", "Cine EI Quick", "Cine EI"])
            let lut = Choice(true, options: [false, true])
            state.monitoring = MonitoringState(outputs: [MonitorOutput(id: "LUT1", name: "SDI/HDMI", overlays: [.lut: lut]),
                                                         MonitorOutput(id: "LUT2", name: "VF", overlays: [.lut: lut])])
            state.recordedLUT = Choice(false, options: [false, true])
            state.proxyRecording = Choice(false, options: [false, true])
            state.ecs = ECSState(on: Choice(false, options: [false, true]))
            state.irisAuto = Choice(false, options: [false, true])
            state.ndAuto = Choice(false, options: [false, true])
            state.isoAuto = Choice(false, options: [false, true])
            state.focalLength = 24
            state.focusDrive = LensDrive(maxSpeed: 8, position: 0.84, distance: 59)
            state.assignableButtons = [
                AssignableButton(id: 1, function: "S&Q Motion", isOn: false, isPressable: true),
                AssignableButton(id: 2, function: "Base ISO/Sens.", isOn: false, isPressable: true),
                AssignableButton(id: 3, function: "Volume", isOn: false, isPressable: false),
                AssignableButton(id: 4, function: "Base ISO/Sens.", isOn: false, isPressable: true),
                AssignableButton(id: 5, function: "Menu", isOn: false, isPressable: false),
                AssignableButton(id: 6, function: "Display", isOn: false, isPressable: false),
                AssignableButton(id: 7, function: "VFx3/x6", isOn: false, isPressable: false),
                AssignableButton(id: 8, function: "Rec Review", isOn: false, isPressable: true),
                AssignableButton(id: 9, function: "Home", isOn: false, isPressable: false),
                AssignableButton(id: 10, function: "Focus Hold", isOn: false, isPressable: false),
            ]
        }
        if body == .burano {
            // What a BURANO lets the network set (docs/burano-controls.md).
            state.ndMode = Choice("Step", options: ["Variable", "Step"])
            state.tally = Choice("Off", options: ["Off", "Green", "Red"])
            state.call = Choice(false, options: [false, true])
            state.colorGamut = Choice("S-Gamut3.Cine", options: ["S-Gamut3.Cine", "S-Gamut3"])
            state.cameraButtons = [.menu, .home, .back, .display, .clips, .up, .down, .left, .right, .enter]
        }
        state.model = body.rawValue
        state.recording = RecordingControl(state: .idle)
        state.shutterMode = Choice(ShutterMode.angle, options: ShutterMode.allCases)
        state.whiteBalance = WhiteBalanceState(
            // An FX6 has Auto too (its White Balance Mode Setting), and takes no tint over the network.
            preset: Choice("5600K", options: WhiteBalancePresets.labels(within: 2500...9900) + (body == .fx6 ? ["Auto"] : [])),
            // Sony reports Kelvin as UINT16 with sentinels below 2500K and above 9900K (docs/protocol.md).
            kelvin: Level(5600, range: 2500...9900, step: 100),
            tint: body.isCinemaLine ? Level(0, range: -99...99, step: 1, isWritable: body != .fx6)
                : Level(0, range: -7...7, step: 0.25)
        )
        state.focusMode = Choice("MF", options: ["AF-C", "MF"])
        // Autofocus settings as an FX3 lists them; an FX6 and BURANO have their own below.
        state.subjectRecognition = Choice("Face/Eye Priority AF", options: ["Face/Eye Priority AF", "Off"])
        state.focusArea = Choice("Wide", options: ["Wide", "Zone", "Center", "Flexible Spot S", "Flexible Spot M",
                                                   "Flexible Spot L", "Expand Flexible Spot"])
        state.afTransitionSpeed = Choice(4, options: Array(1...7))
        state.afSubjectShift = Choice(1, options: Array(1...5))
        state.afAssist = Choice(true, options: [false, true])
        if body == .burano {
            // A BURANO's AF / MF and autofocus settings, all display-only with the lens it had.
            state.focusMode = Choice("MF", options: ["AF", "MF"], isWritable: false)
            state.subjectRecognition = Choice("Face/Eye Priority AF",
                                              options: ["Face/Eye Only AF", "Face/Eye Priority AF", "Off"], isWritable: false)
            state.focusArea = Choice("Wide", options: ["Wide", "Zone", "Flexible Spot"], isWritable: false)
            state.afTransitionSpeed = Choice(5, options: Array(1...7), isWritable: false)
            state.afSubjectShift = Choice(5, options: Array(1...5), isWritable: false)
            state.afAssist = Choice(true, options: [false, true], isWritable: false)
        }
        // Third stops for an f/2.8 zoom, as the FX3 reported its lens. Real cameras report the mounted lens's list.
        state.iris = Choice(4.0, options: [2.8, 3.2, 3.5, 4.0, 4.5, 5.0, 5.6, 6.3, 7.1, 8.0, 9.0, 10, 11, 13, 14, 16, 18, 20, 22])
        state.baseISO = Choice(800, options: body.baseISOs)
        state.look = Choice(true, options: [false, true])
        // As the FX3 reports them: its HDMI info and grid lines, both off. The FX6 and BURANO offer neither.
        if !body.isCinemaLine {
            state.hdmiInfo = Choice(false, options: [false, true])
            state.gridLines = Choice(false, options: [false, true])
        }
        state.batteryPercent = 76
        state.mediaRemainingMinutes = 142
        state.latencyMilliseconds = 38

        if body.isCinemaLine {
            state.shutterAngle = Choice(180, options: [11.25, 22.5, 45, 90, 144, 172.8, 180, 216, 270, 360])
            state.shutterSpeed = Choice("1/48", options: ["1/24", "1/25", "1/30", "1/48", "1/50", "1/60", "1/96", "1/100", "1/120", "1/250", "1/500", "1/1000"])
            state.frameRate = FrameRateState(
                project: Choice("23.98", options: ["23.98", "24", "25", "29.97", "50", "59.94"]),
                variable: Choice(false, options: [false, true])
            )
            state.iso = Choice(1600, options: isoOptions(base: 800))
            state.nd = NDState(
                preset: Choice("Clear", options: ["Clear", "0.6", "1.2", "1.8"]),
                variable: Level(0.25, range: 0...1, step: 0.01)
            )
            if body == .fx6 {
                // Its variable ND as the camera shows it: Clear, and 0.6 to 2.1 every 0.05.
                let densities = stride(from: 60, through: 210, by: 5).map { String(format: $0 % 10 == 0 ? "%.1f" : "%.2f", Double($0) / 100) }
                state.nd = NDState(preset: Choice("0.6", options: ["Clear"] + densities))
            }
            state.clipName = "\(label)015C006"
            state.recordingFormat = body == .burano ? "8640x5760 · X-OCN LT" : "4096x2160 · XAVC-I"
            state.resolution = Choice("3840x2160", options: ["3840x2160", "1920x1080"])
            state.fileFormat = Choice("XAVC-I", options: ["XAVC-I", "XAVC-L"])
            state.recordingSetting = Choice("Class 300", options: ["Class 300", "Class 480"])
            state.desqueeze = Choice("Off", options: ["Off", "1.3x", "2.0x"])
            state.lut = Choice("s709", options: ["s709", "709(800%)", "S-Log3", "User 1: TW Show LUT"])
        } else {
            // FX3 family, as the real FX3 reported in Cine EI, XAVC S-I 4K at 23.98.
            state.shutterAngle = Choice(180, options: [360, 300, 270, 240, 216, 210, 180, 172.8, 150, 144, 120, 90, 86.4,
                                                       72, 45, 30, 22.5, 11.25, 5.6])
            // Shutter speed is off in angle mode; it appears when the mode is switched (see `send`).
            state.frameRate = FrameRateState(
                project: Choice("23.98", options: ["59.94", "29.97", "23.98"]),
                variable: nil  // the FX3 doesn't report S&Q on/off
            )
            state.iso = Choice(800, options: [200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200])
            state.fileFormat = Choice("XAVC S-I 4K", options: ["XAVC HS 4K", "XAVC S 4K", "XAVC S HD", "XAVC S-I 4K", "XAVC S-I HD"])
            state.recordingFormat = "XAVC S-I 4K"
            // Display-only under XAVC S-I: the bitrate follows the frame rate.
            state.recordingSetting = Choice("240M 4:2:2 10bit", options: ["240M 4:2:2 10bit"], isWritable: false)
            state.lut = Choice("1 ARRI Neutral G10 Slog3", options: ["S-Log3", "s709", "709(800%)", "sLogto709-1_33",
                                                                     "1 ARRI Neutral G10 Slog3", "TW False Color"])
            state.fileNaming = FileNaming(title: Choice("C"),
                                          cameraID: Choice("A", options: (65...90).compactMap { UnicodeScalar($0).map(String.init) }),
                                          reel: Level(1, range: 1...999, step: 1))
            state.clipName = "C0007"
        }
        if body == .fx6 {
            // Nor these, on the one measured: no recording bitrate; AF / MF read-only (its lens decided: Focus Mode
            // Setting display-only on MF); the project's frame rate, codec and resolution read-only; S&Q's rate settable;
            // the shutter's speed read-only while it works in angle (and the angle in speed).
            state.focusMode = Choice("MF", options: ["AF", "MF"], isWritable: false)
            // Its autofocus settings as read with the 24 mm lens: the area display-only.
            state.subjectRecognition = Choice("Face/Eye Priority AF",
                                              options: ["Face/Eye Only AF", "Face/Eye Priority AF", "Off"])
            state.focusArea = Choice("Wide", options: ["Wide", "Zone", "Flexible Spot"], isWritable: false)
            state.afSubjectShift = Choice(5, options: Array(1...5))
            state.recordingSetting = nil
            state.frameRate?.project.isWritable = false
            state.frameRate?.variableRate = Choice(60, options: [120, 100] + (1...60).reversed().map(Double.init))
            state.fileFormat?.isWritable = false
            state.resolution?.isWritable = false
            state.shutterAngle?.isWritable = state.shutterMode?.value != .speed
            state.shutterSpeed?.isWritable = state.shutterMode?.value == .speed
        }
        return state
    }
}
