// Sony playback: state mapping, button press wires, FX3 fixture pins no tile.

import Testing
import Foundation
import Network
@testable import SonyPTP
import CameraCore

// MARK: - FX3 fixture: playback through its own buttons, never the Movie Play buttons

@Suite("FX3 playback")
struct FX3PlaybackCapabilityTests {
    /// The control codes the FX3 declares (camctl dump).
    static let fx3Controls: [UInt16] = [
        0xD2C1, 0xD2C2, 0xD2C3, 0xD2C4, 0xD2C7, 0xD2C8, 0xD2C9, 0xD2CD, 0xD2CE, 0xD2CF, 0xD2D0, 0xD2D1, 0xD2D2, 0xD2D7,
        0xD2D8, 0xD2D9, 0xD2DA, 0xD2DB, 0xD2DC, 0xD2DD, 0xD2DF, 0xD2E0, 0xD2E1, 0xD2E2, 0xD2E4, 0xD2E5, 0xD2E6, 0xD2E7,
        0xD2E8, 0xD2E9, 0xD2EA, 0xD2EB, 0xD2F3, 0xD300, 0xD301, 0xD302, 0xD303, 0xD304, 0xD305, 0xD306, 0xD308, 0xD309,
        0xD30A, 0xD30B, 0xD30C, 0xD30E, 0xD30F, 0xD310, 0xD311, 0xD312, 0xD313, 0xD314, 0xD317, 0xF002, 0xF005, 0xF00C,
    ]

    static func fx3Props() throws -> [SDIDevicePropInfo] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try parseSDIDevicePropInfoArray(Data(contentsOf: root.appendingPathComponent("fixtures/fx3-propinfo-full.bin")))
    }

    /// With the controls it declares, the real FX3 plays back through its own buttons: put into review first, then
    /// play/pause, the arrows, and clip changes made from them. It never gets the Movie Play buttons' controls, and
    /// says nothing of play or pause.
    @Test("Real FX3 fixture + its declared controls: review playback, starting on the live picture")
    func fx3ButtonPlayback() throws {
        let pb = try #require(StateMapper(props: try Self.fx3Props(), controls: Self.fx3Controls).playback())
        #expect(pb.capabilities.review && pb.capabilities.playPause && pb.capabilities.fastForwardRewind)
        #expect(pb.capabilities.nextPrevious)
        #expect(!pb.capabilities.stop && !pb.capabilities.seek && !pb.capabilities.recReview)
        #expect(pb.inReview == false)   // captured in Record mode (0xD0BC = 0x01)
        #expect(pb.isPlaying == nil)
    }

    /// Without the control list the property dump alone has no playback: Camera Button Function is a control.
    @Test("Real FX3 fixture without its control list: playback is nil")
    func fx3NoPlayback() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = file.appendingPathComponent("fixtures/fx3-propinfo-full.bin")
        let data = try Data(contentsOf: url)
        let props = try parseSDIDevicePropInfoArray(data)
        let mapper = StateMapper(props: props)
        // FX3 dump has no movie button properties → mapper must return nil
        #expect(mapper.playback() == nil, "FX3 must not offer a playback tile")
    }

    /// The default fake lists neither the playback buttons nor Camera Button Function, so no tile.
    @Test("FakePTPIPCamera without button emulation: offers(.playback) == false", .timeLimit(.minutes(1)))
    func fakeCameraFX3NoPlayback() async throws {
        let cam = FakePTPIPCamera()  // default = ILME-FX3, no button codes
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        cfg.pollInterval = 60
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let state = await collectUntil(backend: backend) { $0.connection == .connected && $0.recording.state != .unknown }
        let s = try #require(state)
        #expect(s.playback == nil, "FX3 fake must not offer playback tile")
        #expect(!s.offers(.playback))
    }
}

// MARK: - State mapping with button props

@Suite("Sony playback state mapper")
struct SonyPlaybackMapperTests {

    private func makeProps(
        playingState: UInt8 = 0x00,
        includePlayPause: Bool = true,
        includePlay: Bool = false,
        includeStop: Bool = true,
        includeFF: Bool = true,
        includeREW: Bool = true,
        includeNext: Bool = true,
        includePrev: Bool = true,
        includeRecReview: Bool = true,
        includeContentsName: Bool = false,
        contentsName: String = "A001C003",
        clipNumber: UInt32 = 3,
        clipTotal: UInt32 = 12
    ) -> [SDIDevicePropInfo] {
        var propBlobs: [Data] = []

        // Movie Playing State: UINT8 read-only
        propBlobs.append(makeUINT8Prop(code: SDIPropCode.moviePlayingState.rawValue, value: playingState, enabled: 0x01))
        if includePlayPause  { propBlobs.append(makeButtonProp(code: SDIPropCode.moviePlayPauseButton.rawValue,  value: 0x0001, enabled: 0x01)) }
        if includePlay       { propBlobs.append(makeButtonProp(code: SDIPropCode.moviePlayButton.rawValue,       value: 0x0001, enabled: 0x01)) }
        if includeStop       { propBlobs.append(makeButtonProp(code: SDIPropCode.moviePlayStopButton.rawValue,   value: 0x0001, enabled: 0x01)) }
        if includeFF         { propBlobs.append(makeButtonProp(code: SDIPropCode.movieForwardButton.rawValue,    value: 0x0001, enabled: 0x01)) }
        if includeREW        { propBlobs.append(makeButtonProp(code: SDIPropCode.movieRewindButton.rawValue,     value: 0x0001, enabled: 0x01)) }
        if includeNext       { propBlobs.append(makeButtonProp(code: SDIPropCode.movieNextButton.rawValue,       value: 0x0001, enabled: 0x01)) }
        if includePrev       { propBlobs.append(makeButtonProp(code: SDIPropCode.moviePrevButton.rawValue,       value: 0x0001, enabled: 0x01)) }
        if includeRecReview  { propBlobs.append(makeButtonProp(code: SDIPropCode.movieRecReviewButton.rawValue,  value: 0x0001, enabled: 0x01)) }
        if includeContentsName {
            propBlobs.append(makeStrProp(code: SDIPropCode.playbackContentsName.rawValue, value: contentsName))
            propBlobs.append(makeUInt32Prop(code: SDIPropCode.playbackContentsNumber.rawValue, value: clipNumber))
            propBlobs.append(makeUInt32Prop(code: SDIPropCode.playbackContentsTotalNumber.rawValue, value: clipTotal))
        }

        var blob = Data()
        blob.appendLE(UInt64(propBlobs.count))
        for p in propBlobs { blob.append(p) }
        return try! parseSDIDevicePropInfoArray(blob)
    }

    private func makeButtonProp(code: UInt16, value: UInt16, enabled: UInt8) -> Data {
        var d = Data()
        d.appendLE(code)
        d.appendLE(UInt16(0x0004))  // UINT16
        d.append(UInt8(0x01))       // GetSet
        d.append(enabled)
        var v = Data(); v.appendLE(value)
        d.append(v); d.append(v)    // default + current
        d.append(UInt8(0x02))       // Enumeration
        d.appendLE(UInt16(2))
        var up = Data(); up.appendLE(UInt16(0x0001))
        var dn = Data(); dn.appendLE(UInt16(0x0002))
        d.append(up); d.append(dn)
        d.appendLE(UInt16(2))
        d.append(up); d.append(dn)
        return d
    }

    private func makeUINT8Prop(code: UInt16, value: UInt8, enabled: UInt8) -> Data {
        var d = Data()
        d.appendLE(code)
        d.appendLE(UInt16(0x0002))  // UINT8
        d.append(UInt8(0x00))       // GetOnly
        d.append(enabled)
        d.append(Data([0x00])); d.append(Data([value]))
        d.append(UInt8(0x02))       // Enumeration
        d.appendLE(UInt16(2))
        d.append(Data([0x00])); d.append(Data([0x01]))
        d.appendLE(UInt16(2))
        d.append(Data([0x00])); d.append(Data([0x01]))
        return d
    }

    private func makeStrProp(code: UInt16, value: String) -> Data {
        var d = Data()
        d.appendLE(code)
        d.appendLE(UInt16(0xFFFF))  // STR
        d.append(UInt8(0x00))       // GetOnly
        d.append(UInt8(0x01))       // enabled
        // default val: empty STR (length 0)
        d.append(UInt8(0))
        // current val: UTF-16LE with null terminator
        let encoded = (value.utf16.map { UInt16($0) } + [0])
        d.append(UInt8(encoded.count))
        for ch in encoded { d.appendLE(ch) }
        d.append(UInt8(0x00))       // FormFlag none
        return d
    }

    private func makeUInt32Prop(code: UInt16, value: UInt32) -> Data {
        var d = Data()
        d.appendLE(code)
        d.appendLE(UInt16(0x0006))  // UINT32
        d.append(UInt8(0x00))       // GetOnly
        d.append(UInt8(0x01))       // enabled
        var v = Data(); v.appendLE(value)
        d.append(v); d.append(v)
        d.append(UInt8(0x01))       // Range
        var rmin = Data(); rmin.appendLE(UInt32(1))
        var rmax = Data(); rmax.appendLE(value)
        var step = Data(); step.appendLE(UInt32(1))
        d.append(rmin); d.append(rmax); d.append(step)
        return d
    }

    @Test("Playback nil when no button props present")
    func noButtonsNoPlayback() throws {
        // Just a moviePlayingState prop, no buttons
        var blob = Data()
        blob.appendLE(UInt64(1))
        let ps = makeButtonProp(code: SDIPropCode.moviePlayingState.rawValue, value: 0x0000, enabled: 0x01)
        blob.append(ps)
        let props = try parseSDIDevicePropInfoArray(blob)
        let mapper = StateMapper(props: props)
        #expect(mapper.playback() == nil)
    }

    @Test("Playback non-nil when PlayPause button present and enabled")
    func playPauseButtonOffersPlayback() throws {
        let props = makeProps()
        let mapper = StateMapper(props: props)
        let pb = try #require(mapper.playback())
        #expect(pb.capabilities.playPause)
        #expect(pb.capabilities.stop)
        #expect(pb.capabilities.nextPrevious)
        #expect(pb.capabilities.fastForwardRewind)
        #expect(pb.capabilities.recReview)
        #expect(!pb.capabilities.seek)   // Sony has no seek
    }

    @Test("A button the camera doesn't list isn't drawn: only Play Pause means no stop, next/prev, FF/REW or review")
    func absentButtonsAreFalse() throws {
        let props = makeProps(includeStop: false, includeFF: false, includeREW: false,
                              includeNext: false, includePrev: false, includeRecReview: false)
        let caps = try #require(StateMapper(props: props).playback()).capabilities
        #expect(caps.playPause)
        #expect(!caps.stop && !caps.nextPrevious && !caps.fastForwardRewind && !caps.recReview && !caps.live && !caps.seek)
    }

    @Test("isPlaying true when 0xD02F = 0x01")
    func playingStateTrue() throws {
        let props = makeProps(playingState: 0x01)
        let pb = try #require(StateMapper(props: props).playback())
        #expect(pb.isPlaying == true)
    }

    @Test("isPlaying false when 0xD02F = 0x00")
    func playingStateFalse() throws {
        let props = makeProps(playingState: 0x00)
        let pb = try #require(StateMapper(props: props).playback())
        #expect(pb.isPlaying == false)
    }

    @Test("Clip name and number parsed when content props present")
    func clipNameAndNumber() throws {
        let props = makeProps(includeContentsName: true, contentsName: "A001C003", clipNumber: 3, clipTotal: 12)
        let pb = try #require(StateMapper(props: props).playback())
        #expect(pb.clipName == "A001C003")
        #expect(pb.clipNumber == 3)
        #expect(pb.clipCount == 12)
    }

    @Test("Playback nil when PlayPause button IsEnabled = disabled")
    func disabledButtonNoPlayback() throws {
        var blob = Data()
        blob.appendLE(UInt64(1))
        // enabled = 0x00 (disabled)
        blob.append(makeButtonProp(code: SDIPropCode.moviePlayPauseButton.rawValue, value: 0x0001, enabled: 0x00))
        let props = try parseSDIDevicePropInfoArray(blob)
        #expect(StateMapper(props: props).playback() == nil)
    }
}

// MARK: - Backend wire tests: button presses for playback commands

@Suite("Sony backend playback button presses", .serialized)
struct SonyPlaybackBackendTests {

    private func backendWithPlayback(cam: FakePTPIPCamera, port: UInt16) -> SonyCameraBackend {
        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        cfg.pollInterval = 60
        cfg.transport.port = NWEndpoint.Port(rawValue: port)!
        let store = EphemeralIdentityStore(friendlyName: "test")
        return SonyCameraBackend(host: "127.0.0.1", identityStore: store, config: cfg)
    }

    /// Build a FakePTPIPCamera that advertises all playback button props.
    private func makeCamWithPlayback(_ adjust: (inout FakePTPIPCamera.Config) -> Void = { _ in }) -> FakePTPIPCamera {
        var camCfg = FakePTPIPCamera.Config()
        adjust(&camCfg)
        // Inject playback button props into the fake's prop data via fakePropData before start.
        // We write button code props as UINT16 GetSet, enabled.
        func buttonData(_ v: UInt16) -> Data { var d = Data(); d.appendLE(v); return d }
        // All button codes present, value = Up (0x0001)
        let codes: [UInt16] = [
            SDIPropCode.moviePlayingState.rawValue,
            SDIPropCode.moviePlayPauseButton.rawValue,
            SDIPropCode.moviePlayButton.rawValue,
            SDIPropCode.moviePlayStopButton.rawValue,
            SDIPropCode.movieForwardButton.rawValue,
            SDIPropCode.movieRewindButton.rawValue,
            SDIPropCode.movieNextButton.rawValue,
            SDIPropCode.moviePrevButton.rawValue,
            SDIPropCode.movieRecReviewButton.rawValue,
        ]
        for code in codes {
            camCfg.fakePropData[code] = buttonData(0x0001)
        }
        return FakePTPIPCamera(config: camCfg)
    }

    @Test("togglePlay sends SetExtDevicePropValue Down then Up on PlayPause button", .timeLimit(.minutes(1)))
    func togglePlaySendsButton() async throws {
        let cam = makeCamWithPlayback()
        try await cam.start()
        defer { cam.stop() }

        let backend = backendWithPlayback(cam: cam, port: cam.port)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let _ = await collectUntil(backend: backend) { $0.connection == .connected && $0.recording.state != .unknown }

        await backend.send(.playback(.togglePlay))

        // Wait for Down + Up writes on PlayPause.
        let code = SDIPropCode.moviePlayPauseButton.rawValue
        for _ in 0..<200 {
            if cam.propWrites.filter({ $0.code == code }).count >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let writes = cam.propWrites.filter { $0.code == code }
        // A missed write is a failure, not an index out of range that takes the whole run down.
        try #require(writes.count == 2)
        let downVal = UInt16(writes[0].data[writes[0].data.startIndex]) | UInt16(writes[0].data[writes[0].data.startIndex + 1]) << 8
        let upVal   = UInt16(writes[1].data[writes[1].data.startIndex]) | UInt16(writes[1].data[writes[1].data.startIndex + 1]) << 8
        #expect(downVal == ButtonValue.down.rawValue)
        #expect(upVal   == ButtonValue.up.rawValue)
    }

    // Parameterized: stop / next / prev each send Down+Up on the right button code.
    @Test("playback buttons: stop/next/prev each send Down then Up", .timeLimit(.minutes(1)),
          arguments: [
            ("stop",     SDIPropCode.moviePlayStopButton.rawValue),
            ("next",     SDIPropCode.movieNextButton.rawValue),
            ("previous", SDIPropCode.moviePrevButton.rawValue),
          ])
    func buttonCommandsSendDownUp(commandName: String, code: UInt16) async throws {
        let cam = makeCamWithPlayback()
        try await cam.start()
        defer { cam.stop() }

        let backend = backendWithPlayback(cam: cam, port: cam.port)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }
        let _ = await collectUntil(backend: backend) { $0.connection == .connected && $0.recording.state != .unknown }

        let command: PlaybackCommand = switch commandName {
        case "stop": .stop
        case "next": .next
        default: .previous
        }
        await backend.send(.playback(command))

        for _ in 0..<200 {
            if cam.propWrites.filter({ $0.code == code }).count >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(cam.propWrites.filter({ $0.code == code }).count == 2)
    }

    /// Live | Review on a body with Sony's Movie Play buttons, as a BURANO takes them (camctl, the app's own
    /// path): Review is Play Pause from the live picture, Live is Stop, a held ▶▶ / ◀◀ is the camera's FF / REW and
    /// letting go is Play, and Rec Review its own button.
    @Test("Movie Play buttons: Review, Live, scan, end of scan and Rec Review each press theirs", .timeLimit(.minutes(1)),
          arguments: [
            ("review",    SDIPropCode.moviePlayPauseButton.rawValue),
            ("live",      SDIPropCode.moviePlayStopButton.rawValue),
            ("scanf",     SDIPropCode.movieForwardButton.rawValue),
            ("scanb",     SDIPropCode.movieRewindButton.rawValue),
            ("endscan",   SDIPropCode.moviePlayButton.rawValue),
            ("recreview", SDIPropCode.movieRecReviewButton.rawValue),
          ])
    func movieButtonsLiveReview(commandName: String, code: UInt16) async throws {
        let cam = makeCamWithPlayback()
        try await cam.start()
        defer { cam.stop() }

        let backend = backendWithPlayback(cam: cam, port: cam.port)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }
        let _ = await collectUntil(backend: backend) { $0.connection == .connected && $0.recording.state != .unknown }

        let command: PlaybackCommand = switch commandName {
        case "review": .review
        case "live": .live
        case "scanf": .scan(forward: true)
        case "scanb": .scan(forward: false)
        case "endscan": .endScan
        default: .recReview
        }
        await backend.send(.playback(command))
        for _ in 0..<200 {
            if cam.propWrites.filter({ $0.code == code }).count >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(cam.propWrites.filter({ $0.code == code }).count == 2, "\(commandName)")
        // Nothing else pressed: Review doesn't also press Play, a scan doesn't also press Play Pause.
        let buttons = Set([SDIPropCode.moviePlayPauseButton, .moviePlayButton, .moviePlayStopButton, .movieForwardButton,
                           .movieRewindButton, .movieRecReviewButton].map(\.rawValue))
        #expect(Set(cam.propWrites.map(\.code)).intersection(buttons) == [code], "\(commandName)")
    }

    /// An FX6 (fixtures/fx6-playback-buttons-2026-10-29.jsonl) ignores Play Pause on the live picture, and its Play
    /// there only sometimes resumes: Review is Prev, which opens the last take paused at its start, then Play once
    /// the camera says Playback. An FX5, with the same buttons, ignored Play Pause there too (docs/fx5-controls.md),
    /// and takes the FX6's way; not yet seen on one with a take on its card.
    @Test("FX6 and FX5: Review is Prev, then Play once it's in Playback; never Play Pause", .timeLimit(.minutes(1)),
          arguments: ["ILME-FX6V", "ILME-FX5"])
    func fx6Review(model: String) async throws {
        let cam = makeCamWithPlayback { $0.model = model; $0.fx6Playback = true }
        try await cam.start()
        defer { cam.stop() }
        let backend = backendWithPlayback(cam: cam, port: cam.port)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }
        // The model comes in just after the first read.
        let _ = await collectUntil(backend: backend) {
            $0.connection == .connected && $0.recording.state != .unknown && $0.model != nil
        }

        await backend.send(.playback(.review))
        let buttons = Set([SDIPropCode.moviePlayPauseButton, .moviePlayButton, .moviePrevButton].map(\.rawValue))
        for _ in 0..<300 where cam.propWrites.filter({ $0.code == SDIPropCode.moviePlayButton.rawValue }).count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(cam.propWrites.map(\.code).filter(buttons.contains)
                == [SDIPropCode.moviePrevButton.rawValue, SDIPropCode.moviePrevButton.rawValue,
                    SDIPropCode.moviePlayButton.rawValue, SDIPropCode.moviePlayButton.rawValue])
        #expect(cam.operatingMode == 0x02 && cam.fx6Speed == 1)
    }

    /// An FX5's Prev on the live picture opens the take before the last (2 of 3, A001C002, settled and 1.5 s after a
    /// cut; fixtures/fx5-review-2026-11-14.jsonl): Review steps on with Next, by the take number and total it gives in
    /// Playback, then plays.
    @Test("FX5: Review opens the last take: Prev, then Next to it, then Play", .timeLimit(.minutes(1)))
    func fx5ReviewOpensTheLastTake() async throws {
        let cam = makeCamWithPlayback { $0.model = "ILME-FX5"; $0.fx6Playback = true; $0.takes = 3 }
        try await cam.start()
        defer { cam.stop() }
        let backend = backendWithPlayback(cam: cam, port: cam.port)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }
        let _ = await collectUntil(backend: backend) {
            $0.connection == .connected && $0.recording.state != .unknown && $0.model != nil
        }

        await backend.send(.playback(.review))
        let buttons = Set([SDIPropCode.moviePlayPauseButton, .moviePlayButton, .moviePrevButton, .movieNextButton].map(\.rawValue))
        for _ in 0..<300 where cam.propWrites.filter({ $0.code == SDIPropCode.moviePlayButton.rawValue }).count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(cam.propWrites.map(\.code).filter(buttons.contains)
                == [SDIPropCode.moviePrevButton.rawValue, SDIPropCode.moviePrevButton.rawValue,
                    SDIPropCode.movieNextButton.rawValue, SDIPropCode.movieNextButton.rawValue,
                    SDIPropCode.moviePlayButton.rawValue, SDIPropCode.moviePlayButton.rawValue])
        #expect(cam.takeNumber == 3 && cam.operatingMode == 0x02 && cam.fx6Speed == 1)
    }

    static let reviewButtons = Set([SDIPropCode.moviePlayPauseButton, .moviePlayButton, .moviePrevButton,
                                     .movieNextButton, .moviePlayStopButton].map(\.rawValue))

    func connectedFX5(_ adjust: @escaping (inout FakePTPIPCamera.Config) -> Void)
        async throws -> (FakePTPIPCamera, SonyCameraBackend, Task<Void, Never>) {
        let cam = makeCamWithPlayback { $0.fx6Playback = true; adjust(&$0) }
        try await cam.start()
        let backend = backendWithPlayback(cam: cam, port: cam.port)
        let t = Task.detached { await backend.connect() }
        let _ = await collectUntil(backend: backend) {
            $0.connection == .connected && $0.recording.state != .unknown && $0.model != nil
        }
        return (cam, backend, t)
    }

    /// Playback left far back (take 2 of 8): an FX5's Prev opens one before it, and Review steps on the whole way.
    @Test("FX5: Review from a take left far back steps on to the last", .timeLimit(.minutes(1)))
    func fx5ReviewFromFarBack() async throws {
        let (cam, backend, t) = try await connectedFX5 { $0.model = "ILME-FX5"; $0.takes = 8; $0.parkedTake = 2 }
        defer { cam.stop(); t.cancel() }
        await backend.send(.playback(.review))
        #expect(cam.takeNumber == 8 && cam.operatingMode == 0x02 && cam.fx6Speed == 1)
        let presses = cam.propWrites.map(\.code).filter(Self.reviewButtons.contains)
        #expect(presses.filter { $0 == SDIPropCode.movieNextButton.rawValue }.count == 14, "seven Nexts, down and up")
        #expect(presses.last == SDIPropCode.moviePlayButton.rawValue)
    }

    /// A Prev the camera ignores (an FX5 once, just after a cut) is pressed again after 3 s on the live picture where
    /// the camera numbers its takes. An FX6, which can't be put right if a second Prev lands in Playback, gets one.
    @Test("A Prev the camera ignores: an FX5's pressed again, an FX6's not", .timeLimit(.minutes(1)),
          arguments: ["ILME-FX5", "ILME-FX6V"])
    func ignoredPrev(model: String) async throws {
        let fx5 = model.contains("FX5")
        let (cam, backend, t) = try await connectedFX5 { $0.model = model; $0.takes = fx5 ? 3 : nil; $0.ignoredPrevs = 1 }
        defer { cam.stop(); t.cancel() }
        await backend.send(.playback(.review))
        let prevs = cam.propWrites.filter { $0.code == SDIPropCode.moviePrevButton.rawValue }.count
        let plays = cam.propWrites.filter { $0.code == SDIPropCode.moviePlayButton.rawValue }.count
        if fx5 {
            #expect(prevs == 4 && plays == 2 && cam.takeNumber == 3 && cam.operatingMode == 0x02)
        } else {
            #expect(prevs == 2 && plays == 0 && cam.operatingMode == 0x01)
        }
    }

    /// The Clips window on an FX5: from the live picture Review's way in (Prev opens a take), then
    /// Prev a take at a time to the one picked, then Play. Its Clips tile is offered.
    @Test("FX5: a clip picked from the live picture: Prev in, Prev to it, Play", .timeLimit(.minutes(1)))
    func fx5GoToClipFromLive() async throws {
        let (cam, backend, t) = try await connectedFX5 { $0.model = "ILME-FX5"; $0.takes = 8 }
        defer { cam.stop(); t.cancel() }
        #expect(await backend.state.offers(.clips))
        await backend.send(.playback(.goToClip(3)))
        #expect(cam.takeNumber == 4 && cam.operatingMode == 0x02 && cam.fx6Speed == 1)
        let presses = cam.propWrites.map(\.code).filter(Self.reviewButtons.contains)
        #expect(presses.filter { $0 == SDIPropCode.moviePrevButton.rawValue }.count == 8, "in, then 7 → 4: four, down and up")
        #expect(!presses.contains(SDIPropCode.movieNextButton.rawValue))
        #expect(presses.last == SDIPropCode.moviePlayButton.rawValue)
    }

    @Test("FX5: a clip picked in Playback steps on from the open one; one past the last goes to the last",
          .timeLimit(.minutes(1)))
    func fx5GoToClipInPlayback() async throws {
        let (cam, backend, t) = try await connectedFX5 { $0.model = "ILME-FX5"; $0.takes = 8; $0.parkedTake = 3 }
        defer { cam.stop(); t.cancel() }
        await backend.send(.playback(.goToClip(4)))   // Prev opens 2, then on to 5
        #expect(cam.takeNumber == 5 && cam.fx6Speed == 1)
        await backend.send(.playback(.goToClip(11)))  // a take since deleted: the last there is
        #expect(cam.takeNumber == 8)
    }

    @Test("FX5: a second pick while the first still steps: on to the second, one Play", .timeLimit(.minutes(1)))
    func fx5SecondPickRedirects() async throws {
        let (cam, backend, t) = try await connectedFX5 { $0.model = "ILME-FX5"; $0.takes = 30 }
        defer { cam.stop(); t.cancel() }
        let first = Task { await backend.send(.playback(.goToClip(0))) }
        let prev = SDIPropCode.moviePrevButton.rawValue
        for _ in 0..<500 where cam.propWrites.filter({ $0.code == prev }).count < 6 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await backend.send(.playback(.goToClip(19)))   // take 20, behind where it is by now
        await first.value
        #expect(cam.takeNumber == 20 && cam.fx6Speed == 1)
        #expect(cam.propWrites.filter { $0.code == SDIPropCode.moviePlayButton.rawValue }.count == 2, "one Play, down and up")
    }

    @Test("No clip list on an FX6, which doesn't number its takes; nor a pick during a take", .timeLimit(.minutes(1)))
    func goToClipNeedsNumberedTakes() async throws {
        let (cam, backend, t) = try await connectedFX5 { $0.model = "ILME-FX6V" }
        defer { cam.stop(); t.cancel() }
        #expect(await !backend.state.offers(.clips))
        await backend.send(.playback(.goToClip(0)))
        #expect(cam.operatingMode == 0x01 && cam.propWrites.filter { Self.reviewButtons.contains($0.code) }.isEmpty)
    }

    /// Live tapped while Review steps through the takes: the camera goes back to the live picture and stays there,
    /// with no Play pressed on it.
    @Test("FX5: Live during Review's Nexts leaves it live, no Play", .timeLimit(.minutes(1)))
    func liveDuringReview() async throws {
        let (cam, backend, t) = try await connectedFX5 { $0.model = "ILME-FX5"; $0.takes = 30; $0.parkedTake = 2 }
        defer { cam.stop(); t.cancel() }
        let review = Task { await backend.send(.playback(.review)) }
        for _ in 0..<500 where !cam.propWrites.contains(where: { $0.code == SDIPropCode.movieNextButton.rawValue }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await backend.send(.playback(.live))
        await review.value
        #expect(cam.operatingMode == 0x01)
        #expect(!cam.propWrites.contains { $0.code == SDIPropCode.moviePlayButton.rawValue })
    }

    /// An FX5 as it lists its focus: no Focus Mode 0x500A; Focus Mode Setting 0xD007 (0x01 AF, 0x02 MF), Focus Mode
    /// status 0xE044 (0x02 MF, 0x03 AF Operation) and Push Auto Focus 0xD05E.
    static func fx5Focus(_ config: inout FakePTPIPCamera.Config, setting: UInt8, status: UInt8) {
        config.model = "ILME-FX5"
        config.omitPropCodes = [SDIPropCode.focusMode.rawValue]
        config.fakePropData[SDIPropCode.pushAutoFocus.rawValue] = Data([0x01, 0x00])
        config.fakePropData[SDIPropCode.focusModeSetting.rawValue] = Data([setting])
        config.fakePropData[SDIPropCode.focusModeStatus.rawValue] = Data([status])
    }

    /// The Autofocus tile on an FX5: Push Auto Focus (0xD05E) held down for the lens to settle, then let go.
    @Test("FX5: Autofocus holds Push AF, then lets it go", .timeLimit(.minutes(1)))
    func fx5PushAF() async throws {
        let (cam, backend, t) = try await connectedFX5 { Self.fx5Focus(&$0, setting: 0x02, status: 0x02) }
        defer { cam.stop(); t.cancel() }
        // The FX5's own controls are mapped once its model and button names are in, just after the first read.
        #expect(await collectUntil(backend: backend) { $0.canAutoFocus }?.canAutoFocus == true)
        let began = Date()
        await backend.send(.autoFocus)
        let writes = cam.propWrites.filter { $0.code == SDIPropCode.pushAutoFocus.rawValue }.map { Array($0.data) }
        #expect(writes == [[0x02, 0x00], [0x01, 0x00]], "Down, then Up")
        #expect(Date().timeIntervalSince(began) >= 1.1, "held long enough for the lens to focus")
    }

    /// With AF on there's nothing to push, and on a cinema body the press would hold focus instead: not sent, and said.
    @Test("FX5: no push while it's autofocusing", .timeLimit(.minutes(1)))
    func fx5NoPushInAF() async throws {
        let (cam, backend, t) = try await connectedFX5 { Self.fx5Focus(&$0, setting: 0x01, status: 0x03) }
        defer { cam.stop(); t.cancel() }
        let state = try #require(await collectUntil(backend: backend) { $0.canAutoFocus })
        #expect(state.focusIsAuto && state.focusMode?.value == "AF")
        await backend.send(.autoFocus)
        #expect(cam.propWrites.filter { $0.code == SDIPropCode.pushAutoFocus.rawValue }.isEmpty)
        #expect(await backend.currentState.warnings.contains { $0.contains("switch to MF") })
    }

    /// AF / MF from the Autofocus tile: an FX5's is Focus Mode Setting 0xD007, one byte. With the setting on AF and the
    /// lens's own switch at MF (status MF Operation) focus is manual, but there's still no push: the camera takes none
    /// with the lens at MF, and with AF set the press is Push MF.
    @Test("FX5: AF / MF writes Focus Mode Setting; no push with it on AF", .timeLimit(.minutes(1)))
    func fx5FocusMode() async throws {
        let (cam, backend, t) = try await connectedFX5 { Self.fx5Focus(&$0, setting: 0x01, status: 0x02) }
        defer { cam.stop(); t.cancel() }
        let state = try #require(await collectUntil(backend: backend) { $0.canAutoFocus })
        #expect(state.focusMode?.value == "AF" && !state.focusIsAuto && !state.canPushAutoFocus)
        await backend.send(.setFocusMode("MF"))
        #expect(cam.propWrites.filter { $0.code == SDIPropCode.focusModeSetting.rawValue }.map { Array($0.data) } == [[0x02]])
        #expect(cam.propWrites.filter { $0.code == SDIPropCode.focusMode.rawValue }.isEmpty)
    }

    /// The AF Settings window on an FX5: each written as the camera takes it, by its own list and names; an area it
    /// doesn't list isn't sent.
    @Test("FX5: AF settings write Subject Recognition, Focus Area, the speeds and AF Assist", .timeLimit(.minutes(1)))
    func fx5AFSettings() async throws {
        let (cam, backend, t) = try await connectedFX5 {
            $0.model = "ILME-FX5"
            $0.fakePropData[SDIPropCode.subjectRecognitionAF.rawValue] = Data([0x03])
            $0.fakePropLists[SDIPropCode.subjectRecognitionAF.rawValue] = [1, 3, 2, 4, 5, 6].map { Data([UInt8($0)]) }
            $0.fakePropData[SDIPropCode.focusArea.rawValue] = Data([0x01, 0x00])
            $0.fakePropLists[SDIPropCode.focusArea.rawValue] = [Data([0x01, 0x00]), Data([0x02, 0x00]), Data([0x05, 0x01])]
        }
        defer { cam.stop(); t.cancel() }
        let state = try #require(await collectUntil(backend: backend) { $0.subjectRecognition != nil && $0.focusArea != nil })
        #expect(state.subjectRecognition?.value == "Human Priority AF" && state.focusArea?.options == ["Wide", "Zone", "Flexible Spot"])
        await backend.send(.setSubjectRecognition("Human Only AF"))
        await backend.send(.setFocusArea("Zone"))
        await backend.send(.setFocusArea("Center"))  // not in its list
        await backend.send(.setAFTransitionSpeed(3))
        await backend.send(.setAFSubjectShift(2))
        await backend.send(.setAFAssist(false))
        func writes(_ code: SDIPropCode) -> [[UInt8]] { cam.propWrites.filter { $0.code == code.rawValue }.map { Array($0.data) } }
        #expect(writes(.subjectRecognitionAF) == [[0x02]])
        #expect(writes(.focusArea) == [[0x02, 0x00]], "Zone; Center isn't listed")
        #expect(writes(.afTransitionSpeed) == [[0x03]] && writes(.afSubjectShiftSens) == [[0x02]] && writes(.afAssist) == [[0x01]])
    }

    /// What autofocus looks for, in the camera's own words (display list 0x15) where it gives them, and set by them.
    @Test("Subject Recognition AF named by the camera's list, and written by those names", .timeLimit(.minutes(1)))
    func subjectNamesFromTheCamera() async throws {
        let (cam, backend, t) = try await connectedFX5 {
            $0.model = "ILME-FX5"
            $0.fakePropData[SDIPropCode.subjectRecognitionAF.rawValue] = Data([0x03])
            $0.fakePropLists[SDIPropCode.subjectRecognitionAF.rawValue] = [1, 3, 2].map { Data([UInt8($0)]) }
            $0.subjectNames = [0x01: "Aus", 0x02: "Nur Gesicht", 0x03: "Gesicht zuerst"]
        }
        defer { cam.stop(); t.cancel() }
        let state = try #require(await collectUntil(backend: backend) { $0.subjectRecognition?.value == "Gesicht zuerst" })
        #expect(state.subjectRecognition?.options == ["Nur Gesicht", "Gesicht zuerst", "Aus"])
        await backend.send(.setSubjectRecognition("Nur Gesicht"))
        #expect(cam.propWrites.filter { $0.code == SDIPropCode.subjectRecognitionAF.rawValue }.map { Array($0.data) } == [[0x02]])
    }

    /// False Color on an FX5 is its button 4: pressed when it's off and asked on, not when it's already as asked.
    @Test("FX5: False Color presses the button set to it, only to change it", .timeLimit(.minutes(1)))
    func fx5FalseColor() async throws {
        let (cam, backend, t) = try await connectedFX5 {
            $0.model = "ILME-FX5"; $0.assignables = [4: 0x6B]; $0.assignableNames = [0x6B: "False Colo"]
        }
        defer { cam.stop(); t.cancel() }
        let state = try #require(await collectUntil(backend: backend) { $0.falseColor != nil })
        #expect(state.falseColor?.value == false && state.falseColor?.isWritable == true)
        await backend.send(.setFalseColor(false))  // already off
        #expect(cam.propWrites.filter { $0.code == 0xE02C }.isEmpty)
        await backend.send(.setFalseColor(true))
        #expect(cam.propWrites.filter { $0.code == 0xE02C }.map { Array($0.data) } == [[0x02, 0x00], [0x01, 0x00]])
    }

    /// With no button set to False Color, the tile is grayed and says it needs one, not vanish. A
    /// camera without the function at all (an FX6's list here) has no False Color tile.
    @Test("FX5: no button set to False Color grays the tile with \"Assign a button\"; no function, no tile", .timeLimit(.minutes(1)))
    func fx5FalseColorUnassigned() async throws {
        let (cam, backend, t) = try await connectedFX5 {
            $0.model = "ILME-FX5"; $0.assignables = [2: 0x03]
            $0.assignableNames = [0x03: "Base ISO/Sens.", 0x6B: "False Colo"]
        }
        defer { cam.stop(); t.cancel() }
        let state = try #require(await collectUntil(backend: backend) { $0.falseColor != nil })
        #expect(state.falseColor == Choice(false, options: [false, true], isWritable: false))
        #expect(state.falseColorHint == "Assign a button" && state.offers(.falseColor))
        await backend.send(.setFalseColor(true))
        #expect(!cam.propWrites.contains { (0xE029...0xE033).contains($0.code) }, "nothing to press")
        // Assigned at the camera: live, and the note goes.
        cam.config.assignables = [2: 0x03, 5: 0x6B]
        await backend.send(.setFalseColor(true))
        #expect(cam.propWrites.filter { $0.code == 0xE02D }.count == 2)
        #expect(await backend.currentState.falseColorHint == nil)

        let (fx6, fx6Backend, t6) = try await connectedFX5 {
            $0.model = "ILME-FX6V"; $0.assignables = [2: 0x31]; $0.assignableNames = [0x31: "S&Q Motion"]
        }
        defer { fx6.stop(); t6.cancel() }
        let six = try #require(await collectUntil(backend: fx6Backend) { $0.assignableButtons.count == 1 })
        #expect(six.falseColor == nil && six.falseColorHint == nil)
    }

    /// False Color on another button: whichever button has it is the one pressed, the lens's too, and one moved at the
    /// camera since the last read is found again: the button it left, now set to something else (Base ISO/Sens., itself
    /// pressable), is never pressed for it.
    @Test("FX5: False Color follows whichever button has it, and one moved at the camera", .timeLimit(.minutes(1)))
    func fx5FalseColorMoved() async throws {
        let (cam, backend, t) = try await connectedFX5 {
            $0.model = "ILME-FX5"; $0.assignables = [2: 0x03, 7: 0x6B]
            $0.assignableNames = [0x03: "Base ISO/Sens.", 0x6B: "False Colo"]
        }
        defer { cam.stop(); t.cancel() }
        #expect(await collectUntil(backend: backend) { $0.falseColor != nil }?.falseColor?.isWritable == true)
        await backend.send(.setFalseColor(true))
        #expect(cam.propWrites.filter { $0.code == 0xE02F }.count == 2, "button 7's press, Down and Up")
        // Moved at the camera: False Color to button 2, Base ISO/Sens. to 7. No event: the next press reads first.
        cam.config.assignables = [2: 0x6B, 7: 0x03]
        let before = cam.propWrites.count
        await backend.send(.setFalseColor(true))
        let presses = cam.propWrites.dropFirst(before).map(\.code)
        #expect(presses == [0xE02A, 0xE02A], "button 2's, not button 7's (now Base ISO/Sens.)")
    }

    /// Two Review taps at once: one Review, one Prev.
    @Test("FX5: two Review taps at once press Prev once", .timeLimit(.minutes(1)))
    func doubleReview() async throws {
        let (cam, backend, t) = try await connectedFX5 { $0.model = "ILME-FX5"; $0.takes = 3 }
        defer { cam.stop(); t.cancel() }
        async let first: Void = backend.send(.playback(.review))
        async let second: Void = backend.send(.playback(.review))
        _ = await (first, second)
        #expect(cam.propWrites.filter { $0.code == SDIPropCode.moviePrevButton.rawValue }.count == 2, "down and up")
        #expect(cam.takeNumber == 3 && cam.fx6Speed == 1)
    }

    /// An FX6's Play Pause only pauses: the play/pause button resumes a paused clip with Play, and pauses with Play
    /// Pause. Read off the camera started in Playback, paused and then playing.
    @Test("FX6 and FX5: play/pause resumes with Play and pauses with Play Pause", .timeLimit(.minutes(1)),
          arguments: ["ILME-FX6V", "ILME-FX5"],
          [(Int32(0), SDIPropCode.moviePlayButton.rawValue), (Int32(1), SDIPropCode.moviePlayPauseButton.rawValue)])
    func fx6PlayPause(model: String, press: (Int32, UInt16)) async throws {
        let (speed, code) = press
        let cam = makeCamWithPlayback { $0.model = model; $0.fx6Playback = true; $0.fx6StartSpeed = speed }
        try await cam.start()
        defer { cam.stop() }
        let backend = backendWithPlayback(cam: cam, port: cam.port)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }
        let s = try #require(await collectUntil(backend: backend) {
            $0.connection == .connected && $0.playback?.isPlaying != nil && $0.model != nil
        })
        #expect(s.playback?.inReview == true && s.playback?.isPlaying == (speed != 0))

        await backend.send(.playback(.togglePlay))
        let buttons = Set([SDIPropCode.moviePlayPauseButton, .moviePlayButton].map(\.rawValue))
        for _ in 0..<300 where cam.propWrites.filter({ buttons.contains($0.code) }).count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(cam.propWrites.map(\.code).filter(buttons.contains) == [code, code], "speed \(speed)")
    }

    /// camctl's raw write (`set:` steps) reaches only a property the camera listed, and never Delete UserBaseLook
    /// (0xD0C7), which an FX3 or FX6 lists as a settable property and which deletes a LUT. Controls aren't properties,
    /// so the card-wiping one (0xD2E2) is out of reach too.
    @Test("Raw writes: a listed property only, and never Delete UserBaseLook, an assignable button or a scene file",
          .timeLimit(.minutes(1)))
    func rawWriteGuard() async throws {
        let cam = makeCamWithPlayback {
            $0.fakePropData[0xD0C7] = Data([0x01, 0x00])
            $0.fakePropData[0xE0E6] = Data([0x01, 0x00])
            $0.assignables = [1: 0x31]
        }
        try await cam.start()
        defer { cam.stop() }
        let backend = backendWithPlayback(cam: cam, port: cam.port)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }
        let _ = await collectUntil(backend: backend) { $0.connection == .connected && $0.recording.state != .unknown }
        #expect(await backend.rawProperties[0xD0C7] != nil, "the fake lists it, as an FX6 does")

        let denied = PTPResponseCode.accessDenied.rawValue
        #expect(await backend.setRawProperty(0xD0C7, data: Data([0x01, 0x00])) == denied)
        #expect(await backend.setRawProperty(0xD2E2, data: Data([0x02, 0x00])) == denied)
        // Listed, settable, and refused: an assignment (which could be Last Clip Del.), a press, a scene file command.
        for code: UInt16 in [0xE014, 0xE029, 0xE0E6] {
            #expect(await backend.rawProperties[code] != nil, "the fake lists \(String(code, radix: 16))")
            #expect(await backend.setRawProperty(code, data: Data([0x01, 0x00])) == denied)
        }
        #expect(await backend.setRawProperty(SDIPropCode.moviePlayStopButton.rawValue, data: Data([0x02, 0x00]))
                == PTPResponseCode.ok.rawValue)
        #expect(!cam.propWrites.contains { [0xD0C7, 0xD2E2, 0xE014, 0xE029, 0xE0E6].contains($0.code) })
    }

    // MARK: FX6 focus drive and assignable buttons

    private func fx6Lens(_ adjust: (inout FakePTPIPCamera.Config) -> Void = { _ in }) async throws
        -> (FakePTPIPCamera, SonyCameraBackend, Task<Void, Never>) {
        let cam = makeCamWithPlayback {
            $0.model = "ILME-FX6V"
            $0.fx6Lens = true
            $0.controlCodes = [SDIControlCode.movieRecButtonHold.rawValue, SDIControlCode.focusOperation.rawValue]
            adjust(&$0)
        }
        try await cam.start()
        let backend = backendWithPlayback(cam: cam, port: cam.port)
        let t = Task.detached { await backend.connect() }
        let _ = await collectUntil(backend: backend) { $0.connection == .connected && $0.focusDrive != nil }
        return (cam, backend, t)
    }

    private func focusControls(_ cam: FakePTPIPCamera) -> [Int8] {
        cam.controls.filter { $0.code == SDIControlCode.focusOperation.rawValue }.compactMap { $0.data.first.map { Int8(bitPattern: $0) } }
    }

    /// An FX6 drives its focus until it's told 0 (it ran 6 s on one +1), so the backend stops a drive that nothing
    /// renews: a lost lift, a dropped connection, a crashed client.
    @Test("FX6 focus: a drive nothing renews is stopped by the backend, after about 600 ms", .timeLimit(.minutes(1)))
    func focusDriveStopsUnrenewed() async throws {
        let (cam, backend, t) = try await fx6Lens()
        defer { t.cancel(); cam.stop() }
        let began = Date()
        await backend.send(.driveFocus(2))
        for _ in 0..<300 where focusControls(cam).count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(focusControls(cam) == [2, 0])
        #expect(Date().timeIntervalSince(began) > 0.55)
    }

    @Test("FX6 focus: held, renewals keep it going and send the camera nothing new; letting go stops it",
          .timeLimit(.minutes(1)))
    func focusDriveRenewed() async throws {
        let (cam, backend, t) = try await fx6Lens()
        defer { t.cancel(); cam.stop() }
        for _ in 0..<7 {
            await backend.send(.driveFocus(-3))
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        #expect(focusControls(cam) == [-3], "1.4 s held, renewed every 200 ms: one drive, no stop")
        await backend.send(.driveFocus(0))
        #expect(focusControls(cam) == [-3, 0])
        // Past the camera's range is its fastest, not more.
        await backend.send(.driveFocus(20))
        await backend.send(.driveFocus(0))
        #expect(focusControls(cam).suffix(2) == [8, 0])
    }

    @Test("FX6 focus: disconnecting while it drives stops it first", .timeLimit(.minutes(1)))
    func focusDriveStopsOnDisconnect() async throws {
        let (cam, backend, t) = try await fx6Lens()
        defer { t.cancel(); cam.stop() }
        await backend.send(.driveFocus(1))
        await backend.disconnect()
        #expect(focusControls(cam) == [1, 0])
    }

    /// A stop the camera didn't answer OK (a wedged link) isn't forgotten: it's sent again on the next session.
    @Test("FX6 focus: a stop that didn't land is sent again on the next connection", .timeLimit(.minutes(1)))
    func focusStopRetriedOnReconnect() async throws {
        let (cam, backend, t) = try await fx6Lens { $0.failedStops = [SDIControlCode.focusOperation.rawValue: 2] }
        defer { t.cancel(); cam.stop() }
        await backend.send(.driveFocus(2))
        await backend.send(.driveFocus(0))       // answered General Error
        await backend.disconnect()                // tries again on the way out: General Error again
        #expect(focusControls(cam) == [2, 0, 0])
        let again = Task.detached { await backend.connect() }
        defer { again.cancel() }
        for _ in 0..<500 where focusControls(cam).count < 4 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(focusControls(cam) == [2, 0, 0, 0], "the stop, sent again as soon as there was a session")
    }

    /// An FX6's LUT switch reaches its outputs only; with none (Custom has no monitor LUT) it writes nothing, never the
    /// older Monitor LUT property (0xD04D) whose reach into the recording no FX6 has shown.
    @Test("FX6: the LUT switch writes nothing where the camera has no LUT outputs", .timeLimit(.minutes(1)))
    func fx6LookWithoutOutputs() async throws {
        let (cam, backend, t) = try await fx6Lens()
        defer { t.cancel(); cam.stop() }
        let before = cam.propWrites.count
        await backend.send(.setLook(true))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(cam.propWrites.count == before)
    }

    /// Down landed and Up didn't: the button is let go on the next session, and the app says so meanwhile.
    @Test("FX6 assignable buttons: an Up that never landed is sent on the next connection", .timeLimit(.minutes(1)))
    func assignableReleasedOnReconnect() async throws {
        let (cam, backend, t) = try await fx6Lens {
            $0.assignables = [2: 0x31]
            $0.assignableNames = [0x31: "S&Q Motion"]
            $0.failedUps = [0xE02A: 4]
        }
        defer { t.cancel(); cam.stop() }
        let _ = await collectUntil(backend: backend) { $0.assignableButtons.first?.isPressable == true }
        await backend.send(.pressAssignable(2))
        let ups = { cam.propWrites.filter { $0.code == 0xE02A && $0.data.first == 0x01 }.count }
        #expect(ups() == 4)
        await backend.disconnect()
        let again = Task.detached { await backend.connect() }
        defer { again.cancel() }
        for _ in 0..<500 where ups() < 5 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(ups() == 5, "let go as soon as there was a session")
    }

    /// Only a function Tiles has checked on a camera is pressed, by its index and its English name both; a button set
    /// to Last Clip Del. never is.
    @Test("FX6 assignable buttons: S&Q Motion is pressed, Down then Up; Last Clip Del. never", .timeLimit(.minutes(1)))
    func assignablePress() async throws {
        let (cam, backend, t) = try await fx6Lens {
            $0.assignables = [1: 0x43, 2: 0x31]
            $0.assignableNames = [0x43: "Last Clip", 0x31: "S&Q Motion"]
        }
        defer { t.cancel(); cam.stop() }
        let s = try #require(await collectUntil(backend: backend) { $0.assignableButtons.count == 2 })
        #expect(s.assignableButtons.map(\.isPressable) == [false, true])
        await backend.send(.pressAssignable(1))
        await backend.send(.pressAssignable(2))
        let up = Data([0x01, 0x00]), down = Data([0x02, 0x00])
        for _ in 0..<300 where cam.propWrites.filter({ $0.code == 0xE02A }).count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(!cam.propWrites.contains { $0.code == 0xE029 }, "Last Clip Del. was pressed")
        #expect(cam.propWrites.filter { $0.code == 0xE02A }.map(\.data) == [down, up])
    }

    /// What a BURANO takes through the app's path (camctl app: steps, each read back): tally lamps one at a
    /// time, CALL, the ND's STEP/VARIABLE switch, the color gamut, and one-push AWB pressed Down then Up.
    @Test("Tally, CALL, ND mode, color gamut and one-push AWB write what the BURANO took", .timeLimit(.minutes(1)))
    func buranoSettings() async throws {
        var camCfg = FakePTPIPCamera.Config()
        var up = Data(); up.appendLE(UInt16(0x0001))
        camCfg.fakePropData[SDIPropCode.awb.rawValue] = up
        let cam = FakePTPIPCamera(config: camCfg)
        try await cam.start()
        defer { cam.stop() }

        let backend = backendWithPlayback(cam: cam, port: cam.port)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }
        let _ = await collectUntil(backend: backend) { $0.connection == .connected && $0.recording.state != .unknown }

        func written(_ code: SDIPropCode) -> [[UInt8]] { cam.propWrites.filter { $0.code == code.rawValue }.map { Array($0.data) } }
        await backend.send(.setTally("Red"))
        await backend.send(.setCall(true))
        await backend.send(.setNDMode("Variable"))
        await backend.send(.setColorGamut("S-Gamut3"))
        await backend.send(.setWhiteBalancePreset("AWB"))
        for _ in 0..<200 {
            if written(.awb).count >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(written(.redTallyLamp) == [[0x02]])
        #expect(written(.greenTallyLamp) == [[0x01]])
        #expect(written(.callSetting) == [[0x02]])
        #expect(written(.ndFilterSwitching) == [[0x02]])
        #expect(written(.colorGamut) == [[0x02]])
        #expect(written(.awb) == [[0x02, 0x00], [0x01, 0x00]])
    }

    /// Camera Menu's buttons: Home and the rest through Camera Button Function (0xD309, the 0xD208 list), MENU held 1.5 s
    /// through the Multi one (0xD30A, the 0xD209 list), as key:0x1D and mkey:0x06:1.5 on a BURANO.
    /// A button the camera doesn't list isn't pressed.
    @Test("Camera buttons: Home on Camera Button Function, MENU held on the Multi one, nothing unlisted", .timeLimit(.minutes(1)))
    func cameraButtons() async throws {
        var camCfg = FakePTPIPCamera.Config()
        func uint16(_ v: UInt16) -> Data { var d = Data(); d.appendLE(v); return d }
        camCfg.fakePropData[SDIPropCode.cameraButtonList.rawValue] = uint16(0x001D)
        camCfg.fakePropData[SDIPropCode.cameraButtonListMulti.rawValue] = uint16(0x0006)
        let cam = FakePTPIPCamera(config: camCfg)
        try await cam.start()
        defer { cam.stop() }

        let backend = backendWithPlayback(cam: cam, port: cam.port)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }
        let _ = await collectUntil(backend: backend) { $0.connection == .connected && $0.recording.state != .unknown }

        func presses() -> [String] {
            cam.controls.filter { [SDIControlCode.cameraButtonFunction.rawValue, SDIControlCode.cameraButtonFunctionMulti.rawValue]
                .contains($0.code) && $0.data.count == 4 }
                .map { String(format: "%04X:%08X", $0.code, $0.data.readLE(UInt32.self, at: 0)) }
        }
        await backend.send(.pressCameraButton(.home))
        await backend.send(.pressCameraButton(.menu))
        await backend.send(.pressCameraButton(.clips))   // not on this camera's list
        #expect(presses() == ["D309:001D0002", "D309:001D0001", "D30A:00060002", "D30A:00060001"])
    }

    @Test("skip does NOT send any button (Sony can't seek)", .timeLimit(.minutes(1)))
    func skipSendsNothing() async throws {
        let cam = makeCamWithPlayback()
        try await cam.start()
        defer { cam.stop() }

        let backend = backendWithPlayback(cam: cam, port: cam.port)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }
        let _ = await collectUntil(backend: backend) { $0.connection == .connected && $0.recording.state != .unknown }

        let writeBefore = cam.propWrites.count
        await backend.send(.playback(.skip(15)))
        // Small wait; a spurious write would appear quickly.
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(cam.propWrites.count == writeBefore)
    }
}

// MARK: - Playback through the camera's own buttons (FX3)

@Suite("Sony playback through the camera's own buttons")
struct SonyButtonPlaybackTests {
    private func connected(_ cam: FakePTPIPCamera) async throws -> (SonyCameraBackend, Task<Void, Never>) {
        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        cfg.pollInterval = 60
        cfg.skipScanTime = 0.05
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let t = Task.detached { await backend.connect() }
        _ = try #require(await collectUntil(backend: backend) { $0.connection == .connected && $0.playback != nil })
        return (backend, t)
    }

    private func fx3() -> FakePTPIPCamera {
        var cfg = FakePTPIPCamera.Config()
        cfg.buttonPlayback = true
        return FakePTPIPCamera(config: cfg)
    }

    @Test("Review first: in Record mode the arrows and ENTER are never pressed", .timeLimit(.minutes(1)))
    func transportOnlyInReview() async throws {
        let cam = fx3()
        try await cam.start()
        defer { cam.stop() }
        let (backend, t) = try await connected(cam)
        defer { t.cancel() }

        // On a real FX3 these would have toggled peaking and zebras.
        await backend.send(.playback(.fastForward))
        await backend.send(.playback(.rewind))
        await backend.send(.playback(.next))
        await backend.send(.playback(.togglePlay))
        #expect(cam.buttonPresses.isEmpty)
        #expect(cam.shortcutPresses == 0)

        await backend.send(.playback(.review))        // Playback, then ENTER plays the clip it opens on
        #expect(await collectUntil(backend: backend) { $0.playback?.inReview == true } != nil)
        #expect(cam.buttonPresses.map(\.id) == [0x11, 0x11, 0x05, 0x05])
        #expect(cam.buttonPresses.map(\.on) == [true, false, true, false])
        #expect(cam.clipPlaying)

        await backend.send(.playback(.fastForward))   // playing: a short scan, ENTER to play on
        await backend.send(.playback(.togglePlay))    // pauses
        await backend.send(.playback(.rewind))        // paused: ENTER to play, then the same
        #expect(cam.buttonPresses.filter(\.on).map(\.id) == [0x11, 0x05, 0x04, 0x05, 0x05, 0x05, 0x03, 0x05])
        #expect(cam.shortcutPresses == 0)
    }

    @Test("Next and previous clip: from a playing or paused clip, Playback back to the clip first; an arrow on a stopped one", .timeLimit(.minutes(1)))
    func nextAndPreviousClip() async throws {
        let cam = fx3()
        try await cam.start()
        defer { cam.stop() }
        let (backend, t) = try await connected(cam)
        defer { t.cancel() }

        await backend.send(.playback(.review))       // Playback, ENTER: playing
        _ = await collectUntil(backend: backend) { $0.playback?.inReview == true }
        await backend.send(.playback(.next))         // playing: Playback, Right, then ENTER so it plays on
        await backend.send(.playback(.togglePlay))   // pauses
        await backend.send(.playback(.previous))     // paused: Playback, Left, and it stays stopped
        await backend.send(.playback(.next))         // stopped: Right
        #expect(cam.buttonPresses.filter(\.on).map(\.id) == [0x11, 0x05, 0x11, 0x04, 0x05, 0x05, 0x11, 0x03, 0x04])
        #expect(cam.operatingMode == 0x02 && cam.clipIndex == 1 && !cam.clipPlaying)
        #expect(cam.shortcutPresses == 0)
    }

    @Test("A clip that ended on its own still changes with ⏭, and Playback is kept", .timeLimit(.minutes(1)))
    func nextAfterAClipEnded() async throws {
        let cam = fx3()
        try await cam.start()
        defer { cam.stop() }
        let (backend, t) = try await connected(cam)
        defer { t.cancel() }

        await backend.send(.playback(.review))       // plays
        _ = await collectUntil(backend: backend) { $0.playback?.inReview == true }
        cam.endClip()                                // and ends: back on its own screen, unseen
        await backend.send(.playback(.next))         // Playback leaves Playback from there: back in, Right, ENTER
        #expect(cam.operatingMode == 0x02 && cam.clipIndex == 1 && cam.clipPlaying)
        #expect(cam.buttonPresses.filter(\.on).map(\.id) == [0x11, 0x05, 0x11, 0x11, 0x04, 0x05])
        #expect(cam.shortcutPresses == 0)
    }

    @Test("Held arrows scan until let go, then play on; a stopped clip is started first", .timeLimit(.minutes(1)))
    func holdToScan() async throws {
        let cam = fx3()
        try await cam.start()
        defer { cam.stop() }
        let (backend, t) = try await connected(cam)
        defer { t.cancel() }

        await backend.send(.playback(.review))
        _ = await collectUntil(backend: backend) { $0.playback?.inReview == true }
        await backend.send(.playback(.scan(forward: true)))   // playing already: Right
        await backend.send(.playback(.endScan))                // ENTER: play on
        #expect(cam.buttonPresses.filter(\.on).map(\.id) == [0x11, 0x05, 0x04, 0x05])

        await backend.send(.playback(.scan(forward: false)))  // playing: Left straight away
        await backend.send(.playback(.endScan))
        #expect(cam.buttonPresses.filter(\.on).map(\.id) == [0x11, 0x05, 0x04, 0x05, 0x03, 0x05])
        await backend.send(.playback(.endScan))                // nothing is scanning: nothing pressed
        #expect(cam.buttonPresses.filter(\.on).count == 6)
    }

    @Test("Live presses Playback until the live picture is back: twice from a playing clip, never a third", .timeLimit(.minutes(1)))
    func liveFromPlayingClip() async throws {
        let cam = fx3()
        try await cam.start()
        defer { cam.stop() }
        let (backend, t) = try await connected(cam)
        defer { t.cancel() }

        await backend.send(.playback(.review))       // the clip plays
        _ = await collectUntil(backend: backend) { $0.playback?.inReview == true }
        await backend.send(.playback(.live))
        #expect(await collectUntil(backend: backend) { $0.playback?.inReview == false } != nil)
        #expect(cam.operatingMode == 0x01)
        #expect(cam.buttonPresses.filter(\.on).map(\.id) == [0x11, 0x05, 0x11, 0x11])
    }

    @Test("A double tap on Review or on Live presses Playback once", .timeLimit(.minutes(1)))
    func doubleTap() async throws {
        let cam = fx3()
        try await cam.start()
        defer { cam.stop() }
        let (backend, t) = try await connected(cam)
        defer { t.cancel() }

        async let a: Void = backend.send(.playback(.review))
        async let b: Void = backend.send(.playback(.review))
        _ = await (a, b)
        #expect(cam.buttonPresses.filter(\.on).map(\.id) == [0x11, 0x05])   // Playback once, and the clip plays
        #expect(cam.operatingMode == 0x02)

        async let c: Void = backend.send(.playback(.live))
        async let d: Void = backend.send(.playback(.live))
        _ = await (c, d)
        #expect(cam.buttonPresses.filter(\.on).map(\.id) == [0x11, 0x05, 0x11, 0x11])
        #expect(cam.operatingMode == 0x01)
    }

    @Test("Review is refused while recording", .timeLimit(.minutes(1)))
    func noReviewWhileRecording() async throws {
        var cfg = FakePTPIPCamera.Config()
        cfg.buttonPlayback = true
        cfg.recordingState = 0x01
        let cam = FakePTPIPCamera(config: cfg)
        try await cam.start()
        defer { cam.stop() }
        let (backend, t) = try await connected(cam)
        defer { t.cancel() }

        await backend.send(.playback(.review))
        #expect(cam.buttonPresses.isEmpty)
        #expect(cam.operatingMode == 0x01)
    }
}
