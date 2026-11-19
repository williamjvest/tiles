import Foundation
import Network
import CameraCore
import SSHTunnel

extension SonyCameraBackend {
    // MARK: - LiveViewProvider

    /// Whether the camera's Live View Status (0xD221) is Enabled (0x01), or live view comes through its stream (an FX5).
    /// FX3 reports this in Remote Control mode when the camera is in shooting mode.
    public var liveViewAvailable: Bool {
        rawProps[SDIPropCode.liveViewStatus.rawValue]?.currentUInt8() == 0x01 || streamsLiveView
    }

    /// The picture: a JPEG over the session, or one decoded from the camera's stream.
    public func liveViewPicture() async throws -> LiveViewFrame {
        if streamsLiveView { return try await streamLiveViewPicture() }
        return LiveViewFrame(jpeg: try await liveViewFrame())
    }

    /// Fetch one JPEG frame via GetObject(0xFFFFC002) over the existing PTP command channel.
    ///
    /// No second connection, no second tunnel. One GetObject transaction serialized through the same
    /// transport queue as every other command. The caller must not invoke this concurrently with
    /// itself or with a REC/set command (LiveViewSheet rate-caps to 1 fps; the transport queue
    /// enforces serial execution).
    ///
    /// Returns the JPEG bytes from the LiveView Dataset.
    /// Throws LiveViewError.noData when the camera says "not ready, retry" (0x200F, busy, or imageSize=0),
    /// .unavailable when 0xD221 is not Enabled (0x2009 response), .refused with any other answer, and .badFrame when
    /// there's no picture in what came.
    public func liveViewFrame() async throws -> Data {
        if streamsLiveView {
            guard let image = try await streamLiveViewPicture().image, let jpeg = RTMPLiveStream.jpeg(image) else {
                throw LiveViewError.noData
            }
            return jpeg
        }
        do {
            let jpeg = try await fetchLiveViewFrame()
            liveViewFrames += 1
            if liveViewFrames == 1 { ActivityLog.shared.note(host, "live view: first frame, \(jpeg.count) B") }
            liveViewProblem = nil
            return jpeg
        } catch {
            // Each new problem once, not once a frame.
            let problem = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            if problem != liveViewProblem {
                liveViewProblem = problem
                ActivityLog.shared.note(host, "live view: \(problem)")
            }
            throw error
        }
    }

    func fetchLiveViewFrame() async throws -> Data {
        guard state.connection == .connected else { throw LiveViewError.disconnected }
        guard let transport else { throw LiveViewError.disconnected }
        guard liveViewAvailable else { throw LiveViewError.unavailable }

        let (resp, data) = try await transport.execute(
            opCode: PTPOpCode.getObject.rawValue,
            params: [liveViewObjectHandle]
        )
        // Over USB: the frame plus three container headers (command, data, response).
        liveViewWireBytes += isUSB ? data.count + 3 * 12 : estimatePTPIPWireBytes(payloadSize: data.count)
        // Access_Denied: frame not ready yet, caller should retry
        if resp.responseCode == PTPResponseCode.accessDenied.rawValue { throw LiveViewError.noData }
        // Invalid ObjectHandle / parameterNotSupported: live view disabled or camera not in shooting mode
        if resp.responseCode == PTPResponseCode.parameterNotSupported.rawValue { throw LiveViewError.unavailable }
        if resp.responseCode == PTPResponseCode.deviceBusy.rawValue { throw LiveViewError.noData }
        guard resp.responseCode == PTPResponseCode.ok.rawValue else { throw LiveViewError.refused(resp.responseCode) }
        return try Self.jpeg(inLiveViewDataset: data)
    }


    public var liveViewConfig: LiveViewConfig { streamsLiveView ? .stream : isUSB ? .cabled : LiveViewConfig() }

    /// Set image quality before streaming; remember original to restore when stopping.
    /// Call before the first liveViewFrame(). Noop if quality already matches.
    public func setLiveViewQuality(_ quality: LiveViewQuality) async {
        guard let currentRaw = rawProps[SDIPropCode.liveViewImageQuality.rawValue]?.currentUInt8(),
              let transport else { return }
        if liveViewOriginalQuality == nil {
            liveViewOriginalQuality = currentRaw
        }
        guard currentRaw != quality.rawValue else { return }
        var d = Data(); d.append(quality.rawValue)
        _ = try? await transport.execute(
            opCode: SDIOOpCode.setExtDevicePropValue.rawValue,
            params: [UInt32(SDIPropCode.liveViewImageQuality.rawValue), sdioExtendedCodesFlag],
            sendData: d
        )
    }

    /// Restore the original quality and reset session state. Call on sheet dismiss.
    /// Also called by tearDown so the camera is always left as we found it.
    public func stopLiveView() async {
        await stopStreamLiveView()
        if let original = liveViewOriginalQuality, let transport {
            var d = Data(); d.append(original)
            _ = try? await transport.execute(
                opCode: SDIOOpCode.setExtDevicePropValue.rawValue,
                params: [UInt32(SDIPropCode.liveViewImageQuality.rawValue), sdioExtendedCodesFlag],
                sendData: d
            )
        }
        if liveViewObjectInfoFetched { ActivityLog.shared.note(host, "live view: stopped after \(liveViewFrames) frames") }
        liveViewOriginalQuality = nil
        liveViewObjectInfoFetched = false
        liveViewWireBytes = 0
    }

    public func startLiveView(quality: LiveViewQuality) async throws {
        ActivityLog.shared.note(host, "live view: starting at \(quality) quality")
        liveViewFrames = 0
        liveViewProblem = nil
        if streamsLiveView {
            do {
                try await startStreamLiveView(quality: quality)
            } catch {
                ActivityLog.shared.note(host, "live view: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                throw error
            }
            return
        }
        await setLiveViewQuality(quality)
        do {
            try await fetchLiveViewObjectInfo()
        } catch {
            ActivityLog.shared.note(host, "live view: its object info failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            throw error
        }
    }

    /// Call once before the first liveViewFrame(), as the protocol asks.
    public func fetchLiveViewObjectInfo() async throws {
        guard !liveViewObjectInfoFetched, let transport else { return }
        let (resp, _) = try await transport.execute(
            opCode: PTPOpCode.getObjectInfo.rawValue,
            params: [liveViewObjectHandle]
        )
        if resp.responseCode == PTPResponseCode.parameterNotSupported.rawValue { throw LiveViewError.unavailable }
        guard resp.responseCode == PTPResponseCode.ok.rawValue else { throw LiveViewError.refused(resp.responseCode) }
        liveViewObjectInfoFetched = true
    }

    // MARK: - Live view internals


    /// Parse LiveView Dataset:
    /// Offset(4) + ImageSize(4) + FocalOffset(4) + FocalSize(4) + Reserved(variable) + JPEG(ImageSize)
    /// The JPEG in a LiveView Dataset, where its Offset and Image Size say it is. Failing that, the JPEG found by its
    /// start and end markers: the dataset's own numbers are all that stand between the frame and the picture, and a
    /// link that hands the data back framed differently would otherwise lose every frame without a word.
    static func jpeg(inLiveViewDataset data: Data) throws -> Data {
        guard data.count >= 16 else { throw LiveViewError.badFrame("\(data.count) B") }
        let imageOffset = Int(data.readLE(UInt32.self, at: 0))
        let imageSize   = Int(data.readLE(UInt32.self, at: 4))
        guard imageSize > 0 else { throw LiveViewError.noData }  // camera says retry
        let end = imageOffset + imageSize
        if imageSize >= 2, end <= data.count, data[imageOffset] == 0xFF, data[imageOffset + 1] == 0xD8 {
            return Data(data[imageOffset..<end])
        }
        let bytes = [UInt8](data)
        guard let start = (0..<bytes.count - 1).first(where: { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xD8 }) else {
            throw LiveViewError.badFrame("\(data.count) B, no JPEG; it said \(imageSize) B at \(imageOffset)")
        }
        let stop = stride(from: bytes.count - 2, through: start + 2, by: -1)
            .first { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xD9 }.map { $0 + 2 }
        return Data(bytes[start..<(stop ?? bytes.count)])
    }

    /// Estimate total on-wire bytes for one GetObject transaction (both directions):
    /// PTP-IP headers + payload + SSH channel framing (~42 B/packet).
    func estimatePTPIPWireBytes(payloadSize: Int) -> Int {
        // Sent: Cmd_Request (26 B PTP-IP) + SSH (~42 B)
        // Recv: Cmd_Response (16 B) + Start_Data (20 B) + End_Data (8 + payloadSize) + SSH * 3
        let ptpIP = 26 + 16 + 20 + 8 + payloadSize
        let ssh   = 4 * 42
        return ptpIP + ssh
    }
}

