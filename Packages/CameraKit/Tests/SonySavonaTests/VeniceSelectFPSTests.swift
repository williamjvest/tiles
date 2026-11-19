@testable import CameraCore
import XCTest
@testable import SonySavona

/// Select FPS follows the imager mode: Tiles must never offer a frame rate the camera can't take for the imager mode it's
/// in. 8.6K 3:2 tops out
/// at 30 and 8.6K 17:9 at 48 (Sony's VENICE 2 manual p. 49), so Tiles must never offer 48 in open gate: not from Sony's
/// table, which VENICE 2's imager mode reached as its menu value ("17") rather than its name, and not from a list the
/// camera gave for the mode it was in before.
final class VeniceSelectFPSTests: XCTestCase {
    private var camera: FakeVeniceCamera!
    private var backend: VeniceCameraBackend!
    private let latest = Latest()
    private var listening: Task<Void, Never>?

    final class Latest: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = CameraState()
        var value: CameraState { lock.withLock { stored } }
        func set(_ state: CameraState) { lock.withLock { stored = state } }
    }

    private static let sq = "Camera.SlowAndQuickMotion.FrameRate"

    private func connect(values: [String: MPValue] = [:], lists: [String: [MPValue]?] = [:]) async throws {
        camera = FakeVeniceCamera()
        camera.preset(values: values, lists: lists)
        try await camera.start()
        backend = VeniceCameraBackend(host: camera.host, user: "admin", password: camera.password)
        let updates = backend.updates
        let latest = latest
        listening = Task { for await state in updates { latest.set(state) } }
        await backend.connect()
        try await until("connected") { $0.connection == .connected && $0.frameRate?.variableRate != nil }
    }

    override func tearDown() async throws {
        await backend?.disconnect()
        listening?.cancel()
        camera?.stop()
    }

    private func until(_ what: String, timeout: Double = 5, _ condition: (CameraState) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(latest.value) {
            guard Date() < deadline else {
                return XCTFail("timed out waiting for \(what): Select FPS \(latest.value.frameRate?.variableRate?.options ?? [])")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private var topRate: Double? { latest.value.frameRate?.variableRate?.options.max() }

    /// No list from the camera: Sony's table for the mode by its name, in 8.6K 3:2 and again once it's 8.6K 17:9.
    func testWithoutTheCamerasListSonysTableForTheImagerModeStandsIn() async throws {
        try await connect(lists: [Self.sq: nil])
        XCTAssertEqual(latest.value.resolution?.value, "8.6K 3:2")
        XCTAssertEqual(topRate, 30, "8.6K 3:2 tops out at 30")
        XCTAssertEqual(latest.value.frameRate?.variableRate?.options.min(), 8, "nothing under 8 at the high base (3200)")
        camera.bodyChange(["P.System.Menu.CamImagermode": "18"])
        try await until("8.6K 17:9's 48") { $0.resolution?.value == "8.6K 17:9" && $0.frameRate?.variableRate?.options.max() == 48 }
    }

    /// Connected in 8.6K 17:9 (Select FPS to 48), then open gate: the camera answers its new list when asked but says
    /// nothing, and the list from 17:9 mustn't stay up.
    func testTheListIsReadAgainWhenTheImagerModeChanges() async throws {
        try await connect(values: ["P.System.Menu.CamImagermode": "18"],
                          lists: [Self.sq: (8...48).map { MPValue.int(Int64($0)) }])
        XCTAssertEqual(topRate, 48)
        camera.quietlyRelist(Self.sq, (8...30).map { MPValue.int(Int64($0)) })
        camera.bodyChange(["P.System.Menu.CamImagermode": "17"])
        try await until("8.6K 3:2's 30") { $0.resolution?.value == "8.6K 3:2" && $0.frameRate?.variableRate?.options.max() == 30 }
        // And it's the camera's own list once it has answered, not only the table's.
        camera.quietlyRelist(Self.sq, (8...29).map { MPValue.int(Int64($0)) })
        camera.bodyChange(["P.System.Menu.CamImagermode": "18"])
        camera.quietlyRelist(Self.sq, (8...47).map { MPValue.int(Int64($0)) })
        try await until("the camera's 47", timeout: 6) { $0.frameRate?.variableRate?.options.max() == 47 }
    }

    /// A rate the list doesn't hold isn't sent: 48 in open gate stays on the iPad.
    func testFortyEightIsNotSentInOpenGate() async throws {
        try await connect(lists: [Self.sq: nil])
        await backend.send(.setFrameRateVariableRate(48))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNotEqual(camera.value(Self.sq), .int(48), "48 went to a camera in 8.6K 3:2")
    }
}
