// FakeBlackmagicCameraTLS — wraps FakeBlackmagicCamera behind a TLS terminator using
// the committed test identity (Tests/BlackmagicRESTTests/Fixtures/test-identity.p12, pass: testpass).
//
// The fake camera only speaks plain HTTP. This TLS front-end accepts HTTPS/WSS and forwards
// each connection to a new plain-HTTP connection on the inner camera's port.
//
// The test certificate's SHA-256 fingerprint is exposed as a constant so tests can use it
// without recomputing. Generated once with openssl and committed to the repo.

import Foundation
import Network
import CameraKitTestSupport
import Security
import Testing

// MARK: - Known test fingerprint

/// SHA-256 of the leaf certificate in test-identity.p12, hex lowercase.
let testCertificateFingerprint = "68e0c1b3984fc778ddedba7e4f4c25c718c42c024d64af6bee7839a82cf4bb48"

// MARK: - TLS front-end

/// Accepts TLS connections and proxies them as plain HTTP/WS to `innerCamera`.
///
/// URLSession's URLSessionDelegate is used on the client side to handle the self-signed cert.
/// On the server side, NWListener with TLS parameters serves the test identity.
public final class FakeBlackmagicCameraTLS: @unchecked Sendable {

    public private(set) var port: UInt16 = 0
    private let innerCamera: FakeBlackmagicCamera
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "fake-bm-tls", qos: .userInteractive)

    public init(innerCamera: FakeBlackmagicCamera) {
        self.innerCamera = innerCamera
    }

    // MARK: - Start / Stop

    public func start() async throws {
        // On 127.0.0.1 (LoopbackListener), again if the system says the address is in use.
        try await LoopbackListener.retrying { [self] in
            listener?.cancel()
            try await startListening()
        }
    }

    private func startListening() async throws {
        let identity = try loadTestIdentity()
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, identity)
        // Allow any cipher suite; this is a loopback test environment.
        sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)

        let params = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        let l = try LoopbackListener.make(params)
        self.listener = l

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let p = l.port?.rawValue { self?.port = p }
                    if !resumed { resumed = true; cont.resume() }
                case .failed(let e), .waiting(let e):
                    if !resumed { resumed = true; cont.resume(throwing: e) }
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Proxy connections

    private func accept(_ tlsConn: NWConnection) {
        tlsConn.start(queue: queue)
        let innerPort = innerCamera.port
        // Open a plain TCP connection to the inner camera, from a local port of its own (LoopbackTCP); one left waiting
        // (EADDRINUSE) drops the pair, and the client connects again.
        let innerConn = LoopbackTCP.connection(to: innerPort, freshLocalPort: true)
        innerConn.stateUpdateHandler = { state in
            if case .waiting = state { innerConn.cancel(); tlsConn.cancel() }
        }
        innerConn.start(queue: queue)
        pipe(from: tlsConn, to: innerConn)
        pipe(from: innerConn, to: tlsConn)
    }

    private func pipe(from src: NWConnection, to dst: NWConnection) {
        src.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            if let data, !data.isEmpty {
                dst.send(content: data, completion: .idempotent)
                self?.pipe(from: src, to: dst)
            } else if isComplete {
                dst.cancel()
            }
        }
    }

    // MARK: - Load test identity

    private func loadTestIdentity() throws -> sec_identity_t {
        // Bundle.module is the SPM-generated accessor for the test target's resource bundle.
        let p12URL = Bundle.module.url(forResource: "test-identity", withExtension: "p12")!

        let p12Data = try Data(contentsOf: p12URL)
        var items: CFArray?
        var options: [String: Any] = [kSecImportExportPassphrase as String: "testpass"]
        // In memory only: imported into the keychain, it failed (-26276) wherever the login keychain can't be reached,
        // as from a process outside the logged-in session.
        if #available(macOS 15.0, iOS 18.0, *) { options[kSecImportToMemoryOnly as String] = true }
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let arr = items as? [[String: Any]],
              let first = arr.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: "FakeBlackmagicCameraTLS", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to import test identity (status \(status))"])
        }
        return sec_identity_create(identity as! SecIdentity)!
    }
}
