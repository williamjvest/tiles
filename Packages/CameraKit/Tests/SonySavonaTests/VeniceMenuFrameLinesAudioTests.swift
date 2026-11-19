@testable import CameraCore
import XCTest
@testable import SonySavona

/// A VENICE's Camera Menu keys, the user frame lines of frame line sets A and B, and the audio meters, against
/// `FakeVeniceCamera`. None of them has met a camera yet: the key names are Sony's page's and SkaarHoj's, the frame
/// line switches the page's menu table's, the meters the VENICE 2 capture's.
final class VeniceMenuFrameLinesAudioTests: XCTestCase {
    final class Latest: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = CameraState()
        var value: CameraState { lock.withLock { stored } }
        func set(_ state: CameraState) { lock.withLock { stored = state } }
    }

    private var camera: FakeVeniceCamera!
    private var backend: VeniceCameraBackend!
    private var latest: Latest!
    private var listening: Task<Void, Never>?

    override func setUp() async throws {
        try await connect(FakeVeniceCamera())
    }

    private func connect(_ fake: FakeVeniceCamera) async throws {
        camera = fake
        try await camera.start()
        backend = VeniceCameraBackend(host: camera.host, user: "admin", password: camera.password)
        let latest = Latest()
        self.latest = latest
        let updates = backend.updates
        listening = Task { for await state in updates { latest.set(state) } }
        await backend.connect()
        try await until("connected") { $0.connection == .connected && $0.lut != nil }
    }

    override func tearDown() async throws {
        await backend.disconnect()
        listening?.cancel()
        camera.stop()
    }

    private func until(_ what: String, timeout: Double = 5, _ condition: (CameraState) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(latest.value) {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: Camera Menu

    func testTheCameraMenuSendsTheCamerasOwnKeys() async throws {
        XCTAssertEqual(latest.value.cameraButtons, [.menu, .home, .back, .up, .down, .enter])
        XCTAssertTrue(latest.value.offers(.cameraMenu))
        for button in [CameraBodyButton.menu, .down, .up, .enter, .back, .home] {
            await backend.send(.pressCameraButton(button))
        }
        XCTAssertEqual(camera.keysPressed, ["Menu", "DownArrow", "UpArrow", "Set", "Cancel", "Home"])
        // Keys a BURANO has and a VENICE hasn't send nothing.
        await backend.send(.pressCameraButton(.left))
        await backend.send(.pressCameraButton(.display))
        XCTAssertEqual(camera.keysPressed.count, 6)
    }

    func testAKeyTheCameraDoesntAnswerComesOffTheMenuAfterItsThreeSeconds() async throws {
        camera.answerNothing(toKeys: ["Menu"])
        let sent = Date()
        await backend.send(.pressCameraButton(.menu))
        let waited = Date().timeIntervalSince(sent)
        XCTAssertLessThan(waited, 4, "the camera page's 3 s, not the client's 8")
        try await until("Menu off the Camera Menu") { !$0.cameraButtons.contains(.menu) }
        XCTAssertEqual(latest.value.cameraButtons, [.home, .back, .up, .down, .enter])
        // Not sent again on this connection; the rest still work.
        await backend.send(.pressCameraButton(.menu))
        await backend.send(.pressCameraButton(.enter))
        XCTAssertEqual(camera.keysPressed, ["Menu", "Set"])
    }

    func testATapWhileAKeyIsOutIsDropped() async throws {
        camera.answerNothing(toKeys: ["DownArrow"])
        let backend = self.backend!
        async let first: Void = backend.send(.pressCameraButton(.down))
        try await Task.sleep(for: .milliseconds(200))
        await backend.send(.pressCameraButton(.down))  // still out: dropped, not queued behind it
        _ = await first
        XCTAssertEqual(camera.keysPressed, ["DownArrow"])
    }

    // MARK: Playback

    func testTheArrowsSayTheyRunAtFourTimes() {
        XCTAssertEqual(latest.value.playback?.capabilities.scanSpeed, 4)
        XCTAssertEqual(latest.value.playback?.capabilities.scanSpeedLabel, "4×")
        XCTAssertNil(PlaybackCapabilities().scanSpeedLabel, "a camera whose speed isn't known gets no label")
        XCTAssertEqual(PlaybackCapabilities(playPause: true, stop: true, nextPrevious: true, seek: false,
                                            fastForwardRewind: true, recReview: false, scanSpeed: 2.5).scanSpeedLabel, "2.5×")
    }

    func testReviewOpensTheClipAndPlaysIt() async throws {
        await backend.send(.playback(.review))
        XCTAssertEqual(camera.keysPressed, ["InsideClips", "Play"], "the camera opens the clip paused: Play after it")
        try await until("playing") { $0.playback?.inReview == true && $0.playback?.isPlaying == true }
    }

    func testReviewWaitsUntilTheClipCanPlay() async throws {
        camera.playbackReadyDelay = 1.5
        let sent = Date()
        await backend.send(.playback(.review))
        XCTAssertEqual(camera.keysPressed, ["InsideClips", "Play"])
        XCTAssertGreaterThan(Date().timeIntervalSince(sent), 1.4, "Play only once the camera says the clip can play")
    }

    func testLettingGoOfAHeldArrowPlaysOnNotTheClipList() async throws {
        await backend.send(.playback(.review))
        await backend.send(.playback(.scan(forward: true)))
        try await Task.sleep(for: .milliseconds(200))   // the camera reports the 4× scan
        await backend.send(.playback(.endScan))
        // Play pauses a scan on the camera, so a second Play once it has.
        XCTAssertEqual(camera.keysPressed, ["InsideClips", "Play", "Forward", "Play", "Play"])
        try await until("playing at normal speed") { $0.playback?.isPlaying == true }
    }

    /// The Clips window: into the clip list (the last clip), Prev a clip at a time to the one
    /// picked by the number the camera gives, then Play once it can play. Built from what a VENICE 2 was seen to send;
    /// never on one.
    func testAClipPickedFromTheListIsSteppedToAndPlayed() async throws {
        await backend.disconnect()
        listening?.cancel()
        camera.stop()
        let fake = FakeVeniceCamera()
        fake.numberClips(6)
        try await connect(fake)
        XCTAssertTrue(latest.value.offers(.clips))
        await backend.send(.playback(.goToClip(1)))
        XCTAssertEqual(camera.keysPressed, ["InsideClips", "Prev", "Prev", "Prev", "Prev", "Play"])
        try await until("clip 2, playing") { $0.playback?.clipNumber == 2 && $0.playback?.isPlaying == true }
        // In playback already: on from there.
        await backend.send(.playback(.goToClip(4)))
        XCTAssertEqual(camera.keysPressed.suffix(4), ["Next", "Next", "Next", "Play"])
        try await until("clip 5") { $0.playback?.clipNumber == 5 }
    }

    func testNoClipListWhereTheCameraDoesntNumberItsClips() {
        XCTAssertFalse(latest.value.offers(.clips), "no AllClipPosition to step by")
    }

    func testAClipAlreadyMovingIsntPausedBySecondPlay() async throws {
        camera.opensPlaying()
        await backend.send(.playback(.review))
        XCTAssertEqual(camera.keysPressed, ["InsideClips"])
        try await until("playing") { $0.playback?.isPlaying == true }
    }

    // MARK: User frame lines

    // MARK: Output options: frame line set and audio meters

    private func output(_ id: String) -> MonitorOutput? { latest.value.monitoring?.outputs.first { $0.id == id } }

    func testEachOutputsFrameLineSetAndAudioMetersRead() async throws {
        try await until("the output options") { _ in self.output("Sdi12")?.frameLines != nil }
        XCTAssertEqual(output("Sdi12")?.frameLines, Choice(.b, options: [.a, .b]))
        XCTAssertEqual(output("Monitor")?.frameLines?.value, .a)
        XCTAssertEqual(output("Sdi12")?.overlays[.audioMeters]?.value, true, "SDI shows Info A, whose meter is on")
        XCTAssertEqual(output("Vf")?.overlays[.audioMeters]?.value, false, "the VF shows Info B, whose meter is off")
        XCTAssertEqual(output("Hdmi")?.frameLines?.isWritable, false, "HDMI follows the Monitor: set there")
    }

    func testAnOutputsFrameLineSetAndAudioMetersWrite() async throws {
        try await until("the output options") { _ in self.output("Monitor")?.frameLines != nil }
        await backend.send(.setFrameLineSet(.b, output: "Monitor"))
        try await until("Monitor on Line B") { _ in self.output("Monitor")?.frameLines?.value == .b }
        XCTAssertEqual(camera.setValues.last, ["P.System.Menu.MarkerMonitorSelect": "1"])
        await backend.send(.setMonitorOverlay(.audioMeters, true, output: "Vf"))
        try await until("VF meters on") { _ in self.output("Vf")?.overlays[.audioMeters]?.value == true }
        XCTAssertEqual(camera.setValues.last, ["P.System.Menu.DisplayInfoBAudioLevelMeterOnoff": "1"], "the VF's set, B")
    }

    func testUserFrameLinesReadAsTheCameraHasThem() async throws {
        // Read after the connect's first state, not with it: on a loaded machine the test read them before they had
        // arrived (nil) in a rare race under load.
        try await until("the user frame lines") { $0.userFrameLinesA != nil && $0.userFrameLinesB != nil }
        XCTAssertEqual(latest.value.userFrameLinesA, Choice("Off", options: ["1 + 2", "1", "2", "Off"]))
        XCTAssertEqual(latest.value.userFrameLinesB, Choice("Off", options: ["1 + 2", "1", "2", "Off"]))
        XCTAssertTrue(latest.value.offers(.userFrameA))
        XCTAssertTrue(latest.value.offers(.userFrameB))
    }

    func testUserFrameLinesWriteOnlyTheSwitchesThatChange() async throws {
        await backend.send(.setUserFrameLines(.a, "1 + 2"))
        try await until("A on both") { $0.userFrameLinesA?.value == "1 + 2" }
        XCTAssertEqual(camera.setValues.last, ["P.System.Menu.MarkerAUserBoxOnoff": "1", "P.System.Menu.MarkerAUserBox2Onoff": "1"])

        // The second is on already: only the first changes, so it's the only one sent (an unchanged one isn't reported
        // back, and would read as unconfirmed).
        await backend.send(.setUserFrameLines(.a, "2"))
        try await until("A on 2") { $0.userFrameLinesA?.value == "2" }
        XCTAssertEqual(camera.setValues.last, ["P.System.Menu.MarkerAUserBoxOnoff": "0"])

        await backend.send(.setUserFrameLines(.b, "1"))
        try await until("B on 1") { $0.userFrameLinesB?.value == "1" }
        XCTAssertEqual(camera.setValues.last, ["P.System.Menu.MarkerBUserBoxOnoff": "1"])
        XCTAssertEqual(latest.value.userFrameLinesA?.value, "2", "set A untouched")

        // What it already shows: nothing sent.
        let writes = camera.setValues.count
        await backend.send(.setUserFrameLines(.b, "1"))
        XCTAssertEqual(camera.setValues.count, writes)
    }

    func testAUserFrameLineChangedOnTheCameraShows() async throws {
        camera.bodyChange(["P.System.Menu.MarkerBUserBox2Onoff": "1"])
        try await until("B on 2") { $0.userFrameLinesB?.value == "2" }
    }

    func testACameraWithOneUserFrameLineOffersOnAndOff() async throws {
        await backend.disconnect()
        listening?.cancel()
        camera.stop()
        let fake = FakeVeniceCamera()
        fake.preset(values: ["P.System.Menu.MarkerAUserBox2Onoff": .null, "P.System.Menu.MarkerBUserBox2Onoff": .null])
        try await connect(fake)
        // Connected means the LUT has been read; the frame lines can land a moment after.
        try await until("A's user frame line") { $0.userFrameLinesA != nil }
        XCTAssertEqual(latest.value.userFrameLinesA, Choice("Off", options: ["Off", "On"]))
        await backend.send(.setUserFrameLines(.a, "On"))
        try await until("A on") { $0.userFrameLinesA?.value == "On" }
        XCTAssertEqual(camera.setValues.last, ["P.System.Menu.MarkerAUserBoxOnoff": "1"])
    }

    // MARK: Audio meters

    func testTheMetersReadOnConnectAndFollowTheCamera() async throws {
        // Read after the connect, so they can land a moment after it (once in five runs here, they hadn't).
        try await until("the meters") { $0.audioMeterCount == 4 && $0.audioMeters != nil }
        XCTAssertEqual(latest.value.audioMeterCount, 4)
        XCTAssertTrue(latest.value.offers(.audio))
        XCTAssertEqual(latest.value.audioMeters, [1.0 / 24, 1.0 / 24, 4.0 / 24, 4.0 / 24])
        XCTAssertFalse(latest.value.audioMetersMuted)

        let before = latest.value
        camera.sendMeters([12, 18, 0, 24])
        try await until("the new levels") { $0.audioMeters == [0.5, 0.75, 0, 1] }
        // The meters and nothing else (the keep-alive's latency aside, which moves on its own).
        var others = latest.value
        others.audioMeters = before.audioMeters
        others.latencyMilliseconds = before.latencyMilliseconds
        XCTAssertEqual(others, before)
    }

    func testTheMetersGreyWhileSAndQRecordsNoSound() async throws {
        camera.bodyChange(["P.System.Menu.SandQPseudoFixed": "0", "Camera.SlowAndQuickMotion.Enabled": .bool(true)])
        try await until("muted") { $0.audioMetersMuted }
        // At 1× it records sound again.
        camera.bodyChange(["P.System.Menu.SandQPseudoFixed": "1"])
        try await until("not muted") { !$0.audioMetersMuted }
    }
}
