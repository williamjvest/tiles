import Foundation
import Observation
import Testing
@testable import CameraCore

/// A camera's audio meters change several times a second (a VENICE's ~6): `CameraController` keeps them out of `state`,
/// which every tile reads, so they redraw the Audio tile alone.
@Suite("Audio meters")
struct AudioMeterTests {
    private actor MeterBackend: CameraBackend {
        nonisolated let updates: AsyncStream<CameraState>
        private let continuation: AsyncStream<CameraState>.Continuation

        init() {
            let stream = AsyncStream.makeStream(of: CameraState.self)
            updates = stream.stream
            continuation = stream.continuation
        }

        func push(_ state: CameraState) { continuation.yield(state) }
        func connect() async {}
        func disconnect() async {}
        func send(_ command: CameraCommand) async {}
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var value: Bool { lock.withLock { raised } }
        func raise() { lock.withLock { raised = true } }
    }

    @MainActor private func settle(_ camera: CameraController, _ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @MainActor @Test("Meters go to audioMeters; a change in them alone leaves state alone")
    func metersStayOutOfState() async throws {
        let backend = MeterBackend()
        let camera = CameraController(slot: CameraSlot(label: "V", color: .red, host: "test"), backend: backend)
        camera.start()
        defer { camera.disconnect() }

        var state = CameraState()
        state.connection = .connected
        state.audioMeterCount = 4
        state.audioMeters = [0.1, 0.2, 0.3, 0.4]
        await backend.push(state)
        try await settle(camera) { camera.audioMeters == [0.1, 0.2, 0.3, 0.4] }
        #expect(camera.state.audioMeters == nil)
        #expect(camera.state.audioMeterCount == 4, "the tile is offered from the state")
        #expect(camera.state.offers(.audio))

        let stateRead = Flag(), metersRead = Flag()
        withObservationTracking { _ = camera.state } onChange: { stateRead.raise() }
        withObservationTracking { _ = camera.audioMeters } onChange: { metersRead.raise() }
        state.audioMeters = [0.5, 0.5, 0.5, 0.5]
        await backend.push(state)
        try await settle(camera) { camera.audioMeters == [0.5, 0.5, 0.5, 0.5] }
        #expect(metersRead.value)
        #expect(!stateRead.value, "a meter-only update redrew every tile")

        // Anything else still goes through, and a link that drops takes the meters with it.
        state.connection = .failed("link down")
        await backend.push(state)
        try await settle(camera) { camera.state.connection == .failed("link down") }
        #expect(stateRead.value)
        #expect(camera.audioMeters == nil)
    }

    @MainActor @Test("A controller made with meters in its first state keeps them apart too")
    func initialMeters() {
        var state = CameraState()
        state.connection = .connected
        state.audioMeterCount = 2
        state.audioMeters = [0.25, 0.75]
        let camera = CameraController(slot: CameraSlot(label: "V", color: .red, host: "test"), backend: MockCameraBackend(body: .venice2),
                                      initialState: state)
        #expect(camera.audioMeters == [0.25, 0.75])
        #expect(camera.state.audioMeters == nil)
    }
}
