// LiveViewTests.swift — on-demand live view via GetObject(0xFFFFC002).

import Testing
import Foundation
@testable import CameraCore
@testable import SonyPTP

// MARK: - Helpers

private func fetchFrames(
    _ provider: any LiveViewProvider,
    count: Int,
    timeout: TimeInterval = 10
) async throws -> [Data] {
    var frames: [Data] = []
    let deadline = Date().addingTimeInterval(timeout)
    while frames.count < count, Date() < deadline {
        let frame = try await provider.liveViewFrame()
        frames.append(frame)
    }
    return frames
}

// MARK: - MockCameraBackend LiveView

@Suite("MockCameraBackend LiveView", .serialized)
struct MockLiveViewTests {

    @Test("liveViewFrame returns non-empty JPEG data", .timeLimit(.minutes(1)))
    func frameIsNonEmpty() async throws {
        let backend = MockCameraBackend(body: .fx3, heartbeat: nil)
        await backend.connect()
        let frame = try await backend.liveViewFrame()
        #expect(!frame.isEmpty)
        #expect(frame[0] == 0xFF && frame[1] == 0xD8)  // JPEG SOI
    }

    @Test("liveViewAvailable is true when connected", .timeLimit(.minutes(1)))
    func availableWhenConnected() async throws {
        let backend = MockCameraBackend(body: .fx3, heartbeat: nil)
        await backend.connect()
        let available = await backend.liveViewAvailable
        #expect(available == true)
    }

    @Test("liveViewAvailable is false when disconnected", .timeLimit(.minutes(1)))
    func unavailableWhenDisconnected() async throws {
        let backend = MockCameraBackend(body: .fx3, heartbeat: nil)
        let available = await backend.liveViewAvailable
        #expect(available == false)
    }

    @Test("liveViewFrame throws when disconnected", .timeLimit(.minutes(1)))
    func throwsWhenDisconnected() async throws {
        let backend = MockCameraBackend(body: .fx3, heartbeat: nil)
        await #expect(throws: LiveViewError.self) {
            _ = try await backend.liveViewFrame()
        }
    }

    @Test("hasLiveView is true in sampleState")
    func hasLiveViewInState() {
        let sample = MockCameraBackend.sampleState(body: .fx3)
        #expect(sample.hasLiveView == true)
    }
}

// MARK: - REC not delayed behind live view

@Suite("LiveView does not delay REC", .serialized)
struct LiveViewRECPriorityTests {

    @Test("REC confirms promptly while live view is active", .timeLimit(.minutes(1)))
    func recNotDelayedByFrames() async throws {
        var camConfig = FakePTPIPCamera.Config()
        camConfig.liveViewEnabled = true
        let cam = FakePTPIPCamera(config: camConfig)
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let connectTask = Task.detached { await backend.connect() }
        defer { connectTask.cancel() }

        _ = await collectUntil(backend: backend, timeout: 10) {
            $0.connection == .connected && $0.hasLiveView == true
        }

        // Start a live view consumer that keeps fetching frames during REC.
        let liveViewTask = Task {
            if let provider = (backend as Any) as? any LiveViewProvider {
                try? await provider.startLiveView(quality: .low)
                while !Task.isCancelled {
                    _ = try? await provider.liveViewFrame()
                }
                await provider.stopLiveView()
            }
        }
        defer { liveViewTask.cancel() }

        // Give live view a moment to start fetching.
        try await Task.sleep(nanoseconds: 100_000_000)

        let t0 = Date()
        await backend.send(.record(true))
        let recState = await collectUntil(backend: backend, timeout: 5) {
            $0.recording.state == .recording || $0.recording.failure != nil
        }
        let elapsed = Date().timeIntervalSince(t0)

        #expect(recState?.recording.state == .recording)
        #expect(elapsed < 3.0, "REC took \(elapsed) s while live view was active — expected < 3 s")

        await backend.send(.record(false))
        _ = await collectUntil(backend: backend, timeout: 5) { $0.recording.state == .idle }
    }
}

// MARK: - LiveView Dataset parser

@Suite("LiveView Dataset parsing", .serialized)
struct LiveViewDatasetTests {

    /// Build a minimal LiveView Dataset wrapping the given JPEG.
    private func buildDataset(jpeg: Data) -> Data {
        // Header: 16 bytes. Offset=16, ImageSize=jpeg.count, FocalOffset=16+jpeg.count, FocalSize=0
        var d = Data()
        func appendUInt32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        appendUInt32(16)                      // Offset to Live View Image
        appendUInt32(UInt32(jpeg.count))       // Live View Image Size
        appendUInt32(UInt32(16 + jpeg.count))  // Offset to Focal Frame Info
        appendUInt32(0)                        // Focal Frame Info Size
        d.append(jpeg)
        return d
    }

    @Test("The JPEG is where the dataset says")
    func parsesAtTheOffset() throws {
        let jpeg = MockCameraBackend.syntheticJPEG
        #expect(try SonyCameraBackend.jpeg(inLiveViewDataset: buildDataset(jpeg: jpeg)) == jpeg)
    }

    @Test("Image Size 0 is the camera saying retry")
    func imageSizeZeroIsRetry() {
        var d = buildDataset(jpeg: Data())
        d.append(Data(repeating: 0, count: 4))
        #expect(throws: LiveViewError.self) { try SonyCameraBackend.jpeg(inLiveViewDataset: d) }
        do { _ = try SonyCameraBackend.jpeg(inLiveViewDataset: d) } catch LiveViewError.noData {} catch {
            Issue.record("expected noData, got \(error)")
        }
    }

    @Test("Framed differently (a container header in front), the JPEG is still found by its markers")
    func findsTheJPEGWhenTheNumbersMiss() throws {
        let jpeg = MockCameraBackend.syntheticJPEG
        let dataset = buildDataset(jpeg: jpeg)
        var framed = PTPUSBContainer(kind: .data, code: 0x1009, transactionID: 7, payload: dataset).encoded
        framed.append(Data([0x00, 0x00]))  // padding after the picture
        #expect(try SonyCameraBackend.jpeg(inLiveViewDataset: framed) == jpeg)
    }

    @Test("No JPEG at all says what came")
    func noJPEGSaysSo() {
        var d = buildDataset(jpeg: Data(repeating: 0x11, count: 40))
        d.append(Data(repeating: 0, count: 8))
        do {
            _ = try SonyCameraBackend.jpeg(inLiveViewDataset: d)
            Issue.record("expected badFrame")
        } catch LiveViewError.badFrame(let what) {
            #expect(what.contains("\(d.count) B"))
        } catch {
            Issue.record("expected badFrame, got \(error)")
        }
    }
}

// MARK: - FakePTPIPCamera live view

@Suite("FakePTPIPCamera GetObject live view", .serialized)
struct FakeCameraLiveViewTests {

    @Test("GetObject(0xFFFFC002) returns LiveView Dataset with JPEG", .timeLimit(.minutes(1)))
    func getObjectReturnsDataset() async throws {
        var camConfig = FakePTPIPCamera.Config()
        camConfig.liveViewEnabled = true
        let cam = FakePTPIPCamera(config: camConfig)
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        cfg.pollInterval = 60
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let connectTask = Task.detached { await backend.connect() }
        defer { connectTask.cancel() }

        // Wait for props to be fetched (hasLiveView comes from 0xD221 in the prop array)
        _ = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected && $0.hasLiveView == true }

        let available = await backend.liveViewAvailable
        #expect(available == true)

        let frame = try await backend.liveViewFrame()
        #expect(!frame.isEmpty)
        #expect(frame[0] == 0xFF && frame[1] == 0xD8)
    }

    @Test("The app's path: the FX3 backend as a LiveViewProvider drops to Low, streams, restores", .timeLimit(.minutes(1)))
    func appPathThroughTheProtocol() async throws {
        var camConfig = FakePTPIPCamera.Config()
        camConfig.liveViewEnabled = true
        let cam = FakePTPIPCamera(config: camConfig)
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        cfg.pollInterval = 60
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let connectTask = Task.detached { await backend.connect() }
        defer { connectTask.cancel() }
        _ = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected && $0.hasLiveView == true }

        // CameraController reaches live view only through this cast. Without the conformance the FX3's tile opened an
        // empty sheet, and without startLiveView the app streamed at the camera's own (High) quality.
        let provider = try #require((backend as Any) as? any LiveViewProvider)
        try await provider.startLiveView(quality: .low)
        let quality = SDIPropCode.liveViewImageQuality.rawValue
        #expect(cam.propWrites.last { $0.code == quality }?.data == Data([0x01]))
        let frame = try await provider.liveViewFrame()
        #expect(frame.starts(with: [0xFF, 0xD8]))
        await provider.stopLiveView()
        #expect(cam.propWrites.last { $0.code == quality }?.data == Data([0x02]), "the camera's own quality comes back")
    }

    @Test("GetObject(0xFFFFC002) returns 0x2009 when live view disabled", .timeLimit(.minutes(1)))
    func getObjectDisabled() async throws {
        var camConfig = FakePTPIPCamera.Config()
        camConfig.liveViewEnabled = false
        let cam = FakePTPIPCamera(config: camConfig)
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        cfg.pollInterval = 60
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let connectTask = Task.detached { await backend.connect() }
        defer { connectTask.cancel() }

        // Wait for props to be fetched (hasLiveView = false from 0xD221=0x00)
        _ = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected && $0.hasReported }

        let available = await backend.liveViewAvailable
        #expect(available == false)

        // Direct liveViewFrame() call should throw .unavailable because liveViewAvailable is false
        do {
            _ = try await backend.liveViewFrame()
            Issue.record("Expected LiveViewError.unavailable")
        } catch LiveViewError.unavailable {
            // correct
        } catch {
            Issue.record("Expected .unavailable, got \(error)")
        }
    }
}

// MARK: - StateMapper live view status

@Suite("StateMapper live view status", .serialized)
struct StateMapperLiveViewTests {

    @Test("0xD221 = 0x01 → hasLiveView = true")
    func enabledMapsToTrue() throws {
        let prop = makeStatusProp(0x01)
        let mapper = StateMapper(props: [prop])
        var state = CameraState()
        mapper.map(into: &state)
        #expect(state.hasLiveView == true)
    }

    @Test("0xD221 = 0x00 → hasLiveView = false")
    func disabledMapsToFalse() throws {
        let prop = makeStatusProp(0x00)
        let mapper = StateMapper(props: [prop])
        var state = CameraState()
        mapper.map(into: &state)
        #expect(state.hasLiveView == false)
    }

    @Test("0xD221 absent → hasLiveView = false")
    func absentMapsToFalse() {
        let mapper = StateMapper(props: [])
        var state = CameraState()
        mapper.map(into: &state)
        #expect(state.hasLiveView == false)
    }

    private func makeStatusProp(_ value: UInt8) -> SDIDevicePropInfo {
        // SDIDevicePropInfo for 0xD221 (UINT8, read-only, IsEnabled=true, currentValue=value)
        var data = Data()
        func appendU16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        appendU16(0xD221)   // code
        appendU16(0x0002)   // DataType UINT8
        data.append(0x00)   // GetSet: read-only
        data.append(0x01)   // IsEnabled: true
        data.append(0x00)   // factory default
        data.append(value)  // current value
        data.append(0x02)   // FormFlag: Enumeration
        appendU16(2)        // set enum count
        data.append(0x00)   // 0x00
        data.append(0x01)   // 0x01
        appendU16(3)        // getset enum count
        data.append(0x00)
        data.append(0x01)
        data.append(0x02)
        let props = try! parseSDIDevicePropInfoArray(buildWrapper(data))
        return props[0]
    }

    private func buildWrapper(_ propData: Data) -> Data {
        var result = Data()
        var count = UInt64(1).littleEndian
        withUnsafeBytes(of: &count) { result.append(contentsOf: $0) }
        result.append(propData)
        return result
    }
}

