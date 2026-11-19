// LUTImportCoreTests — MockCameraBackend LUTImportCapable flow.
import Foundation
import Testing
@testable import CameraCore

@Suite("LUT Import — CameraCore mock")
struct LUTImportCoreTests {

    // Fully-connected mock with fast latency.
    private func connectedMock() async -> MockCameraBackend {
        let backend = MockCameraBackend(body: .fx3, latency: .milliseconds(10), connectDelay: .zero, heartbeat: nil)
        await backend.connect()
        // Drain the connect emissions.
        var it = backend.updates.makeAsyncIterator()
        _ = await it.next()  // connecting
        _ = await it.next()  // connected
        return backend
    }

    @Test("lutSlots() returns 16 slots; first few named, rest empty")
    func slotsReturnedWhenConnected() async throws {
        let backend = await connectedMock()
        let slots = try await backend.lutSlots()
        #expect(slots.count == 16)
        #expect(slots.map(\.index) == Array(1...16))
        #expect(slots[0].name == "TW Show LUT")
        #expect(slots[3].name == "GK SLog3 False Color")
        #expect(slots[4].name == nil)
    }

    @Test("lutSlots() throws .notConnected when camera is disconnected")
    func slotsThrowWhenDisconnected() async throws {
        let backend = MockCameraBackend(body: .fx3, latency: .milliseconds(10), connectDelay: .zero, heartbeat: nil)
        do {
            _ = try await backend.lutSlots()
            #expect(Bool(false), "Should have thrown")
        } catch LUTImportError.notConnected {
            // expected
        }
    }

    @Test("importLUT puts the LUT in the picker without making it the active LUT", .timeLimit(.minutes(1)))
    func importAddsLUTToOptions() async throws {
        let backend = MockCameraBackend(body: .fx3, latency: .milliseconds(10), connectDelay: .zero, heartbeat: nil)
        // One iterator for the whole test: the stream is single-consumer, and a second iterator waiting for an update
        // the first already took waits forever (this test hung the whole run that way).
        var updates = backend.updates.makeAsyncIterator()
        await backend.connect()
        _ = await updates.next()  // connecting
        let before = await updates.next()?.lut?.value
        try await backend.importLUT(data: Data("LUT_3D_SIZE 17\n".utf8), name: "Day Exterior 2", slot: 5)
        let after = await updates.next()
        #expect(after?.lut?.options.contains("User 5: Day Exterior 2") == true)
        #expect(after?.lut?.value == before, "loading a LUT into a slot doesn't select it")
        #expect(try await backend.lutSlots()[4].name == "Day Exterior 2")
    }

    @Test("importLUT throws .notConnected when camera is disconnected")
    func importThrowsWhenDisconnected() async throws {
        let backend = MockCameraBackend(body: .fx3, latency: .milliseconds(10), connectDelay: .zero, heartbeat: nil)
        do {
            try await backend.importLUT(data: Data(), name: "test", slot: 1)
            #expect(Bool(false), "Should have thrown")
        } catch LUTImportError.notConnected {
            // expected
        }
    }

    @Test("importLUT throws .other for out-of-range slot")
    func importThrowsForBadSlot() async throws {
        let backend = await connectedMock()
        do {
            try await backend.importLUT(data: Data("test".utf8), name: "test", slot: 0)
            #expect(Bool(false), "Should have thrown")
        } catch LUTImportError.other(_) {
            // expected
        }
        do {
            try await backend.importLUT(data: Data("test".utf8), name: "test", slot: 17)
            #expect(Bool(false), "Should have thrown")
        } catch LUTImportError.other(_) {
            // expected
        }
    }

    @Test("MockCameraBackend conforms to LUTImportCapable")
    func mockConformsToCapable() async {
        let backend = MockCameraBackend(body: .fx3)
        let capable: (any LUTImportCapable)? = backend
        #expect(capable != nil)
    }

    @Test("CameraController exposes lutImporter for mock backend")
    @MainActor func controllerExposesLUTImporter() {
        let backend = MockCameraBackend(body: .fx3)
        let slot = CameraSlot(label: "A", color: .red, host: "test")
        let controller = CameraController(slot: slot, backend: backend)
        #expect(controller.lutImporter != nil)
    }
}
