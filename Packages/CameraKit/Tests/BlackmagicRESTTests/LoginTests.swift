// A Blackmagic camera's network access login: a PYXIS 12K with one set turns down HTTPS without it (401, Basic realm
// 'PYXIS 12K', Camera 10.3.1). Tiles sends it with every request and the WebSocket's opening one.

import Testing
import Foundation
import CameraCore
@testable import BlackmagicRESTBackend

@Suite("BlackmagicREST — login", .serialized)
struct LoginTests {
    private func connect(_ cameraLogin: String?, with login: BlackmagicLogin?)
        async throws -> (FakeBlackmagicCamera, BlackmagicCameraBackend, Task<Void, Never>, CameraState?) {
        var config = FakeBlackmagicCamera.Config()
        config.login = cameraLogin
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        let backend = makeBackendDirectly(cam: cam, login: login)
        let t = Task.detached { await backend.connect() }
        let state = await collectUntil(backend: backend) {
            if case .failed = $0.connection { return true }
            return $0.connection == .connected
        }
        return (cam, backend, t, state)
    }

    @Test("A camera with a login: connected with it, REST and events", .timeLimit(.minutes(1)))
    func withTheLogin() async throws {
        let (cam, _, t, state) = try await connect("crew:test-password", with: BlackmagicLogin(user: "crew", password: "test-password"))
        defer { cam.stop(); t.cancel() }
        #expect(state?.connection == .connected)
        #expect(state?.iso != nil)
        #expect(await cam.subscribed(to: "/transports/0/record"))
    }

    @Test("Without the login, Tiles says the camera wants one", .timeLimit(.minutes(1)))
    func withoutALogin() async throws {
        let (cam, _, t, state) = try await connect("crew:test-password", with: nil)
        defer { cam.stop(); t.cancel() }
        #expect(state?.connection == .failed(BlackmagicError.login(sent: false).description))
        #expect(BlackmagicError.login(sent: false).description.contains("wants a login"))
    }

    @Test("A wrong login: Tiles says it was turned down", .timeLimit(.minutes(1)))
    func wrongLogin() async throws {
        let (cam, _, t, state) = try await connect("crew:test-password", with: BlackmagicLogin(user: "crew", password: "nope"))
        defer { cam.stop(); t.cancel() }
        #expect(state?.connection == .failed(BlackmagicError.login(sent: true).description))
    }

    @Test("A login set for a camera without one: sent, and it connects all the same", .timeLimit(.minutes(1)))
    func loginTheCameraHasnt() async throws {
        let (cam, _, t, state) = try await connect(nil, with: BlackmagicLogin(user: "crew", password: "test-password"))
        defer { cam.stop(); t.cancel() }
        #expect(state?.connection == .connected)
        #expect(cam.loginsSeen > 0)
    }

    @Test("The camera's login is saved with it, and setups from before still load")
    func savedWithTheCamera() throws {
        let old = try JSONDecoder().decode(BlackmagicConnection.self, from: Data(#"{"host":"pyxis-12k.local","useHTTPS":true}"#.utf8))
        #expect(old.username == nil && old.useHTTPS)
        let withLogin = BlackmagicConnection(host: "192.0.2.13", useHTTPS: true, username: "crew")
        let back = try JSONDecoder().decode(BlackmagicConnection.self, from: JSONEncoder().encode(withLogin))
        #expect(back == withLogin && back.username == "crew")
        #expect(BlackmagicLogin(user: "crew", password: "test-password").authorization == "Basic Y3Jldzp0ZXN0LXBhc3N3b3Jk")
    }
}
