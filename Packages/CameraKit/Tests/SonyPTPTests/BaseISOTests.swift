// BaseISOTests.swift — setBaseISO two-step command sequence.
// Bug: tapping a base button swapped to the previously-selected ISO for that base
// instead of the base's own native value. Fix: setBaseISO sets 0xD020 then calls
// setISO(nativeValue), so the confirmed state always reflects the base. [iso-base branch]

import Testing
import Foundation
@testable import SonyPTP
import CameraCore
import CameraKitTestSupport
import Network

@Suite("Base ISO — command sequence", .serialized)
struct BaseISOTests {

    // MARK: - Helpers

    private func connectedBackend(_ cam: FakePTPIPCamera) async -> (SonyCameraBackend, Task<Void, Never>) {
        var cfg = SonyBackendConfig()
        cfg.transport.connectTimeout = 5
        let backend = makeBackend(host: "127.0.0.1", port: cam.port, config: cfg)
        let task = Task.detached { await backend.connect() }
        _ = await collectUntil(backend: backend, timeout: 10) {
            $0.connection == .connected && $0.baseISO != nil
        }
        return (backend, task)
    }

    /// Prop writes captured by the fake camera, filtered to the given codes,
    /// as "CODE:HEXDATA" strings in receive order.
    private func propWriteLog(_ cam: FakePTPIPCamera, codes: [UInt16]) -> [String] {
        cam.propWrites
            .filter { codes.contains($0.code) }
            .map { w in
                let code = String(format: "%04X", w.code)
                let hex = w.data.map { String(format: "%02X", $0) }.joined()
                return "\(code):\(hex)"
            }
    }

    // MARK: - Tests

    /// Exposure Index is UINT16: an ISO it can't hold is refused with a warning instead of trapping.
    @Test("ISO above 65535 while the camera uses Exposure Index is refused, not a crash", .timeLimit(.minutes(1)))
    func eiOverflowRefused() async throws {
        var config = FakePTPIPCamera.Config()
        config.exposureIndex = true
        let cam = FakePTPIPCamera(config: config)
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }
        await backend.send(.setISO(102_400))
        #expect(await collectUntil(backend: backend, timeout: 5) { $0.warnings.contains { $0.contains("102400") } } != nil)
        #expect(propWriteLog(cam, codes: [SDIPropCode.exposureIndex.rawValue]).isEmpty)
        await backend.send(.setISO(51_200))
        #expect(await waitUntil(timeout: 5) { !propWriteLog(cam, codes: [SDIPropCode.exposureIndex.rawValue]).isEmpty })
        #expect(propWriteLog(cam, codes: [SDIPropCode.exposureIndex.rawValue]) == ["D022:00C8"])
    }

    /// Switching to Low (800) sets 0xD020=0x02 then sets ISO/0xD21E to 800.
    @Test("setBaseISO Low: sets 0xD020=Low then sets ISO to 800", .timeLimit(.minutes(1)))
    func setBaseLow() async throws {
        let cam = FakePTPIPCamera()
        // Start on High (12800) so switching to Low is a real change.
        cam.config.fakePropData[SDIPropCode.gainBaseIso.rawValue] = Data([0x01])
        cam.config.fakePropData[SDIPropCode.isoSensitivity.rawValue] = uint32LE(12800)
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }

        await backend.send(.setBaseISO(800))
        // Wait for the UI to reflect the new base.
        _ = await collectUntil(backend: backend, timeout: 5) { $0.baseISO?.value == 800 }

        let writes = propWriteLog(cam, codes: [SDIPropCode.gainBaseIso.rawValue,
                                               SDIPropCode.isoSensitivity.rawValue])
        // 0xD020 must be set to Low (0x02).
        #expect(writes.contains("D020:02"), "0xD020 must be set to 0x02 (Low)")
        // 0xD21E must be set to 800 (0x00000320 LE = 20 03 00 00).
        #expect(writes.contains("D21E:20030000"), "0xD21E must be set to 800 after base switch")
        // Base selector must precede ISO write.
        if let baseIdx = writes.firstIndex(where: { $0.hasPrefix("D020:") }),
           let isoIdx  = writes.firstIndex(where: { $0.hasPrefix("D21E:") }) {
            #expect(baseIdx < isoIdx, "0xD020 must be written before 0xD21E")
        }
    }

    /// Switching to High (12800) sets 0xD020=0x01 then sets ISO to 12800.
    @Test("setBaseISO High: sets 0xD020=High then sets ISO to 12800", .timeLimit(.minutes(1)))
    func setBaseHigh() async throws {
        let cam = FakePTPIPCamera()
        // Default starts on Low (800).
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }

        await backend.send(.setBaseISO(12800))
        _ = await collectUntil(backend: backend, timeout: 5) { $0.baseISO?.value == 12800 }

        let writes = propWriteLog(cam, codes: [SDIPropCode.gainBaseIso.rawValue,
                                               SDIPropCode.isoSensitivity.rawValue])
        #expect(writes.contains("D020:01"), "0xD020 must be set to 0x01 (High)")
        // 12800 = 0x00003200 LE = 00 32 00 00.
        #expect(writes.contains("D21E:00320000"), "0xD21E must be set to 12800 after base switch")
        if let baseIdx = writes.firstIndex(where: { $0.hasPrefix("D020:") }),
           let isoIdx  = writes.firstIndex(where: { $0.hasPrefix("D21E:") }) {
            #expect(baseIdx < isoIdx, "0xD020 must be written before 0xD21E")
        }
    }

    /// Tapping the current base still drives 0xD020 + ISO — the camera may remember
    /// a different ISO for that base from a prior manual selection (the original bug).
    @Test("setBaseISO same base: still forces ISO to native base value", .timeLimit(.minutes(1)))
    func setBaseSameBase() async throws {
        let cam = FakePTPIPCamera()
        // Camera is on Low (800) but ISO has drifted to 3200 via a prior manual pick.
        cam.config.fakePropData[SDIPropCode.isoSensitivity.rawValue] = uint32LE(3200)
        try await cam.start()
        defer { cam.stop() }
        let (backend, task) = await connectedBackend(cam)
        defer { task.cancel() }

        await backend.send(.setBaseISO(800))
        // Wait until the ISO write with the expected value lands.
        let expectedISO = SDIPropCode.isoSensitivity.rawValue
        for _ in 0..<200 {
            if cam.propWrites.contains(where: { $0.code == expectedISO }) { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let isoWrites = propWriteLog(cam, codes: [SDIPropCode.isoSensitivity.rawValue])
        // ISO must be forced back to 800 even though the base selector didn't change.
        #expect(isoWrites.contains("D21E:20030000"),
                "ISO must be forced to 800 even when base selector is unchanged (bug: was staying at 3200)")
    }
}

// MARK: - Helpers

private func uint32LE(_ v: UInt32) -> Data {
    var d = Data(); d.appendLE(v); return d
}
