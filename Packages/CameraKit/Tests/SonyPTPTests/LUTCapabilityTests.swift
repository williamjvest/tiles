// LUTCapabilityTests — SonyCameraBackend LUTImportCapable: slot listing and error mapping.
import Testing
import Foundation
import Network
@testable import SonyPTP
import CameraCore

@Suite("LUT Capability — SonyPTP", .serialized)
struct LUTCapabilityTests {

    private func connectedBackend(_ cam: FakePTPIPCamera) async -> (SonyCameraBackend, Task<Void, Never>) {
        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        cfg.transport.port = NWEndpoint.Port(rawValue: cam.port)!
        let store = EphemeralIdentityStore(friendlyName: "lut-cap-test")
        let backend = SonyCameraBackend(host: "127.0.0.1", identityStore: store, config: cfg)
        let task = Task.detached { await backend.connect() }
        _ = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected }
        try? await Task.sleep(nanoseconds: 300_000_000)
        return (backend, task)
    }

    // MARK: - lutSlots()

    @Test("lutSlots() returns 16 slots when connected (fake camera serves empty type-3 list)", .timeLimit(.minutes(1)))
    func slotListReturns16() async throws {
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }

        let slots = try await backend.lutSlots()
        #expect(slots.count == 16)
        #expect(slots.map(\.index) == Array(1...16))
        // Fake camera returns empty type-3 list → all slots are unnamed.
        #expect(slots.allSatisfy { $0.name == nil })
    }

    @Test("lutSlots() throws LUTImportError.notConnected when not connected", .timeLimit(.minutes(1)))
    func slotListThrowsWhenDisconnected() async throws {
        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 1
        cfg.transport.port = NWEndpoint.Port(rawValue: 9)!   // refuse-only port
        let store = EphemeralIdentityStore(friendlyName: "lut-cap-test2")
        let backend = SonyCameraBackend(host: "127.0.0.1", identityStore: store, config: cfg)
        do {
            _ = try await backend.lutSlots()
            #expect(Bool(false), "Should have thrown")
        } catch LUTImportError.notConnected {
            // expected
        }
    }

    // MARK: - importLUT(data:name:slot:) error mapping

    @Test("importLUT(data:name:slot:) succeeds on OK result", .timeLimit(.minutes(1)))
    func importCapableSuccess() async throws {
        let cam = FakePTPIPCamera()
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }

        let data = Data("LUT_3D_SIZE 17\n".utf8)
        try await backend.importLUT(data: data, name: "GK SLog3", slot: 4)
        #expect(cam.lastImportSlot == 0x0004)
    }

    @Test("importLUT(data:name:slot:) maps NG Busy → LUTImportError.busy", .timeLimit(.minutes(1)))
    func importCapableBusy() async throws {
        let cam = FakePTPIPCamera()
        cam.config.lutImportResult = .ngBusy
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }

        do {
            try await backend.importLUT(data: Data("test".utf8), name: "test", slot: 1)
            #expect(Bool(false), "Should have thrown")
        } catch LUTImportError.busy {
            // expected
        }
    }

    @Test("importLUT(data:name:slot:) maps NG Invalid Name → LUTImportError.invalidName", .timeLimit(.minutes(1)))
    func importCapableInvalidName() async throws {
        let cam = FakePTPIPCamera()
        cam.config.lutImportResult = .ngInvalidName
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }

        do {
            try await backend.importLUT(data: Data("test".utf8), name: "bad?name", slot: 2)
            #expect(Bool(false), "Should have thrown")
        } catch LUTImportError.invalidName {
            // expected
        }
    }

    @Test("SonyCameraBackend conforms to LUTImportCapable", .timeLimit(.minutes(1)))
    func sonyConformsToCapable() async throws {
        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 1
        cfg.transport.port = NWEndpoint.Port(rawValue: 9)!
        let store = EphemeralIdentityStore(friendlyName: "lut-cap-test3")
        let backend = SonyCameraBackend(host: "127.0.0.1", identityStore: store, config: cfg)
        let capable: (any LUTImportCapable)? = backend
        #expect(capable != nil)
    }
}
