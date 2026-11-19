@testable import BlackmagicRESTBackend
@testable import CameraCore
import Foundation
import Testing

/// Live view on a camera with Remote Control, through the fake (which behaves as a PYXIS on Camera 10.3.1 did): the
/// stream still goes through Tiles' platform, and a session held just for it stops the stream, where the camera
/// without Remote Control has to flip to Review. Part of `LiveViewLifecycleTests`, so serialized with it: each receiver
/// wants port 1935.
extension LiveViewLifecycleTests {
    private func withRemoteControl(_ configure: (inout FakeBlackmagicCamera.Config) -> Void = { _ in })
        async throws -> (FakeBlackmagicCamera, BlackmagicCameraBackend, Task<Void, Never>) {
        try await connected { config in
            config.remoteAccess = true
            configure(&config)
        }
    }

    @Test("With Remote Control, the stop after the linger is a session's: no Review, and the camera's own platform back",
          .timeLimit(.minutes(1)))
    func remoteControlStop() async throws {
        let (cam, backend, t) = try await withRemoteControl()
        defer { cam.stop(); t.cancel() }
        try await backend.startLiveView(quality: .low)
        #expect(cam.activePlatform["platform"] == "Tiles" && cam.streamStatus == "Streaming")
        #expect(cam.accessRequests == 0)

        await backend.stopLiveView()
        #expect(await eventually { cam.customPlatformFiles.isEmpty })
        #expect(cam.streamStops == 1 && cam.transportModePuts.isEmpty && cam.streamStatus == "Idle")
        #expect(cam.accessRequests == 1 && cam.sessionDisconnects == 1 && !cam.sessionActive)
        #expect(cam.activePlatform["platform"] == "YouTube RTMP" && cam.platformPuts.last?["platform"] == "YouTube RTMP")
        #expect(cam.ownPlatformStreams == 0)
    }

    @Test("With Remote Control, moving the stream to another quality stops it through a session", .timeLimit(.minutes(1)))
    func remoteControlMove() async throws {
        let (cam, backend, t) = try await withRemoteControl()
        defer { cam.stop(); t.cancel() }
        try await backend.startLiveView(quality: .low)
        await backend.stopLiveView()
        try await backend.startLiveView(quality: .high)
        #expect(cam.streamStops == 1 && cam.transportModePuts.isEmpty && cam.streamStarts == 2)
        #expect(cam.activePlatform["quality"] == "Tiles High" && cam.streamStatus == "Streaming")
        await backend.endLiveViewStream()
        #expect(cam.activePlatform["platform"] == "YouTube RTMP" && cam.customPlatformFiles.isEmpty)
    }

    @Test("Another device holding the camera's remote control: the stop goes through Review, as without it",
          .timeLimit(.minutes(1)))
    func remoteControlHeldElsewhere() async throws {
        let (cam, backend, t) = try await withRemoteControl { $0.sessionHolder = "Director's iPhone" }
        defer { cam.stop(); t.cancel() }
        try await backend.startLiveView(quality: .low)
        await backend.stopLiveView()
        #expect(await eventually { cam.customPlatformFiles.isEmpty })
        #expect(cam.streamStops == 0 && cam.transportModePuts == ["Output", "InputPreview"])
        #expect(cam.streamStatus == "Idle" && cam.activePlatform["platform"] == "YouTube RTMP")
    }

    @Test("With Remote Control, a stop during a take still waits for the take to end", .timeLimit(.minutes(1)))
    func remoteControlHeldForTake() async throws {
        let (cam, backend, t) = try await withRemoteControl()
        defer { cam.stop(); t.cancel() }
        try await backend.startLiveView(quality: .low)
        cam.setRecording(true)
        _ = await collectUntil(backend: backend) { $0.recording.state == .recording }
        await backend.stopLiveView()
        try await Task.sleep(for: .seconds(1.2))
        #expect(cam.streamStops == 0 && cam.accessRequests == 0 && cam.streamStatus == "Streaming")

        cam.setRecording(false)
        #expect(await eventually { cam.customPlatformFiles.isEmpty })
        #expect(cam.streamStops == 1 && cam.transportModePuts.isEmpty && cam.activePlatform["platform"] == "YouTube RTMP")
    }

    @Test("With Remote Control, another device's live view is still left alone: no session asked for",
          .timeLimit(.minutes(1)))
    func remoteControlLeavesOthersAlone() async throws {
        let (theirs, _, t) = try await withRemoteControl { config in
            config.customPlatforms = ["Tiles.xml": BlackmagicLiveStream.platformXML(url: "rtmp://10.9.9.9:1935/live")]
            config.activePlatform = ["platform": "Tiles", "server": "Tiles", "quality": "Tiles Low", "key": "tiles"]
            config.streamStatus = "Streaming"
        }
        defer { theirs.stop(); t.cancel() }
        try await Task.sleep(for: .seconds(1.5))
        #expect(theirs.customPlatformFiles == ["Tiles.xml"] && theirs.streamStatus == "Streaming")
        #expect(theirs.accessRequests == 0 && theirs.streamStops == 0 && theirs.transportModePuts.isEmpty)
    }
}
