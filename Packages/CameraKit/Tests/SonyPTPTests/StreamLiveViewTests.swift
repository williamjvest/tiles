// Live view through the camera's own stream (an FX5: no Live View Status over Camera Remote, but RTMP streaming with
// its destination and Start / Stop over the session). The FX5 has no Live View Status; the FX3 does.

import Testing
import Foundation
import Network
@testable import SonyPTP
import CameraCore
import CameraKitTestSupport

@Suite("Live view through the camera's stream", .serialized, .rtmpPort)
struct StreamLiveViewTests {
    @Test("What stops an FX5 streaming is said before anything is set (Sony's FX5 guide)")
    func streamBlockers() {
        var s = CameraState()
        s.frameRate = FrameRateState(project: Choice("23.98", options: ["23.98"]))
        s.fileFormat = Choice("XAVC S-I 422", options: ["XAVC S-I 422"])
        s.resolution = Choice("3840x2160", options: ["3840x2160"])
        #expect(SonyCameraBackend.streamBlocker(s) == nil)
        var t = s; t.frameRate?.variable = Choice(true, options: [false, true])
        #expect(SonyCameraBackend.streamBlocker(t)?.contains("S&Q") == true)
        t = s; t.fileFormat = Choice("X-OCN LT", options: ["X-OCN LT"])
        #expect(SonyCameraBackend.streamBlocker(t)?.contains("X-OCN") == true)
        t = s; t.frameRate = FrameRateState(project: Choice("119.88", options: ["119.88"]))
        #expect(SonyCameraBackend.streamBlocker(t)?.contains("119.88") == true)
        t = s; t.resolution = Choice("4096x2160", options: ["4096x2160"])
        #expect(SonyCameraBackend.streamBlocker(t)?.contains("4096") == true)
        #expect(SonyCameraBackend.streamBlocker(CameraState()) == nil, "nothing read, nothing claimed")
    }

    @Test("The stream settings dataset reads as the reference lays it out, and goes back unchanged")
    func streamSettingListRoundTrip() throws {
        let list = StreamSettingList(version: 100, streams: [
            .init(protocolBits: 0x01, permission: 0x01, url: "rtmps://a.rtmp.youtube.com/live2", key: "abcd-efgh"),
            .init(protocolBits: 0x01, permission: 0x01, url: "", key: nil),
            .init(protocolBits: 0x02, permission: 0x02, url: "srt://10.0.0.5", port: 7001, latency: 120, ttl: 64,
                  cipherType: 0x02, cipherKey: "passphrase-16chars", mode: 0x02),
        ])
        let get = list.encoded(permissions: true)
        #expect(get.readLE(UInt32.self, at: 0) == 8, "the list right after the offset and size")
        #expect(Int(get.readLE(UInt32.self, at: 4)) == get.count - 8)
        #expect(try StreamSettingList.parse(get) == list)
        var set = list
        for i in set.streams.indices { set.streams[i].permission = nil }
        #expect(try StreamSettingList.parse(list.encoded(), permissions: false) == set)
        // A URL's length counts its null: "rtmp://h/live" is 13 characters, 14 sent.
        let one = StreamSettingList(version: 100, streams: [.init(protocolBits: 0x01, url: "rtmp://h/live", key: "k")]).encoded()
        #expect(one.readLE(UInt16.self, at: 8 + 2 + 2 + 4 + 1) == 14)
    }

    @Test("Offered on an FX5 by its 11/14 list; an FX3 has its own live view, an FX6 and a BURANO neither")
    func offered() throws {
        let fx5 = try FX5MappingTests.state(FX5MappingTests.asFound)
        #expect(fx5.hasLiveView)
        #expect(StateMapper.streamsLiveView(props: Dictionary(uniqueKeysWithValues: try FX5MappingTests.props(FX5MappingTests.asFound)
            .map { ($0.code, $0) }), controls: FX5MappingTests.controls))
        let withoutButton = Dictionary(uniqueKeysWithValues: try FX5MappingTests.props(FX5MappingTests.asFound).map { ($0.code, $0) })
        #expect(!StateMapper.streamsLiveView(props: withoutButton, controls: [0xD2C8]), "no Stream button, no stream")
        for fixture in ["fx6-propinfo-paused-2026-10-29", "burano-propinfo-2026-10-27"] {
            let props = Dictionary(uniqueKeysWithValues: try FX6MappingTests.props(fixture).map { ($0.code, $0) })
            #expect(!StateMapper.streamsLiveView(props: props, controls: FX5MappingTests.controls), "\(fixture)")
        }
    }

    private func connectedFX5(streamLive: Bool = true, _ adjust: (inout FakePTPIPCamera.Config) -> Void = { _ in })
        async throws -> (FakePTPIPCamera, SonyCameraBackend, Task<Void, Never>) {
        var config = FakePTPIPCamera.Config()
        config.model = "ILME-FX5"
        config.streaming = true
        config.controlCodes = [SDIControlCode.movieRecButtonHold.rawValue, SDIControlCode.streamButton.rawValue]
        config.omitPropCodes = [SDIPropCode.liveViewStatus.rawValue, SDIPropCode.liveViewImageQuality.rawValue]  // as an FX5
        adjust(&config)
        let cam = FakePTPIPCamera(config: config)
        try await cam.start()
        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        cfg.pollInterval = 60
        cfg.streamLiveView = streamLive
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let t = Task.detached { await backend.connect() }
        _ = await collectUntil(backend: backend) { $0.connection == .connected && $0.hasReported && $0.model != nil }
        return (cam, backend, t)
    }

    @Test("Off in the app for now: an FX5 with the backend's own config offers no live view", .timeLimit(.minutes(1)))
    func offInTheApp() async throws {
        #expect(SonyBackendConfig().streamLiveView == false)
        let (cam, backend, t) = try await connectedFX5(streamLive: false)
        defer { cam.stop(); t.cancel() }
        #expect(await !backend.state.hasLiveView)
        #expect(await !backend.liveViewConfig.isStream)
        #expect(cam.streamSets.isEmpty)
    }

    /// Its RTMP 3 set to this device, named Tiles, 720p at its lowest rate, picked, streamed; pictures come; stopping
    /// gives back what it had picked.
    @Test("An FX5's live view through its stream", .timeLimit(.minutes(1)))
    func liveViewThroughTheStream() async throws {
        let (cam, backend, t) = try await connectedFX5()
        defer { cam.stop(); t.cancel() }
        #expect(await backend.state.hasLiveView)
        #expect(await backend.liveViewAvailable)
        #expect(await backend.liveViewConfig.isStream)

        try await backend.startLiveView(quality: .low)
        let set = try #require(cam.streamSets.first)
        #expect(set.slot == 3)
        let destination = try #require(set.list.streams.first)
        #expect(destination.url.hasPrefix("rtmp://127.0.0.1:") && destination.url.hasSuffix("/live"))
        #expect(destination.key == "tiles" && destination.isRTMP)
        let writes = cam.propWrites.map(\.code)
        #expect(writes.contains(SDIPropCode.streamDisplayName.rawValue))
        #expect(cam.propWrites.last { $0.code == SDIPropCode.videoStreamSelect.rawValue }?.data == Data([3]))
        #expect(cam.propWrites.last { $0.code == SDIPropCode.videoStreamResolution.rawValue }?.data.readLE(UInt32.self, at: 0)
                == 0x0500_02D0, "720p")
        #expect(cam.propWrites.last { $0.code == SDIPropCode.videoStreamMaxBitRate.rawValue }?.data.readLE(UInt64.self, at: 0)
                == 1500, "the lowest at 720p")
        #expect(cam.propWrites.last { $0.code == SDIPropCode.targetStreamingDestinationSelect.rawValue }?.data
                .readLE(UInt16.self, at: 0) == 3)
        #expect(cam.controls.last { $0.code == SDIControlCode.streamButton.rawValue }?.data == Data([0x02, 0x00]), "started")

        var picture: LiveViewFrame?
        for _ in 0 ..< 5 where picture == nil { picture = try? await backend.liveViewPicture() }
        #expect(picture?.image != nil, "a picture decoded from what the camera streams")

        await backend.stopLiveView()
        #expect(cam.controls.last { $0.code == SDIControlCode.streamButton.rawValue }?.data == Data([0x01, 0x00]), "stopped")
        #expect(cam.propWrites.last { $0.code == SDIPropCode.targetStreamingDestinationSelect.rawValue }?.data
                .readLE(UInt16.self, at: 0) == 1, "its own destination picked again")
        #expect(cam.propWrites.last { $0.code == SDIPropCode.videoStreamSelect.rawValue }?.data == Data([1]))
        #expect(cam.streamStatus == 0x02)
    }

    @Test("Streaming off on the camera: live view says where to turn it on, and sets nothing", .timeLimit(.minutes(1)))
    func streamingOff() async throws {
        let (cam, backend, t) = try await connectedFX5 { $0.streamSettingOn = false }
        defer { cam.stop(); t.cancel() }
        await #expect {
            try await backend.startLiveView(quality: .low)
        } throws: { error in
            (error as? LiveViewError)?.errorDescription?.contains("MENU → Network → Stream → Setting → On") == true
        }
        #expect(cam.streamSets.isEmpty && !cam.controls.contains { $0.code == SDIControlCode.streamButton.rawValue })
    }

    // Edge cases in the stream setup and teardown.

    @Test("A stop while live view is still setting the stream up: it ends there, and the camera isn't left streaming",
          .timeLimit(.minutes(1)))
    func stopDuringStart() async throws {
        let (cam, backend, t) = try await connectedFX5 { $0.streamSetDelay = 0.5 }
        defer { cam.stop(); t.cancel() }
        let start = Task { try await backend.startLiveView(quality: .low) }
        for _ in 0 ..< 200 where cam.streamSets.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        await backend.stopLiveView()
        #expect(await (try? start.value) == nil, "the start gave up")
        #expect(!cam.controls.contains { $0.code == SDIControlCode.streamButton.rawValue && $0.data == Data([0x02, 0x00]) })
        #expect(cam.propWrites.last { $0.code == SDIPropCode.targetStreamingDestinationSelect.rawValue }?.data
                .readLE(UInt16.self, at: 0) ?? 1 == 1, "the camera's own destination still picked")
    }

    @Test("A stream an app that went away left running to Tiles: stopped and set to this receiver; anyone else's is left",
          .timeLimit(.minutes(1)))
    func streamLeftRunning() async throws {
        let (cam, backend, t) = try await connectedFX5 { $0.streamingTo = (3, "rtmp://127.0.0.1:1/live", "tiles") }
        defer { cam.stop(); t.cancel() }
        try await backend.startLiveView(quality: .low)
        let presses = cam.controls.filter { $0.code == SDIControlCode.streamButton.rawValue }.map(\.data)
        #expect(presses == [Data([0x01, 0x00]), Data([0x02, 0x00])], "stopped, then started to here")
        #expect(cam.streamList.streams[2].url != "rtmp://127.0.0.1:1/live")
        await backend.stopLiveView()

        let (other, otherBackend, t2) = try await connectedFX5 { $0.streamingTo = (1, "rtmps://a.rtmp.youtube.com/live2", "abcd") }
        defer { other.stop(); t2.cancel() }
        await #expect(throws: LiveViewError.self) { try await otherBackend.startLiveView(quality: .low) }
        #expect(!other.controls.contains { $0.code == SDIControlCode.streamButton.rawValue } && other.streamSets.isEmpty)
    }

    @Test("A camera that wants the whole list of destinations gets it", .timeLimit(.minutes(1)))
    func wholeList() async throws {
        let (cam, backend, t) = try await connectedFX5 { $0.wantsWholeStreamList = true }
        defer { cam.stop(); t.cancel() }
        try await backend.startLiveView(quality: .low)
        #expect(cam.streamSets.map(\.list.streams.count) == [1, 6])
        #expect(cam.streamList.streams[2].key == "tiles" && cam.streamList.streams[0].url.isEmpty)
        await backend.stopLiveView()
    }

    @Test("A restore the camera didn't take is tried again on the next stop", .timeLimit(.minutes(1)))
    func restoreRetried() async throws {
        let (cam, backend, t) = try await connectedFX5 { $0.failedUps[SDIPropCode.targetStreamingDestinationSelect.rawValue] = 1 }
        defer { cam.stop(); t.cancel() }
        try await backend.startLiveView(quality: .low)
        await backend.stopLiveView()
        await backend.stopLiveView()
        let backToOne = cam.propWrites.filter {
            $0.code == SDIPropCode.targetStreamingDestinationSelect.rawValue && $0.data.readLE(UInt16.self, at: 0) == 1
        }
        #expect(backToOne.count == 2, "turned down once, then taken")
    }
}
