import CameraCore
import Foundation
import os

/// An ARRI camera — ALEXA Mini first, and the Mini LF, ALEXA 35 and AMIRA — over its Web Remote's HTTP interface
/// (docs/arri.md): `all.cgi` once to open a session and read every variable; the page script for enum labels; then
/// `update.cgi?id=` polled continuously with the session id, as the camera's own page does. Each answer carries only
/// what changed for this session since the last poll, including any updated min/max/readonly. An `{"ERROR": "…Invalid
/// id…"}` answer means the session is gone: call `all.cgi` again. Network errors wait ~3 s then do the same.
///
/// HaLow: answers on a real camera arrive every 0.2–1 s (level sensor, temperature, timecode), so the long poll is
/// never idle for long. Big answers are paced to stay near `trafficBudget`. A camera whose `update.cgi` returns a 404
/// or a non-change-list answer falls back to polling `all.cgi` at the same budget. Two failed reads in a row drop the
/// link; the controller reconnects on its backoff.
///
/// REC is a command, never optimistic, and absolute (`record(true)` only to a camera that says it isn't rolling).
/// Everything unusual is logged (`com.toldwell.twcc`, category `arri`).
public actor ArriCameraBackend: CameraBackend {
    public nonisolated let updates: AsyncStream<CameraState>
    private nonisolated let continuation: AsyncStream<CameraState>.Continuation

    public nonisolated let client: ArriClient?
    private let host: String
    private let label: String
    private let log = Logger(subsystem: "com.toldwell.twcc", category: "arri")

    /// Bits a second the background reads aim to stay under (the long poll's answers, or the fallback's polling).
    public var trafficBudget: Double = 64_000

    private var reading: ArriReading?
    private var pending: [String: (value: ArriValue, since: Date)] = [:]
    private var state = CameraState()
    private var updateTask: Task<Void, Never>?
    /// The last `set.cgi` sent: each waits for the one before, so a dial turned quickly lands in the order it turned
    /// (two connections could otherwise deliver them out of order).
    private var lastWrite: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    /// A pick from the Clips window is being stepped to (`goToClip`), and the clip it's heading for now: a newer pick
    /// changes it.
    private var steppingToClip = false
    private var clipTarget: Int?
    private var polling = false
    private var unansweredUpdates = 0
    private var failures = 0
    /// Until when a software reload the camera announced (PrepareCommandFWWillReload) is expected: the link may drop
    /// meanwhile, and that is shown as stale, not as a lost camera.
    private var reloadingUntil: Date?
    private var reloading: Bool { reloadingUntil.map { Date() < $0 } ?? false }
    /// True once a full read has succeeded while stale (the session broke and reconnected via all.cgi during the reload).
    /// After this, update answers that show SystemSoftwareIsRestarting false can flip the connection back to connected.
    private var reloadSessionBroke = false
    private var lastAllBytes = 0
    private var recConfirmTimeout: TimeInterval = 6
    /// The shortest wait between `all.cgi` reads when the long poll isn't there.
    private var pollInterval: TimeInterval = 2
    /// Bytes read since connecting, for camctl and the network budget.
    public private(set) var bytesRead = 0

    public init(host: String, label: String = "A",
                cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("ArriWebRemote", isDirectory: true)) {
        self.host = host.trimmingCharacters(in: .whitespaces)
        self.label = label
        client = try? ArriClient(host: host, cacheDirectory: cacheDirectory)
        let stream = AsyncStream.makeStream(of: CameraState.self, bufferingPolicy: .bufferingNewest(4))
        updates = stream.stream
        continuation = stream.continuation
        state.make = .arri
        state.model = "ALEXA"
    }

    /// For tests: a quicker REC confirmation window, polling interval, or a different traffic budget.
    public func configure(recConfirmTimeout: TimeInterval? = nil, pollInterval: TimeInterval? = nil,
                          trafficBudget: Double? = nil) {
        if let recConfirmTimeout { self.recConfirmTimeout = recConfirmTimeout }
        if let pollInterval { self.pollInterval = pollInterval }
        if let trafficBudget { self.trafficBudget = trafficBudget }
    }

    /// What the camera's variables are now, with the page script's enums (camctl's `--dump`).
    public var currentReading: ArriReading? { reading }

    // MARK: - CameraBackend

    public func connect() async {
        guard state.connection != .connected && state.connection != .connecting else { return }
        guard let client else {
            state.connection = .failed("ARRI: not an address: \(host)")
            yield()
            return
        }
        state.connection = .connecting
        yield()
        do {
            let (snapshot, bytes) = try await client.all()
            bytesRead += bytes
            lastAllBytes = bytes
            let probe = ArriReading(snapshot: snapshot, catalog: ArriEnumCatalog())
            var catalog = ArriEnumCatalog()
            do {
                // Kept per camera and firmware: ARRI warns the page can misbehave after an update until the browser's
                // cache is cleared (ALEXA 35 manual, 23.1), so a new SUP never reuses the old script.
                let key = [probe.text(.serial), probe.firmwareText].compactMap { $0 }.joined(separator: "-")
                let script = try await client.pageScript(key: key.isEmpty ? nil : key)
                bytesRead += script.bytes
                catalog = ArriEnumCatalog(javascript: script.text)
                let enums = catalog.tokens.count
                log.notice("page script: \(script.bytes, privacy: .public) bytes, \(enums, privacy: .public) enums")
            } catch {
                log.error("page script: \(String(describing: error).prefix(160), privacy: .public)")
            }
            if catalog.isEmpty {
                catalog = ArriEnumCatalog.fallback(for: snapshot, model: probe.modelText)
                let model = probe.modelText ?? "an ALEXA Mini"
                log.notice("no enum labels from the camera: Tiles' tables for \(model, privacy: .public)")
            }
            reading = ArriReading(snapshot: snapshot, catalog: catalog)
            logResolution()
        } catch {
            log.error("connect failed: \(String(describing: error).prefix(200), privacy: .public)")
            ActivityLog.shared.note(host, "ARRI connect failed: \(String(describing: error).prefix(140))")
            state.connection = .failed(readableReason(error))
            yield()
            return
        }
        failures = 0
        polling = false
        unansweredUpdates = 0
        state.connection = .connected
        // The session id from all.cgi stays for the lifetime of this connection: never re-read all.cgi unless the
        // session is lost (Invalid id error, network failure) or update.cgi is absent.
        rebuild()
        ActivityLog.shared.note(host, "ARRI connected (\(state.model ?? "?"))")
        yield()
        startUpdates()
    }

    public func disconnect() async {
        updateTask?.cancel()
        refreshTask?.cancel()
        updateTask = nil
        refreshTask = nil
        state.connection = .disconnected
        yield()
    }

    public func send(_ command: CameraCommand) async {
        guard state.connection == .connected, let reading else { return }
        switch command {
        case .record(let start):
            await record(start)
        case .setISO(let ei):
            if let index = reading.index(of: String(ei), in: .ei, normalise: { ArriFormat.eiNumber($0).map(String.init) ?? $0 }) {
                await write([.ei: .number(Double(index))])
            }
        case .setNDPreset(let label):
            if let index = reading.index(of: label, in: .nd, normalise: ArriFormat.ndLabel) {
                await write([.nd: .number(Double(index))])
            }
        case .setKelvin(let kelvin):
            await write([.kelvin: .number(kelvin.rounded())])
        case .setTint(let tint):
            await write([.tint: .number((tint * 10).rounded() / 10)])
        case .setWhiteBalancePreset(let preset):
            if preset == "AWB", let id = reading.autoWhiteBalanceID {
                // The camera measures and pushes the Kelvin and tint it found (and MessageEventAWB).
                await runID(id, name: "AutoWB", [:])
                scheduleRefresh(after: polling ? 1 : 2)
            } else if preset.hasSuffix("K"), let kelvin = Double(preset.dropLast()) {
                await write([.kelvin: .number(kelvin), .tint: .number(0)])
            }
        case .setShutterAngle(let angle):
            await write([.shutterAngle: .number((angle * 10).rounded() / 10)])
        case .setShutterSpeed(let speed):
            if let fps = reading.value(.fps)?.number, let angle = ArriTables.angle(forSpeed: speed, fps: fps) {
                await write([.shutterAngle: .number(angle)])
            }
        case .setShutterMode(let mode):
            await write([.shutterIsAngle: .bool(mode == .angle)])
        case .setFrameRate(let label):
            if let fps = Double(label) { await write([.fps: .number(fps)]) }
        case .setResolution(let mode):
            if let index = reading.index(of: mode, in: .sensorMode) { await change(.sensorMode, to: index, prep: "SensorFormatPrep") }
        case .setFileFormat(let codec):
            if let index = reading.index(of: codec, in: .codec) { await change(.codec, to: index, prep: "MediaCodecPrep") }
        case .setLUT(let look):
            if let index = reading.index(of: look, in: .look) { await write([.look: .number(Double(index))]) }
        case .setDesqueeze(let ratio):
            if let index = reading.index(of: ratio, in: .desqueeze) {
                await write([.desqueeze: .number(Double(index))])
            } else if reading.variable(.desqueeze)?.isBool == true {
                await write([.desqueeze: .bool(ratio.lowercased() != "off")])
            }
        case .setColorBars(let on):
            if let sw = reading.switchBinding(.colorBars, onWords: ["bar", "on", "enabled"]) {
                await writeNamed([sw.variable: on ? sw.on : sw.off])
            }
        case .setImageFlip(let on):
            if let sw = reading.switchBinding(.imageFlip, onWords: ArriReading.flipWords) {
                await writeNamed([sw.variable: on ? sw.on : sw.off])
            }
        case .setLook(let on):
            await setOverlay(.lut, on, output: nil)
        case .setFalseColor(let on):
            await setOverlay(.falseColor, on, output: nil)
        case .setMonitorOverlay(let overlay, let on, let output):
            await setOverlay(overlay, on, output: output)
        case .setClipCameraID(let letter):
            if let index = reading.index(of: letter, in: .cameraIndex, normalise: { $0.uppercased() }) {
                await write([.cameraIndex: .number(Double(index))])
            } else if let scalar = letter.uppercased().unicodeScalars.first, (65...90).contains(scalar.value),
                      reading.variable(.cameraIndex)?.isEnum == false {
                await write([.cameraIndex: .number(Double(scalar.value - 65))])
            }
        case .setClipReel(let reel):
            await write([reading.reelField ?? .reel: .number(Double(reel))])
        case .playback(let command):
            await play(command)
        case .setOutputFollows(let on, let output) where output == "Sdi2":
            await writeNamed(["SDI2IsSDI1Clone": .bool(on)])
        default:
            break  // Iris and focus: the Web Remote reads the lens, it doesn't drive it.
        }
        yield()
    }

    // MARK: - Writes

    /// A sensor format or codec, the way an ALEXA Mini's own page changes one: the target goes to the "…Prepare" twin
    /// through the prepare command (the camera then works out what the change does: a software reload, the new fastest
    /// rate), and the value itself is written a moment later. The camera reloads its software (10–20 s) and the link
    /// comes back through the usual reconnect. The tile has asked first: these choices carry `restartRequired`. A
    /// camera without the twin takes the value directly.
    private func change(_ field: ArriField, to index: Int, prep: String) async {
        guard let reading, let name = reading.fields[field] else { return }
        let twin = name + "Prepare"
        guard reading.snapshot.variables[twin] != nil else {
            await write([field: .number(Double(index))])
            return
        }
        let ids = reading.snapshot.commandIDs(named: prep)
        // The page's own command for each, when the camera has it; else the first of that name.
        let id = ids.first { ["_GnbMUFfSEeWK7Pu_oST6Ew", "_CAhSoFfSEeWK7Pu_oST6Ew"].contains($0) } ?? ids.first
        let counted = reading.snapshot.variables["PrepareCommandResultCount"]?.value.number
        guard let id, await runID(id, name: prep, [twin: .number(Double(index))]) else {
            log.notice("\(prep, privacy: .public): not on this camera, \(name, privacy: .public) left as it is")
            return
        }
        // As the page: the twin set as well, and the value written once the camera has worked the change out
        // (PrepareCommandResultCount moves), not before. Written 0.8 s after the command, a codec change was
        // ignored; written after the camera's answer, it took.
        await writeNamed([twin: .number(Double(index))])
        let asked = Date()
        while Date().timeIntervalSince(asked) < 3 {
            if let now = self.reading?.snapshot.variables["PrepareCommandResultCount"]?.value.number, now != counted { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(300))
        let reloads = self.reading?.snapshot.variables["PrepareCommandFWWillReload"]?.value.bool == true
        await writeNamed([name: .number(Double(index))])
        if reloads {
            ActivityLog.shared.note(host, "ARRI: \(name) changed, the camera reloads its software")
            reloadingUntil = Date().addingTimeInterval(45)
            reloadSessionBroke = false
            state.connection = .stale
            yield()
        }
    }

    private func write(_ values: [ArriField: ArriValue]) async {
        guard let reading else { return }
        var named: [String: ArriValue] = [:]
        for (field, value) in values {
            if let name = reading.fields[field] { named[name] = value }
        }
        await writeNamed(named)
    }

    /// Sends settings by the camera's names: checked against what the camera allows now (read-only, its range, an
    /// enum choice it can't take), shown as pending until the camera reports them, sent in one `set.cgi`.
    private func writeNamed(_ values: [String: ArriValue]) async {
        guard let client, let reading else { return }
        var body: [String: ArriValue] = [:]
        for (name, raw) in values {
            guard let variable = reading.snapshot.variables[name] else { continue }
            guard !variable.readOnly else {
                log.notice("\(name, privacy: .public) is read-only now: not sent")
                continue
            }
            var value = raw
            if variable.isEnum, let index = raw.number.map({ Int($0) }) {
                guard variable.selectable(index) else {
                    log.notice("\(name, privacy: .public) = \(index, privacy: .public) isn't selectable now")
                    continue
                }
            } else if let number = raw.number, case .number = raw {
                guard number.isFinite else { continue }
                let low = variable.min ?? -Double.infinity, high = variable.max ?? Double.infinity
                value = .number(min(max(number, low), high))
            }
            body[name] = value
        }
        guard !body.isEmpty else { return }
        for (name, value) in body { pending[name] = (value, Date()) }
        rebuild()
        yield()
        let sent = body
        let names = sent.keys.sorted().joined(separator: ", ")
        let previous = lastWrite
        let sending = Task { () -> Error? in
            await previous?.value
            do { try await client.set(sent); return nil } catch { return error }
        }
        lastWrite = Task { _ = await sending.value }
        if let error = await sending.value {
            for name in sent.keys { pending[name] = nil }
            let why = String(describing: error).prefix(140)
            log.error("set \(names, privacy: .public): \(why, privacy: .public)")
            ActivityLog.shared.note(host, "ARRI refused \(names): \(why.prefix(80))")
            rebuild()
            yield()
            return
        }
        let text = sent.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        log.notice("→ \(text, privacy: .public)")
        // A frame rate, sensor mode or codec moves other limits: read them all back once things settle. Without a
        // working long poll, every write is read back. Anything the camera never confirms stops showing as pending.
        let limits = [ArriField.fps, .sensorMode, .codec].compactMap { reading.fields[$0] }
        if polling || body.keys.contains(where: limits.contains) {
            scheduleRefresh(after: polling ? 0.4 : 1.0)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            await self?.expirePending()
        }
    }

    private func setOverlay(_ overlay: MonitorOverlay, _ on: Bool, output: String?) async {
        guard let reading else { return }
        var values: [String: ArriValue] = [:]
        // While an ALEXA Mini clones SDI 1 onto SDI 2, an every-output switch leaves SDI 2 to follow (its own setting
        // is grayed on the camera).
        let cloned = reading.snapshot.variables["SDI2IsSDI1Clone"]?.value.bool == true
        for out in reading.outputs where output == nil || out.id == output {
            if output == nil, cloned, out.id == "Sdi2" { continue }
            guard let sw = out.switches[overlay] else { continue }
            // Off on an exposure tool showing the other overlay (zebra while asked to turn false color off) is left. What
            // it shows counts a write still on its way: off just after on was left, the camera's reading not having the
            // on yet, and zebra stayed on (camctl shakedown against the mock ALEXA, 2026-11-14).
            let current = pending[sw.variable]?.value ?? reading.snapshot.variables[sw.variable]?.value
            if !on, let current, sw.isOn(current) == false { continue }
            values[sw.variable] = on ? sw.on : sw.off
        }
        await writeNamed(values)
    }

    // MARK: - REC

    private func record(_ start: Bool) async {
        guard let client, let reading else { return }
        let isRecording = state.recording.state == .recording
        // Absolute, and one at a time: a second tap while the first is still being confirmed sends nothing.
        guard isRecording != start, state.recording.request == nil else { return }
        let names = start ? ["RecordingStart", "RecordStart", "RecStart", "StartRecording"]
            : ["RecordingStop", "RecordStop", "RecStop", "StopRecording"]
        guard let id = names.lazy.compactMap({ reading.snapshot.commandIDs(named: $0).first }).first else {
            state.recording.failure = RecordingControl.Failure.noCommand
            log.error("no REC command among \(reading.snapshot.commands.count, privacy: .public) commands")
            yield()
            return
        }
        state.recording.request = start ? .start : .stop
        state.recording.failure = nil
        yield()
        do {
            try await client.call(id)
        } catch {
            state.recording.request = nil
            state.recording.failure = RecordingControl.Failure.notSent
            log.error("rec: \(String(describing: error).prefix(160), privacy: .public)")
            ActivityLog.shared.note(host, "REC \(start ? "start" : "stop") didn't reach the camera: \(String(describing: error).prefix(160))")
            yield()
            return
        }
        if reading.recording() == nil {
            // Nothing to read back (no state variable, or one that can't be told): the camera accepted, that's all.
            state.recording.request = nil
            state.recording.state = start ? .recording : .idle
            state.takeStartedAt = start ? Date() : nil
            log.notice("REC \(start ? "start" : "stop", privacy: .public) accepted; no state variable to confirm it")
            yield()
            return
        }
        // The long poll brings the new state; if it doesn't in time, read everything and say what happened.
        let deadline = Date().addingTimeInterval(recConfirmTimeout)
        while Date() < deadline, (state.recording.state == .recording) != start {
            try? await Task.sleep(for: .milliseconds(150))
        }
        if (state.recording.state == .recording) != start {
            await fullRead()
            if (state.recording.state == .recording) != start {
                state.recording.failure = RecordingControl.Failure.notConfirmed(start: start)
            }
        }
        state.recording.request = nil
        yield()
    }

    // MARK: - Playback

    /// The page's playback commands: PlayBackPrepare cues the card with clips, PlayBackGo plays, PlayBackStop pauses,
    /// PlayBackEnd goes back to live (`endPlayback`), PlayBackSkipClip steps a clip; shuttle speeds are the
    /// PlaybackSpeedEnum.
    private func play(_ command: PlaybackCommand) async {
        guard let reading else { return }
        let cued = (reading.value(.playbackClipIndex)?.number ?? -1) >= 0
        switch command {
        case .togglePlay where state.playback?.isPlaying == true, .pause, .stop:
            await run("PlayBackStop")
        case .play, .togglePlay, .review:
            // Review plays too: it's for checking what was just shot.
            if !cued { guard await prepare() else { return } }
            await run("PlayBackGo")
        case .live:
            await endPlayback()
        case .next, .previous:
            await skip(forward: command == .next)
        case .fastForward, .scan(forward: true):
            await shuttle(forward: true)
        case .rewind, .scan(forward: false):
            await shuttle(forward: false)
        case .endScan:
            await setSpeed("FWD_1")
        case .goToClip(let index):
            await goToClip(index + 1)
        default:
            break
        }
        scheduleRefresh(after: polling ? 0.4 : 1.5)
    }

    /// The clip the Clips window picked (`number`, from 1, as the Playback tile counts them: PlaybackClipIndex + 1),
    /// playing. Cued first where nothing is (PlayBackPrepare, as Review), then PlayBackSkipClip a clip at a time by
    /// where a fresh read says it is, then PlayBackGo. A pick while another still steps changes where that one goes.
    /// Not during a take. Built from the commands an ALEXA Mini's page sends; never run on one (docs/feature-gaps.md).
    private func goToClip(_ number: Int) async {
        var idle: Bool { state.recording.state == .idle }
        guard number >= 1, idle else { return }
        clipTarget = number
        guard !steppingToClip else { return }
        steppingToClip = true
        defer { steppingToClip = false; clipTarget = nil }
        if (reading?.value(.playbackClipIndex)?.number ?? -1) < 0 {
            guard await prepare() else { return }
            // Cued once a read says which clip (Review plays straight on; stepping needs where it starts): 3 s at most.
            for _ in 0..<15 where (reading?.value(.playbackClipIndex)?.number ?? -1) < 0 {
                try? await Task.sleep(for: .milliseconds(200))
                await fullRead()
            }
        }
        func wanted(_ total: Int) -> Int { min(clipTarget ?? number, total) }
        // Again if a pick lands meanwhile, even while PlayBackGo goes: the last tap wins (five at most).
        for _ in 0..<5 {
            let target = clipTarget
            let end = await ClipStepper.step(
                to: wanted,
                read: {
                    await self.fullRead()
                    guard let n = self.state.playback?.clipNumber, let t = self.state.playback?.clipCount else { return nil }
                    return (n, t)
                },
                press: { forward in await self.skip(forward: forward) },
                keepGoing: { idle })
            guard let end else {
                ActivityLog.shared.note(host, "Clips: lost which clip the camera has cued; nothing played")
                return
            }
            if end.number != wanted(end.total) {
                ActivityLog.shared.note(host, "Clips: clip \(end.number) of \(end.total) is cued, not clip \(wanted(end.total))")
            }
            guard idle else { return }
            guard clipTarget == target else { continue }
            await run("PlayBackGo")
            if clipTarget == target { return }
        }
    }

    /// Cues playback on the appropriate card. Sends the Mini's page payload: `{"_TableVersion_Local": <version>}` with
    /// the matching command id for the card in use. The card is chosen by `PlaybackMediumActive` when present (the
    /// Mini's active-card variable), else by whichever card has clips. Falls back to the first PlayBackPrepare id when
    /// neither card-specific id is in the commands map.
    private func prepare() async -> Bool {
        guard let reading else { return false }
        let onB = (reading.value(.clipCountB)?.number ?? 0) > 0
        let onA = (reading.value(.clipCountA)?.number ?? 0) > 0
        guard onA || onB else {
            log.notice("playback: no clips on either card")
            return false
        }
        // PlaybackMediumActive on the Mini: {None, Card A, Card B} as an enum. Index 2 = Card B, 1 = Card A.
        let activeIndex = reading.snapshot.variables["PlaybackMediumActive"]?.value.number?.asInt
        let useB: Bool
        if let active = activeIndex, active > 0 {
            useB = active == 2
        } else {
            useB = onB
        }
        // The Mini's page sends {_TableVersion_Local: <clip table version>} with a card-specific command id.
        let prepareIDForB = "_EeUkIwIBEeSgptigTra4vQ"
        let prepareIDForA = "_EeUkLAIBEeSgptigTra4vQ"
        let ids = reading.snapshot.commandIDs(named: "PlayBackPrepare")
        let commandID: String
        if useB, ids.contains(prepareIDForB) {
            commandID = prepareIDForB
        } else if !useB, ids.contains(prepareIDForA) {
            commandID = prepareIDForA
        } else {
            commandID = ids.first ?? prepareIDForB
        }
        var values: [String: ArriValue] = [:]
        let tableField: ArriField = useB ? .clipTableB : .clipTableA
        if let name = reading.fields[tableField], let version = reading.snapshot.variables[name]?.value {
            values["_TableVersion_Local"] = version
        }
        return await runID(commandID, name: "PlayBackPrepare", values)
    }

    /// The PlayBackEnd the page's own exit sends. An ALEXA Mini lists another, its LOCK button's, which sorts first.
    static let pageEndID = "_cCCFscHSEeStK8NH8ZPGbQ"

    /// Back to live as the camera's own page does it: PlayBackEnd, then its screen off the playback page (GuiMode
    /// NORMAL). PlayBackEnd alone ends playback but leaves an ALEXA Mini's own screen on that page, "No clip selected",
    /// until PLAY is held on the camera or REC is pressed, which also rolls. In a capture of the page, GuiMode stayed
    /// PLAYBACK after every PlayBackEnd sent on its own, and the page set it to NORMAL itself, right after its
    /// PlayBackEnd. Sent whatever the camera's state, as the page's exit does; a menu or erase dialog
    /// open on the camera's screen is left alone.
    private func endPlayback() async {
        guard let ids = reading?.snapshot.commandIDs(named: "PlayBackEnd") else { return }
        if ids.contains(Self.pageEndID) {
            await runID(Self.pageEndID, name: "PlayBackEnd", [:])
        } else {
            await run("PlayBackEnd")
        }
        guard let reading, reading.screenInPlayback else { return }
        guard let normal = reading.catalog.tokens(forVariable: "GuiMode")?.firstIndex(of: "NORMAL"),
              let variable = reading.snapshot.variables["GuiMode"], !variable.readOnly, variable.selectable(normal) else {
            // Another body, or a page script without GuiMode's tokens: the screen may stay on its playback page.
            ActivityLog.shared.note(host, "ARRI: playback ended, but the camera's screen can't be taken off its playback "
                                    + "page from here (GuiMode NORMAL isn't writable): hold PLAY on the camera")
            return
        }
        await writeNamed(["GuiMode": .number(Double(normal))])
    }

    /// One clip back or forward. The two PlayBackSkipClip IDs are told apart by the ones a Mini LF uses; a camera with
    /// others is skipped by their order (to confirm on the first session).
    private func skip(forward: Bool) async {
        guard let reading else { return }
        let ids = reading.snapshot.commandIDs(named: "PlayBackSkipClip")
        let known = forward ? "_H_V7l8JjEeSbpa7lQ8OAJw" : "_BJbzscJjEeSbpa7lQ8OAJw"
        let id = ids.contains(known) ? known : (ids.count == 2 ? (forward ? ids[1] : ids[0]) : ids.first)
        guard let id else { return }
        await runID(id, name: "PlayBackSkipClip", [:])
    }

    /// Shuttle: the next speed up in the direction asked (2×, 4×, … 32×), from wherever it is.
    private func shuttle(forward: Bool) async {
        guard let reading, let token = reading.playbackSpeedToken else { return }
        let prefix = forward ? "FWD_" : "REV_"
        let current = token.hasPrefix(prefix) ? Int(token.dropFirst(4)) ?? 1 : 1
        await setSpeed("\(prefix)\(min(max(current * 2, 2), 32))")
    }

    private func setSpeed(_ token: String) async {
        guard let reading, let name = reading.fields[.playbackSpeed],
              let tokens = reading.catalog.tokens(forVariable: name), let index = tokens.firstIndex(of: token) else { return }
        await writeNamed([name: .number(Double(index))])
    }

    @discardableResult
    private func run(_ name: String, _ values: [String: ArriValue] = [:]) async -> Bool {
        guard let reading, let id = reading.snapshot.commandIDs(named: name).first else {
            log.notice("no \(name, privacy: .public) command on this camera")
            return false
        }
        return await runID(id, name: name, values)
    }

    @discardableResult
    private func runID(_ id: String, name: String, _ values: [String: ArriValue]) async -> Bool {
        guard let client else { return false }
        do {
            try await client.call(id, set: values)
            log.notice("call \(name, privacy: .public)")
            return true
        } catch {
            log.error("\(name, privacy: .public): \(String(describing: error).prefix(120), privacy: .public)")
            return false
        }
    }

    // MARK: - Changes

    private func startUpdates() {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            await self?.runUpdates()
        }
    }

    private func runUpdates() async {
        while !Task.isCancelled, state.connection == .connected || state.connection == .stale {
            if polling {
                await fullRead()
                let pace = max(pollInterval, Double(lastAllBytes) * 8 / trafficBudget)
                try? await Task.sleep(for: .seconds(pace))
                continue
            }
            guard let client, let id = reading?.snapshot.id else { return }
            let started = Date()
            do {
                // The camera answers every second or so (its level sensor, temperature and timecode move), and its
                // own page gives up after 3 s. Silence this long means a lost link: start again as the page does.
                guard let data = try await client.update(after: id, timeout: 10) else {
                    log.notice("update.cgi: no answer in 10 s; a new session")
                    try? await Task.sleep(for: .seconds(3))
                    await fullRead()
                    continue
                }
                failures = 0
                do {
                    bytesRead += data.count
                    let answer = absorb(update: data)
                    switch answer {
                    case .sessionExpired:
                        // The camera has a new session; re-read all.cgi to get a fresh session id.
                        await fullRead()
                    case .counterOnly:
                        // No fields in the answer (older camera firmware): read everything once.
                        await fullRead()
                        let pause = max(0.5, Double(lastAllBytes) * 8 / trafficBudget)
                        try? await Task.sleep(for: .seconds(pause))
                        continue
                    case .changes, .nothing:
                        // Changes are asked after at once, as the page does; a big answer waits its share of the
                        // budget. An answer with nothing in it waits at least 0.2 s, so a camera that answers empty
                        // at once is never asked in a tight loop.
                        let elapsed = Date().timeIntervalSince(started)
                        let floor = answer == .nothing ? 0.2 : 0
                        let pace = max(floor, Double(data.count) * 8 / trafficBudget) - elapsed
                        if pace > 0 { try? await Task.sleep(for: .seconds(pace)) }
                    }
                }
            } catch let error as ArriError {
                switch error {
                case .http(404), .http(400), .http(501):
                    // update.cgi absent or unsupported on this camera: fall back to all.cgi polling.
                    fallBackToPolling("update.cgi: \(error)")
                case .camera, .badResponse:
                    // Unexpected camera-level or parse error: fall back rather than loop on it.
                    fallBackToPolling("update.cgi: \(error)")
                default:
                    await failedRead(error)
                }
            } catch {
                // Network error: wait ~3 s then start a new session with all.cgi, as the camera's page does.
                await failedRead(error)
                if state.connection != .connected && state.connection != .stale { return }
                try? await Task.sleep(for: .seconds(3))
                await fullRead()
            }
        }
    }

    enum UpdateAnswer { case changes, counterOnly, nothing, sessionExpired }

    /// An `update.cgi` answer: folded into the variables, the tiles rebuilt if anything moved. The id echoed back is
    /// the same session id — it doesn't advance. `counterOnly` means the answer had no variable fields at all (some
    /// cameras only echo the id); the caller then does a one-off `all.cgi`. An answer that isn't a change list (no id,
    /// nothing at all, three times running) triggers a fallback to `all.cgi` polling.
    @discardableResult
    private func absorb(update data: Data) -> UpdateAnswer {
        guard var current = reading else { return .nothing }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fallBackToPolling("update.cgi answered \(data.count) bytes that aren't a JSON object")
            return .nothing
        }
        if let message = json["ERROR"] as? String {
            if message.lowercased().contains("invalid id") || message.lowercased().contains("invalid session") {
                log.notice("session expired (\(message.prefix(60), privacy: .public))")
                return .sessionExpired
            }
            fallBackToPolling("update.cgi: \(message)")
            return .nothing
        }
        let names = Set(current.snapshot.variables.keys)
        let idBefore = current.snapshot.id
        let changed = current.snapshot.merge(update: json)
        if changed.isEmpty {
            // An empty change list is the camera saying nothing moved: a normal answer.
            if json["variables"] is [String: Any] {
                unansweredUpdates = 0
                return .nothing
            }
            // A different id and no list: a camera that only says something changed. Read it once.
            if current.snapshot.id != idBefore {
                unansweredUpdates = 0
                reading?.snapshot.id = current.snapshot.id
                return .counterOnly
            }
            // Neither: not the answer this protocol gives. Three in a row, and all.cgi is read instead.
            unansweredUpdates += 1
            if unansweredUpdates >= 3 { fallBackToPolling("update.cgi answers without a change list") }
            return .nothing
        }
        unansweredUpdates = 0
        // Determine whether any entry in this answer carried field metadata (type, min, max, or readonly). When it
        // does, read-only flags and ranges are already up to date — no all.cgi needed after REC/playback state changes.
        let carriesFields = {
            let raw = json["variables"] as? [String: Any] ?? json
            return raw.values.contains { ($0 as? [String: Any]).map { d in
                d["type"] != nil || d["min"] != nil || d["max"] != nil || d["readonly"] != nil
            } ?? false }
        }()
        if changed.contains(where: { !names.contains($0) }) {
            current = ArriReading(snapshot: current.snapshot, catalog: current.catalog)  // new names: resolve again
        }
        reading = current
        for name in changed { pending[name] = nil }
        // When the update answer carries field info, ranges and read-only flags are already merged in. Only fall back
        // to a full read when the answer is value-only (older camera firmware style).
        let modes = [ArriField.recState, .playbackClipIndex].compactMap { current.fields[$0] }
        if changed.contains(where: modes.contains) && !carriesFields {
            scheduleRefresh(after: 0.5)
        }
        let text = changed.prefix(8).map { "\($0)=\(current.snapshot.variables[$0]?.value.description.prefix(24) ?? "?")" }
            .joined(separator: " ")
        log.notice("← \(text, privacy: .public)")
        // After a software reload: flip back to connected once the camera confirms it has stopped restarting.
        // Checked here so update-stream answers (which arrive before all.cgi catches up) can finish the transition.
        if state.connection == .stale {
            let isRestarting = current.snapshot.variables["SystemSoftwareIsRestarting"]?.value.bool == true
            let windowExpired = reloadingUntil.map { Date() >= $0 } ?? false
            if reloadSessionBroke && !isRestarting {
                state.connection = .connected
                reloadingUntil = nil
                reloadSessionBroke = false
                ActivityLog.shared.note(host, "ARRI: back after the software reload (update stream)")
            } else if windowExpired && !isRestarting {
                // The 45 s window passed and the camera is answering and not restarting: recover.
                state.connection = .connected
                reloadingUntil = nil
                reloadSessionBroke = false
                ActivityLog.shared.note(host, "ARRI: reload window expired, back to connected via update stream")
            }
        }
        rebuild()
        yield()
        return .changes
    }

    private func expirePending() {
        let before = pending.count
        rebuild()
        if pending.count != before { yield() }
    }

    private func fallBackToPolling(_ why: String) {
        guard !polling else { return }
        polling = true
        log.notice("reading with all.cgi instead of the long poll: \(why, privacy: .public)")
        ActivityLog.shared.note(host, "ARRI: \(why.prefix(100)); reading all.cgi instead")
    }

    /// `all.cgi`: opens a new session and reads every value, range and flag. Called on connect, on session expiry
    /// (Invalid id), on network errors (after ~3 s), and as the polling fallback when update.cgi is absent.
    private func fullRead() async {
        guard let client, let current = reading else { return }
        do {
            var (snapshot, bytes) = try await client.all()
            bytesRead += bytes
            lastAllBytes = bytes
            failures = 0
            // all.cgi's timecode can run a few seconds behind the session's own answers (an ALEXA Mini's was 3 s
            // behind at a connect): a full read doesn't take the clock back by less than five seconds.
            let tc = ["TimecodeHours", "TimecodeMinutes", "TimecodeSeconds"]
            func seconds(_ s: ArriSnapshot) -> Int? {
                let n = tc.compactMap { s.variables[$0]?.value.number?.asInt }
                return n.count == 3 ? n[0] * 3600 + n[1] * 60 + n[2] : nil
            }
            if let had = seconds(current.snapshot), let got = seconds(snapshot), had > got, had - got < 5 {
                for name in tc { snapshot.variables[name] = current.snapshot.variables[name] }
            }
            let changed = snapshot.variables.filter { current.snapshot.variables[$0.key]?.value != $0.value.value }.map(\.key)
            reading = ArriReading(snapshot: snapshot, catalog: current.catalog)
            for name in changed { pending[name] = nil }
            // Back from a software reload: the values are the camera's again.
            if state.connection == .stale {
                // Record that the session broke and reconnected; update answers can now finish the transition.
                reloadSessionBroke = true
                if snapshot.variables["SystemSoftwareIsRestarting"]?.value.bool != true {
                    state.connection = .connected
                    reloadingUntil = nil
                    reloadSessionBroke = false
                    ActivityLog.shared.note(host, "ARRI: back after the software reload")
                }
            }
            rebuild()
            yield()
        } catch {
            await failedRead(error)
        }
    }

    private func failedRead(_ error: Error) async {
        if reloading {
            log.notice("read failed while the camera reloads: \(String(describing: error).prefix(80), privacy: .public)")
            try? await Task.sleep(for: .seconds(1))
            return
        }
        failures += 1
        let count = failures
        let why = String(describing: error).prefix(140)
        log.error("read failed (\(count, privacy: .public)): \(why, privacy: .public)")
        if failures >= 2 {
            state.connection = .failed("ARRI: link went quiet")
            ActivityLog.shared.note(host, "ARRI link went quiet")
            yield()
            updateTask?.cancel()
            return
        }
        try? await Task.sleep(for: .seconds(1))
    }

    private func scheduleRefresh(after seconds: Double) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.fullRead()
        }
    }

    // MARK: - State

    /// The tiles from the variables, afresh each time, so a control the camera stops reporting goes gray rather than
    /// keeping its last value. What isn't the variables' (the link, a REC request, the take's start) carries over.
    private func rebuild() {
        guard var shown = reading else { return }
        let now = Date()
        pending = pending.filter { now.timeIntervalSince($0.value.since) < 3 }
        for (name, entry) in pending { shown.snapshot.variables[name]?.value = entry.value }
        var next = CameraState()
        next.connection = state.connection
        next.recording = state.recording
        next.takeStartedAt = state.takeStartedAt
        next.model = state.model
        let wasIdle = state.recording.state == .idle
        shown.apply(to: &next, host: host)
        // A running timecode the camera sends in whole seconds (an ALEXA Mini) is anchored afresh by every rebuild,
        // and any variable moving rebuilds: the frames would keep snapping back to 00. While the clock already
        // counting is within a second ahead of what the camera says, it keeps counting.
        if let old = state.timecode, let new = next.timecode, old.isRunning, new.isRunning, old.rate == new.rate {
            let ahead = old.frames(at: now) - new.frames
            if ahead >= 0, ahead < new.rate { next.timecode = old }
        }
        let isRecording = next.recording.state == .recording
        // Seen starting: not a take already rolling when the link came up, whose length would be made up.
        if isRecording && wasIdle { next.takeStartedAt = Date() }
        if !isRecording { next.takeStartedAt = nil }
        next.latencyMilliseconds = client?.latencyMilliseconds
        state = next
    }

    private func logResolution() {
        guard let reading else { return }
        let missing = ArriField.allCases.filter { reading.fields[$0] == nil }.map(\.rawValue)
        let guessed = reading.fields.filter { !$0.key.candidates.contains($0.value) }
            .map { "\($0.key.rawValue)→\($0.value)" }.sorted()
        let outputs = reading.outputs.map { "\($0.name)[\($0.switches.keys.map(\.rawValue).sorted().joined(separator: ","))]" }
        log.notice("""
            \(reading.snapshot.variables.count, privacy: .public) variables, \(reading.snapshot.commands.count, privacy: .public) commands; \
            resolved \(reading.fields.count, privacy: .public)/\(ArriField.allCases.count, privacy: .public); \
            by words: \(guessed.joined(separator: " "), privacy: .public); missing: \(missing.joined(separator: " "), privacy: .public); \
            outputs: \(outputs.joined(separator: " "), privacy: .public)
            """)
    }

    private func yield() {
        continuation.yield(state)
    }
}

extension ArriEnumCatalog {
    /// Tiles' own tables for the three enums it can't do without (EI, ND, playback speed), used only when the camera's
    /// page script couldn't be read, and only where the camera's list is the same length as the table's.
    public static func fallback(for snapshot: ArriSnapshot, model: String?) -> ArriEnumCatalog {
        var catalog = ArriEnumCatalog()
        func add(_ variable: String, type: String, tokens: [String], labels: [String]) {
            guard let v = snapshot.variables[variable], v.isEnum, v.enumIndexes.count == tokens.count else { return }
            catalog.typeOfVariable[variable] = type
            catalog.tokens[type] = tokens
            for (token, label) in zip(tokens, labels) { catalog.labels["\(type)_\(token)"] = label }
        }
        let eis = ArriTables.exposureIndexes(model: model)
        add("ExposureIndex", type: "ExposureIndex", tokens: eis.map { "EI_\($0)" }, labels: eis.map(String.init))
        let nds = ArriTables.ndFilters(model: model)
        let ndTokens = nds.map { $0 == "Clear" ? "CLEAR" : "ND_\($0.replacingOccurrences(of: ".", with: "_"))" }
        for name in ["NDFilterPosition", "NDFilterPositionEffective"] {
            add(name, type: "NDFilter", tokens: ndTokens, labels: nds.map { $0 == "Clear" ? "ND  -" : "ND \($0)" })
        }
        let speeds = [512, 256, 128, 64, 32, 16, 8, 4, 2, 1].map { "REV_\($0)" } + ["PAUSE"]
            + [1, 2, 4, 8, 16, 32, 64, 128, 256, 512].map { "FWD_\($0)" }
        add("PlaybackSpeedEnum", type: "PlaybackSpeed", tokens: speeds, labels: speeds)
        return catalog
    }
}
