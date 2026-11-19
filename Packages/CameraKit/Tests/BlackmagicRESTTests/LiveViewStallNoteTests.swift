@testable import BlackmagicRESTBackend
import CameraCore
import Foundation
import Testing

/// A start that never reaches this device gets one line in the Activity Log, and a start that reaches it gets none.
/// Part of `LiveViewLifecycleTests`, so serialized with it: each receiver wants port 1935.
extension LiveViewLifecycleTests {
    /// This camera's live view lines in the Activity Log that contain `text`.
    private func logLines(_ cam: FakeBlackmagicCamera, containing text: String) -> [String] {
        ActivityLog.shared.text.split(separator: "\n").map(String.init)
            .filter { $0.contains("127.0.0.1:\(cam.port): live view:") && $0.contains(text) }
    }

    @Test("A start that never reaches this device gets one line, with the camera's status and Tiles' platform",
          .timeLimit(.minutes(1)))
    func stalledStartNotedOnce() async throws {
        let (cam, backend, t) = try await connected()
        defer { cam.stop(); t.cancel() }
        await backend.setStalledStartAfter(.milliseconds(500))
        let before = logLines(cam, containing: "without reaching this device").count
        try await backend.startLiveView(quality: .low)
        // The fake streams nothing: each ask waits 3 s for a picture, then checks.
        _ = try? await backend.liveViewPicture()
        _ = try? await backend.liveViewPicture()
        let lines = logLines(cam, containing: "without reaching this device").dropFirst(before)
        #expect(lines.count == 1)
        #expect(lines.first?.contains("has been Streaming for") == true && lines.first?.contains("on Tiles' platform") == true)
        #expect(cam.streamStarts == 1 && cam.streamStops == 0 && cam.transportModePuts.isEmpty)
        await backend.endLiveViewStream()
    }

    @Test("A stream the camera moved to another platform is said apart, and left alone", .timeLimit(.minutes(1)))
    func streamOnAnotherPlatformNoted() async throws {
        let (cam, backend, t) = try await connected()
        defer { cam.stop(); t.cancel() }
        await backend.setStalledStartAfter(.milliseconds(500))
        let before = (logLines(cam, containing: "not Tiles'").count, logLines(cam, containing: "without reaching this device").count)
        try await backend.startLiveView(quality: .low)
        cam.setActivePlatform(["platform": "YouTube RTMP", "server": "Primary", "quality": "Streaming High"])
        cam.setStreamStatus("Connecting")
        _ = try? await backend.liveViewPicture()
        let lines = logLines(cam, containing: "not Tiles'").dropFirst(before.0)
        #expect(lines.count == 1 && lines.first?.contains("on YouTube RTMP") == true && lines.first?.contains("Connecting") == true)
        #expect(logLines(cam, containing: "without reaching this device").count == before.1)
        #expect(cam.streamStops == 0 && cam.transportModePuts.isEmpty && cam.streamStarts == 1)
    }

    @Test("No line once the camera has connected and is publishing", .timeLimit(.minutes(1)))
    func publishingStartNotNoted() async throws {
        let (cam, backend, t) = try await connected()
        defer { cam.stop(); t.cancel() }
        await backend.setStalledStartAfter(.milliseconds(500))
        let before = logLines(cam, containing: "without reaching this device").count
        try await backend.startLiveView(quality: .low)
        let xml = try #require(cam.customPlatform("Tiles.xml"))
        let url = try #require(xml.components(separatedBy: "<url>").dropFirst().first?.components(separatedBy: "</url>").first)
        let port = try #require(URLComponents(string: url)?.port.flatMap { UInt16(exactly: $0) })
        let publisher = try await Publisher(port: port)
        defer { publisher.close() }
        try await publisher.handshake()
        try await publisher.publish(app: "live", stream: "tiles")
        try await Task.sleep(for: .milliseconds(300))
        _ = try? await backend.liveViewPicture()
        #expect(logLines(cam, containing: "without reaching this device").count == before)
        await backend.endLiveViewStream()
    }
}
