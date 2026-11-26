import CameraCore
import CoreGraphics
import Foundation

/// Live view through the camera's own stream, for a camera with no live view over Camera Remote that can stream: an
/// FX5 lists no Live View Status (0xD221), but streams RTMP and takes its stream destination and Start / Stop over
/// the same session (SDIO_SetStreamSettingList 0x9242; the Stream button 0xD307). Tiles
/// sets one RTMP destination to itself, named "Tiles", picks it, starts the stream and is the server it streams to, as
/// for a Blackmagic camera (`RTMPLiveStream`); when live view ends the stream stops and the camera's own destination
/// comes back. The camera's streaming has to be on (MENU → Network → Stream → Setting: Stream Status reads Inactive
/// while it's off). docs/fx5-controls.md, Live view.
extension SonyCameraBackend {
    /// Whether live view comes through the camera's stream: no Live View Status, stream settings it lets a session set,
    /// the Stream button, H.264. Over the network only: the stream goes to this device's address there.
    var streamsLiveView: Bool {
        config.streamLiveView && !isUSB
            && StateMapper.streamsLiveView(props: rawProps, controls: sessionInfo?.extDeviceInfo.controlCodes ?? [])
    }

    /// Tiles' destination's name in the camera's menu.
    static let streamDestinationName = "Tiles"
    /// The RTMP destinations, last first: Tiles takes the first that's empty or already its own.
    static let rtmpSlots: [UInt32] = [3, 2, 1]

    func startStreamLiveView(quality: LiveViewQuality) async throws {
        guard state.connection == .connected, transport != nil else { throw LiveViewError.disconnected }
        // A stop while this runs ends it: nothing it would set after that point is left set.
        liveStreamGeneration += 1
        let generation = liveStreamGeneration
        func stillWanted() throws { if generation != liveStreamGeneration { throw LiveViewError.disconnected } }
        _ = await readNow()
        switch rawProps[SDIPropCode.streamStatus.rawValue]?.currentUInt8() {
        case 0x01:
            throw LiveViewError.streamRefused("streaming is off on the camera: MENU → Network → Stream → Setting → On")
        default: break
        }
        if let blocker = Self.streamBlocker(state) { throw LiveViewError.streamRefused(blocker) }
        guard let address = await RTMPLiveStream.localAddress(toward: host) else { throw LiveViewError.unavailable }
        let stream = liveStream ?? RTMPLiveStream()
        liveStream = stream
        let port = try await stream.listen()
        let url = "rtmp://\(address):\(port)/live"
        func isTiles(_ s: StreamSettingList.StreamSetting) -> Bool { s.key == Self.streamKey && s.url.hasSuffix("/live") }

        var step = "read its stream destinations"
        do {
            var list = try await streamSettings()
            if rawProps[SDIPropCode.streamStatus.rawValue]?.currentUInt8() == 0x03 {
                // Streaming already. To this device's receiver as it is now: picked up (the receiver listens again and the
                // camera reconnects). To Tiles' destination with another address or port (an app that went away
                // mid-stream): stopped, and set again below. Anything else is a broadcast of the camera's own: left alone.
                let target = rawProps[SDIPropCode.targetStreamingDestinationSelect.rawValue]?.currentUInt16().map(Int.init)
                guard let target, list.streams.indices.contains(target - 1), isTiles(list.streams[target - 1]) else {
                    throw LiveViewError.streamRefused("the camera is streaming to its own destination")
                }
                if list.streams[target - 1].url == url {
                    liveStreamStartedAt = .now
                    return
                }
                step = "stop the stream an earlier session left"
                try await pressStreamButton(start: false)
            }
            step = "pick a stream destination"
            guard let slot = Self.rtmpSlots.first(where: { slot in
                list.streams.indices.contains(Int(slot) - 1) && list.streams[Int(slot) - 1].isRTMP
                    && (list.streams[Int(slot) - 1].url.isEmpty || isTiles(list.streams[Int(slot) - 1]))
            }) else {
                throw LiveViewError.streamRefused("its three RTMP destinations are in use: clear one on the camera (MENU → "
                    + "Network → Stream → RTMP/RTMPS 3)")
            }
            // What the camera had picked, given back when live view ends.
            if liveStreamRestore == nil {
                liveStreamRestore = (target: rawProps[SDIPropCode.targetStreamingDestinationSelect.rawValue]?.currentUInt16(),
                                     select: rawProps[SDIPropCode.videoStreamSelect.rawValue]?.currentUInt8())
            }
            try stillWanted()
            step = "set its stream destination to this device"
            list.streams[Int(slot) - 1].url = url
            list.streams[Int(slot) - 1].key = Self.streamKey
            try await setStreamSetting(slot: slot, list: list)
            // The per-stream settings below are the selected destination's.
            try stillWanted()
            step = "select it"
            try await setStreamProp(.videoStreamSelect, Data([UInt8(slot)]))
            if let name = encodePTPString(Self.streamDestinationName) {
                try? await setStreamProp(.streamDisplayName, name)  // a nicety: "Tiles" in its menu
            }
            try stillWanted()
            step = "set its resolution"
            var resolution = Data()
            resolution.appendLE(quality == .high ? UInt32(1920) << 16 | 1080 : UInt32(1280) << 16 | 720)
            try await setStreamProp(.videoStreamResolution, resolution)
            await setStreamBitRate(quality)
            try stillWanted()
            step = "pick it to stream to"
            var target = Data()
            target.appendLE(UInt16(slot))
            try await setStreamProp(.targetStreamingDestinationSelect, target)
            try stillWanted()
            step = "start the stream"
            try await pressStreamButton(start: true)
            liveStreamStartedAt = .now
            ActivityLog.shared.note(host, "live view: streaming to \(url) (\(quality))")
        } catch let error as LiveViewError {
            throw error
        } catch {
            throw LiveViewError.streamRefused("\(step): \(error)")
        }
    }

    /// The bit rate: the lowest the camera allows at Low, 4 Mbps at High. Its range follows the resolution and the project
    /// rate (1.5–9 Mbps at 720p 23.98, 2.3–13.5 at 720p 59.94; 3–18 and 4.5–27 at 1080p: Sony's help guide), so the
    /// lowest is the larger of that table's and the range a full read now gives. A rate it turns down is left to the
    /// camera: the stream still runs, at its own rate.
    func setStreamBitRate(_ quality: LiveViewQuality) async {
        _ = await readAllNow()
        let fast = (state.frameRate?.project.value).flatMap(Double.init).map { $0 > 30 } ?? false
        let table: UInt64 = quality == .high ? (fast ? 4500 : 3000) : (fast ? 2300 : 1500)
        var low = table, high: UInt64 = .max
        if let rate = rawProps[SDIPropCode.videoStreamMaxBitRate.rawValue], rate.rangeMin.count >= 8, rate.rangeMax.count >= 8 {
            low = max(table, rate.rangeMin.readLE(UInt64.self, at: 0))
            high = rate.rangeMax.readLE(UInt64.self, at: 0)
        }
        var data = Data()
        data.appendLE(quality == .high ? min(max(4000, low), high) : low)
        do {
            try await setStreamProp(.videoStreamMaxBitRate, data)
        } catch {
            ActivityLog.shared.note(host, "live view: the camera kept its own stream bit rate (\(error))")
        }
    }

    /// The next picture from the stream; none within 3 s says why, once.
    func streamLiveViewPicture() async throws -> LiveViewFrame {
        guard let stream = liveStream, liveStreamStartedAt != nil else { throw LiveViewError.disconnected }
        if let image = await stream.nextFrame(timeout: .seconds(3)) {
            liveViewFrames += 1
            if liveViewFrames == 1 { ActivityLog.shared.note(host, "live view: first picture from the stream") }
            return LiveViewFrame(image: image)
        }
        _ = await readNow()
        if rawProps[SDIPropCode.streamStatus.rawValue]?.currentUInt8() == 0x04 {
            throw LiveViewError.streamRefused("the camera's stream couldn't reach this device")
        }
        throw LiveViewError.noData
    }

    /// Stops the camera's stream and gives back the destination it had picked. Best effort: the session may be going, so
    /// what didn't land is tried again on the next stop (a sheet closed, then the session torn down).
    func stopStreamLiveView() async {
        liveStreamGeneration += 1
        liveStream?.close()
        guard liveStreamStartedAt != nil || liveStreamRestore != nil else { return }
        liveStreamStartedAt = nil
        var landed = (try? await pressStreamButton(start: false)) != nil
        if let restore = liveStreamRestore {
            if let target = restore.target {
                var data = Data()
                data.appendLE(target)
                landed = (try? await setStreamProp(.targetStreamingDestinationSelect, data)) != nil && landed
            }
            if let select = restore.select {
                landed = (try? await setStreamProp(.videoStreamSelect, Data([select]))) != nil && landed
            }
        }
        if landed { liveStreamRestore = nil }
        ActivityLog.shared.note(host, "live view: stream stopped after \(liveViewFrames) pictures"
            + (landed ? "" : "; the camera didn't take all of it, tried again on the next stop"))
    }

    static let streamKey = "tiles"

    /// What stops an FX5 streaming, in what the camera reports (Sony's FX5 help guide, Streaming: not with S&Q on, X-OCN,
    /// a 119.88 or 100 project rate, or 4096×2160; Simul Rec and Interval Rec too, which aren't read). Said before
    /// anything is set, rather than a stream that never comes. nil: nothing known in the way.
    static func streamBlocker(_ state: CameraState) -> String? {
        if state.frameRate?.variable?.value == true { return "the camera can't stream with S&Q on: turn S&Q off" }
        if let codec = state.fileFormat?.value, codec.uppercased().contains("X-OCN") {
            return "the camera can't stream while recording X-OCN: pick an XAVC codec"
        }
        if let project = (state.frameRate?.project.value).flatMap(Double.init), project > 99 {
            return "the camera can't stream at a \(state.frameRate?.project.value ?? "") project rate"
        }
        if state.resolution?.value.hasPrefix("4096") == true {
            return "the camera can't stream in 4096×2160: pick 3840×2160 or smaller"
        }
        return nil
    }

    // MARK: - The session's side

    /// SDIO_GetStreamSettingList, once the camera allows it.
    func streamSettings() async throws -> StreamSettingList {
        guard let transport else { throw LiveViewError.disconnected }
        let (resp, data) = try await transport.execute(opCode: SDIOOpCode.getStreamSettingList.rawValue, params: [])
        guard resp.responseCode == PTPResponseCode.ok.rawValue else { throw StreamSettingError.refused(resp.responseCode) }
        return try StreamSettingList.parse(data)
    }

    /// SDIO_SetStreamSettingList for one destination: the list of just that one, and failing that the whole list (the
    /// reference doesn't say which the camera wants). Its result parameter: 0 OK, 2 a URL it won't take, 3 a port.
    func setStreamSetting(slot: UInt32, list: StreamSettingList) async throws {
        guard let transport else { throw LiveViewError.disconnected }
        var failure: StreamSettingError = .result(1)
        for sent in [StreamSettingList(version: list.version, streams: [list.streams[Int(slot) - 1]]), list] {
            let (resp, _) = try await transport.execute(opCode: SDIOOpCode.setStreamSettingList.rawValue, params: [slot],
                                                        sendData: sent.encoded())
            guard resp.responseCode == PTPResponseCode.ok.rawValue else { failure = .refused(resp.responseCode); continue }
            let result = resp.params.first ?? 0
            if result == 0 { return }
            failure = .result(result)
        }
        throw failure
    }

    func setStreamProp(_ code: SDIPropCode, _ data: Data) async throws {
        guard let transport else { throw LiveViewError.disconnected }
        let (resp, _) = try await transport.execute(opCode: SDIOOpCode.setExtDevicePropValue.rawValue,
                                                    params: [UInt32(code.rawValue), sdioExtendedCodesFlag], sendData: data)
        guard resp.responseCode == PTPResponseCode.ok.rawValue else { throw StreamSettingError.refused(resp.responseCode) }
    }

    /// The Stream button: Down starts streaming, Up stops it (absolute, as REC's hold button).
    func pressStreamButton(start: Bool) async throws {
        guard let transport else { throw LiveViewError.disconnected }
        var data = Data()
        data.appendLE(start ? ButtonValue.down.rawValue : ButtonValue.up.rawValue)
        let (resp, _) = try await transport.execute(opCode: SDIOOpCode.controlDevice.rawValue,
                                                    params: [UInt32(SDIControlCode.streamButton.rawValue), sdioExtendedCodesFlag],
                                                    sendData: data)
        guard resp.responseCode == PTPResponseCode.ok.rawValue else { throw StreamSettingError.refused(resp.responseCode) }
    }
}

enum StreamSettingError: Error, CustomStringConvertible {
    case refused(UInt16)
    case result(UInt32)

    var description: String {
        switch self {
        case .refused(let code): String(format: "the camera answered 0x%04X", code)
        case .result(2): "the camera won't take that address"
        case .result(let code): "the camera turned it down (\(code))"
        }
    }
}

extension StateMapper {
    /// A camera whose live view comes through its stream (`SonyCameraBackend.streamsLiveView`): no Live View Status,
    /// stream settings a session may set, the Stream button, H.264.
    static func streamsLiveView(props: [UInt16: SDIDevicePropInfo], controls: [UInt16]) -> Bool {
        props[SDIPropCode.liveViewStatus.rawValue] == nil
            && props[SDIPropCode.streamSettingListOperationEnableStatus.rawValue]?.currentUInt8() == 0x01
            && controls.contains(SDIControlCode.streamButton.rawValue)
            && props[SDIPropCode.videoStreamCodec.rawValue].map { $0.currentUInt16() == 0x0003 || $0.enumAllUInt16().contains(0x0003) } == true
    }
}
