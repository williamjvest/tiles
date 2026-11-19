// Monitoring feature tests for BlackmagicCameraBackend.

import Testing
import Foundation
import CameraCore
@testable import BlackmagicRESTBackend

@Suite("BlackmagicREST — Monitoring", .serialized)
struct BlackmagicMonitoringTests {

    // MARK: 1. Connect maps look and falseColor from first display

    /// Polls `condition` until it holds or `seconds` pass. The state reflects the first display, so a test that stopped
    /// when the state changed checked the second display before its PUT had landed (flaky under a full run).
    private func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("Look and false color are on when every output shows them", .timeLimit(.minutes(1)))
    func lookAndFalseColorOnEveryOutput() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.displayLUTEnabled = ["LCD": true, "HDMI": true]
        config.falseColorEnabled = ["LCD": false, "HDMI": true]
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        // Every output's overlays come in after connect.
        let state = await collectUntil(backend: backend, timeout: 10) { $0.monitoring?.outputs.count == 2 }
        #expect(state?.look?.value == true)          // LUT on both
        #expect(state?.falseColor?.value == false)   // false color on HDMI only
        #expect(state?.monitoring?.outputs.map(\.name) == ["LCD", "HDMI"])
        #expect(state?.monitoring?.outputs.last?.overlays[.falseColor]?.value == true)
    }

    // MARK: 2. setLook PUTs to every display

    @Test("setLook: PUTs to all displays", .timeLimit(.minutes(1)))
    func setLookPutsToAllDisplays() async throws {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        _ = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected && $0.look != nil }
        await backend.send(.setLook(true))
        let state = try #require(await collectUntil(backend: backend, timeout: 10) { $0.look?.value == true })
        #expect(state.look?.value == true)
        #expect(await eventually { cam.configNow.displayLUTEnabled["LCD"] == true })
        #expect(await eventually { cam.configNow.displayLUTEnabled["HDMI"] == true })
        #expect(cam.displayLUTPutCount >= 2, "Both displays should have received a PUT")
    }

    // MARK: 3. setFalseColor PUTs to every display

    @Test("setFalseColor: PUTs to all displays", .timeLimit(.minutes(1)))
    func setFalseColorPutsToAllDisplays() async throws {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        _ = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected && $0.falseColor != nil }
        await backend.send(.setFalseColor(true))
        let state = try #require(await collectUntil(backend: backend, timeout: 10) { $0.falseColor?.value == true })
        #expect(state.falseColor?.value == true)
        #expect(await eventually { cam.configNow.falseColorEnabled["LCD"] == true })
        #expect(await eventually { cam.configNow.falseColorEnabled["HDMI"] == true })
        #expect(cam.falseColorPutCount >= 2, "Both displays should have received a PUT")
    }

    // MARK: 4. WS push of a display's falseColor updates state

    @Test("WS push of falseColor updates state", .timeLimit(.minutes(1)))
    func wsPushFalseColorUpdatesState() async throws {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        _ = await collectUntil(backend: backend, timeout: 10) {
            $0.connection == .connected && $0.falseColor != nil
        }

        // False color is on when every output shows it: push both, once the backend has subscribed to both.
        #expect(await cam.subscribed(to: "/monitoring/LCD/falseColor"))
        #expect(await cam.subscribed(to: "/monitoring/HDMI/falseColor"))
        cam.pushPropertyChanged("/monitoring/LCD/falseColor", value: ["enabled": true])
        cam.pushPropertyChanged("/monitoring/HDMI/falseColor", value: ["enabled": true])

        let state = await collectUntil(backend: backend, timeout: 5) {
            $0.falseColor?.value == true
        }
        #expect(state?.falseColor?.value == true)
    }

    // MARK: 5. No displays → look and falseColor stay nil

    @Test("No displays: look and falseColor are nil", .timeLimit(.minutes(1)))
    func noDisplaysMeansNilMonitoring() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.displayNames = []
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        // Connected (a nil here passed both checks below), and a moment for the monitoring read that follows.
        _ = try #require(await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected })
        try await Task.sleep(for: .milliseconds(300))
        let state = await backend.state
        #expect(state.look == nil)
        #expect(state.falseColor == nil)
    }

    // MARK: 6. setLUT sends nothing

    @Test("setLUT: no REST call made", .timeLimit(.minutes(1)))
    func setLUTSendsNothing() async throws {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let connected = try #require(await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected })
        // Blackmagic backend never sets lut (presets are whole camera setups, not LUT slots).
        #expect(connected.lut == nil)
        let putsBefore = cam.displayLUTPutCount + cam.falseColorPutCount

        await backend.send(.setLUT("Day Ext"))
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(cam.displayLUTPutCount + cam.falseColorPutCount == putsBefore, "setLUT must not make any REST PUT")
    }

    // MARK: 7. colorBars initial mapping and setColorBars

    @Test("colorBars: mapped on connect; setColorBars PUTs /camera/colorBars", .timeLimit(.minutes(1)))
    func colorBarsMapping() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.colorBarsEnabled = true
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }

        let connected = await collectUntil(backend: backend, timeout: 10) {
            $0.connection == .connected && $0.colorBars != nil
        }
        #expect(connected?.colorBars?.value == true)

        // Sent directly: sending from inside the predicate only happened if the idle backend emitted again.
        await backend.send(.setColorBars(false))
        let state = await collectUntil(backend: backend, timeout: 10) { $0.colorBars?.value == false }
        #expect(state?.colorBars?.value == false)
        #expect(await eventually { cam.configNow.colorBarsEnabled == false })
    }
}
