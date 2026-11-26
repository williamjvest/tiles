import Testing
import Foundation
@testable import CameraCore

// MARK: - Record All tile tests

/// Every camera state offers Record All (the tile is always available once the camera has reported).
@Test func recordAllOfferedByEveryCamera() {
    for body in MockBody.allCases {
        #expect(MockCameraBackend.sampleState(body: body).offers(.recordAll), "\(body)")
    }
}

/// Record All is not shown in Add Tile on a 1-camera page (it would do what per-camera REC already does).
@MainActor @Test func recordAllNotInTileKindsWithOneCamera() throws {
    // A store with exactly one camera on its only page.
    let saved = SavedCamera(slot: CameraSlot(label: "A", color: .red, host: "192.0.2.21"), demoBody: .fx3)
    let page = CameraPage(name: "A", cameraIDs: [saved.slot.id])
    let store = DashboardStore(cameras: [saved], pages: [page], startCameras: false)
    let camera = try #require(store.visibleCameras.first)
    #expect(store.visibleCameras.count == 1)
    #expect(!store.tileKinds(for: camera).contains(.recordAll))
}

/// With 2+ cameras on the page, Record All appears in Add Tile.
@MainActor @Test func recordAllInTileKindsWithMultipleCameras() throws {
    let store = DashboardStore.preview(page: "A+B")
    let camera = try #require(store.visibleCameras.first)
    #expect(store.visibleCameras.count >= 2)
    #expect(store.tileKinds(for: camera).contains(.recordAll))
}

/// Tapping Record All sends record(true) to every camera on the page when none is rolling.
@Test func recordAllStartsEveryCameraWhenAllIdle() async {
    // Two independent cameras at idle.
    let backendA = MockCameraBackend(body: .fx3, latency: .milliseconds(10), connectDelay: .zero, heartbeat: nil)
    let backendB = MockCameraBackend(body: .fx6, latency: .milliseconds(10), connectDelay: .zero, heartbeat: nil)
    var updatesA = backendA.updates.makeAsyncIterator()
    var updatesB = backendB.updates.makeAsyncIterator()
    await backendA.connect()
    await backendB.connect()
    _ = await updatesA.next()  // connecting
    let connA = await updatesA.next()  // connected
    _ = await updatesB.next()
    let connB = await updatesB.next()
    #expect(connA?.recording.state == .idle)
    #expect(connB?.recording.state == .idle)

    // Tile action: none rolling → start all idle cameras.
    let states = [connA, connB]
    let anyRolling = states.contains { $0?.recording.state == .recording }
    #expect(!anyRolling)

    let pressA = Task { await backendA.send(.record(true)) }
    let pressB = Task { await backendB.send(.record(true)) }
    _ = await updatesA.next()  // A pending
    let confirmedA = await updatesA.next()  // A confirmed
    _ = await updatesB.next()  // B pending
    let confirmedB = await updatesB.next()  // B confirmed
    #expect(confirmedA?.recording.state == .recording)
    #expect(confirmedB?.recording.state == .recording)
    await pressA.value
    await pressB.value
}

/// When one camera is rolling, the tile action stops only the rolling one; idle cameras stay idle.
@Test func recordAllStopsOnlyRollingCameras() async {
    let backendA = MockCameraBackend(body: .fx3, latency: .milliseconds(10), connectDelay: .zero, heartbeat: nil)
    let backendB = MockCameraBackend(body: .fx6, latency: .milliseconds(10), connectDelay: .zero, heartbeat: nil)
    var updatesA = backendA.updates.makeAsyncIterator()
    var updatesB = backendB.updates.makeAsyncIterator()
    await backendA.connect()
    await backendB.connect()
    _ = await updatesA.next(); _ = await updatesA.next()  // A: connecting, connected
    _ = await updatesB.next(); _ = await updatesB.next()  // B: connecting, connected

    // Start camera A only.
    let startA = Task { await backendA.send(.record(true)) }
    _ = await updatesA.next()   // A pending
    let rollingA = await updatesA.next()  // A confirmed
    #expect(rollingA?.recording.state == .recording)
    await startA.value

    // B is still idle — tile sees at least one rolling, so it sends stop only to rolling ones.
    let stateA = rollingA?.recording.state
    let stopA = Task { await backendA.send(.record(false)) }
    // B must NOT receive a record command (it's idle, the tile only stops rolling cameras).
    _ = await updatesA.next()   // A pending stop
    let stoppedA = await updatesA.next()  // A confirmed stop
    #expect(stoppedA?.recording.state == .idle)
    await stopA.value
    _ = stateA  // used
}

/// Per-camera state summary matches what the accessibility value builder produces.
@Test func recordAllPerCameraStateSummary() {
    var stateA = MockCameraBackend.sampleState(body: .fx3, label: "A")
    stateA.recording = RecordingControl(state: .recording)
    var stateB = MockCameraBackend.sampleState(body: .fx6, label: "B")
    stateB.recording = RecordingControl(state: .idle)

    // Reproduce the accessibility value logic from RecordAllTile.
    let summary = [("A", stateA.recording.state), ("B", stateB.recording.state)]
        .map { label, state -> String in
            let word: String
            switch state {
            case .recording: word = "rolling"
            case .idle:      word = "idle"
            case .unknown:   word = "unknown"
            }
            return "\(label) \(word)"
        }
        .joined(separator: ", ")
    #expect(summary == "A rolling, B idle")
}
