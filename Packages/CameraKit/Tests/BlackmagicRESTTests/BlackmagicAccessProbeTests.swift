@testable import CameraCore
import Foundation
import Testing

/// Add Camera's check of a Blackmagic camera's way in, against the fakes: Remote Control's port asks for the remote
/// password (the TLS front on a fake with a login), Network Access's REST API answers on the plain fake.
@Suite(.serialized)
struct BlackmagicAccessProbeTests {
    /// A fake answering over HTTPS for a login only, as Remote Control's port does.
    private func remoteControl() async throws -> (FakeBlackmagicCamera, FakeBlackmagicCameraTLS) {
        var config = FakeBlackmagicCamera.Config()
        config.login = "\(BlackmagicConnection.remoteControlUser):remote-pass"
        let inner = FakeBlackmagicCamera(config: config)
        try await inner.start()
        let tls = FakeBlackmagicCameraTLS(innerCamera: inner)
        try await tls.start()
        return (inner, tls)
    }

    private func networkAccess() async throws -> FakeBlackmagicCamera {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        return cam
    }

    /// A port nothing listens on: one a fake just had.
    private func closedPort() async throws -> UInt16 {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        let port = cam.port
        cam.stop()
        try await Task.sleep(for: .milliseconds(100))
        return port
    }

    private func remoteURL(_ port: UInt16) -> URL {
        URL(string: "https://127.0.0.1:\(port)/control/api/v1/system/product")!
    }

    @Test("Remote Control's port asking for the remote password: Remote Control")
    func remoteControlOnly() async throws {
        let (inner, tls) = try await remoteControl()
        defer { tls.stop(); inner.stop() }
        let found = await BlackmagicAccessProbe.probe(remote: remoteURL(tls.port),
                                                      networkHost: "127.0.0.1:\(try await closedPort())", timeout: 5)
        #expect(found == .remoteControl)
    }

    @Test("Only the REST API on the plain port: Network Access")
    func networkAccessOnly() async throws {
        let cam = try await networkAccess()
        defer { cam.stop() }
        let found = await BlackmagicAccessProbe.probe(remote: remoteURL(try await closedPort()),
                                                      networkHost: "127.0.0.1:\(cam.port)", timeout: 5)
        #expect(found == .networkAccess)
    }

    @Test("Both answering: Remote Control, which needs no computer")
    func bothPrefersRemoteControl() async throws {
        let (inner, tls) = try await remoteControl()
        let cam = try await networkAccess()
        defer { tls.stop(); inner.stop(); cam.stop() }
        let found = await BlackmagicAccessProbe.probe(remote: remoteURL(tls.port), networkHost: "127.0.0.1:\(cam.port)",
                                                      timeout: 5)
        #expect(found == .remoteControl)
    }

    @Test("Nothing at either: neither")
    func neither() async throws {
        let found = await BlackmagicAccessProbe.probe(remote: remoteURL(try await closedPort()),
                                                      networkHost: "127.0.0.1:\(try await closedPort())", timeout: 5)
        #expect(found == .neither)
    }

    @Test("An address with a port of its own isn't asked: it has said which way in already")
    func addressWithPort() async {
        #expect(await BlackmagicAccessProbe.probe(host: "192.0.2.105:444") == nil)
    }
}
