import CameraCore
import CoreGraphics
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers

/// Live view of a Blackmagic camera through its livestream: its API has no preview image, and the stream is the
/// one video it sends over the network (docs/pyxis-controls.md, Live view). Tiles adds a streaming platform pointing
/// at itself (`Tiles.xml`), picks it, starts the stream, and is the RTMP server it streams to; when live view is
/// over, the camera's own platform comes back and Tiles' goes.
///
/// Stopping: the camera refuses `PUT /livestreams/0/stop` for every stream ("stream is active to a different
/// destination", 403), wherever it goes, and refuses a platform change while one runs. A camera with Remote Control
/// turned on (Camera 10.3) lets a Remote Control session stop it, which nothing on the camera shows
/// (`BlackmagicRemoteControl.swift`). Without it, Review stops it: a camera in playback can't stream, so Tiles flips to
/// Review and back, which shows playback on the camera's outputs for a moment. Either way not during a take (Review
/// isn't allowed then): the stream stops when the take ends. The stream outlives live view, so a page change, a dropout
/// or the app in the background picks it up again (the receiver listens again, and the camera reconnects to it within
/// about 10 s): by `liveStreamLinger` when a stop shows, by 15 s when it doesn't.
typealias BlackmagicLiveStream = RTMPLiveStream

/// Blackmagic's side of the stream: Tiles' streaming platform, which points the camera at the receiver.
extension RTMPLiveStream {
    /// Tiles' streaming platform: one server, this device, and a profile per quality. The camera picks the config
    /// matching its stream's resolution and frame rate (a 24p camera uses the 30 fps one). Low latency (fewer frames
    /// buffered: after a dropout the picture comes back current, not seconds behind) and a key frame every second (a
    /// picture that soon after the camera reconnects).
    static func platformXML(url: String) -> String {
        func configs(_ rates: [(String, String, Int)]) -> String {
            rates.map {
                "<config resolution=\"\($0.0)\" fps=\"\($0.1)\" codec=\"H264\"><bitrate>\($0.2)</bitrate>"
                    + "<keyframe-interval>1</keyframe-interval></config>"
            }.joined()
        }
        func profile(_ quality: LiveViewQuality, _ configs: String) -> String {
            "<profile><name>\(Self.profile(quality))</name><low-latency>true</low-latency>\(configs)</profile>"
        }
        let low = configs([("1080p", "30", 1_500_000), ("1080p", "60", 2_000_000), ("720p", "30", 1_000_000), ("720p", "60", 1_500_000)])
        let high = configs([("1080p", "30", 4_000_000), ("1080p", "60", 6_000_000), ("720p", "30", 2_500_000), ("720p", "60", 3_500_000)])
        return "<streaming><service><name>\(platform)</name><servers><server><name>\(platform)</name><url>\(url)</url></server></servers>"
            + "<profiles>\(profile(.low, low))\(profile(.high, high))</profiles></service></streaming>"
    }

    static let platform = "Tiles"
    static let platformFile = "Tiles.xml"
    static let key = "tiles"
    static func profile(_ quality: LiveViewQuality) -> String { quality == .high ? "Tiles High" : "Tiles Low" }
}

/// The live view receiver on its own, for tools (`camctl rtmp-listen`): listens, decodes and counts what arrives.
public final class BlackmagicStreamListener: @unchecked Sendable {
    private let stream: BlackmagicLiveStream
    /// `trace` gets each step of each connection (the handshake, every command, the first video messages).
    public init(trace: (@Sendable (String) -> Void)? = nil) { stream = BlackmagicLiveStream(trace: trace) }
    public func start() async throws -> UInt16 { try await stream.listen() }
    public func nextFrame(timeout: Duration) async -> CGImage? { await stream.nextFrame(timeout: timeout) }
    public var frameCount: Int { stream.frameCount }
    public func stop() { stream.close() }
}

private struct ActivePlatformBody: Codable, Sendable {
    let platform: String
    let server: String
    let quality: String
    var key: String?
    var url: String?
    var passphrase: String?
}

/// `GET /livestreams/platforms/{name}`, only as far as where it streams to.
private struct PlatformServers: Decodable {
    struct Server: Decodable {
        let server: String
        let url: String?
    }
    let servers: [Server]
}

private struct TransportModeRequest: Encodable { let mode: String }

extension BlackmagicCameraBackend: LiveViewProvider {
    public var liveViewAvailable: Bool {
        state.connection == .connected && liveStreamAvailable != false
    }

    public var liveViewConfig: LiveViewConfig { .stream }

    /// Starts live view: Tiles' platform, picked, streaming to this device. A stream this device already has is picked
    /// up as it is (the receiver listens again; the camera reconnects to it). Never takes over a broadcast of the
    /// camera's own.
    public func startLiveView(quality: LiveViewQuality) async throws {
        guard state.connection == .connected else { throw LiveViewError.disconnected }
        // Wanted before waiting for a step under way: a finish that hasn't begun leaves the stream alone.
        liveStreamWanted = true
        liveStreamFinish?.cancel()
        liveStreamFinish = nil
        try await liveViewStep {
            guard liveStreamWanted, state.connection == .connected else { throw LiveViewError.disconnected }
            liveStreamBusy = true
            defer { liveStreamBusy = false }
            liveStreamStopPending = false
            try await startPlatformStream(quality: quality)
            // For the linger, once the stream's on its way: the camera takes longer than this to send a picture.
            if remoteControl == nil { remoteControl = await remoteControlOn() }
        }
    }

    private func startPlatformStream(quality: LiveViewQuality) async throws {
        guard let address = await liveStreamAddress() else { throw LiveViewError.unavailable }
        let receiver = liveStream ?? BlackmagicLiveStream()
        liveStream = receiver
        let port = try await receiver.listen()
        let url = "rtmp://\(address):\(port)/live"
        var step = "read the camera's streaming platform"
        do {
            let activeData = try await restClient.get("livestreams/0/activePlatform")
            let active = try? JSONDecoder().decode(ActivePlatformBody.self, from: activeData)
            let streaming = await liveStreamRunning()
            if active?.platform == BlackmagicLiveStream.platform {
                step = "read Tiles' streaming platform"
                if await liveStreamURL() == url, active?.quality == BlackmagicLiveStream.profile(quality) {
                    // This device's already: going (it reconnects), or stopped by playback or a stop that got this far.
                    if streaming {
                        markStreamStarted()
                    } else {
                        step = "start the stream"
                        try await startStream()
                    }
                    liveStreamQuality = quality
                    return
                }
                // Another quality, an old address of this device's, or another device's live view: stopped first.
                if streaming {
                    step = "stop the stream"
                    guard await stopCameraStream() else {
                        throw LiveViewError.streamRefused("the camera's stream can't be moved here during a take")
                    }
                }
            } else {
                if streaming {
                    throw LiveViewError.streamRefused("the camera is streaming to \(active?.platform ?? "its own platform")")
                }
                savedPlatform = activeData
            }
            step = "add Tiles' streaming platform"
            let xml = BlackmagicLiveStream.platformXML(url: url)
            try await restClient.putRaw("livestreams/customPlatforms/\(BlackmagicLiveStream.platformFile)", body: Data(xml.utf8),
                                        contentType: "application/xml")
            // The camera takes a moment to load a platform file: picked straight after, it's "Invalid server" (400).
            step = "load it"
            let deadline = ContinuousClock.now + .seconds(5)
            while await liveStreamURL() != url, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }
            step = "pick it"
            let body = ActivePlatformBody(platform: BlackmagicLiveStream.platform, server: BlackmagicLiveStream.platform,
                                          quality: BlackmagicLiveStream.profile(quality), key: BlackmagicLiveStream.key)
            try await retrying { try await self.restClient.put("livestreams/0/activePlatform", body: body) }
            step = "start the stream"
            try await startStream()
            liveStreamQuality = quality
        } catch let error as LiveViewError {
            throw error
        } catch {
            throw LiveViewError.streamRefused("\(step): \(error.localizedDescription)")
        }
    }

    /// Asks the camera to start the stream. The camera's TCP connection to this device normally opens
    /// 0.15–0.3 s after the PUT; sometimes it waits about 10.5 s before connecting regardless of how the last
    /// stream stopped (docs/pyxis-controls.md, Before connecting).
    private func startStream() async throws {
        try await retrying { try await self.restClient.put("livestreams/0/start", body: EmptyBody()) }
        markStreamStarted()
    }

    /// From now the camera should reach this device: a start just asked for, or a running stream picked up (the
    /// receiver listens again and the camera reconnects). `noteStalledStart` counts from here.
    private func markStreamStarted() {
        liveStreamStartedAt = .now
        liveStreamStallNoted = false
    }

    /// The next picture from the stream (`LiveViewSession` asks for one after another). None for a while, with the
    /// camera's stream idle: it's started again (`restartStreamIfStopped`); going but not reaching this device: said
    /// once in the Activity Log (`noteStalledStart`).
    public func liveViewPicture() async throws -> LiveViewFrame {
        guard liveStreamWanted, let receiver = liveStream else { throw LiveViewError.disconnected }
        if let image = await receiver.nextFrame(timeout: .seconds(3)) { return LiveViewFrame(image: image) }
        await restartStreamIfStopped()
        await noteStalledStart()
        throw LiveViewError.noData
    }

    /// After `stalledStartAfter` with no connection from the camera, one line in the Activity Log: what the camera
    /// says of its stream, and the platform it's on. Sometimes the camera waits about 10.5 s before it connects
    /// (docs/pyxis-controls.md, Before connecting); nothing is done about it here. A stream that went to the camera's
    /// own platform reads "Connecting" too (to YouTube, say, with no internet on set), so that's said apart.
    func noteStalledStart() async {
        guard liveStreamWanted, !liveStreamStallNoted, state.connection == .connected, let started = liveStreamStartedAt,
              ContinuousClock.now - started >= stalledStartAfter, liveStream?.published(since: started) == false
        else { return }
        // Both read fresh: a read that fails (a dropout, most likely) says nothing, and the next look tries again.
        guard let streamData = try? await restClient.get("livestreams/0"),
              let status = (try? JSONSerialization.jsonObject(with: streamData) as? [String: Any])?["status"] as? String,
              let platformData = try? await restClient.get("livestreams/0/activePlatform"),
              let platform = (try? JSONDecoder().decode(ActivePlatformBody.self, from: platformData))?.platform
        else { return }
        liveStreamStatus = status
        // Idle is `restartStreamIfStopped`'s, and a start since this one counts afresh: neither is said here.
        guard status != "Idle", liveStreamWanted, !liveStreamStallNoted, liveStreamStartedAt == started else { return }
        liveStreamStallNoted = true
        let waited = Self.seconds(.now - started)
        guard platform == BlackmagicLiveStream.platform else {
            ActivityLog.shared.note(host, "live view: the camera's stream is on \(platform), not Tiles', \(status) \(waited) s "
                + "after Tiles started it; left alone")
            return
        }
        ActivityLog.shared.note(host, "live view: the camera's stream has been \(status) for \(waited) s on Tiles' platform "
            + "without reaching this device")
    }

    /// Whole seconds, rounded, for the Activity Log.
    static func seconds(_ duration: Duration) -> Int {
        Int((Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18).rounded())
    }

    /// One picture as a JPEG, for tools (`camctl`).
    public func liveViewFrame() async throws -> Data {
        guard let image = try await liveViewPicture().image, let jpeg = BlackmagicLiveStream.jpeg(image) else {
            throw LiveViewError.noData
        }
        return jpeg
    }

    /// Live view is closed: the receiver stops now (after a dropout it stays, as the stream may come through), the
    /// camera's stream after the linger (`finishStream`), unless live view comes back first.
    public func stopLiveView() async {
        liveStreamWanted = false
        if state.connection == .connected { liveStream?.close() }
        scheduleStreamFinish(after: linger)
    }

    /// How long the camera's stream outlives live view: `liveStreamLinger`, or `remoteControlLinger` (15 s) on a camera
    /// that stops it without showing (Remote Control), long enough for a sheet opening or a page flipped away and back.
    private var linger: Duration { remoteControl == true ? min(liveStreamLinger, remoteControlLinger) : liveStreamLinger }

    /// Stops the camera's stream now, not after the linger: for tools, which exit straight after.
    public func endLiveViewStream() async {
        liveStreamWanted = false
        liveStream?.close()
        liveStreamFinish?.cancel()
        await finishStream()
    }

    /// How long the camera's stream outlives live view (tests shorten it).
    func setLiveStreamLinger(_ linger: Duration) { liveStreamLinger = linger }

    func scheduleStreamFinish(after delay: Duration) {
        liveStreamFinish?.cancel()
        liveStreamFinish = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.finishStream()
        }
    }

    /// Live view is over: stops the camera's stream and puts its streaming setup back. A take holds it until the take
    /// ends, a dropout until the next connection. Only a stream to this device is touched, and Tiles' platform only
    /// goes once the stream is idle: deleted while it streams, the camera carries on streaming to its default platform.
    func finishStream() async {
        liveStreamFinish = nil
        guard !liveStreamWanted else { return }
        await liveViewStep {
            guard !liveStreamWanted else { return }
            liveStreamBusy = true
            defer { liveStreamBusy = false }
            await finishPlatformStream()
        }
    }

    private func finishPlatformStream() async {
        liveStream?.close()
        guard state.connection == .connected else {
            liveStreamFinishOnConnect = true
            return
        }
        liveStreamFinishOnConnect = false
        if state.recording.state == .recording {
            ActivityLog.shared.note(host, "live view: stream stop held until the take ends")
            liveStreamStopPending = true
            return
        }
        liveStreamStopPending = false
        guard let activeData = try? await restClient.get("livestreams/0/activePlatform") else {
            scheduleStreamFinish(after: .seconds(30))
            return
        }
        if (try? JSONDecoder().decode(ActivePlatformBody.self, from: activeData))?.platform == BlackmagicLiveStream.platform {
            guard await liveStreamIsThisDevices() else {
                // Another device's live view now: it puts the camera back when it's done.
                savedPlatform = nil
                liveStreamQuality = nil
                return
            }
            guard await stopCameraStream() else {
                scheduleStreamFinish(after: .seconds(30))
                return
            }
            if let saved = savedPlatform, let body = try? JSONDecoder().decode(ActivePlatformBody.self, from: saved) {
                _ = try? await restClient.put("livestreams/0/activePlatform", body: body)
            }
        }
        _ = try? await restClient.delete("livestreams/customPlatforms/\(BlackmagicLiveStream.platformFile)")
        savedPlatform = nil
        liveStreamQuality = nil
        liveStreamStartedAt = nil
        ActivityLog.shared.note(host, "live view: stream \(liveStreamStatus ?? "?"), the camera's platform back")
    }

    /// After a connection: a finish a dropout held runs, and so does one for a stream an earlier run left going to this
    /// device; both after the linger, so live view coming back picks the stream up instead.
    func liveStreamConnected() async {
        // Asked again after each connection: Remote Control may have been switched on or off at the camera meanwhile.
        remoteControl = nil
        guard !liveStreamWanted else { return }
        if liveStreamFinishOnConnect || savedPlatform != nil || liveStreamQuality != nil {
            scheduleStreamFinish(after: linger)
            return
        }
        guard liveStreamPlatform == BlackmagicLiveStream.platform, await liveStreamIsThisDevices() else { return }
        ActivityLog.shared.note(host, "live view: a stream left going to this device; it stops unless live view opens")
        scheduleStreamFinish(after: linger)
    }

    /// A take ended: a stop held for it runs now.
    func recordingEnded() async {
        if liveStreamStopPending { await finishStream() }
    }

    /// Back in live from playback, or no pictures for a while: a stream the camera stopped (playback stops one, and so
    /// can a format change) starts again, if the camera is still on Tiles' platform. At most every 5 s.
    func restartStreamIfStopped() async {
        guard liveStreamWanted, !liveStreamBusy, state.connection == .connected, transportMode != "Output" else { return }
        await waitForStream(.seconds(3)) { $0 != "Disconnecting" }
        guard liveStreamStatus == "Idle", liveStreamWanted, !liveStreamBusy else { return }
        if let last = liveStreamRestartedAt, ContinuousClock.now - last < .seconds(5) { return }
        liveStreamRestartedAt = .now
        await liveViewStep {
            guard liveStreamWanted, state.connection == .connected, liveStreamStatus == "Idle" else { return }
            guard let data = try? await restClient.get("livestreams/0/activePlatform"),
                  (try? JSONDecoder().decode(ActivePlatformBody.self, from: data))?.platform == BlackmagicLiveStream.platform
            else { return }
            ActivityLog.shared.note(host, "live view: the camera's stream had stopped; starting it again")
            try? await startStream()
        }
    }

    /// Stops the camera's stream: through Remote Control if the camera has it (not during a take), else the documented
    /// stop (in case a later camera takes it), else Review and back (not during a take, when Review isn't allowed).
    /// True once the camera says it's idle.
    private func stopCameraStream() async -> Bool {
        guard await liveStreamRunning() else { return true }
        let recording = state.recording.state == .recording
        if !recording, await stopThroughRemoteControl() {
            // Stopped, with nothing shown on the camera.
        } else if (try? await restClient.put("livestreams/0/stop", body: EmptyBody())) == nil {
            guard !recording else { return false }
            if transportMode != "Output" {
                ActivityLog.shared.note(host, "live view: stopping the stream through Review")
                _ = try? await restClient.put("transports/0", body: TransportModeRequest(mode: "Output"))
                // Back to live as soon as the stream is ending: playback shows on the camera's outputs until then.
                await waitForStream(.seconds(10)) { $0 == "Idle" || $0 == "Disconnecting" }
                _ = try? await restClient.put("transports/0", body: TransportModeRequest(mode: "InputPreview"))
            }
        }
        await waitForStream(.seconds(5)) { $0 == "Idle" }
        return await !liveStreamRunning()
    }

    /// Until the stream's status (as pushed) passes `done`, or `limit`.
    private func waitForStream(_ limit: Duration, until done: (String?) -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(liveStreamStatus), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Whether the camera's stream is going (connecting, streaming, interrupted, disconnecting: anything but idle), as
    /// the camera says now. Unknown counts as going.
    private func liveStreamRunning() async -> Bool {
        if let data = try? await restClient.get("livestreams/0"),
           let status = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String {
            liveStreamStatus = status
        }
        return liveStreamStatus.map { $0 != "Idle" } ?? true
    }

    /// Where Tiles' platform on the camera streams to, as the camera has it.
    private func liveStreamURL() async -> String? {
        guard let data = try? await restClient.get("livestreams/platforms/\(BlackmagicLiveStream.platform)") else { return nil }
        return (try? JSONDecoder().decode(PlatformServers.self, from: data))?.servers.first?.url
    }

    /// Tiles' platform streams to this device (any port).
    private func liveStreamIsThisDevices() async -> Bool {
        guard let address = await liveStreamAddress(), let url = await liveStreamURL() else { return false }
        return url.hasPrefix("rtmp://\(address):")
    }

    /// Where the camera streams to: this device's address toward it, or a relay set for a test.
    func liveStreamAddress() async -> String? {
        if let liveViewStreamAddress { return liveViewStreamAddress }
        return await BlackmagicLiveStream.localAddress(toward: hostAddress)
    }

    /// A refusal right after a platform change can be the camera still settling: three tries, half a second apart.
    private func retrying(_ attempt: () async throws -> Data) async throws {
        for n in 1 ... 3 {
            do {
                _ = try await attempt()
                return
            } catch where n < 3 {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}
