// End-to-end backend tests against the in-process FakeBlackmagicCamera.
// Tests: connect, state mapping, commands, REC confirmation via WS push,
//        reconnect, and network budget (bytes on connect + idle).

import Testing
import Foundation
import CameraCore
@testable import BlackmagicRESTBackend

// MARK: - Helpers

func makeBackendDirectly(cam: FakeBlackmagicCamera, login: BlackmagicLogin? = nil, knownLUTs: [String] = []) -> BlackmagicCameraBackend {
    let session = URLSession(configuration: .ephemeral)
    return BlackmagicCameraBackend(host: "127.0.0.1:\(cam.port)", urlSession: session, login: login, knownLUTs: knownLUTs)
}

/// Collect state updates until predicate matches, or timeout.
/// Runs predicate on a single consumer task to avoid racing with a canceled previous consumer.
func collectUntil(
    backend: BlackmagicCameraBackend,
    timeout: TimeInterval = 10,
    predicate: @escaping @Sendable (CameraState) -> Bool
) async -> CameraState? {
    return await withTaskGroup(of: CameraState?.self) { group in
        group.addTask {
            for await state in backend.updates {
                if predicate(state) { return state }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

// MARK: - Integration tests

@Suite("BlackmagicREST — Fake Camera", .serialized)
struct BlackmagicRESTBackendTests {

    // MARK: Connect

    @Test("Full connect reaches .connected", .timeLimit(.minutes(1)))
    func connectReachesConnected() async throws {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let state = await collectUntil(backend: backend) { $0.connection == .connected }
        #expect(state?.connection == .connected)
    }

    // MARK: Initial state mapping

    @Test("On a DC input (a power plate on the 2-pin input) the battery reads as the input's voltage",
          .timeLimit(.minutes(1)))
    func dcInputVolts() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.onDCInput = true
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        defer { cam.stop() }
        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }
        let state = await collectUntil(backend: backend) { $0.connection == .connected && $0.batteryVolts != nil }
        #expect(state?.batteryVolts == 17.9 && state?.batteryPercent == nil)
        #expect(state?.powerSource == "DC", "its \"AC\" is the DC input: the tile says what's powering it")
        // The camera pushes the voltage when it moves.
        var moved = CameraState()
        BlackmagicRESTStateMapper.applyEvent(property: "/camera/power", value: ["batteries": [], "milliVolt": 14200, "source": "AC"],
                                             to: &moved)
        #expect(moved.batteryVolts == 14.2 && moved.batteryPercent == nil && moved.powerSource == "DC")
        BlackmagicRESTStateMapper.applyEvent(property: "/camera/power", value: ["batteries": [], "milliVolt": 5100, "source": "USB"],
                                             to: &moved)
        #expect(moved.powerSource == "USB")
        BlackmagicRESTStateMapper.applyEvent(property: "/camera/power", value: ["batteries": [["chargeRemainingPercent": 64]],
                                                                                 "milliVolt": 15200, "source": "Battery"], to: &moved)
        #expect(moved.powerSource == nil && moved.batteryPercent == 64)
    }

    /// The shutter takes a set while the camera's auto exposure drives it, which the camera turns down.
    @Test("Shutter read-only while auto exposure drives it, as the iris is")
    func shutterUnderAutoExposure() throws {
        func applied(_ json: String) throws -> CameraState {
            var state = CameraState()
            let shutter = try JSONDecoder().decode(ShutterResponse.self, from: Data(json.utf8))
            BlackmagicRESTStateMapper.applyShutter(to: &state, shutter: shutter, measurement: nil, supported: nil)
            return state
        }
        #expect(try applied(#"{"shutterAngle": 18000, "continuousShutterAutoExposure": true}"#).shutterAngle?.isWritable == false)
        #expect(try applied(#"{"shutterAngle": 18000, "continuousShutterAutoExposure": false}"#).shutterAngle?.isWritable == true)
        #expect(try applied(#"{"shutterAngle": 18000}"#).shutterAngle?.isWritable == true)
    }

    @Test("Initial state populates all mapped fields", .timeLimit(.minutes(1)))
    func initialStateMapping() async throws {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let state = await collectUntil(backend: backend, timeout: 10) {
            $0.connection == .connected && $0.iso != nil
        }
        #expect(state?.iso?.value == 800)
        #expect(state?.shutterMode?.value == .angle)
        #expect(state?.shutterAngle?.value == 180.0)  // 18000 on the wire
        #expect(state?.shutterAngle?.options.first == 11.25)
        #expect(state?.whiteBalance?.kelvin.value == 5600.0)
        #expect(state?.batteryPercent == 85 && state?.batteryVolts == 13.6)
        #expect(state?.mediaRemainingMinutes == 60)   // the active disk, past the working set's nulls
        #expect(state?.recording.state == .idle)
        #expect(state?.model == "PYXIS 12K")
        // Format: labels as the camera's menu writes them, choices from the current recording area.
        #expect(state?.resolution?.value == "9K 16:9")
        #expect(state?.resolution?.options == ["12K 17:9", "9K 16:9", "4K 16:9"])
        #expect(state?.fileFormat?.value == "BRAW 8:1")
        #expect(state?.fileFormat?.options.first == "BRAW Q0")
        #expect(state?.fileFormat?.options.count == 8)
        #expect(state?.frameRate?.project.value == "24")
        #expect(state?.frameRate?.project.options == ["23.98", "24", "25", "29.97", "30", "50", "59.94", "60"])
        // Iris in third stops across the lens's range; no ND on this body.
        #expect(state?.iris?.value == 2.8)
        #expect(state?.iris?.options.prefix(4) == [2.8, 3.2, 3.5, 4.0])
        #expect(state?.iris?.options.last == 22)
        #expect(state?.nd == nil)
        #expect(state?.timecode != nil)
    }

    // MARK: REC — start confirmation via WS push

    @Test("REC start: confirmed by WS push, request cleared", .timeLimit(.minutes(1)))
    func recStartConfirmedByWS() async throws {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        await backend.setRecConfirmTimeout(5)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        _ = await collectUntil(backend: backend, timeout: 10) {
            $0.connection == .connected && $0.recording.state != .unknown
        }
        await backend.send(.record(true))

        let state = await collectUntil(backend: backend, timeout: 8) {
            $0.recording.request == nil && $0.recording.state == .recording
        }
        #expect(state?.recording.state == .recording)
        #expect(state?.recording.request == nil)
        #expect(state?.recording.failure == nil)
        #expect(cam.recordCommandsReceived == 1)
    }

    // MARK: REC — stop confirmation via WS push

    @Test("REC stop: confirmed by WS push, request cleared", .timeLimit(.minutes(1)))
    func recStopConfirmedByWS() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.recording = true
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        await backend.setRecConfirmTimeout(5)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        _ = await collectUntil(backend: backend, timeout: 10) {
            $0.connection == .connected && $0.recording.state == .recording
        }
        await backend.send(.record(false))

        let state = await collectUntil(backend: backend, timeout: 8) {
            $0.recording.request == nil && $0.recording.state == .idle
        }
        #expect(state?.recording.state == .idle)
        #expect(state?.recording.request == nil)
        #expect(cam.stopCommandsReceived == 1)
    }

    // MARK: REC — absolute semantics (no double-fire)

    @Test("REC send(true) when already recording: no command sent", .timeLimit(.minutes(1)))
    func recAbsoluteSemanticsNoDoubleStart() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.recording = true
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        _ = await collectUntil(backend: backend, timeout: 10) {
            $0.connection == .connected && $0.recording.state == .recording
        }
        await backend.send(.record(true))  // already recording — must be a no-op
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(cam.recordCommandsReceived == 0)
    }

    // MARK: REC timeout → re-read, no resend

    @Test("REC timeout: re-reads state, no resend, failure reported", .timeLimit(.minutes(1)))
    func recTimeoutReadsNotResends() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.neverConfirmRec = true
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        await backend.setRecConfirmTimeout(0.5)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        _ = await collectUntil(backend: backend, timeout: 10) {
            $0.connection == .connected && $0.recording.state != .unknown
        }

        let before = cam.recordCommandsReceived
        await backend.send(.record(true))

        let state = await collectUntil(backend: backend, timeout: 4) {
            $0.recording.request == nil
        }
        // Must not have resent (only the original 1 command)
        #expect(cam.recordCommandsReceived - before == 1)
        // Failure must be reported
        #expect(state?.recording.failure != nil)
    }

    // MARK: Command tests

    private func connectedBackend(cam: FakeBlackmagicCamera) async -> (BlackmagicCameraBackend, Task<Void, Never>) {
        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        return (backend, t)
    }

    @Test("setISO/setKelvin/setShutterAngle send PUT and state updates via WS push", .timeLimit(.minutes(1)),
          arguments: ["iso", "kelvin", "shutter"])
    func setterUpdatesState(field: String) async throws {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        defer { cam.stop() }

        let (backend, t) = await connectedBackend(cam: cam)
        defer { t.cancel() }

        _ = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected && $0.iso != nil }

        switch field {
        case "iso":
            await backend.send(.setISO(3200))
            let state = try #require(await collectUntil(backend: backend, timeout: 10) { $0.iso?.value == 3200 })
            #expect(cam.config.iso == 3200)
            #expect(state.iso?.value == 3200)
        case "kelvin":
            await backend.send(.setKelvin(4500))
            let state = try #require(await collectUntil(backend: backend, timeout: 10) { $0.whiteBalance?.kelvin.value == 4500.0 })
            #expect(cam.config.kelvin == 4500)
            #expect(state.whiteBalance?.kelvin.value == 4500.0)
        case "shutter":
            await backend.send(.setShutterAngle(90.0))
            let state = try #require(await collectUntil(backend: backend, timeout: 10) { $0.shutterAngle?.value == 90.0 })
            #expect(cam.config.shutterAngle == 9000)
            #expect(state.shutterAngle?.value == 90.0)
        default:
            Issue.record("unknown field: \(field)")
        }
    }

    // MARK: Reconnect

    @Test("disconnect then reconnect succeeds", .timeLimit(.minutes(2)))
    func reconnectAfterDisconnect() async throws {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        _ = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected }
        await backend.disconnect()
        _ = await collectUntil(backend: backend, timeout: 5) { $0.connection == .disconnected }

        let t2 = Task.detached { await backend.connect() }
        defer { t2.cancel() }

        let state = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected }
        #expect(state?.connection == .connected)
    }
}

// MARK: - Budget test

@Suite("BlackmagicREST — Network Budget", .serialized)
struct BlackmagicBudgetTests {

    @Test("Connect: a handful of reads and one burst on the WebSocket; idle: no REST at all", .timeLimit(.minutes(1)))
    func connectAndIdleBudget() async throws {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let connected = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected }
        #expect(connected != nil)
        let reads = cam.restRequests
        let traffic = cam.traffic

        // On a link as quick as this one, connecting ends with a timecode look (two reads half a second apart).
        try? await Task.sleep(for: .seconds(1))
        let settled = cam.restRequests

        // 2 s is enough to catch any polling that fires on a timer.
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // Identity, formats, displays, the timecode twice, and power (its subscribe answer has no value): everything
        // else is in the subscribe answers.
        #expect(reads == 6, "\(reads) REST requests on connect")
        // At the camera, REST and WebSocket together: about 4 KB up (25 subscribe requests) and 7 KB down.
        #expect(traffic.up < 5_000, "connect sent \(traffic.up) B")
        #expect(traffic.down < 8_500, "connect received \(traffic.down) B")
        #expect(cam.restRequests == settled, "\(cam.restRequests - settled) REST requests while idle")
    }
}
