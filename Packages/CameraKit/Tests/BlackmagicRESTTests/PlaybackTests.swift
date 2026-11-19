// Blackmagic playback: state mapping, command requests, WebSocket-driven state updates.

import Testing
import Foundation
import CameraCore
@testable import BlackmagicRESTBackend

// MARK: - FakeBlackmagicCamera playback extensions

extension FakeBlackmagicCamera.Config {
    /// A config with playback state suitable for playback tests.
    static func playback(isOutput: Bool = false, speed: Double = 0, position: Int = 0,
                         clipIndex: Int = 0, clipCount: Int = 5) -> FakeBlackmagicCamera.Config {
        var c = FakeBlackmagicCamera.Config()
        c.playbackMode = isOutput ? "Output" : "InputPreview"
        c.playbackSpeed = speed
        c.playbackPosition = position
        c.clipIndex = clipIndex
        c.clipCount = clipCount
        return c
    }
}

// MARK: - Tests

@Suite("Blackmagic playback — state mapping", .serialized)
struct BlackmagicPlaybackStateTests {

    @Test("Connect: playback is non-nil for Blackmagic camera")
    func playbackNonNil() async throws {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let state = await collectUntil(backend: backend) { $0.connection == .connected }
        let s = try #require(state)
        #expect(s.playback != nil, "Blackmagic must always offer playback tile")
        #expect(s.offers(.playback))
    }

    @Test("Connect: playback.isPlaying false when mode is InputPreview")
    func playbackNotPlayingOnConnect() async throws {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let state = await collectUntil(backend: backend) { $0.connection == .connected }
        let pb = try #require(state?.playback)
        #expect(pb.isPlaying == false)
    }

    @Test("Connect: capabilities — playPause, Live | Review, nextPrevious, seek; no stop, FF/REW or recReview")
    func capabilities() async throws {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let state = await collectUntil(backend: backend) { $0.connection == .connected }
        let caps = try #require(state?.playback?.capabilities)
        #expect(caps.playPause)
        #expect(!caps.stop)   // stop is pause on Blackmagic; play/pause covers it
        #expect(caps.review && !caps.live)   // the Live | Review switch: InputPreview or Output
        #expect(caps.nextPrevious)
        #expect(caps.seek)
        #expect(!caps.fastForwardRewind)
        #expect(!caps.recReview)
    }

    @Test("WS /transports/0/play true → isPlaying = true")
    func wsPlayEventUpdatesState() async throws {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let _ = await collectUntil(backend: backend) { $0.connection == .connected }
        #expect(await cam.subscribed(to: "/transports/0/play"))

        // A bare boolean, as the camera sends it.
        cam.pushPropertyChanged("/transports/0/play", value: true)
        let state = await collectUntil(backend: backend) { $0.playback?.isPlaying == true }
        #expect(state?.playback?.isPlaying == true)
    }

    @Test("WS /transports/0 mode=InputPreview → isPlaying = false")
    func wsTransportModeInputPreviewStopsPlaying() async throws {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let _ = await collectUntil(backend: backend) { $0.connection == .connected }
        #expect(await cam.subscribed(to: "/transports/0"))
        #expect(await cam.subscribed(to: "/transports/0/play"))

        // Set playing first
        cam.pushPropertyChanged("/transports/0/play", value: true)
        let _ = await collectUntil(backend: backend) { $0.playback?.isPlaying == true }

        // Then push InputPreview
        cam.pushPropertyChanged("/transports/0", value: ["mode": "InputPreview"])
        let state = await collectUntil(backend: backend) { $0.playback?.isPlaying == false }
        #expect(state?.playback?.isPlaying == false)
    }

    @Test("WS /transports/0/clipIndex → clipNumber updated")
    func wsClipIndexUpdatesCameraState() async throws {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let _ = await collectUntil(backend: backend) { $0.connection == .connected }
        #expect(await cam.subscribed(to: "/transports/0/clipIndex"))

        cam.pushPropertyChanged("/transports/0/clipIndex", value: ["clipIndex": 2])
        let state = await collectUntil(backend: backend) { $0.playback?.clipNumber == 3 }
        #expect(state?.playback?.clipNumber == 3)
    }
}

@Suite("Blackmagic playback — commands", .serialized)
struct BlackmagicPlaybackCommandTests {

    private func connected() async throws -> (FakeBlackmagicCamera, BlackmagicCameraBackend, Task<Void, Never>) {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        _ = await collectUntil(backend: backend) { $0.connection == .connected }
        return (cam, backend, t)
    }

    @Test("play/pause/live/skip/next: correct REST call sent", .timeLimit(.minutes(1)),
          arguments: ["play", "pause", "live", "skip", "next"])
    func playbackCommandSendsREST(cmd: String) async throws {
        let (cam, backend, t) = try await connected()
        defer { cam.stop(); t.cancel() }

        switch cmd {
        case "play":
            await backend.send(.playback(.play))
            for _ in 0..<200 { if cam.playCommandsReceived > 0 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            #expect(cam.playCommandsReceived > 0)
        case "pause":
            await backend.send(.playback(.pause))
            for _ in 0..<200 { if cam.playbackStopCommandsReceived > 0 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            #expect(cam.playbackStopCommandsReceived > 0)
        case "live":
            await backend.send(.playback(.live))
            for _ in 0..<200 { if cam.lastTransportModePut != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            #expect(cam.lastTransportModePut == "InputPreview")
        case "skip":
            await backend.send(.playback(.skip(15)))
            for _ in 0..<200 { if cam.playbackPutCount > 0 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            #expect(cam.playbackPutCount > 0)
        case "next":
            await backend.send(.playback(.next))
            for _ in 0..<200 { if cam.playbackPutCount > 0 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            #expect(cam.playbackPutCount > 0)
        default:
            Issue.record("unknown command: \(cmd)")
        }
    }
}
