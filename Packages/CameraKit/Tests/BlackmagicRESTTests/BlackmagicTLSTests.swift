// TLS / HTTPS tests for BlackmagicCameraBackend.
//
// Covers:
//   1. HTTPS connect works and the certificate fingerprint is reported (TOFU — no pin yet).
//   2. A matching pin connects successfully.
//   3. A mismatched pin yields `.fingerprintChanged` and no traffic beyond the handshake.
//   4. Plain HTTP is unchanged (regression).
//   5. Old saved setups without `useHTTPS` / `pinnedCertificateFingerprint` decode correctly.

import Testing
import Foundation
import CameraCore
@testable import BlackmagicRESTBackend

// MARK: - Helpers

/// Make a TLS-enabled backend with the given pin (nil = TOFU).
func makeTLSBackend(tlsCam: FakeBlackmagicCameraTLS,
                    pinnedFingerprint: String? = nil) -> (BlackmagicCameraBackend, BlackmagicTLSDelegate) {
    let delegate = BlackmagicTLSDelegate()
    delegate.pinnedFingerprint = pinnedFingerprint
    let config = URLSessionConfiguration.ephemeral
    // Allow localhost connections without ATS restrictions.
    config.tlsMinimumSupportedProtocolVersion = .TLSv12
    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    let backend = BlackmagicCameraBackend(
        host: "127.0.0.1:\(tlsCam.port)",
        useHTTPS: true,
        tlsSession: session,
        delegate: delegate
    )
    return (backend, delegate)
}

// MARK: - TLS test suite

@Suite("BlackmagicREST — TLS / HTTPS", .serialized)
struct BlackmagicTLSTests {

    // MARK: 1. TOFU: no pin → accept and report fingerprint

    @Test("TOFU: HTTPS connect with no pin reports fingerprint and reaches .connected", .timeLimit(.minutes(1)))
    func tofuNoPinReportsFingerprint() async throws {
        let inner = FakeBlackmagicCamera()
        try await inner.start()
        defer { inner.stop() }

        let tls = FakeBlackmagicCameraTLS(innerCamera: inner)
        try await tls.start()
        defer { tls.stop() }

        let (backend, _) = makeTLSBackend(tlsCam: tls, pinnedFingerprint: nil)
        let connectTask = Task.detached { await backend.connect() }
        defer { connectTask.cancel() }

        // We expect: observedFingerprint is set, then connection reaches .connected.
        let state = await collectUntil(backend: backend, timeout: 15) {
            $0.connection == .connected && $0.observedFingerprint != nil
        }
        #expect(state?.connection == .connected)
        #expect(state?.observedFingerprint == testCertificateFingerprint)
    }

    // MARK: 2. Matching pin → connect succeeds

    @Test("Matching pin: HTTPS connect succeeds", .timeLimit(.minutes(1)))
    func matchingPinConnects() async throws {
        let inner = FakeBlackmagicCamera()
        try await inner.start()
        defer { inner.stop() }

        let tls = FakeBlackmagicCameraTLS(innerCamera: inner)
        try await tls.start()
        defer { tls.stop() }

        let (backend, _) = makeTLSBackend(tlsCam: tls, pinnedFingerprint: testCertificateFingerprint)
        let connectTask = Task.detached { await backend.connect() }
        defer { connectTask.cancel() }

        let state = await collectUntil(backend: backend, timeout: 15) {
            $0.connection == .connected
        }
        #expect(state?.connection == .connected)
    }

    // MARK: 3. Mismatched pin → fingerprintChanged, no further traffic

    @Test("Mismatched pin: connection stops with .fingerprintChanged", .timeLimit(.minutes(1)))
    func mismatchedPinGivesFingerprintChanged() async throws {
        let inner = FakeBlackmagicCamera()
        try await inner.start()
        defer { inner.stop() }

        let tls = FakeBlackmagicCameraTLS(innerCamera: inner)
        try await tls.start()
        defer { tls.stop() }

        let wrongPin = "0000000000000000000000000000000000000000000000000000000000000000"
        let (backend, _) = makeTLSBackend(tlsCam: tls, pinnedFingerprint: wrongPin)
        let connectTask = Task.detached { await backend.connect() }
        defer { connectTask.cancel() }

        let state = await collectUntil(backend: backend, timeout: 15) {
            if case .fingerprintChanged = $0.connection { return true }
            return false
        }
        guard case .fingerprintChanged(let observed) = state?.connection else {
            Issue.record("Expected .fingerprintChanged, got \(String(describing: state?.connection))")
            return
        }
        // The observed fingerprint should be the actual cert fingerprint.
        #expect(observed == testCertificateFingerprint)
        // The backend must never have reached .connected.
        #expect(state?.connection != .connected)
        // No REST calls should have succeeded (product name not set).
        #expect(state?.model == nil)
    }

    // MARK: 4. Plain HTTP regression: existing HTTP path unchanged

    @Test("Plain HTTP: connect still works (regression)", .timeLimit(.minutes(1)))
    func plainHTTPRegression() async throws {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        defer { cam.stop() }

        let backend = makeBackendDirectly(cam: cam)
        let connectTask = Task.detached { await backend.connect() }
        defer { connectTask.cancel() }

        let state = await collectUntil(backend: backend, timeout: 10) { $0.connection == .connected }
        #expect(state?.connection == .connected)
        #expect(state?.model == "PYXIS 12K")
    }

    // MARK: 5. Legacy Codable: old saved setups decode

    @Test("BlackmagicConnection: old setup without useHTTPS/pinnedFingerprint decodes to defaults")
    func legacyCodableDecodes() throws {
        let json = #"{"host":"192.168.1.42"}"#
        let conn = try JSONDecoder().decode(BlackmagicConnection.self, from: Data(json.utf8))
        #expect(conn.host == "192.168.1.42")
        #expect(conn.useHTTPS == false)
        #expect(conn.pinnedCertificateFingerprint == nil)
    }

    @Test("BlackmagicConnection: full setup round-trips through Codable")
    func fullCodableRoundTrip() throws {
        let original = BlackmagicConnection(
            host: "pyxis-12k.local",
            useHTTPS: true,
            pinnedCertificateFingerprint: testCertificateFingerprint
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BlackmagicConnection.self, from: data)
        #expect(decoded.host == original.host)
        #expect(decoded.useHTTPS == original.useHTTPS)
        #expect(decoded.pinnedCertificateFingerprint == original.pinnedCertificateFingerprint)
    }
}
