@testable import CameraCore
import XCTest
@testable import SonySavona

/// VENICE multicam: VENICE 2s on one page, each on its own Savona connection (a `FakeVeniceCamera` each), and a VENICE
/// beside a demo FX3,
/// with the page's controls linked, through the same `DashboardStore` link fan-out two FX3s or an FX3 and a PYXIS use.
@MainActor
final class VeniceMulticamTests: XCTestCase {
    private var fakes: [FakeVeniceCamera] = []
    private var store: DashboardStore?

    override func tearDown() async throws {
        for camera in store?.cameras ?? [] { camera.disconnect() }
        for fake in fakes { fake.stop() }
        fakes = []
        store = nil
    }

    /// One page, linked: `venices` fake VENICE 2s (A, B, …), and a demo FX3 after them when `fx3`. Waits for every
    /// camera to report.
    private func linkedPage(venices: Int, fx3: Bool = false) async throws -> DashboardStore {
        let letters = ["A", "B", "C", "D"]
        var saved: [SavedCamera] = []
        for index in 0..<venices {
            let fake = FakeVeniceCamera()
            try await fake.start()
            fakes.append(fake)
            saved.append(SavedCamera(slot: CameraSlot(label: letters[index], color: .red, host: fake.host),
                                     connection: .venice(VeniceConnection(host: fake.host))))
        }
        if fx3 {
            saved.append(SavedCamera(slot: CameraSlot(label: letters[saved.count], color: .yellow, host: "192.0.2.30"),
                                     demoBody: .fx3))
        }
        let page = CameraPage(name: "Multicam", cameraIDs: saved.map(\.slot.id))
        let fakes = self.fakes
        let store = DashboardStore(cameras: saved, pages: [page], makeBackend: { camera, _ in
            if case .demo(let body) = camera.connection {
                return MockCameraBackend(body: body, label: camera.slot.label, latency: .milliseconds(1),
                                         connectDelay: .milliseconds(1), heartbeat: nil)
            }
            let fake = fakes.first { $0.host == camera.slot.host }!
            return VeniceCameraBackend(host: fake.host, user: "admin", password: fake.password, label: camera.slot.label)
        })
        self.store = store
        store.setLinking(true, on: page.id)
        for camera in store.cameras {
            try await until("camera \(camera.slot.label) to report") {
                camera.state.connection == .connected && camera.state.hasReported && camera.state.whiteBalance != nil
            }
        }
        return store
    }

    private func until(_ what: String, timeout: Double = 8, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Every write the camera got, to any of `names`.
    private func writes(_ fake: FakeVeniceCamera, to names: Set<String>) -> [[String: MPValue]] {
        fake.setValues.filter { !names.isDisjoint(with: $0.keys) }
    }

    /// Two VENICEs, two connections: neither turned the other's client away, and REC from either rolls and stops both.
    func testLinkedRECRollsAndStopsEveryVENICE() async throws {
        let store = try await linkedPage(venices: 2)
        let a = store.cameras[0], b = store.cameras[1]
        XCTAssertEqual(fakes.map(\.clientsTurnedAway), [0, 0])

        a.send(.record(true))
        try await until("A and B rolling") { a.state.recording.state == .recording && b.state.recording.state == .recording }
        b.send(.record(false))
        try await until("A and B stopped") { a.state.recording.state == .idle && b.state.recording.state == .idle }
        XCTAssertEqual(fakes.map { $0.keysPressed.filter { $0 == "Rec" }.count }, [2, 2], "one press to roll, one to stop, each")
    }

    /// REC is absolute on a VENICE too, where it's a toggle key: a camera already rolling isn't pressed, which would stop
    /// its take.
    func testLinkedRECLeavesARollingVENICERolling() async throws {
        let store = try await linkedPage(venices: 2)
        let a = store.cameras[0], b = store.cameras[1]
        fakes[1].bodyChange(["Storage.Media.Recording": ["media.5": "Recording"]])  // B rolled from its own button
        try await until("B rolling") { b.state.recording.state == .recording }

        a.send(.record(true))
        try await until("A rolling") { a.state.recording.state == .recording }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(fakes[1].keysPressed.contains("Rec"), "B was already rolling")
        XCTAssertEqual(b.state.recording.state, .recording)
    }

    /// White balance, shutter and Select FPS set on one VENICE follow on the other; EI, which isn't linked, doesn't.
    func testLinkedSettingsFollowAcrossVENICEs() async throws {
        let store = try await linkedPage(venices: 2)
        let a = store.cameras[0], b = store.cameras[1]

        a.send(.setKelvin(4300))
        try await until("B at 4300 K") { b.state.whiteBalance?.kelvin.value == 4300 }
        b.send(.setShutterAngle(172.8))
        try await until("A at 172.8°") { a.state.shutterAngle?.value == 172.8 }
        a.send(.setFrameRateVariableRate(30))
        try await until("B's Select FPS at 30") { b.state.frameRate?.variableRate?.value == 30 }

        a.send(.setISO(1600))
        try await until("A at 1600EI") { a.state.iso?.value == 1600 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(b.state.iso?.value, 800, "EI isn't linked")
    }

    /// A VENICE beside an FX3 takes what it can: white balance and REC. What it can't take now isn't sent to it: a
    /// project rate its menu doesn't allow (nothing written, its mediabox reading least of all, which takes no write), a
    /// Select FPS it doesn't list, a setting it has locked. Its queue stays free, so a linked REC right behind them rolls
    /// it at once.
    func testAVENICEBesideAnFX3SkipsWhatItCantTake() async throws {
        let store = try await linkedPage(venices: 1, fx3: true)
        let venice = store.cameras[0], fx3 = store.cameras[1]
        let fake = fakes[0]

        fx3.send(.setKelvin(4300))
        try await until("the VENICE at 4300 K") { venice.state.whiteBalance?.kelvin.value == 4300 }

        let rates: Set<String> = ["P.System.Menu.SystemFrequency", "P.Clip.Mediabox.Video.Format.FrameRate"]
        fx3.send(.setFrameRate("59.94"))  // its menu allows 23.98, 24, 25 and 29.97 in this imager mode
        fx3.send(.setFrameRateVariableRate(120))  // its Select FPS runs 8 to 30 here
        fake.lockChange(["Camera.WhiteBalance.ColorTemperature.Value": "Locked"])
        try await until("white balance locked") { venice.state.whiteBalance?.kelvin.isWritable == false }
        let wbWrites = writes(fake, to: ["Camera.WhiteBalance.ColorTemperature.Value"]).count
        fx3.send(.setKelvin(5000))

        let sent = Date()
        fx3.send(.record(true))
        try await until("the VENICE rolling", timeout: 2) { venice.state.recording.state == .recording }
        XCTAssertLessThan(Date().timeIntervalSince(sent), 1.5, "REC waited behind a write the VENICE couldn't take")
        XCTAssertEqual(writes(fake, to: rates).count, 0, "a project rate the camera doesn't allow was written")
        XCTAssertEqual(writes(fake, to: ["Camera.SlowAndQuickMotion.FrameRate"]).count, 0, "a Select FPS it doesn't list was written")
        XCTAssertEqual(writes(fake, to: ["Camera.WhiteBalance.ColorTemperature.Value"]).count, wbWrites,
                       "white balance was written while locked")
        try await until("the FX3 rolling") { fx3.state.recording.state == .recording }
    }

    /// One VENICE dropping out leaves the rest of the page working: a linked REC still rolls the one that's there.
    func testOneVENICEDroppingLeavesTheOthersWorking() async throws {
        let store = try await linkedPage(venices: 2)
        let a = store.cameras[0], b = store.cameras[1]
        fakes[1].stop()
        try await until("B gone") { b.state.connection != .connected }
        a.send(.record(true))
        try await until("A rolling") { a.state.recording.state == .recording }
        XCTAssertEqual(a.state.connection, .connected)
    }
}
