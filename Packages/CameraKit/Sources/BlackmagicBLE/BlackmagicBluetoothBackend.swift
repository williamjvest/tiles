import CameraCore
import Foundation

/// A Blackmagic camera over Bluetooth LE: the URSA Mini Pro 12K and G2, the Pocket cameras, and anything that takes
/// Blackmagic's camera control protocol over Bluetooth (the PYXIS and URSA Cine list "Bluetooth control" too). Built
/// from Blackmagic's published Camera Control document alone, not yet tried on a camera:
/// docs/blackmagic-bluetooth.md has what to check.
///
/// Range is Bluetooth's, the same room. What the protocol doesn't carry, Tiles doesn't show: no battery, media,
/// clip names or option lists from the camera, and no live view.
public actor BlackmagicBluetoothBackend: CameraBackend {
    public nonisolated let updates: AsyncStream<CameraState>
    private nonisolated let continuation: AsyncStream<CameraState>.Continuation
    private let link: any BluetoothLink
    private let recConfirmTimeout: Duration

    private var control = CameraControlState()
    private var state = CameraState()
    private var status: BlackmagicBluetooth.Status?
    private var linkReady = false
    private var heard = false
    private var eventsTask: Task<Void, Never>?
    private var recTask: Task<Void, Never>?
    private var lastTimecode: UInt32?
    private var timecodeWatch: Task<Void, Never>?
    private var recentLatencies: [Double] = []

    public init(link: any BluetoothLink, recConfirmTimeout: Duration = .seconds(3)) {
        self.link = link
        self.recConfirmTimeout = recConfirmTimeout
        let stream = AsyncStream.makeStream(of: CameraState.self, bufferingPolicy: .bufferingNewest(16))
        updates = stream.stream
        continuation = stream.continuation
    }

    // MARK: - CameraBackend

    public func connect() async {
        if eventsTask == nil {
            // One consumer for the link's events, for the backend's life: the controller reconnects the same backend.
            let events = link.events
            eventsTask = Task { [weak self] in
                for await event in events { await self?.handle(event) }
            }
        }
        control = CameraControlState()
        status = nil
        linkReady = false
        heard = false
        lastTimecode = nil
        recentLatencies = []
        state = CameraState()
        state.make = .blackmagic
        state.connection = .connecting
        emit()
        await link.open()
    }

    public func disconnect() async {
        recTask?.cancel()
        recTask = nil
        await link.close()
        linkReady = false
        state.connection = .disconnected
        emit()
    }

    public func send(_ command: CameraCommand) async {
        guard state.connection == .connected else { return }
        do {
            try await dispatch(command)
        } catch {
            state.warnings = ["\(command): \(error)"]
            emit()
        }
    }

    // MARK: - Events

    private func handle(_ event: BluetoothLinkEvent) {
        switch event {
        case .pairing:
            state.connection = .awaitingApproval
        case .ready(let model):
            linkReady = true
            state.model = model ?? state.model ?? "Blackmagic camera"
        case .status(let flags):
            status = flags
        case .incoming(let bytes):
            let messages = BMMessage.decode(bytes)
            guard !messages.isEmpty else { return }
            heard = true
            for message in messages { control.apply(message) }
            remap()
        case .timecode(let bcd):
            guard timecode(bcd) else { return }
        case .closed(let why):
            linkReady = false
            recTask?.cancel()
            recTask = nil
            state.recording.request = nil
            state.connection = why.map { .failed($0) } ?? .disconnected
            emit()
            return
        }
        updateConnection()
        emit()
    }

    /// Connected once the link is open and the camera has said something: its first messages are its settings
    /// (the protocol's "initial payload"). Off, it's reported as off rather than left connecting.
    private func updateConnection() {
        guard linkReady else { return }
        if let status, !status.contains(.powerOn) {
            state.connection = .failed("The camera is off. Switch it on, and it reconnects.")
        } else if heard || status?.contains(.cameraReady) == true {
            state.connection = .connected
        }
    }

    /// The dashboard's view of the camera, from what it has reported. REC's request and the take's start are ours.
    private func remap() {
        var next = state
        let wasRecording = state.recording.state == .recording
        control.map(into: &next)
        if let request = next.recording.request {
            let confirmed = (request == .start) == (next.recording.state == .recording)
            if confirmed {
                next.recording.request = nil
                next.takeStartedAt = request == .start ? Date() : nil
                recTask?.cancel()
                recTask = nil
            }
        } else if wasRecording, next.recording.state == .idle {
            next.takeStartedAt = nil  // stopped at the camera, or the card filled
        } else if !wasRecording, next.recording.state == .recording, next.takeStartedAt == nil, state.recording.state != .unknown {
            next.takeStartedAt = Date()  // started at the camera
        }
        state = next
    }

    /// Takes a timecode notification. True when it changed what the clock would show (they may come every frame).
    /// Running while the value moves; when the notifications stop (rec run timecode at the end of a take), the clock
    /// stops too, rather than counting on by itself.
    private func timecode(_ bcd: UInt32) -> Bool {
        let running = lastTimecode.map { $0 != bcd } ?? false
        lastTimecode = bcd
        timecodeWatch?.cancel()
        if running {
            timecodeWatch = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { return }
                await self?.timecodeStopped(at: bcd)
            }
        }
        let t = BlackmagicBluetooth.timecode(bcd: bcd)
        let format = control[.recordingFormat]?.int16s ?? []
        let rate = Int(format.first ?? 24)
        let mRate = format.count >= 5 && UInt16(bitPattern: format[4]) & 0x01 != 0
        let clock = TimecodeClock(hours: t.hours, minutes: t.minutes, seconds: t.seconds, frames: t.frames, rate: rate,
                                  fps: mRate ? Double(rate) * 1000 / 1001 : Double(rate), anchor: Date(), isRunning: running)
        if let shown = state.timecode, shown.isRunning == running, shown.rate == rate,
           abs(shown.frames(at: clock.anchor) - clock.frames) <= 2 {
            return false
        }
        state.timecode = clock
        return true
    }

    private func timecodeStopped(at bcd: UInt32) {
        guard lastTimecode == bcd, let shown = state.timecode, shown.isRunning else { return }
        let t = BlackmagicBluetooth.timecode(bcd: bcd)
        state.timecode = TimecodeClock(hours: t.hours, minutes: t.minutes, seconds: t.seconds, frames: t.frames,
                                       rate: shown.rate, fps: shown.fps, anchor: Date(), isRunning: false)
        emit()
    }

    private func emit() {
        continuation.yield(state)
    }

    // MARK: - Commands

    private func dispatch(_ command: CameraCommand) async throws {
        switch command {
        case .record(let start):
            await record(start)
        case .setISO(let iso):
            try await set(.assign(.iso, int32: [Int32(iso)]))
        case .setShutterAngle(let degrees):
            try await set(.assign(.shutterAngle, int32: [Int32((degrees * 100).rounded())]))
        case .setShutterSpeed(let label):
            guard let speed = Int32(label.split(separator: "/").last ?? "") else { return }
            try await set(.assign(.shutterSpeed, int32: [speed]))
        case .setNDPreset(let label):
            guard let stop = Stops.ndStops(label) else { return }
            // With the display mode it came with, so the camera's own ND readout doesn't change style.
            let mode = control[.ndFilter]?.fixed16s.dropFirst().first
            try await set(.assign(.ndFilter, fixed16: mode.map { [stop, $0] } ?? [stop]))
        case .setWhiteBalancePreset(let preset):
            if preset == "Auto" {
                try await write(.trigger(.setAutoWhiteBalance))  // the camera reports the Kelvin it measured
            } else if preset.hasSuffix("K"), let kelvin = Int16(preset.dropLast()) {
                try await setWhiteBalance(kelvin: kelvin, tint: nil)
            }
        case .setKelvin(let kelvin):
            try await setWhiteBalance(kelvin: Int16(kelvin.rounded()), tint: nil)
        case .setTint(let tint):
            try await setWhiteBalance(kelvin: nil, tint: Int16(tint.rounded()))
        case .setIris(let fNumber):
            try await set(.assign(.apertureFStop, fixed16: [CameraControlState.av(fNumber: fNumber)]))
        case .setFrameRate(let label):
            guard let rate = CameraControlState.frameRateValue(label) else { return }
            try await changeFormat { format in
                format[0] = rate.fps
                format[4] = Int16(bitPattern: rate.mRate ? UInt16(bitPattern: format[4]) | 0x01 : UInt16(bitPattern: format[4]) & ~0x01)
            }
        case .setFrameRateVariable(let on):
            try await changeFormat { format in
                let flags = UInt16(bitPattern: format[4])
                format[4] = Int16(bitPattern: on ? flags | 0x04 : flags & ~0x04)
                if on, format[1] == 0 { format[1] = format[0] }
            }
        case .setFrameRateVariableRate(let rate):
            try await changeFormat { format in
                format[1] = Int16(rate.rounded())
                format[4] = Int16(bitPattern: UInt16(bitPattern: format[4]) | 0x04)
            }
        case .setDynamicRange(let label):
            guard let index = CameraControlState.dynamicRanges.firstIndex(of: label) else { return }
            try await set(.assign(.dynamicRange, int8: [Int8(index)]))
        case .setFileFormat(let label):
            guard let codec = CameraControlState.codecs.first(where: { $0.label == label }) else { return }
            try await set(.assign(.codec, int8: [codec.basic, codec.variant]))
        case .setLook(let on):
            guard let lut = control[.displayLUT]?.int8s, lut.count >= 2 else { return }
            try await set(.assign(.displayLUT, int8: [lut[0], on ? 1 : 0]))
        case .setLUT(let name):
            guard let index = CameraControlState.luts.firstIndex(of: name) else { return }
            let enabled = control[.displayLUT]?.int8s.dropFirst().first ?? 1
            try await set(.assign(.displayLUT, int8: [Int8(index), index == 0 ? 0 : max(enabled, 1)]))
        case .setFalseColor(let on):
            try await setOverlay(.falseColor, on)
        case .setMonitorOverlay(let overlay, let on, _):
            try await setOverlay(overlay, on)
        case .setZebraLevel(let percent):
            try await set(.assign(.zebraLevel, fixed16: [Double(percent) / 100]))
        case .setColorBars(let on):
            try await set(.assign(.colorBars, int8: [on ? 30 : 0]))
        case .setFrameGuideRatio(let ratio):
            guard let style = CameraControlState.frameGuideStyles.firstIndex(of: ratio),
                  var overlays = control[.overlays]?.int8s, overlays.count >= 4 else { return }
            overlays[0] = Int8(style)
            try await set(.assign(.overlays, int8: overlays))
        default:
            break  // not in the protocol: shutter measurement, base ISO, playback, file naming
        }
    }

    /// REC never goes optimistic: the request waits for the camera to report the transport mode it asked for.
    private func record(_ start: Bool) async {
        guard state.recording.request == nil else { return }
        guard state.recording.state != .unknown else {
            state.recording.failure = RecordingControl.Failure.notReported
            emit()
            return
        }
        guard (state.recording.state == .recording) != start else { return }  // there already: absolute
        state.recording.request = start ? .start : .stop
        state.recording.failure = nil
        emit()
        // Mode 2 records, 0 is preview; speed 0; the camera's flags and media as it last reported them.
        let now = control[.transportMode]?.int8s ?? []
        func kept(_ i: Int) -> Int8 { now.indices.contains(i) ? now[i] : 0 }
        do {
            try await write(.assign(.transportMode, int8: [start ? 2 : 0, 0, kept(2), kept(3), kept(4)]))
        } catch {
            state.recording.request = nil
            state.recording.failure = RecordingControl.Failure.notSent
            emit()
            return
        }
        recTask?.cancel()
        recTask = Task { [weak self, recConfirmTimeout] in
            try? await Task.sleep(for: recConfirmTimeout)
            guard !Task.isCancelled else { return }
            await self?.recTimedOut()
        }
    }

    private func recTimedOut() {
        guard let request = state.recording.request else { return }
        state.recording.request = nil
        state.recording.failure = RecordingControl.Failure.notConfirmed(start: request == .start)
        emit()
    }

    private func setWhiteBalance(kelvin: Int16?, tint: Int16?) async throws {
        let now = control[.manualWhiteBalance]?.int16s ?? []
        guard let k = kelvin ?? now.first else { return }
        let t = tint ?? (now.count >= 2 ? now[1] : 0)
        try await set(.assign(.manualWhiteBalance, int16: [k, t]))
    }

    /// Recording format (1.9) changes go out whole, from what the camera last reported.
    private func changeFormat(_ change: (inout [Int16]) -> Void) async throws {
        guard var format = control[.recordingFormat]?.int16s, format.count >= 5 else { return }
        change(&format)
        try await set(.assign(.recordingFormat, int16: format))
    }

    /// Display tools (4.1) and overlays (3.0) are flags for a set of displays: every display, as one switch.
    private func setOverlay(_ overlay: MonitorOverlay, _ on: Bool) async throws {
        let (parameter, bit): (BMParameter, UInt16)
        switch overlay {
        case .zebra: (parameter, bit) = (.exposureAndFocusTools, 0x1)
        case .focusAssist: (parameter, bit) = (.exposureAndFocusTools, 0x2)
        case .falseColor: (parameter, bit) = (.exposureAndFocusTools, 0x4)
        case .statusText: (parameter, bit) = (.overlayEnables, 0x1)
        case .frameGuides: (parameter, bit) = (.overlayEnables, 0x2)
        case .cleanFeed: (parameter, bit) = (.overlayEnables, 0x4)
        case .lut:
            try await dispatch(.setLook(on))
            return
        default:
            return
        }
        guard let flags = control[parameter]?.bitFields.first else { return }
        let next = on ? flags | bit : flags & ~bit
        try await set(.assign(parameter, int16: [Int16(bitPattern: next), Self.everyDisplay]))
    }

    /// LCD, HDMI, EVF, main SDI and front SDI.
    static let everyDisplay: Int16 = 0x1F

    /// Sends a setting and shows it, the camera's own report overwriting it when it comes (it clamps what it can't
    /// take). Whether the camera echoes a Bluetooth change back is one of the hardware checks.
    private func set(_ message: BMMessage) async throws {
        try await write(message)
        control.apply(message)
        remap()
        emit()
    }

    private func write(_ message: BMMessage) async throws {
        let started = ContinuousClock.now
        try await link.send(message.encoded)
        let elapsed = ContinuousClock.now - started
        recentLatencies.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        if recentLatencies.count > 4 { recentLatencies.removeFirst() }
        state.latencyMilliseconds = Int((recentLatencies.reduce(0, +) / Double(recentLatencies.count)).rounded())
    }
}

