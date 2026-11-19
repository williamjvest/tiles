@testable import BlackmagicRESTBackend
import CameraCore
import Foundation
import Testing

/// The backend from a saved connection, made as the app makes it (`BlackmagicCameraBackend.make`).
@Suite(.serialized)
struct BackendFactoryTests {
    @Test("Remote Control: port 444 over HTTPS, unless the address names a port")
    func remoteControlAddress() async {
        let backend = BlackmagicCameraBackend.make(BlackmagicConnection(host: "192.0.2.105", remoteControl: true),
                                                   password: "remote-pass")
        #expect(await backend.host == "192.0.2.105:444")
        let url = await backend.restClient.baseURL
        #expect(url.scheme == "https" && url.port == 444)
    }

    @Test("Network Access: the address as entered, HTTP unless HTTPS is on")
    func networkAccessAddress() async {
        let plain = BlackmagicCameraBackend.make(BlackmagicConnection(host: "192.0.2.105"), password: nil)
        #expect(await plain.restClient.baseURL.absoluteString == "http://192.0.2.105/control/api/v1/")
        let secure = BlackmagicCameraBackend.make(BlackmagicConnection(host: "192.0.2.105", useHTTPS: true, username: "crew"),
                                                  password: "pw")
        #expect(await secure.restClient.baseURL.scheme == "https")
    }

    @Test("Remote Control end to end: HTTPS, Blackmagic's user name and the remote password, the certificate taken on first use",
          .timeLimit(.minutes(1)))
    func remoteControlConnects() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.login = "\(BlackmagicConnection.remoteControlUser):remote-pass"
        let inner = FakeBlackmagicCamera(config: config)
        try await inner.start()
        let tls = FakeBlackmagicCameraTLS(innerCamera: inner)
        try await tls.start()
        defer { tls.stop(); inner.stop() }
        let backend = BlackmagicCameraBackend.make(
            BlackmagicConnection(host: "127.0.0.1:\(tls.port)", remoteControl: true), password: "remote-pass")
        let connecting = Task.detached { await backend.connect() }
        defer { connecting.cancel() }
        let state = await collectUntil(backend: backend, timeout: 15) { $0.connection == .connected }
        #expect(state?.connection == .connected)
        #expect(state?.observedFingerprint == testCertificateFingerprint)
        #expect(inner.loginsSeen > 0)
    }

    @Test("Remote Control with the wrong password: the camera's refusal, not a connection", .timeLimit(.minutes(1)))
    func remoteControlWrongPassword() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.login = "\(BlackmagicConnection.remoteControlUser):remote-pass"
        let inner = FakeBlackmagicCamera(config: config)
        try await inner.start()
        let tls = FakeBlackmagicCameraTLS(innerCamera: inner)
        try await tls.start()
        defer { tls.stop(); inner.stop() }
        let backend = BlackmagicCameraBackend.make(
            BlackmagicConnection(host: "127.0.0.1:\(tls.port)", remoteControl: true), password: "wrong")
        let connecting = Task.detached { await backend.connect() }
        defer { connecting.cancel() }
        let state = await collectUntil(backend: backend, timeout: 15) {
            if case .failed = $0.connection { return true }
            return false
        }
        guard case .failed(let reason)? = state?.connection else {
            Issue.record("didn't fail")
            return
        }
        #expect(reason.contains("turned down the remote password"))
        #expect(reason.contains("Remote Control is on"))
    }
}
