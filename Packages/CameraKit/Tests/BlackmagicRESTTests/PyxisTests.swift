// What a PYXIS 12K (Camera 10.1) does differently from the API document: the fake answers as one did.

import Testing
import Foundation
import CameraCore
@testable import BlackmagicRESTBackend

@Suite("BlackmagicREST — PYXIS 12K", .serialized)
struct PyxisTests {

    /// The camera, the connected backend, its connect task, and the state it connected with (the whole state comes
    /// in that one update).
    private func connected(_ config: FakeBlackmagicCamera.Config = .init())
        async throws -> (FakeBlackmagicCamera, BlackmagicCameraBackend, Task<Void, Never>, CameraState?) {
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        let state = await collectUntil(backend: backend) { $0.connection == .connected }
        return (cam, backend, t, state)
    }

    // MARK: Shutter

    @Test("Switching to speed shows the speed with every option, and sets it", .timeLimit(.minutes(1)))
    func shutterSpeedMode() async throws {
        let (cam, backend, t, _) = try await connected()
        defer { cam.stop(); t.cancel() }
        #expect(await cam.subscribed(to: "/video/shutter/measurement"))

        await backend.send(.setShutterMode(.speed))
        let speed = try #require(await collectUntil(backend: backend) {
            $0.shutterMode?.value == .speed && $0.shutterSpeed?.value == "1/48"
        })
        #expect(speed.shutterSpeed?.options.count == 12)
        #expect(speed.shutterSpeed?.isWritable == true)
        #expect(speed.shutterAngle?.isWritable == false)

        await backend.send(.setShutterSpeed("1/50"))
        _ = await collectUntil(backend: backend) { $0.shutterSpeed?.value == "1/50" }
        #expect(cam.config.shutterSpeed == 50)

        // Back to angle: the camera carries the exposure over (1/50 at 24 fps is 172.8°).
        await backend.send(.setShutterMode(.angle))
        let angle = await collectUntil(backend: backend) { $0.shutterMode?.value == .angle && $0.shutterAngle?.value == 172.8 }
        #expect(angle?.shutterAngle?.isWritable == true)
    }

    // MARK: Format

    @Test("Frame rate goes as a whole format (the camera refuses one field)", .timeLimit(.minutes(1)))
    func frameRateWholeFormat() async throws {
        let (cam, backend, t, _) = try await connected()
        defer { cam.stop(); t.cancel() }
        #expect(await cam.subscribed(to: "/system/format"))

        await backend.send(.setFrameRate("25"))
        let state = await collectUntil(backend: backend) { $0.frameRate?.project.value == "25" }
        #expect(state?.frameRate?.project.value == "25")
        #expect(cam.config.frameRate == "25")
        let put = try #require(cam.formatPuts.last)
        #expect(Set(put.keys) == ["codec", "frameRate", "offSpeedEnabled", "offSpeedFrameRate",
                                  "recordResolution", "sensorResolution"])
    }

    @Test("A recording area without the codec takes the nearest it has, not Q0", .timeLimit(.minutes(1)))
    func resolutionNearestCodec() async throws {
        let (cam, backend, t, _) = try await connected()
        defer { cam.stop(); t.cancel() }
        #expect(await cam.subscribed(to: "/system/format"))

        await backend.send(.setResolution("4K 16:9"))
        let state = await collectUntil(backend: backend) { $0.resolution?.value == "4K 16:9" }
        #expect(state?.fileFormat?.value == "BRAW 6:1")   // 8:1 isn't offered in 4K
        #expect(state?.fileFormat?.options.contains("BRAW 8:1") == false)
        #expect(cam.config.sensorResolution == FakeBlackmagicCamera.Size(12288, 6912))
        #expect(cam.config.frameRate == "24")
    }

    @Test("A codec label goes back to the camera's own name", .timeLimit(.minutes(1)))
    func codecRoundTrip() async throws {
        let (cam, backend, t, _) = try await connected()
        defer { cam.stop(); t.cancel() }
        #expect(await cam.subscribed(to: "/system/format"))

        await backend.send(.setFileFormat("BRAW 12:1"))
        let state = await collectUntil(backend: backend) { $0.fileFormat?.value == "BRAW 12:1" }
        #expect(state?.fileFormat?.value == "BRAW 12:1")
        #expect(cam.config.codec == "BRaw:12_1")
    }

    @Test("A format pushed without its sensor window still changes", .timeLimit(.minutes(1)))
    func formatPushWithoutSensor() async throws {
        let (cam, backend, t, _) = try await connected()
        defer { cam.stop(); t.cancel() }
        #expect(await cam.subscribed(to: "/system/format"))

        // What the camera pushes on leaving playback.
        cam.pushPropertyChanged("/system/format", value: [
            "codec": "BRaw:8_1", "frameRate": "24", "offSpeedEnabled": false, "offSpeedFrameRate": 45,
            "recordResolution": ["width": 8688, "height": 4896],
            "resolutionDescriptor": ["description": "9K 16:9", "group": "9K", "aspectRatio": "16:9"],
        ] as [String: Any])
        try await Task.sleep(for: .milliseconds(200))

        await backend.send(.setFrameRate("30"))
        let state = await collectUntil(backend: backend) { $0.frameRate?.project.value == "30" }
        #expect(state?.frameRate?.project.value == "30")
    }

    @Test("Nearest frame rate and codec for a recording area")
    func nearestChoices() {
        #expect(SupportedFormat.nearestFrameRate(to: "60", in: ["23.98", "24", "25", "29.97", "30"]) == "30")
        #expect(SupportedFormat.nearestFrameRate(to: "24", in: ["23.98", "24", "25"]) == "24")
        let fourK = FakeBlackmagicCamera.codecs4K
        #expect(SupportedFormat.nearestCodec(to: "BRaw:8_1", in: fourK) == "BRaw:6_1")
        #expect(SupportedFormat.nearestCodec(to: "BRaw:Q3", in: fourK) == "BRaw:Q3")
        #expect(SupportedFormat.nearestCodec(to: "BRaw:18_1", in: ["BRaw:Q0", "BRaw:5_1", "BRaw:12_1"]) == "BRaw:12_1")
        #expect(BlackmagicRESTStateMapper.codecLabel("BRaw:Q0") == "BRAW Q0")
    }

    // MARK: Dynamic range, off-speed

    @Test("Dynamic range: the camera's choices, and setting one", .timeLimit(.minutes(1)))
    func dynamicRange() async throws {
        let (cam, backend, t, initial) = try await connected()
        defer { cam.stop(); t.cancel() }
        #expect(initial?.dynamicRange?.value == "Film")
        #expect(initial?.dynamicRange?.options == ["Film", "Extended Video", "Video"])
        #expect(await cam.subscribed(to: "/system/dynamicRange"))

        await backend.send(.setDynamicRange("Video"))
        let state = await collectUntil(backend: backend) { $0.dynamicRange?.value == "Video" }
        #expect(state?.dynamicRange?.value == "Video")
        #expect(cam.config.dynamicRange == "Video")
    }

    @Test("Off-speed rate: within the format's range, set as a whole format", .timeLimit(.minutes(1)))
    func offSpeedRate() async throws {
        let (cam, backend, t, initial) = try await connected()
        defer { cam.stop(); t.cancel() }
        let rate = try #require(initial?.frameRate)
        #expect(rate.variableName == "Off-speed")
        #expect(rate.variableRate?.value == 45)
        // 9K 16:9 runs off-speed from 12 to 65 fps: the usual rates in that range, and 65.
        #expect(rate.variableRate?.options == [12, 15, 18, 20, 24, 25, 30, 36, 40, 45, 48, 50, 60, 65])
        #expect(await cam.subscribed(to: "/system/format"))

        await backend.send(.setFrameRateVariableRate(60))
        let state = await collectUntil(backend: backend) { $0.frameRate?.variableRate?.value == 60 }
        #expect(state?.frameRate?.variableRate?.value == 60)
        #expect(cam.formatPuts.last?["offSpeedFrameRate"] as? Double == 60)
        #expect(LinkKind(.setFrameRateVariableRate(60)) == .frameRate)   // linked cameras follow it
    }

    // MARK: Monitoring

    @Test("Outputs come from what answered: the stream output can't report, so it isn't one", .timeLimit(.minutes(1)))
    func monitoringOutputs() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.displayNames = ["LCD", "MainSDI", "Stream"]
        config.overlays = ["MainSDI/frameGuide": true]
        let (cam, backend, t, _) = try await connected(config)
        defer { cam.stop(); t.cancel() }

        let state = try #require(await collectUntil(backend: backend) { $0.monitoring?.zebraLevel != nil })
        let outputs = try #require(state.monitoring?.outputs)
        #expect(outputs.map(\.id) == ["LCD", "MainSDI"])
        #expect(outputs.map(\.name) == ["LCD", "SDI"])
        // Every overlay the API has (status text comes from a preset, which a PYXIS's four outputs list: PresetTests).
        #expect(outputs.allSatisfy { Set($0.overlays.keys) == Set(MonitorOverlay.allCases.filter(\.isREST)) })
        #expect(outputs[1].overlays[.frameGuides]?.value == true)
        #expect(state.monitoring?.onEverywhere(.frameGuides)?.value == false)   // on SDI only
        #expect(state.monitoring?.zebraLevel?.value == 95)
        #expect(state.monitoring?.frameGuideRatio?.value == "2.39:1")
        #expect(state.monitoring?.frameGuideRatio?.options.count == 12)
        #expect(state.offers(.monitoring) && state.offers(.zebra) && state.offers(.frameGuides))
    }

    @Test("An overlay on every output reaches only the outputs that report it", .timeLimit(.minutes(1)))
    func overlayEverywhere() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.displayNames = ["LCD", "MainSDI", "Stream"]
        let (cam, backend, t, _) = try await connected(config)
        defer { cam.stop(); t.cancel() }

        await backend.send(.setMonitorOverlay(.zebra, true, output: nil))
        let state = await collectUntil(backend: backend) { $0.monitoring?.onEverywhere(.zebra)?.value == true }
        #expect(state?.monitoring?.onEverywhere(.zebra)?.value == true)
        #expect(Set(cam.overlayPuts) == ["LCD/zebra", "MainSDI/zebra"])
    }

    @Test("Clean feed on one output leaves the others' overlays alone", .timeLimit(.minutes(1)))
    func overlayOnOneOutput() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.displayNames = ["LCD", "MainSDI"]
        let (cam, backend, t, _) = try await connected(config)
        defer { cam.stop(); t.cancel() }
        #expect(await cam.subscribed(to: "/monitoring/MainSDI/cleanFeed"))

        await backend.send(.setMonitorOverlay(.cleanFeed, true, output: "MainSDI"))
        let state = try #require(await collectUntil(backend: backend) {
            $0.monitoring?.outputs.last?.overlays[.cleanFeed]?.value == true
        })
        #expect(state.monitoring?.outputs.first?.overlays[.cleanFeed]?.value == false)
        #expect(cam.overlayPuts == ["MainSDI/cleanFeed"])
    }

    @Test("Every-output switches leave an output on clean feed alone, but the LUT still reaches it", .timeLimit(.minutes(1)))
    func everyOutputSkipsCleanFeed() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.displayNames = ["LCD", "MainSDI"]
        config.overlays = ["MainSDI/cleanFeed": true]
        config.falseColorEnabled = ["LCD": false, "MainSDI": false]
        config.displayLUTEnabled = ["LCD": false, "MainSDI": false]
        let (cam, backend, t, _) = try await connected(config)
        defer { cam.stop(); t.cancel() }
        let loaded = try #require(await collectUntil(backend: backend) { $0.monitoring?.zebraLevel != nil })
        let sdi = try #require(loaded.monitoring?.outputs.last)
        #expect(sdi.isCleanFeed)
        #expect(sdi.setting(.zebra)?.isWritable == false)   // grayed in Monitoring Options

        await backend.send(.setMonitorOverlay(.zebra, true, output: nil))
        await backend.send(.setFalseColor(true))
        await backend.send(.setLook(true))
        let state = await collectUntil(backend: backend) {
            $0.monitoring?.onEverywhere(.zebra)?.value == true && $0.falseColor?.value == true && $0.look?.value == true
        }
        #expect(state != nil)
        #expect(cam.overlayPuts == ["LCD/zebra"])
        #expect(cam.config.falseColorEnabled == ["LCD": true, "MainSDI": false])
        #expect(cam.config.displayLUTEnabled == ["LCD": true, "MainSDI": true])
    }

    @Test("Look and false color reach every output, as one switch", .timeLimit(.minutes(1)))
    func lookEverywhere() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.displayNames = ["LCD", "MainSDI", "Stream"]
        config.displayLUTEnabled = ["LCD": true, "MainSDI": false, "Stream": false]
        let (cam, backend, t, _) = try await connected(config)
        defer { cam.stop(); t.cancel() }

        let mixed = await collectUntil(backend: backend) { $0.monitoring?.outputs.count == 2 }
        #expect(mixed?.look?.value == false)   // on the LCD, not on SDI

        await backend.send(.setLook(true))
        let state = await collectUntil(backend: backend) { $0.look?.value == true }
        #expect(state?.look?.value == true)
        #expect(cam.config.displayLUTEnabled["MainSDI"] == true)
        #expect(cam.config.displayLUTEnabled["Stream"] == false)   // not written: it can't report
    }

    @Test("Zebra level and frame guide ratio", .timeLimit(.minutes(1)))
    func monitoringSettings() async throws {
        let (cam, backend, t, _) = try await connected()
        defer { cam.stop(); t.cancel() }
        _ = await collectUntil(backend: backend) { $0.monitoring?.frameGuideRatio != nil }

        await backend.send(.setZebraLevel(85))
        await backend.send(.setFrameGuideRatio("1.85:1"))
        let state = await collectUntil(backend: backend) {
            $0.monitoring?.zebraLevel?.value == 85 && $0.monitoring?.frameGuideRatio?.value == "1.85:1"
        }
        #expect(state != nil)
        #expect(cam.config.zebraLevel == 85)
    }

    // MARK: Slate

    @Test("Naming: the camera letter and reel from the slate, and no next clip name ('Next Clip' isn't one)",
          .timeLimit(.minutes(1)))
    func slateNaming() async throws {
        let (cam, _, t, initial) = try await connected()
        defer { cam.stop(); t.cancel() }

        let state = try #require(initial)
        #expect(state.clipName == nil)
        #expect(state.fileNaming?.title == nil)   // a Blackmagic clip name has no title
        #expect(state.fileNaming?.cameraID?.value == "A")
        #expect(state.fileNaming?.cameraID?.options.count == 26)
        #expect(state.fileNaming?.reel?.value == 1)
        #expect(state.fileNaming?.reel?.isWritable == false)   // the PYXIS keeps it with the card
        #expect(state.offers(.clipName))
    }

    @Test("A new camera letter goes into the slate", .timeLimit(.minutes(1)))
    func slateCameraLetter() async throws {
        let (cam, backend, t, _) = try await connected()
        defer { cam.stop(); t.cancel() }
        #expect(await cam.subscribed(to: "/slates/nextClip"))

        await backend.send(.setClipCameraID("B"))
        let letter = await collectUntil(backend: backend) { $0.fileNaming?.cameraID?.value == "B" }
        #expect(letter?.fileNaming?.cameraID?.value == "B")
        #expect(cam.config.slateCamera == "B")
    }

    @Test("A reel the camera won't take shows its reason", .timeLimit(.minutes(1)))
    func slateRefusal() async throws {
        let (cam, backend, t, _) = try await connected()
        defer { cam.stop(); t.cancel() }

        await backend.send(.setClipReel(2))
        let state = await collectUntil(backend: backend) { $0.fileNaming?.failure != nil }
        #expect(state?.fileNaming?.failure == "Reel number is not editable.")
        #expect(state?.fileNaming?.reel?.value == 1)
    }

    // MARK: Lens, timecode, events

    // An electronic lens's iris, built from the camera's API documentation (no such lens has been on the PYXIS yet).
    @Test("An electronic lens: third stops across its range, set from Tiles", .timeLimit(.minutes(1)))
    func electronicLensIris() async throws {
        let (cam, backend, t, initial) = try await connected()
        defer { cam.stop(); t.cancel() }
        let iris = try #require(initial?.iris)
        #expect(iris.value == 2.8 && iris.isWritable && iris.options.contains(4.0) && iris.options.last == 22)

        await backend.send(.setIris(4.0))
        let set = await collectUntil(backend: backend) { $0.iris?.value == 4.0 }
        #expect(set != nil && cam.config.irisStop == 4.0)
    }

    @Test("Auto exposure on the aperture: the iris shows, read-only, and comes back when AE lets go", .timeLimit(.minutes(1)))
    func irisUnderAutoExposure() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.irisAuto = true
        let (cam, backend, t, initial) = try await connected(config)
        defer { cam.stop(); t.cancel() }
        #expect(initial?.iris?.isWritable == false)
        cam.setIrisAuto(false)
        #expect(await collectUntil(backend: backend) { $0.iris?.isWritable == true } != nil)
    }

    @Test("A lens fitted after connecting gets its iris tile, at its own aperture", .timeLimit(.minutes(1)))
    func lensFittedLater() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.irisControllable = false
        let (cam, backend, t, initial) = try await connected(config)
        defer { cam.stop(); t.cancel() }
        #expect(initial != nil && initial?.iris == nil)
        cam.fitLens(stop: 5.6)
        let fitted = await collectUntil(backend: backend) { $0.iris?.value == 5.6 }
        #expect(fitted?.offers(.iris) == true)
    }

    @Test("A lens the camera can't drive has no iris tile", .timeLimit(.minutes(1)))
    func manualLensHasNoIris() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.irisControllable = false
        let (cam, _, t, initial) = try await connected(config)
        defer { cam.stop(); t.cancel() }

        let state = try #require(initial)
        #expect(state.iso != nil)
        #expect(state.iris == nil)
        #expect(!state.offers(.iris))
    }

    @Test("Time of day timecode runs; a stopped one stands still", .timeLimit(.minutes(1)), arguments: [true, false])
    func timecodeRunning(running: Bool) async throws {
        var config = FakeBlackmagicCamera.Config()
        config.timecodeRunning = running
        let (cam, backend, t, _) = try await connected(config)
        defer { cam.stop(); t.cancel() }

        // REC starting re-reads the timecode, twice half a second apart. (The connect reads, on localhost, can be
        // too quick for a running clock to have moved a frame.)
        #expect(await cam.subscribed(to: "/transports/0/record"))
        cam.setRecording(true)
        if running {
            let state = await collectUntil(backend: backend, timeout: 5) { $0.timecode?.isRunning == true }
            #expect(state?.timecode?.isRunning == true)
        } else {
            try await Task.sleep(for: .seconds(1))
            let state = try #require(await collectUntil(backend: backend, timeout: 3) { $0.timecode != nil })
            #expect(state.timecode?.isRunning == false)
            #expect(state.timecode?.string(at: Date()) == "15:00:00:00")
        }
    }

    @Test("A WebSocket that never answers fails the connect rather than hanging it", .timeLimit(.minutes(1)))
    func silentWebSocket() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.silentWebSocket = true
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        defer { cam.stop() }
        let backend = makeBackendDirectly(cam: cam)
        await backend.setEventTimeout(0.5)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let state = await collectUntil(backend: backend, timeout: 5) {
            if case .failed = $0.connection { true } else { false }
        }
        #expect(state?.connection == .failed("The camera's event connection didn't answer"))
    }

    @Test("A WebSocket that drops fails the connection, so the controller reconnects", .timeLimit(.minutes(1)))
    func droppedWebSocket() async throws {
        let (cam, backend, t, _) = try await connected()
        defer { cam.stop(); t.cancel() }
        #expect(await cam.subscribed(to: "/video/iso"))

        cam.dropWebSockets()
        let state = await collectUntil(backend: backend, timeout: 5) {
            if case .failed = $0.connection { true } else { false }
        }
        #expect(state?.connection == .failed("The camera's event connection closed"))

        let t2 = Task.detached { await backend.connect() }
        defer { t2.cancel() }
        let again = await collectUntil(backend: backend, timeout: 5) { $0.connection == .connected }
        #expect(again?.iso?.value == 800)
    }

    @Test("Latency is a WebSocket ping's round trip", .timeLimit(.minutes(1)))
    func latencyFromPing() async throws {
        let (cam, backend, t, _) = try await connected()
        defer { cam.stop(); t.cancel() }

        let state = await collectUntil(backend: backend, timeout: 5) { $0.latencyMilliseconds != nil }
        #expect(state?.latencyMilliseconds.map { $0 >= 0 && $0 < 1000 } == true)
    }

    @Test("A link that stops answering pings fails the connection", .timeLimit(.minutes(1)))
    func unansweredPing() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.ignoresPings = true
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        defer { cam.stop() }
        let backend = makeBackendDirectly(cam: cam)
        await backend.setPing(every: .milliseconds(200), timeout: .milliseconds(300))
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let state = await collectUntil(backend: backend, timeout: 5) {
            if case .failed = $0.connection { true } else { false }
        }
        #expect(state?.connection == .failed("The camera stopped answering"))
    }

    @Test("A property the camera won't subscribe to doesn't stop the others", .timeLimit(.minutes(1)))
    func refusedSubscription() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.refusedSubscriptions = ["/camera/colorBars"]
        let (cam, backend, t, _) = try await connected(config)
        defer { cam.stop(); t.cancel() }

        #expect(await cam.subscribed(to: "/video/iso"))
        await backend.send(.setISO(1600))
        let state = await collectUntil(backend: backend) { $0.iso?.value == 1600 }
        #expect(state?.iso?.value == 1600)
    }

    @Test("Play from live waits for playback mode (play before it lands is refused)", .timeLimit(.minutes(1)))
    func playFromLive() async throws {
        let (cam, backend, t, _) = try await connected()
        defer { cam.stop(); t.cancel() }
        #expect(await cam.subscribed(to: "/transports/0/play"))

        await backend.send(.playback(.togglePlay))
        let state = await collectUntil(backend: backend, timeout: 5) { $0.playback?.isPlaying == true }
        #expect(state?.playback?.isPlaying == true)
        #expect(state?.warnings.isEmpty == true)
        #expect(cam.playCommandsReceived == 1)
    }

    @Test("Previous: within a second of a clip's start goes to the clip before, later to its own start",
          .timeLimit(.minutes(1)), arguments: [(250, 0), (300, 240)])
    func previous(position: Int, seeksTo: Int) async throws {
        // Clip 2 of five 240-frame clips starts at 240; a second is 24 frames.
        let (cam, backend, t, _) = try await connected(.playback(isOutput: true, position: position, clipIndex: 1))
        defer { cam.stop(); t.cancel() }

        await backend.send(.playback(.previous))
        for _ in 0..<200 { if cam.playbackPutCount > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(cam.lastPlaybackPut?["position"] as? Int == seeksTo)
    }

    @Test("Seeking sends the position alone, so playback keeps its speed", .timeLimit(.minutes(1)))
    func seekPositionOnly() async throws {
        let (cam, backend, t, _) = try await connected(.playback(isOutput: true, speed: 1, position: 300, clipIndex: 1))
        defer { cam.stop(); t.cancel() }

        await backend.send(.playback(.skip(10)))
        for _ in 0..<200 { if cam.playbackPutCount > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let put = try #require(cam.lastPlaybackPut)
        #expect(put.keys.sorted() == ["position"])
        #expect(put["position"] as? Int == 540)   // 300 + 10 s × 24 fps
    }

    @Test("Review puts the camera into playback, playing the last take, and Live takes it out", .timeLimit(.minutes(1)))
    func reviewAndLive() async throws {
        let (cam, backend, t, initial) = try await connected()
        defer { cam.stop(); t.cancel() }
        #expect(initial?.playback?.inReview == false)

        await backend.send(.playback(.review))
        let reviewing = await collectUntil(backend: backend) { $0.playback?.inReview == true && $0.playback?.isPlaying == true }
        #expect(cam.lastTransportModePut == "Output")
        #expect(reviewing?.playback?.isPlaying == true)
        #expect(cam.playCommandsReceived == 1)
        #expect(cam.lastPlaybackPut?["position"] as? Int == (cam.config.clipCount - 1) * 240, "the last take's first frame")

        await backend.send(.playback(.live))
        let live = await collectUntil(backend: backend) { $0.playback?.inReview == false }
        #expect(cam.lastTransportModePut == "InputPreview")
        #expect(live?.playback?.inReview == false)
    }

    @Test("Review on a playback list that leaves out the card's latest take says so; Live clears it, and a list with it doesn't",
          .timeLimit(.minutes(1)))
    func reviewSaysTheLatestTakeIsMissing() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.clipCount = 2
        config.clipsOffTimeline = 3
        let (cam, backend, t, _) = try await connected(config)
        defer { cam.stop(); t.cancel() }
        let before = ActivityLog.shared.text.components(separatedBy: "doesn't have the latest take").count

        await backend.send(.playback(.review))
        let flagged = await collectUntil(backend: backend) { $0.playback?.latestTakeMissing == true }
        #expect(flagged?.playback?.inReview == true)
        #expect(ActivityLog.shared.text.components(separatedBy: "doesn't have the latest take").count == before + 1)

        await backend.send(.playback(.live))
        let live = await collectUntil(backend: backend) { $0.playback?.inReview == false }
        #expect(live?.playback?.latestTakeMissing == false)

        let (whole, wholeBackend, t2, _) = try await connected()
        defer { whole.stop(); t2.cancel() }
        await wholeBackend.send(.playback(.review))
        let reviewing = await collectUntil(backend: wholeBackend) { $0.playback?.inReview == true }
        try await Task.sleep(for: .milliseconds(300))
        let after = await wholeBackend.state
        #expect(reviewing != nil && after.playback?.latestTakeMissing == false)
    }

    @Test("Review lands on the last take even when the camera goes back to the clip it last showed",
          .timeLimit(.minutes(1)))
    func reviewStaysOnTheLastTake() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.resumesAt = 240   // the second clip, last pulled up on the camera
        let (cam, backend, t, _) = try await connected(config)
        defer { cam.stop(); t.cancel() }
        await backend.send(.playback(.review))
        _ = await collectUntil(backend: backend) { $0.playback?.inReview == true && $0.playback?.isPlaying == true }
        let last = (cam.config.clipCount - 1) * 240
        #expect((last..<(last + 240)).contains(cam.config.playbackPosition), "on the last take, not where it was")
        #expect(cam.playbackPutCount >= 2, "the seek the camera didn't keep was sent again")
    }

    /// The Clips window: the playback
    /// list in its order, named from the card's files (`/clips`), each its length at the project's rate; a pick seeks
    /// to that clip's start and plays it. The Playback tile names the open clip too.
    @Test("Clips: the playback list named from the card's files; a pick plays that clip from its start",
          .timeLimit(.minutes(1)))
    func clipList() async throws {
        let (cam, backend, t, _) = try await connected()
        defer { cam.stop(); t.cancel() }
        let listed = await collectUntil(backend: backend) { $0.playback?.clips?.first?.name != nil }
        let clips = try #require(listed?.playback?.clips)
        #expect(clips.map(\.name) == (1...5).map { String(format: "A001_C%03d", $0) })
        #expect(clips.map(\.seconds) == Array(repeating: 10, count: 5), "240 frames at 24")
        #expect(listed?.offers(.clips) == true)

        await backend.send(.playback(.goToClip(2)))
        _ = await collectUntil(backend: backend) { $0.playback?.inReview == true && $0.playback?.isPlaying == true }
        #expect((480..<720).contains(cam.config.playbackPosition), "the third clip's frames")
        #expect(cam.playCommandsReceived >= 1)

        cam.pushPropertyChanged("/transports/0/clipIndex", value: ["clipIndex": 2])
        let named = await collectUntil(backend: backend) { $0.playback?.clipNumber == 3 }
        #expect(named?.playback?.clipName == "A001_C003", "the Playback tile names it")
    }

    /// A second pick while the first still seeks must end on the second: the first's check could otherwise send
    /// the camera back to its own clip. A later playback command stops an earlier one.
    @Test("Clips: a second pick while the first still seeks ends on the second", .timeLimit(.minutes(1)))
    func secondPickWins() async throws {
        let (cam, backend, t, _) = try await connected()
        defer { cam.stop(); t.cancel() }
        _ = await collectUntil(backend: backend) { $0.playback?.clips?.count == 5 }
        let first = Task { await backend.send(.playback(.goToClip(1))) }
        for _ in 0..<500 where cam.playbackPutCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await backend.send(.playback(.goToClip(3)))
        await first.value
        try await Task.sleep(for: .milliseconds(700))   // past the first's own check, had it gone on
        #expect((720..<960).contains(cam.config.playbackPosition), "on the fourth clip, the second pick")
    }

    @Test("Clips: a take added is named from the card, and no pick plays during a take", .timeLimit(.minutes(1)))
    func clipListFollowsTakes() async throws {
        let (cam, backend, t, _) = try await connected()
        defer { cam.stop(); t.cancel() }
        _ = await collectUntil(backend: backend) { $0.playback?.clips?.count == 5 && $0.playback?.clips?.last?.name != nil }
        cam.addTake()
        let six = await collectUntil(backend: backend) { $0.playback?.clips?.last?.name == "A001_C006" }
        #expect(six?.playback?.clips?.count == 6 && six?.playback?.clipCount == 6)

        cam.setRecording(true)
        _ = await collectUntil(backend: backend) { $0.recording.state == .recording }
        let puts = cam.playbackPutCount
        await backend.send(.playback(.goToClip(0)))
        #expect(cam.playbackPutCount == puts && cam.playCommandsReceived == 0)
    }

    @Test("No Review during a take", .timeLimit(.minutes(1)))
    func noReviewWhileRecording() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.recording = true
        let (cam, backend, t, _) = try await connected(config)
        defer { cam.stop(); t.cancel() }

        await backend.send(.playback(.review))
        try await Task.sleep(for: .milliseconds(500))
        #expect(cam.lastTransportModePut == nil)
    }

    @Test("White balance: Tiles' presets as on every camera, then Auto", .timeLimit(.minutes(1)))
    func whiteBalancePresets() async throws {
        let (cam, backend, t, initial) = try await connected()
        defer { cam.stop(); t.cancel() }
        let preset = try #require(initial?.whiteBalance?.preset)
        #expect(preset.options == ["2800K", "3200K", "4300K", "5000K", "5600K", "6500K", "Auto"])
        #expect(preset.value == "\(cam.config.kelvin)K")

        await backend.send(.setWhiteBalancePreset("3200K"))
        let tungsten = await collectUntil(backend: backend) { $0.whiteBalance?.kelvin.value == 3200 }
        #expect(tungsten?.whiteBalance?.preset.value == "3200K")   // the preset it matches is the one ticked

        await backend.send(.setWhiteBalancePreset("Auto"))
        let auto = await collectUntil(backend: backend) {
            $0.whiteBalance?.kelvin.value == 4950 && $0.whiteBalance?.tint?.value == 3
        }
        #expect(auto?.whiteBalance?.preset.value == "4950K")       // Auto is a measurement, not a mode
        #expect(auto?.whiteBalance?.tint?.value == 3)
    }

    @Test("An URSA Cine's ND: its own stops, shown as ND numbers, and set as stops", .timeLimit(.minutes(1)))
    func ursaCineND() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.productName = "URSA Cine 12K LF"
        config.ndStops = [0, 2, 4, 6]
        let (cam, backend, t, _) = try await connected(config)
        defer { cam.stop(); t.cancel() }

        let nd = try #require(await collectUntil(backend: backend) { $0.nd?.preset.options.count == 4 })
        #expect(nd.nd?.preset.value == "Clear")
        #expect(nd.nd?.preset.options == ["Clear", "0.6", "1.2", "1.8"])
        await backend.send(.setNDPreset("1.2"))
        let four = await collectUntil(backend: backend) { $0.nd?.preset.value == "1.2" }
        #expect(four != nil)
        #expect(cam.config.ndStop == 4)  // 1.2 / 0.3, sent as a stop
    }

    @Test("ND numbers and stops round-trip; a PYXIS, with no ND, has no ND tile", .timeLimit(.minutes(1)))
    func ndLabels() async throws {
        for stop in [0.0, 1.5, 2, 3, 4, 6, 8] {
            #expect(Stops.ndStops(Stops.ndLabel(stop)) == stop)
        }
        #expect(Stops.ndLabel(2) == "0.6" && Stops.ndLabel(8) == "2.4")
        let (cam, _, t, initial) = try await connected()
        defer { cam.stop(); t.cancel() }
        #expect(initial != nil && initial?.nd == nil)
    }

    @Test("The 12K's native ISO, 800, is marked", .timeLimit(.minutes(1)))
    func nativeISO() async throws {
        let (cam, _, t, initial) = try await connected()
        defer { cam.stop(); t.cancel() }
        #expect(initial?.nativeISOs == [800])
        #expect(BlackmagicRESTStateMapper.nativeISOs(model: "PYXIS 6K") == [400, 3200])
        #expect(BlackmagicRESTStateMapper.nativeISOs(model: "URSA Cine 12K LF").isEmpty)   // not checked: not marked
    }
}
