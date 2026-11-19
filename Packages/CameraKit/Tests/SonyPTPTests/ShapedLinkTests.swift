// The backend over a slow, laggy link (HaLow-like), and across a link that drops.
// ShapedLink is a TCP proxy between the backend and the fake camera: each direction is paced to a byte
// rate and every chunk is delayed by a fixed one-way latency. `cut()` drops every connection at once.
// `dropRate` (0–1) randomly discards received chunks before forwarding, simulating wireless loss.

import CameraCore
import CameraKitTestSupport
import Foundation
import Network
@testable import SonyPTP
import Testing

final class ShapedLink: @unchecked Sendable {
    private let targetPort: UInt16
    private let oneWayDelay: TimeInterval
    private let bytesPerSecond: Double
    /// Fraction of forwarded data chunks to drop (0 = no loss, 1 = all dropped).
    let dropRate: Double
    private let queue = DispatchQueue(label: "shaped-link")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var silent = false
    /// When each direction's pipe is next free, for pacing: [upstream, downstream].
    private var freeAt: [ObjectIdentifier: DispatchTime] = [:]
    private(set) var port: UInt16 = 0

    init(to targetPort: UInt16, oneWayDelay: TimeInterval, bitsPerSecond: Double, dropRate: Double = 0) {
        self.targetPort = targetPort
        self.oneWayDelay = oneWayDelay
        self.bytesPerSecond = bitsPerSecond / 8
        self.dropRate = dropRate
    }

    func start() async throws {
        // On 127.0.0.1 (LoopbackListener), again if the system says the address is in use.
        try await LoopbackListener.retrying { [self] in
            listener?.cancel()
            try await startListening()
        }
    }

    private func startListening() async throws {
        let listener = try LoopbackListener.make()
        self.listener = listener
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            listener.newConnectionHandler = { [weak self] inbound in self?.accept(inbound) }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = listener.port?.rawValue ?? 0
                    if !resumed { resumed = true; cont.resume() }
                case .failed(let error), .waiting(let error):
                    if !resumed { resumed = true; cont.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Drops every connection, like the link going away.
    func cut() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    /// Keeps every connection open and forwards nothing: a link that dies without either end being told (a cable
    /// pulled a hop away, a node out of range).
    func silence() {
        queue.sync { silent = true }
    }

    func stop() {
        cut()
        listener?.cancel()
    }

    private func accept(_ inbound: NWConnection) {
        // From a local port of its own (LoopbackTCP): the system's pick can collide with a TIME_WAIT, and does so every
        // time. A connect still left waiting would carry nothing for good: drop the pair, as a dead link would, and the
        // camera's client connects again.
        let outbound = LoopbackTCP.connection(to: targetPort, freshLocalPort: true)
        outbound.stateUpdateHandler = { state in
            if case .waiting = state { outbound.cancel(); inbound.cancel() }
        }
        connections += [inbound, outbound]
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        pump(from: inbound, to: outbound)
        pump(from: outbound, to: inbound)
    }

    private func pump(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 1500) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let shouldDrop = self.silent || (self.dropRate > 0 && Double.random(in: 0..<1) < self.dropRate)
                if !shouldDrop {
                    let key = ObjectIdentifier(source)
                    let start = max(DispatchTime.now(), self.freeAt[key] ?? .now())
                    let transmit = Double(data.count) / self.bytesPerSecond
                    self.freeAt[key] = start + transmit
                    self.queue.asyncAfter(deadline: start + transmit + self.oneWayDelay) {
                        sink.send(content: data, completion: .idempotent)
                    }
                }
            }
            if isComplete || error != nil {
                self.queue.asyncAfter(deadline: .now() + self.oneWayDelay) { sink.cancel() }
                return
            }
            self.pump(from: source, to: sink)
        }
    }
}

@Suite("Over a shaped link", .serialized)
struct ShapedLinkTests {
    /// Roughly a two-hop HaLow mesh at 2 MHz on a bad day: 64 kbit/s each way, 150 ms each way.
    static let bitsPerSecond = 64_000.0
    static let oneWayDelay = 0.15

    @Test("Connects and confirms REC over 64 kbit/s with 300 ms round trips", .timeLimit(.minutes(1)))
    func slowLink() async throws {
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }
        let link = ShapedLink(to: cam.port, oneWayDelay: Self.oneWayDelay, bitsPerSecond: Self.bitsPerSecond)
        try await link.start()
        defer { link.stop() }

        let backend = makeBackend(host: "127.0.0.1", port: link.port)
        let started = Date()
        let task = Task.detached { await backend.connect() }
        defer { task.cancel() }
        let ready = await collectUntil(backend: backend, timeout: 20) {
            $0.connection == .connected && $0.recording.state != .unknown
        }
        let connectTime = Date().timeIntervalSince(started)
        #expect(ready != nil)

        let sent = Date()
        await backend.send(.record(true))
        let rolling = await collectUntil(backend: backend, timeout: 10) {
            $0.recording.request == nil && $0.recording.state == .recording
        }
        let recTime = Date().timeIntervalSince(sent)
        #expect(rolling?.recording.failure == nil)
        print(String(format: "shaped link: connected in %.1f s, REC confirmed in %.1f s", connectTime, recTime))
        #expect(connectTime < 10)
        // REC over 64 kbit/s + 300 ms RTT: down + hold + up ≈ 3 PTP round trips = ~3 × 300 ms + transfer time.
        // Budget: 5 s with a 20% safety margin over the worst-case shaped RTT.
        #expect(recTime < 5.0)
    }

    @MainActor @Test("A camera comes back by itself after the link drops", .timeLimit(.minutes(1)))
    func reconnectsAfterADrop() async throws {
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }
        let link = ShapedLink(to: cam.port, oneWayDelay: 0.02, bitsPerSecond: 1_000_000)
        try await link.start()
        defer { link.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        let backend = makeBackend(host: "127.0.0.1", port: link.port, config: cfg)
        let camera = CameraController(slot: CameraSlot(label: "C", color: .yellow, host: "127.0.0.1"), backend: backend)
        camera.start()
        defer { camera.disconnect() }

        func wait(until done: @MainActor () -> Bool, seconds: Double) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !done() && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        try await wait(until: { camera.state.connection == .connected }, seconds: 10)
        #expect(camera.state.connection == .connected)

        link.cut()
        try await wait(until: { camera.state.connection != .connected }, seconds: 15)
        #expect(camera.state.connection != .connected)  // the transport noticed

        try await wait(until: { camera.state.connection == .connected }, seconds: 15)
        #expect(camera.state.connection == .connected)  // and the controller brought it back
    }

    @MainActor @Test("A REC waiting on the camera when the link drops fails, and REC works again after reconnect",
                     .timeLimit(.minutes(1)))
    func recPendingAcrossADrop() async throws {
        let cam = FakePTPIPCamera()
        cam.config.neverConfirmRec = true  // the camera never confirms, so the request is still pending at the cut
        try await cam.start()
        defer { cam.stop() }
        let link = ShapedLink(to: cam.port, oneWayDelay: 0.02, bitsPerSecond: 1_000_000)
        try await link.start()
        defer { link.stop() }
        var cfg = SonyBackendConfig()
        cfg.recConfirmTimeout = 30
        let backend = makeBackend(host: "127.0.0.1", port: link.port, config: cfg)
        let camera = CameraController(slot: CameraSlot(label: "C", color: .yellow, host: "127.0.0.1"), backend: backend)
        camera.start()
        defer { camera.disconnect() }
        func wait(until done: @MainActor () -> Bool, seconds: Double) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !done() && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        try await wait(until: { camera.state.connection == .connected && camera.state.recording.state != .unknown },
                       seconds: 10)
        camera.send(.record(true))
        try await wait(until: { camera.state.recording.request != nil }, seconds: 5)
        #expect(camera.state.recording.request != nil)

        link.cut()
        try await wait(until: { camera.state.recording.request == nil }, seconds: 15)
        #expect(camera.state.recording.request == nil)  // not stuck, which would block every later REC
        // Which failure depends on where the cut lands: after the REC transaction (waiting on the camera) or during it,
        // which a loaded machine makes likely on this 1 Mbit link. Either way REC isn't stuck and says why.
        #expect([RecordingControl.Failure.lost, RecordingControl.Failure.notSent].contains(camera.state.recording.failure ?? ""),
                "unexpected REC failure: \(camera.state.recording.failure ?? "nil")")

        cam.config.neverConfirmRec = false
        try await wait(until: { camera.state.connection == .connected && camera.state.recording.state != .unknown },
                       seconds: 15)
        camera.send(.record(true))
        try await wait(until: { camera.state.recording.state == .recording && camera.state.recording.request == nil },
                       seconds: 10)
        #expect(camera.state.recording.state == .recording)
    }

    /// The backend's state once `done` holds, read from the backend itself, 10 s at most: its updates stream still holds
    /// what it sent before (here, the first connect's session), and a wait on it can match that.
    private func stateWhen(_ backend: SonyCameraBackend, _ done: (CameraState) -> Bool) async -> CameraState? {
        for _ in 0 ..< 200 {
            let state = await backend.state
            if done(state) { return state }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    @Test("Two overlapping connects end in one working session", .timeLimit(.minutes(1)))
    func overlappingConnects() async throws {
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }
        let backend = makeBackend(host: "127.0.0.1", port: cam.port)
        let first = Task.detached { await backend.connect() }
        try await Task.sleep(nanoseconds: 20_000_000)
        let second = Task.detached { await backend.connect() }  // e.g. a retry and a return from the background
        defer { first.cancel(); second.cancel() }
        // Both connects over (each returns once its session is up, or given way to the other), then the session they
        // left. Waiting on the updates instead caught the first connect's session, often up within the 20 ms, and the
        // REC sent then went nowhere while the second was replacing it: the old check of REC passed on a nil.
        await first.value
        await second.value
        let ready = await stateWhen(backend) { $0.connection == .connected && $0.recording.state != .unknown }
        let now = await backend.state
        #expect(ready != nil, "\(now.connection), REC \(now.recording.state)")
        await backend.send(.record(true))
        let rolling = await stateWhen(backend) { $0.recording.request == nil && $0.recording.state == .recording }
        #expect(rolling != nil && rolling?.recording.failure == nil, "REC \(now.recording.state), \(rolling?.recording.failure ?? "")")
    }

    /// CameraController retries after failure and eventually connects when the camera becomes ready.
    @MainActor @Test("Controller retries after failure and connects when camera is ready", .timeLimit(.minutes(1)))
    func reconnectAfterFailure() async throws {
        // Camera that rejects the init request (simulates camera busy / not yet ready)
        var camCfg = FakePTPIPCamera.Config()
        camCfg.rejectInit = true
        let cam = FakePTPIPCamera(config: camCfg)
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 3
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        // 100 ms retry so we don't wait 1 s between attempts.
        let camera = CameraController(slot: CameraSlot(label: "C", color: .yellow, host: "127.0.0.1"),
                                      backend: backend, initialRetryDelay: 0.1)
        camera.start()
        defer { camera.disconnect() }

        func wait(until done: @MainActor () -> Bool, seconds: Double) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !done() && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        }

        // Wait for at least one failed/approval state — confirms the controller tried at least once
        try await wait(until: {
            switch camera.state.connection {
            case .failed, .awaitingApproval: return true
            default: return false
            }
        }, seconds: 10)
        let sawFailure: Bool
        switch camera.state.connection {
        case .failed, .awaitingApproval: sawFailure = true
        default: sawFailure = false
        }
        #expect(sawFailure, "Expected a failed/awaitingApproval state after rejected init")

        // Now let the camera accept: the app is asking again every second on a fresh connection, so it gets in.
        cam.config.rejectInit = false
        try await wait(until: { camera.state.connection == .connected }, seconds: 20)
        #expect(camera.state.connection == .connected, "Controller should reconnect once camera accepts")
    }

    /// A link that goes silent, connections still open (a cable pulled a hop away): only a probe that gets no answer
    /// can tell, since over the SSH tunnel the probe's own send always succeeds. It took 30+ s on a real iPad.
    @MainActor @Test("A link that goes silent is noticed within probeInterval + probeTimeout", .timeLimit(.minutes(1)))
    func silentLinkDetection() async throws {
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }
        let link = ShapedLink(to: cam.port, oneWayDelay: 0.01, bitsPerSecond: 10_000_000)
        try await link.start()
        defer { link.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.probeInterval = 1
        cfg.transport.probeTimeout = 1
        cfg.transport.connectTimeout = 10
        cfg.pollInterval = 60
        let backend = makeBackend(host: "127.0.0.1", port: link.port, config: cfg)
        let camera = CameraController(slot: CameraSlot(label: "C", color: .yellow, host: "127.0.0.1"), backend: backend)
        camera.start()
        defer { camera.disconnect() }
        #expect(await waitUntilMain(timeout: 30) { camera.state.connection == .connected })

        link.silence()
        let silenced = Date()
        let noticed = await waitUntilMain(timeout: 10) {
            if case .failed = camera.state.connection { return true }
            return camera.state.connection == .disconnected
        }
        #expect(noticed)
        // Quiet and the timeout are each checked on a 1 s tick, so the worst case is interval + timeout + 2 s; a
        // second more covers a loaded test run.
        #expect(Date().timeIntervalSince(silenced) < cfg.transport.probeInterval + cfg.transport.probeTimeout + 3)
    }

    /// A link that closes (the far end's connection goes away) is seen at once.
    @MainActor @Test("A link that closes is seen within probeInterval + probeTimeout", .timeLimit(.minutes(1)))
    func halfOpenTCPDetection() async throws {
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }
        let link = ShapedLink(to: cam.port, oneWayDelay: 0.01, bitsPerSecond: 10_000_000)
        try await link.start()
        defer { link.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.probeInterval = 2.0  // short for test speed
        cfg.transport.probeTimeout = 4.0
        cfg.transport.connectTimeout = 10
        let backend = makeBackend(host: "127.0.0.1", port: link.port, config: cfg)
        let camera = CameraController(slot: CameraSlot(label: "C", color: .yellow, host: "127.0.0.1"), backend: backend)
        camera.start()
        defer { camera.disconnect() }

        func wait(until done: @MainActor () -> Bool, seconds: Double) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !done() && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        }

        // Give ample time to connect — the suite is serialized and may run after long tests
        try await wait(until: { camera.state.connection == .connected }, seconds: 30)
        guard camera.state.connection == .connected else {
            // Can't test probe detection if we never connected; fail with a clear message
            #expect(Bool(false), "Failed to reach .connected within 30 s — can't test half-open detection")
            return
        }

        // Drop the link silently (no RST) — simulates a dead HaLow link
        link.cut()
        let t0 = Date()

        // Must detect failure within probeInterval + probeTimeout + some tolerance
        let maxDetect = cfg.transport.probeInterval + cfg.transport.probeTimeout + 3.0
        try await wait(until: {
            if case .failed = camera.state.connection { return true }
            if case .disconnected = camera.state.connection { return true }
            return false
        }, seconds: maxDetect + 2)
        let elapsed = Date().timeIntervalSince(t0)

        #expect(elapsed <= maxDetect + 1, "Dead link not detected in time: \(elapsed)s (limit \(maxDetect)s)")
    }

    /// Camera stops answering mid-fetch (e.g. power off): the transaction timeout fires and the connection fails.
    @MainActor @Test("Transaction timeout fires when camera goes silent mid-fetch", .timeLimit(.minutes(1)))
    func silentCameraDetected() async throws {
        // Camera drops after 5 transactions (session open, a few sdio ops, then the prop fetch starts)
        var camCfg = FakePTPIPCamera.Config()
        camCfg.killAfterTransactions = 7  // die mid-way through session setup
        let cam = FakePTPIPCamera(config: camCfg)
        try await cam.start()
        defer { cam.stop() }

        var cfg = SonyBackendConfig()
        cfg.transport.transactionTimeout = 5.0  // short for test speed
        cfg.transport.connectTimeout = 10
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let camera = CameraController(slot: CameraSlot(label: "C", color: .yellow, host: "127.0.0.1"), backend: backend)
        camera.start()
        defer { camera.disconnect() }

        func wait(until done: @MainActor () -> Bool, seconds: Double) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !done() && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        }

        // Should fail within transactionTimeout + connect time
        try await wait(until: {
            if case .failed = camera.state.connection { return true }
            if case .disconnected = camera.state.connection { return true }
            return false
        }, seconds: 30)

        if case .failed = camera.state.connection { }
        else { #expect(camera.state.connection == .disconnected, "Camera going silent mid-fetch should fail the connection") }
    }
}

