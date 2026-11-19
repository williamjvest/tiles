@testable import BlackmagicRESTBackend
@testable import CameraCore
import Foundation
import Testing
import CameraKitTestSupport

/// Live view's stream on the camera, through the fake: started on Tiles' platform, picked up again within the linger,
/// stopped through Review after it (a camera without Remote Control; with it, `LiveViewRemoteStopTests.swift`), held for
/// a take, and never a broadcast of the camera's own. Serialized: each receiver wants port 1935.
@Suite(.serialized, .rtmpPort)
struct LiveViewLifecycleTests {
    func connected(_ configure: (inout FakeBlackmagicCamera.Config) -> Void = { _ in })
        async throws -> (FakeBlackmagicCamera, BlackmagicCameraBackend, Task<Void, Never>) {
        var config = FakeBlackmagicCamera.Config()
        config.livestream = true
        configure(&config)
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        let backend = makeBackendDirectly(cam: cam)
        await backend.setLiveViewStreamAddress("127.0.0.1")
        await backend.setLiveStreamLinger(.milliseconds(600))
        let t = Task.detached { await backend.connect() }
        _ = await collectUntil(backend: backend) { $0.connection == .connected && $0.hasLiveView }
        return (cam, backend, t)
    }

    /// Polls until `condition` holds, or `seconds` pass.
    func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test("Live view picks Tiles' platform and streams; after the linger, a stop through Review and the camera's own back",
          .timeLimit(.minutes(1)))
    func startAndFinish() async throws {
        let (cam, backend, t) = try await connected()
        defer { cam.stop(); t.cancel() }
        try await backend.startLiveView(quality: .low)
        #expect(cam.activePlatform["platform"] == "Tiles" && cam.activePlatform["quality"] == "Tiles Low")
        #expect(cam.streamStatus == "Streaming" && cam.streamStarts == 1)
        #expect(cam.customPlatformFiles == ["Tiles.xml"])

        await backend.stopLiveView()
        #expect(cam.streamStatus == "Streaming")
        #expect(await eventually { cam.customPlatformFiles.isEmpty })
        #expect(cam.transportModePuts == ["Output", "InputPreview"])
        #expect(cam.streamStatus == "Idle" && cam.activePlatform["platform"] == "YouTube RTMP")
        // Put back, not fallen back to: a custom platform of the camera's own would come back too.
        #expect(cam.platformPuts.last?["platform"] == "YouTube RTMP")
    }

    @Test("Live view back within the linger picks the stream up: no stop and no second start", .timeLimit(.minutes(1)))
    func pickUp() async throws {
        let (cam, backend, t) = try await connected()
        defer { cam.stop(); t.cancel() }
        try await backend.startLiveView(quality: .low)
        await backend.stopLiveView()
        try await backend.startLiveView(quality: .low)
        try await Task.sleep(for: .seconds(1.5))
        #expect(cam.streamStarts == 1 && cam.transportModePuts.isEmpty && cam.platformPuts.count == 1)
        #expect(cam.activePlatform["platform"] == "Tiles" && cam.customPlatformFiles == ["Tiles.xml"])

        await backend.endLiveViewStream()
        #expect(cam.activePlatform["platform"] == "YouTube RTMP" && cam.customPlatformFiles.isEmpty)
    }

    @Test("Playback stops the camera's stream; back in live, live view starts it again at once", .timeLimit(.minutes(1)))
    func restartAfterReview() async throws {
        let (cam, backend, t) = try await connected()
        defer { cam.stop(); t.cancel() }
        try await backend.startLiveView(quality: .low)
        cam.setTransportMode("Output")
        #expect(await eventually { cam.streamStatus == "Idle" })
        try await Task.sleep(for: .milliseconds(300))
        #expect(cam.streamStarts == 1)
        cam.setTransportMode("InputPreview")
        #expect(await eventually(1.5) { cam.streamStarts == 2 })
        await backend.endLiveViewStream()
    }

    @Test("A stream the camera stopped by itself starts again when no pictures come", .timeLimit(.minutes(1)))
    func restartWhenIdle() async throws {
        let (cam, backend, t) = try await connected()
        defer { cam.stop(); t.cancel() }
        try await backend.startLiveView(quality: .low)
        cam.setStreamStatus("Idle")
        // The fake sends no pictures: after the wait for one, live view finds the stream idle in live and starts it.
        _ = try? await backend.liveViewPicture()
        #expect(await eventually { cam.streamStarts == 2 })
        await backend.endLiveViewStream()
    }

    @Test("A broadcast of the camera's own is never taken over", .timeLimit(.minutes(1)))
    func ownBroadcastLeftAlone() async throws {
        let (cam, backend, t) = try await connected { $0.streamStatus = "Streaming" }
        defer { cam.stop(); t.cancel() }
        await #expect(throws: LiveViewError.self) { try await backend.startLiveView(quality: .low) }
        #expect(cam.activePlatform["platform"] == "YouTube RTMP" && cam.customPlatformFiles.isEmpty)
        #expect(cam.streamStarts == 0 && cam.transportModePuts.isEmpty)
    }

    @Test("A stop during a take waits for the take to end", .timeLimit(.minutes(1)))
    func heldForTake() async throws {
        let (cam, backend, t) = try await connected()
        defer { cam.stop(); t.cancel() }
        try await backend.startLiveView(quality: .low)
        cam.setRecording(true)
        _ = await collectUntil(backend: backend) { $0.recording.state == .recording }
        await backend.stopLiveView()
        try await Task.sleep(for: .seconds(1.2))
        #expect(cam.transportModePuts.isEmpty && cam.streamStatus == "Streaming")

        cam.setRecording(false)
        #expect(await eventually { cam.customPlatformFiles.isEmpty })
        #expect(cam.transportModePuts == ["Output", "InputPreview"] && cam.activePlatform["platform"] == "YouTube RTMP")
    }

    @Test("A stream an earlier run left going to this device stops after the linger; another device's stays",
          .timeLimit(.minutes(1)))
    func leftovers() async throws {
        func leftover(to host: String) -> (inout FakeBlackmagicCamera.Config) -> Void {
            { config in
                config.customPlatforms = ["Tiles.xml": BlackmagicLiveStream.platformXML(url: "rtmp://\(host):1935/live")]
                config.activePlatform = ["platform": "Tiles", "server": "Tiles", "quality": "Tiles Low", "key": "tiles"]
                config.streamStatus = "Streaming"
            }
        }
        let (mine, _, t) = try await connected(leftover(to: "127.0.0.1"))
        defer { mine.stop(); t.cancel() }
        #expect(await eventually { mine.customPlatformFiles.isEmpty })
        #expect(mine.streamStatus == "Idle" && mine.activePlatform["platform"] == "YouTube RTMP")

        let (theirs, _, t2) = try await connected(leftover(to: "10.9.9.9"))
        defer { theirs.stop(); t2.cancel() }
        try await Task.sleep(for: .seconds(1.5))
        #expect(theirs.customPlatformFiles == ["Tiles.xml"] && theirs.streamStatus == "Streaming")
        #expect(theirs.transportModePuts.isEmpty)
    }
}
