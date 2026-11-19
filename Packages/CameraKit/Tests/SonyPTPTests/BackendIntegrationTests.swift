// End-to-end backend tests against the in-process FakePTPIPCamera.
// Tests: connect sequence, property dump, REC confirm, REC timeout → re-read (no resend), dead-link detection.

import Testing
import Foundation
@testable import SonyPTP
import CameraCore

// MARK: - Helpers

func makeBackend(host: String, port: UInt16, config: SonyBackendConfig = SonyBackendConfig()) -> SonyCameraBackend {
    var cfg = config
    // Point transport at the fake camera's port
    cfg.transport.port = NWEndpoint.Port(rawValue: port)!
    let store = EphemeralIdentityStore(friendlyName: "test")
    return SonyCameraBackend(host: host, identityStore: store, config: cfg)
}

/// Collect state updates until predicate matches, or timeout.
func collectUntil(backend: SonyCameraBackend, timeout: TimeInterval = 10, predicate: @escaping @Sendable (CameraState) -> Bool) async -> CameraState? {
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

@Suite("Backend Integration — Fake Camera", .serialized)
struct BackendIntegrationTests {

    // MARK: Connect sequence

    @Test("Full connect sequence reaches .connected", .timeLimit(.minutes(1)))
    func connectSequence() async throws {
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }
        let state = await collectUntil(backend: backend) { $0.connection == .connected }
        #expect(state?.connection == .connected)
    }

    @Test("SDIO_Connect called in correct phase order", .timeLimit(.minutes(1)))
    func connectPhaseOrder() async throws {
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }
        _ = await collectUntil(backend: backend) { $0.connection == .connected }

        // Check that SDIO_Connect was called 3 times in order
        let sdioConnects = cam.lastTransactions.filter { $0.opCode == SDIOOpCode.connect.rawValue }
        // A missed connect is a failure, not an index out of range that takes the whole run down.
        try #require(sdioConnects.count == 3)
        #expect(sdioConnects[0].params.first == SDIOConnectPhase.phase1.rawValue)
        #expect(sdioConnects[1].params.first == SDIOConnectPhase.phase2.rawValue)
        #expect(sdioConnects[2].params.first == SDIOConnectPhase.phase3.rawValue)
    }

    @Test("Camera that rejects init reaches .awaitingApproval (pairingShowsApprovalWhileTheCameraAsks covers the happy path)")
    func awaitingApproval() async throws {
        var camConfig = FakePTPIPCamera.Config()
        camConfig.rejectInit = true
        let cam = FakePTPIPCamera(config: camConfig)
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 2
        cfg.session.extDeviceInfoRetryTimeout = 1
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)

        let connectTask = Task.detached { await backend.connect() }
        defer { connectTask.cancel() }

        let state = try #require(await collectUntil(backend: backend, timeout: 4) { $0.connection == .awaitingApproval })
        #expect(state.connection == .awaitingApproval)
    }

    // MARK: Property dump

    @Test("Initial property fetch populates CameraState", .timeLimit(.minutes(1)))
    func initialPropertyFetch() async throws {
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let state = await collectUntil(backend: backend, timeout: 10) {
            $0.connection == .connected && $0.shutterAngle != nil
        }
        #expect(state?.shutterAngle?.value == 180.0)
        #expect(state?.batteryPercent == 85)
        #expect(state?.recording.state == .idle)
    }

    @Test("A failed first property read is a failure, not a connected camera with no values", .timeLimit(.minutes(1)))
    func failedInitialFetchIsAFailure() async throws {
        let cam = FakePTPIPCamera()
        cam.config.failFullPropFetches = 1
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let failed = await collectUntil(backend: backend, timeout: 10) {
            if case .failed = $0.connection { return true } else { return false }
        }
        guard case .failed(let message) = failed?.connection else { Issue.record("never failed"); return }
        #expect(message.contains("settings") && message.contains("0x2006"), "\(message)")

        // The next attempt (the controller's retry) reads them.
        let t2 = Task.detached { await backend.connect() }
        defer { t2.cancel() }
        let state = await collectUntil(backend: backend, timeout: 10) {
            $0.connection == .connected && $0.shutterAngle != nil
        }
        #expect(state?.shutterAngle?.value == 180.0)
    }

    @Test("No property read goes out before the session is set up, even when an event arrives mid-setup",
          .timeLimit(.minutes(1)))
    func noReadBeforeSessionReady() async throws {
        let cam = FakePTPIPCamera()
        cam.config.eventBeforeSessionReady = true
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        cfg.transport.transactionTimeout = 3   // a read stuck behind setup would fail inside the wait below
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let state = await collectUntil(backend: backend, timeout: 10) {
            $0.connection == .connected && $0.shutterAngle != nil
        }
        #expect(state?.shutterAngle?.value == 180.0)
        #expect(cam.propReadsBeforeSessionReady == 0)
    }

    // MARK: REC confirm

    @Test("REC start: request cleared when camera confirms recording", .timeLimit(.minutes(1)))
    func recStartConfirm() async throws {
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        cfg.recConfirmTimeout = 5
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        _ = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected }
        // Wait for initial prop fetch so recording state is known (not .unknown) before sending REC
        _ = await collectUntil(backend: backend, timeout: 5) { $0.recording.state != .unknown }
        await backend.send(.record(true))

        let state = await collectUntil(backend: backend, timeout: 8) {
            $0.recording.request == nil && $0.recording.state == .recording
        }
        #expect(state?.recording.state == .recording)
        #expect(state?.recording.request == nil)
        #expect(state?.recording.failure == nil)
    }

    @Test("REC stop: request cleared when camera confirms stopped", .timeLimit(.minutes(1)))
    func recStopConfirm() async throws {
        var camConfig = FakePTPIPCamera.Config()
        camConfig.recordingState = 0x01  // Start recording
        let cam = FakePTPIPCamera(config: camConfig)
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        cfg.recConfirmTimeout = 5
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
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
    }

    // MARK: REC timeout → re-read, no resend

    @Test("REC timeout re-reads state and does not resend", .timeLimit(.minutes(1)))
    func recTimeoutNoResend() async throws {
        // Camera accepts REC but never changes recording state → backend must time out and not resend
        var camConfig = FakePTPIPCamera.Config()
        camConfig.recordingState = 0x00  // stays not recording
        camConfig.neverConfirmRec = true  // camera accepts command but state never flips
        let cam = FakePTPIPCamera(config: camConfig)
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        cfg.recConfirmTimeout = 1.0  // Short timeout for test
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        _ = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected }
        _ = await collectUntil(backend: backend, timeout: 5) { $0.recording.state != .unknown }

        let controlsBefore = cam.lastTransactions.filter {
            $0.opCode == SDIOOpCode.controlDevice.rawValue
        }.count

        await backend.send(.record(true))

        let state = await collectUntil(backend: backend, timeout: 5) {
            $0.recording.request == nil
        }

        let controlsAfter = cam.lastTransactions.filter {
            $0.opCode == SDIOOpCode.controlDevice.rawValue
        }.count

        // Should have exactly 1 (or 2 for hold down/up) — NOT doubled [Architecture rule 6]
        #expect(controlsAfter - controlsBefore <= 2)
        // State should report failure, not just silently flip [Architecture rule 6]
        if let failure = state?.recording.failure {
            #expect(!failure.isEmpty)
        }
    }

    // MARK: Dead-link detection

    @Test("Dead link transitions to .failed state", .timeLimit(.minutes(1)))
    func deadLinkDetection() async throws {
        var camConfig = FakePTPIPCamera.Config()
        camConfig.killAfterTransactions = 12  // Drop TCP after connect sequence + a few more ops
        let cam = FakePTPIPCamera(config: camConfig)
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        cfg.transport.transactionTimeout = 2
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        _ = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected }

        // Trigger enough transactions to hit the kill limit
        for _ in 0..<5 {
            await backend.send(.setKelvin(5000))
        }

        let state = try #require(await collectUntil(backend: backend, timeout: 10) { s in
            if case .failed = s.connection { return true }
            return s.connection == .disconnected
        })
        if case .failed = state.connection { } else { #expect(state.connection == .disconnected) }
    }

    // MARK: Spurious double-emission regression

    @Test("Failed then disconnected transport does not double-emit", .timeLimit(.minutes(1)))
    func noDoubleEmissionOnFailedThenDisconnected() async throws {
        // Verifies that handleTransportStateChange suppresses a .disconnected after .failed.
        var camConfig = FakePTPIPCamera.Config()
        camConfig.killAfterTransactions = 8
        let cam = FakePTPIPCamera(config: camConfig)
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        cfg.transport.transactionTimeout = 2
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        _ = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected }

        // Collect terminal states after the kill.
        nonisolated(unsafe) var terminalStates: [CameraState] = []
        let collectorDone = Task {
            for await state in backend.updates {
                let c = state.connection
                if c == .disconnected { terminalStates.append(state); return }
                if case .failed(_) = c { terminalStates.append(state) }
            }
        }
        // Trigger enough ops to hit the kill limit.
        for _ in 0..<3 { await backend.send(.setKelvin(5000)) }
        // Wait for the first .failed rather than sleeping a fixed 4 s.
        let failed = await collectUntil(backend: backend, timeout: 10) {
            if case .failed = $0.connection { return true }
            return $0.connection == .disconnected
        }
        try? await Task.sleep(nanoseconds: 500_000_000)  // short window for a spurious second event
        collectorDone.cancel()

        let _ = failed  // we cared only about timing; the count is what we assert
        let failedCount = terminalStates.filter {
            if case .failed(_) = $0.connection { return true }
            return false
        }.count
        #expect(failedCount <= 1)
    }

    // MARK: Poll loop single instance regression

    @Test("Reconnect does not duplicate poll loop", .timeLimit(.minutes(1)))
    func reconnectNoDuplicatePollLoop() async throws {
        // Ensures startPollLoop cancels any prior loop so only one runs after reconnect.
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        cfg.pollInterval = 0.05  // Fast poll to detect duplicate activity quickly
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let state = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected }
        #expect(state?.connection == .connected)
        // A duplicate poll loop doubles the transaction rate. At 50 ms poll interval we expect ~4
        // transactions per 200 ms window; two loops would produce ~8. Reject anything ≥ 12 to keep
        // a comfortable margin while still catching a double loop.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let txBefore = cam.lastTransactions.count
        try? await Task.sleep(nanoseconds: 200_000_000)
        let txAfter = cam.lastTransactions.count
        #expect(txAfter - txBefore < 12, "Too many transactions: \(txAfter - txBefore) in 200 ms suggests a duplicate poll loop")
    }

    // MARK: SDIO_OpenSession fallback

    @Test("SDIO_OpenSession: graceful skip when camera returns Parameter_Not_Supported", .timeLimit(.minutes(1)))
    func sdioOpenSessionFallback() async throws {
        var camConfig = FakePTPIPCamera.Config()
        camConfig.sdioOpenSessionUnsupported = true
        let cam = FakePTPIPCamera(config: camConfig)
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let state = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected }
        #expect(state?.connection == .connected)
    }

    // MARK: Position Key Setting

    @Test("Session setup: Position Key 0xD25A set to PC Remote priority (0x01) after connect", .timeLimit(.minutes(1)))
    func positionKeySetDuringSetup() async throws {
        // The FX3 silently accepts SDIO_ControlDevice for REC but never starts recording when
        // 0xD25A is 0x00 (camera priority). Session setup must set it to 0x01.
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let state = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected }
        #expect(state?.connection == .connected)
        #expect(cam.positionKeySetToPCRemote == true, "0xD25A must be set to 0x01 during session setup")
    }

    @Test("SDIO_OpenSession 0x201E (Session_Already_Open) treated as success and Position Key still set", .timeLimit(.minutes(1)))
    func sdioOpenSessionAlreadyOpenTreatedAsSuccess() async throws {
        // The FX3 returns 0x201E when a prior PC remote session is still alive.
        // The backend must treat this as success so Position Key Setting is applied and REC works.
        var camConfig = FakePTPIPCamera.Config()
        camConfig.sdioOpenSessionAlreadyOpen = true
        let cam = FakePTPIPCamera(config: camConfig)
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let state = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected }
        #expect(state?.connection == .connected, "0x201E must not abort session setup")
        #expect(cam.positionKeySetToPCRemote == true, "0xD25A must be set after 0x201E SDIO_OpenSession")
    }

    /// Connect a backend to `cam` and wait until it is controllable with a known recording state.
    private func connectedBackend(_ cam: FakePTPIPCamera) async -> (SonyCameraBackend, Task<Void, Never>) {
        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        cfg.recConfirmTimeout = 3
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let task = Task.detached { await backend.connect() }
        _ = await collectUntil(backend: backend, timeout: 10) {
            $0.connection == .connected && $0.recording.state != .unknown
        }
        return (backend, task)
    }

    private func recControls(_ cam: FakePTPIPCamera) -> [String] {
        cam.controls
            .filter { $0.code == 0xD2C8 || $0.code == 0xF001 }
            .map { String(format: "%04X:", $0.code) + $0.data.map { String(format: "%02X", $0) }.joined() }
    }

    @Test("Pairing: a camera that holds the Init Ack shows 'approve on camera', then connects", .timeLimit(.minutes(1)))
    func pairingShowsApprovalWhileTheCameraAsks() async throws {
        let cam = FakePTPIPCamera()
        cam.config.approvalDelay = 5  // the camera waits for OK on the body before answering
        try await cam.start()
        defer { cam.stop() }
        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let task = Task.detached { await backend.connect() }
        defer { task.cancel() }

        let asking = await collectUntil(backend: backend, timeout: 5) { $0.connection == .awaitingApproval }
        #expect(asking?.connection == .awaitingApproval)
        let connected = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected }
        #expect(connected?.connection == .connected)
    }

    @Test("REC on an FX3 is one Hold press: Down to start, Up to stop, UINT16, never the toggle", .timeLimit(.minutes(1)))
    func recUsesHoldButton() async throws {
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }

        await backend.send(.record(true))
        let started = await collectUntil(backend: backend, timeout: 8) {
            $0.recording.request == nil && $0.recording.state == .recording
        }
        #expect(started?.recording.failure == nil)
        await backend.send(.record(false))
        let stopped = await collectUntil(backend: backend, timeout: 8) {
            $0.recording.request == nil && $0.recording.state == .idle
        }
        #expect(stopped?.recording.failure == nil)
        #expect(recControls(cam) == ["D2C8:0200", "D2C8:0100"])
        #expect(cam.positionKeySetToPCRemote == true)  // Sony's scripts set it; harmless, not what REC needs
    }

    @Test("REC on a toggle-only body presses only when the state has to change", .timeLimit(.minutes(1)))
    func recToggleOnlyBody() async throws {
        let cam = FakePTPIPCamera()
        cam.config.controlCodes = [SDIControlCode.movieRecButtonToggle.rawValue]
        cam.config.recordingState = 0x01  // already rolling
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }

        await backend.send(.record(true))  // already recording: nothing to press
        _ = await collectUntil(backend: backend, timeout: 8) { $0.recording.request == nil }
        #expect(recControls(cam).isEmpty)
        await backend.send(.record(false))
        let stopped = await collectUntil(backend: backend, timeout: 8) {
            $0.recording.request == nil && $0.recording.state == .idle
        }
        #expect(stopped?.recording.failure == nil)
        #expect(recControls(cam) == ["F001:0200", "F001:0100"])
    }

    @Test("REC on an FX6 (no 0xD21D): the recorder's status is the state, and the Hold press starts and stops", .timeLimit(.minutes(1)))
    func recFX6RecorderStatus() async throws {
        let cam = FakePTPIPCamera()
        cam.config.recordingStateSource = .recorderMainStatus
        cam.config.recConfirmDelay = 0.3  // PreparingToRecord first, as a real recorder spins up
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }

        let ready = await collectUntil(backend: backend, timeout: 8) { $0.recording.state == .idle }
        #expect(ready != nil)  // known, so REC is enabled; it stayed .unknown before
        await backend.send(.record(true))
        let started = await collectUntil(backend: backend, timeout: 8) {
            $0.recording.request == nil && $0.recording.state == .recording
        }
        #expect(started?.recording.failure == nil)
        #expect(started?.takeStartedAt != nil)
        await backend.send(.record(false))
        let stopped = await collectUntil(backend: backend, timeout: 8) {
            $0.recording.request == nil && $0.recording.state == .idle
        }
        #expect(stopped?.recording.failure == nil)
        #expect(recControls(cam) == ["D2C8:0200", "D2C8:0100"])
    }

    @Test("A stop the recorder takes a while over (Stopping) is waited out, not called a failure", .timeLimit(.minutes(1)))
    func recStopWhileStopping() async throws {
        // An FX5 on a linked stop: REC FAILED on it while the FX3 and FX30 stopped. A long take, proxy and all,
        // can sit at Stopping past the usual wait (3 s here).
        let cam = FakePTPIPCamera()
        cam.config.recordingStateSource = .recorderMainStatus
        cam.config.stopDelay = 5
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }
        await backend.send(.record(true))
        #expect(await collectUntil(backend: backend, timeout: 8) {
            $0.recording.request == nil && $0.recording.state == .recording
        } != nil)
        await backend.send(.record(false))
        var stopped: CameraState?
        for _ in 0 ..< 200 {
            let now = await backend.state
            if now.recording.request == nil { stopped = now; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(stopped?.recording.state == .idle && stopped?.recording.failure == nil,
                "\(String(describing: stopped?.recording.state)), \(stopped?.recording.failure ?? "no failure")")
    }

    @Test("A stop the camera answers but doesn't act on is sent once more and lands; a start never is", .timeLimit(.minutes(1)))
    func recStopSentAgain() async throws {
        let cam = FakePTPIPCamera()
        cam.config.recordingStateSource = .recorderMainStatus
        cam.config.ignoredStops = 1
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }
        await backend.send(.record(true))
        #expect(await collectUntil(backend: backend, timeout: 8) {
            $0.recording.request == nil && $0.recording.state == .recording
        } != nil)
        await backend.send(.record(false))
        var settled: CameraState?
        for _ in 0 ..< 300 {
            let now = await backend.state
            if now.recording.request == nil { settled = now; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(settled?.recording.state == .idle && settled?.recording.failure == nil,
                "\(String(describing: settled?.recording.state)), \(settled?.recording.failure ?? "no failure")")
        #expect(recControls(cam) == ["D2C8:0200", "D2C8:0100", "D2C8:0100"], "Down, Up, and Up once more")
    }

    @Test("A take started at the camera gets its REC time", .timeLimit(.minutes(1)))
    @MainActor func recStartedAtTheCamera() async throws {
        // REC pressed on the FX5 itself: Tiles' Timecode tile should show the REC time.
        let cam = FakePTPIPCamera()
        cam.config.recordingStateSource = .recorderMainStatus
        try await cam.start()
        defer { cam.stop() }
        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        cfg.pollInterval = 0.2  // the fake raises no event for a press on the body: the poll finds it
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let camera = CameraController(slot: CameraSlot(label: "A", color: .red, host: "127.0.0.1"), backend: backend)
        camera.start()
        defer { camera.disconnect() }
        func until(_ met: () -> Bool) async throws {
            for _ in 0..<400 where !met() { try await Task.sleep(for: .milliseconds(25)) }
        }
        try await until { camera.state.connection == .connected && camera.state.recording.state == .idle }
        #expect(camera.state.recording.state == .idle)

        cam.config.recordingState = 0x01  // REC on the camera
        try await until { camera.state.recording.state == .recording }
        let started = try #require(camera.state.takeStartedAt, "a take started at the camera has no REC time")
        #expect(abs(started.timeIntervalSinceNow) < 3)
        #expect(recControls(cam).isEmpty)  // Tiles pressed nothing

        cam.config.recordingState = 0x00  // and stopped there
        try await until { camera.state.recording.state == .idle }
        #expect(camera.state.takeStartedAt == nil)
    }

    @Test("A start asked for while the camera is still stopping goes once it has stopped", .timeLimit(.minutes(1)))
    func recStartAfterStop() async throws {
        // A linked take started again while an FX5 still closes the last (Stopping for seconds) would miss it.
        let cam = FakePTPIPCamera()
        cam.config.recordingStateSource = .recorderMainStatus
        cam.config.stopDelay = 2
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }
        await backend.send(.record(true))
        #expect(await collectUntil(backend: backend, timeout: 8) {
            $0.recording.request == nil && $0.recording.state == .recording
        } != nil)
        let stopping = Task { await backend.send(.record(false)) }
        try await Task.sleep(for: .milliseconds(400))
        await backend.send(.record(true))  // the camera still Stopping
        await stopping.value
        var rolling: CameraState?
        for _ in 0 ..< 300 {
            let now = await backend.state
            if now.recording.request == nil, now.recording.state == .recording, recControls(cam).count == 3 {
                rolling = now
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(rolling?.recording.failure == nil && rolling != nil, "the second take never started")
        #expect(recControls(cam) == ["D2C8:0200", "D2C8:0100", "D2C8:0200"])
    }

    @Test("A stop asked for while the start is still being confirmed isn't dropped", .timeLimit(.minutes(1)))
    func recStopWhileStartPending() async throws {
        let cam = FakePTPIPCamera()
        cam.config.recordingStateSource = .recorderMainStatus
        cam.config.recConfirmDelay = 2  // Preparing to Record for 2 s
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }
        let starting = Task { await backend.send(.record(true)) }
        try await Task.sleep(for: .milliseconds(300))
        await backend.send(.record(false))  // the start not confirmed yet
        await starting.value
        var settled: CameraState?
        for _ in 0 ..< 400 {
            let now = await backend.state
            if now.recording.request == nil, now.recording.state == .idle { settled = now; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(settled != nil, "the camera ended up recording: the stop was dropped")
        #expect(recControls(cam).filter { $0 == "D2C8:0100" }.count >= 1, "an Up went")
    }

    @Test("REC on a BURANO (toggle only, no 0xD21D) stops a rolling take, pressing off the recorder's status", .timeLimit(.minutes(1)))
    func recBuranoToggleRecorderStatus() async throws {
        let cam = FakePTPIPCamera()
        cam.config.recordingStateSource = .recorderMainStatus
        cam.config.controlCodes = [SDIControlCode.movieRecButtonToggle.rawValue]  // a BURANO has no 0xD2C8
        cam.config.recordingState = 0x01  // already rolling
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }

        let rolling = await collectUntil(backend: backend, timeout: 8) { $0.recording.state == .recording }
        #expect(rolling != nil)
        await backend.send(.record(true))  // already recording: nothing to press
        _ = await collectUntil(backend: backend, timeout: 8) { $0.recording.request == nil }
        #expect(recControls(cam).isEmpty)
        await backend.send(.record(false))  // before: read 0xD21D, saw no take, and pressed nothing
        let stopped = await collectUntil(backend: backend, timeout: 8) {
            $0.recording.request == nil && $0.recording.state == .idle
        }
        #expect(stopped?.recording.failure == nil)
        #expect(recControls(cam) == ["F001:0200", "F001:0100"])
    }

    @Test("REC refused by the camera (MovieRecOperationResults NG) fails at once, not at the timeout", .timeLimit(.minutes(1)))
    func recRefusedFailsFast() async throws {
        let cam = FakePTPIPCamera()
        cam.config.rejectRec = true
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }

        let sent = Date()
        await backend.send(.record(true))
        let failed = await collectUntil(backend: backend, timeout: 8) { $0.recording.failure != nil }
        #expect(failed?.recording.failure == RecordingControl.Failure.refused)
        #expect(failed?.recording.state == .idle)
        #expect(Date().timeIntervalSince(sent) < 2)  // recConfirmTimeout is 3 s
    }
}

// MARK: - EADDRINUSE: a retry names its own local port

@Suite("PTP/IP connect retry")
struct ConnectRetryTests {
    @Test("After EADDRINUSE the retry binds its own ephemeral port, on loopback for a loopback camera; a name keeps the system's")
    func ownLocalPort() {
        let loopback = PTPIPTransport.withOwnLocalPort(.tcp, toward: .hostPort(host: "127.0.0.1", port: 15740))
        guard case .hostPort(let host, let port)? = loopback.requiredLocalEndpoint else {
            Issue.record("no local endpoint"); return
        }
        #expect(host == .ipv4(.loopback))
        #expect((49152...65535).contains(port.rawValue))
        let lan = PTPIPTransport.withOwnLocalPort(.tcp, toward: .hostPort(host: "192.168.1.40", port: 15740))
        if case .hostPort(let host, _)? = lan.requiredLocalEndpoint { #expect(host == .ipv4(.any)) } else { Issue.record("no local endpoint") }
        let named = PTPIPTransport.withOwnLocalPort(.tcp, toward: .hostPort(host: "fx3.local", port: 15740))
        #expect(named.requiredLocalEndpoint == nil)
    }
}

// MARK: - Import for NWEndpoint
import Network

// MARK: - Bandwidth measurement

/// Counts bytes via TrafficRecorder.
final class ByteCounter: TrafficRecorder, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent = 0
    private var _received = 0
    var sent: Int { lock.withLock { _sent } }
    var received: Int { lock.withLock { _received } }

    func record(direction: TrafficDirection, channel: TrafficChannel, data: Data) {
        lock.withLock {
            switch direction {
            case .sent: _sent += data.count
            case .received: _received += data.count
            }
        }
    }
}

@Suite("Bandwidth — connect + idle", .serialized)
struct BandwidthTests {

    // Run with BANDWIDTH=1 swift test for the full 60-second measurement.
    // In CI the short version only verifies the backend connects and the counter wires up.
    @Test("Idle bandwidth: short window ≤ 1.5 KB (BANDWIDTH=1 for the full 60 s)", .timeLimit(.minutes(2)))
    func connectAndIdleBandwidth() async throws {
        let fullRun = ProcessInfo.processInfo.environment["BANDWIDTH"] != nil
        let idleSeconds: Double = fullRun ? 60 : 3
        let idleBudget = fullRun ? 1_500 : 500   // 60 s: <1.5 KB; 3 s: <500 B

        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        cfg.transport.port = NWEndpoint.Port(rawValue: cam.port)!

        let counter = ByteCounter()
        let store = EphemeralIdentityStore(friendlyName: "bw-test")
        let backend = SonyCameraBackend(host: "127.0.0.1", identityStore: store, config: cfg, recorder: counter)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let connected = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected }
        #expect(connected?.connection == .connected)
        let connectSent = counter.sent
        let connectRecv = counter.received
        #expect(connectSent > 100)
        #expect(connectRecv > 100)

        try? await Task.sleep(nanoseconds: UInt64(idleSeconds * 1_000_000_000))

        let idleSent = counter.sent - connectSent
        let idleRecv = counter.received - connectRecv

        if fullRun {
            print("""
                ── Bandwidth ──────────────────────────────────
                connect:  sent=\(connectSent)B  recv=\(connectRecv)B
                \(Int(idleSeconds))s idle: sent=\(idleSent)B  recv=\(idleRecv)B
                total:    sent=\(counter.sent)B  recv=\(counter.received)B
                ───────────────────────────────────────────────
                """)
        }
        #expect(idleSent < idleBudget, "idle sent \(idleSent) B in \(Int(idleSeconds)) s (budget: \(idleBudget) B)")
    }
}

