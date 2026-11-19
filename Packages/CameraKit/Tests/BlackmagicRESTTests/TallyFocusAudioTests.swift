// Blackmagic tally, one-shot autofocus and the audio channels against the fake camera. Built from
// the API's documentation (Camera 10.1): no camera has answered any of these yet.

import Testing
import Foundation
import CameraCore
@testable import BlackmagicRESTBackend

@Suite("BlackmagicREST — tally, autofocus, audio", .serialized)
struct TallyFocusAudioTests {

    private func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func start(_ config: FakeBlackmagicCamera.Config = .init(), eventTimeout: TimeInterval? = nil)
        async throws -> (FakeBlackmagicCamera, BlackmagicCameraBackend, Task<Void, Never>) {
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        let backend = makeBackendDirectly(cam: cam)
        if let eventTimeout { await backend.setEventTimeout(eventTimeout) }
        let task = Task.detached { await backend.connect() }
        return (cam, backend, task)
    }

    // MARK: Tally

    @Test("Tally reads after connect, sets as Program and Preview, and shows the camera's own change", .timeLimit(.minutes(1)))
    func tally() async throws {
        let (cam, backend, task) = try await start()
        defer { task.cancel(); cam.stop() }

        let first = await collectUntil(backend: backend) { $0.tally != nil }
        #expect(first?.tally?.value == "Off")
        #expect(first?.tally?.options == ["Off", "Green", "Red"])
        #expect(first?.offers(.tally) == true)

        await backend.send(.setTally("Red"))
        #expect(await collectUntil(backend: backend) { $0.tally?.value == "Red" } != nil)
        await backend.send(.setTally("Green"))
        #expect(await collectUntil(backend: backend) { $0.tally?.value == "Green" } != nil)
        #expect(cam.tallyPuts == ["Program", "Preview"])

        // A switcher's tally over SDI, say.
        cam.setTallyOnCamera("None")
        #expect(await collectUntil(backend: backend) { $0.tally?.value == "Off" } != nil)
    }

    @Test("Tally the WebSocket refuses is read over REST", .timeLimit(.minutes(1)))
    func tallyOverREST() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.refusedSubscriptions = ["/camera/tallyStatus"]
        config.tallyStatus = "Program"
        let (cam, backend, task) = try await start(config)
        defer { task.cancel(); cam.stop() }
        #expect(await collectUntil(backend: backend) { $0.tally?.value == "Red" } != nil)
    }

    @Test("Subscriptions the camera never answers hold up neither the connection nor the monitoring", .timeLimit(.minutes(1)))
    func unansweredSubscriptions() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.audioChannels = FakeBlackmagicCamera.twoAudioChannels
        config.silentSubscriptions = ["/camera/tallyStatus", "/lens/focus/description", "/audio/channel/1/level"]
        let started = Date()
        let (cam, backend, task) = try await start(config, eventTimeout: 4)
        defer { task.cancel(); cam.stop() }

        // Connected and the monitoring in well inside the 4 s the unanswered ones are waited for.
        let monitoring = await collectUntil(backend: backend) { $0.monitoring?.outputs.isEmpty == false }
        #expect(monitoring?.iso != nil)
        #expect(Date().timeIntervalSince(started) < 2.5, "the monitoring waited for tally, focus or audio")
        // Then those, read over REST once their wait is over.
        let state = await collectUntil(backend: backend) { $0.tally != nil && $0.canAutoFocus && $0.audioChannels.count == 2 }
        #expect(state?.tally?.value == "Off")
        #expect(state?.audioChannels[1].gain?.value == 20)
    }

    // MARK: Autofocus

    @Test("Autofocus: offered with a lens the camera can focus, and sent for the middle of the picture", .timeLimit(.minutes(1)))
    func autoFocus() async throws {
        let (cam, backend, task) = try await start()
        defer { task.cancel(); cam.stop() }

        let state = await collectUntil(backend: backend) { $0.canAutoFocus }
        #expect(state?.offers(.autoFocus) == true)
        await backend.send(.autoFocus)
        #expect(await eventually { cam.autoFocusPuts.count == 1 })
        let position = cam.autoFocusPuts.first?["position"] as? [String: Any]
        #expect((position?["x"] as? NSNumber)?.doubleValue == 0.5)
        #expect((position?["y"] as? NSNumber)?.doubleValue == 0.5)
    }

    @Test("Autofocus isn't offered with a manual lens", .timeLimit(.minutes(1)))
    func noAutoFocusOnAManualLens() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.focusControllable = false
        let (cam, backend, task) = try await start(config)
        defer { task.cancel(); cam.stop() }

        // Everything after connect is in once the tally is (it comes in the same burst as the focus lens).
        let state = await collectUntil(backend: backend) { $0.tally != nil && $0.monitoring != nil }
        #expect(state?.canAutoFocus == false)
        #expect(state?.offers(.autoFocus) == false)
    }

    // MARK: Audio

    @Test("Audio: each channel's input, gain and switches, as its input describes them", .timeLimit(.minutes(1)))
    func audioChannels() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.audioChannels = FakeBlackmagicCamera.twoAudioChannels
        let (cam, backend, task) = try await start(config)
        defer { task.cancel(); cam.stop() }

        let state = try #require(await collectUntil(backend: backend) { $0.audioChannels.count == 2 })
        #expect(state.offers(.audio))
        let mic = state.audioChannels[0]
        #expect(mic.name == "CH1")
        #expect(mic.input?.value == "XLR1 - Mic")
        #expect(mic.input?.options == ["XLR1 - Mic", "XLR1 - Line", "Camera - Left"])
        #expect(mic.gain?.value == 30)
        #expect(mic.gain?.range == -12...60)
        #expect(mic.phantomPower?.value == true)
        #expect(mic.lowCut?.value == false)
        #expect(mic.pad?.value == false)
        #expect(mic.pad?.isWritable == true)
        // The camera's own microphone: a gain and a low cut, no phantom power and no pad.
        let camera = state.audioChannels[1]
        #expect(camera.input?.value == "Camera - Right")
        #expect(camera.gain?.range == 0...40)
        #expect(camera.phantomPower == nil)
        #expect(camera.pad == nil)
        #expect(camera.lowCut != nil)
    }

    @Test("Audio: gain, phantom power, low cut and pad go to the camera and come back", .timeLimit(.minutes(1)))
    func audioWrites() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.audioChannels = FakeBlackmagicCamera.twoAudioChannels
        let (cam, backend, task) = try await start(config)
        defer { task.cancel(); cam.stop() }
        _ = await collectUntil(backend: backend) { $0.audioChannels.count == 2 }

        await backend.send(.setAudio(channel: 0, .gain(42)))
        #expect(await collectUntil(backend: backend) { $0.audioChannels.first?.gain?.value == 42 } != nil)
        await backend.send(.setAudio(channel: 0, .phantomPower(false)))
        #expect(await collectUntil(backend: backend) { $0.audioChannels.first?.phantomPower?.value == false } != nil)
        await backend.send(.setAudio(channel: 0, .lowCut(true)))
        #expect(await collectUntil(backend: backend) { $0.audioChannels.first?.lowCut?.value == true } != nil)
        await backend.send(.setAudio(channel: 0, .pad(true)))
        #expect(await collectUntil(backend: backend) { $0.audioChannels.first?.pad?.value == true } != nil)
        #expect(cam.audioPuts == ["0/level", "0/phantomPower", "0/lowCutFilter", "0/padding"])
        #expect(cam.audio?[0].gain == 42)
    }

    @Test("Audio: a pad the camera answers for but keeps stays as the camera reads it, and the log says so",
          .timeLimit(.minutes(1)))
    func audioPadKept() async throws {
        var config = FakeBlackmagicCamera.Config()
        let mic = FakeBlackmagicCamera.AudioInputSpec(gainRange: 0...60, phantomPower: true, padAvailable: true, padKept: true)
        var channel = FakeBlackmagicCamera.AudioChannelState(input: "XLR1 - Mic", inputs: [("XLR1 - Mic", mic)], gain: 0)
        channel.padding = true
        config.audioChannels = [channel]
        let (cam, backend, task) = try await start(config)
        defer { task.cancel(); cam.stop() }
        _ = await collectUntil(backend: backend) { $0.audioChannels.first?.pad?.value == true }

        await backend.send(.setAudio(channel: 0, .pad(false)))
        #expect(cam.audioPuts == ["0/padding"])
        #expect(await backend.state.audioChannels.first?.pad?.value == true)
        #expect(ActivityLog.shared.text.contains("audio channel 1: the camera kept its pad on"))
    }

    @Test("Audio: another input brings its own range and switches, set here or on the camera", .timeLimit(.minutes(1)))
    func audioInputChange() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.audioChannels = FakeBlackmagicCamera.twoAudioChannels
        let (cam, backend, task) = try await start(config)
        defer { task.cancel(); cam.stop() }
        _ = await collectUntil(backend: backend) { $0.audioChannels.count == 2 }

        // A line input: ±12 dB, its pad always on, no phantom power. The gain the camera clamped into the new range.
        await backend.send(.setAudio(channel: 0, .input("XLR1 - Line")))
        let line = await collectUntil(backend: backend) {
            $0.audioChannels.first?.input?.value == "XLR1 - Line" && $0.audioChannels.first?.gain?.range == -12...12
                && $0.audioChannels.first?.pad?.isWritable == false
        }
        let channel = try #require(line?.audioChannels.first)
        #expect(channel.gain?.value == 12)
        #expect(channel.phantomPower == nil)
        #expect(channel.pad?.value == true)

        // Someone plugs an XLR mic into channel 2 and switches it on the camera.
        cam.changeAudioInputOnCamera(1, to: "XLR2 - Mic")
        let mic = await collectUntil(backend: backend) {
            $0.audioChannels.count == 2 && $0.audioChannels[1].input?.value == "XLR2 - Mic"
                && $0.audioChannels[1].phantomPower != nil
        }
        #expect(mic?.audioChannels[1].gain?.range == -12...60)
    }

    @Test("Audio the WebSocket refuses is read over REST", .timeLimit(.minutes(1)))
    func audioOverREST() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.audioChannels = FakeBlackmagicCamera.twoAudioChannels
        config.refusedSubscriptions = Set((0..<2).flatMap { channel in
            ["input", "level", "phantomPower", "padding", "lowCutFilter", "available"].map { "/audio/channel/\(channel)/\($0)" }
        })
        let (cam, backend, task) = try await start(config)
        defer { task.cancel(); cam.stop() }

        let state = await collectUntil(backend: backend) { $0.audioChannels.count == 2 }
        #expect(state?.audioChannels[0].gain?.value == 30)
        #expect(state?.audioChannels[1].input?.value == "Camera - Right")
    }

    @Test("A camera without the API's audio connects as before, with nothing to show", .timeLimit(.minutes(1)))
    func noAudio() async throws {
        let (cam, backend, task) = try await start()
        defer { task.cancel(); cam.stop() }

        let state = await collectUntil(backend: backend) { $0.tally != nil && $0.monitoring != nil }
        #expect(state?.audioChannels.isEmpty == true)
        #expect(state?.offers(.audio) == false)
    }

    // MARK: Mapping

    @Test("A channel without a range shows its gain, unset; a forced pad is on and fixed")
    func channelMapping() {
        var report = AudioReport()
        report.gain = 6
        report.input = "XLR1 - Line"
        let unset = BlackmagicAudio.channel(0, report)
        #expect(unset?.gain?.isWritable == false)
        #expect(unset?.input?.isWritable == false)  // nothing else to pick

        report.description = AudioInputDescription(
            gainRange: .init(min: -12, max: 12),
            capabilities: [.init(phantomPower: false, lowCutFilter: true, padding: .init(available: false, forced: true))])
        let line = BlackmagicAudio.channel(0, report)
        #expect(line?.pad == Choice(true, options: [false, true], isWritable: false))
        #expect(line?.lowCut?.value == false)
        #expect(line?.phantomPower == nil)
        #expect(BlackmagicAudio.channel(1, AudioReport()) == nil)
    }
}
