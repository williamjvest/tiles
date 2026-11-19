@testable import BlackmagicRESTBackend
import CameraCore
import Foundation
import Testing

/// A camera on a USB cable: found at each connect (`findAddress`), its clients pointed where it is.
@Suite(.serialized)
struct USBConnectTests {
    @Test("Found at each connect: plugged in again at another address, it's reached there, under the same name",
          .timeLimit(.minutes(1)))
    func foundEachConnect() async throws {
        var first = FakeBlackmagicCamera.Config()
        first.iso = 800
        var second = FakeBlackmagicCamera.Config()
        second.iso = 1600
        let a = FakeBlackmagicCamera(config: first), b = FakeBlackmagicCamera(config: second)
        try await a.start()
        try await b.start()
        defer { a.stop(); b.stop() }
        let place = Place("127.0.0.1:\(a.port)")
        let backend = BlackmagicCameraBackend(host: "usb:0123", urlSession: URLSession(configuration: .ephemeral),
                                              findAddress: { place.address })
        let one = Task.detached { await backend.connect() }
        defer { one.cancel() }
        let atFirst = await collectUntil(backend: backend) { $0.connection == .connected && $0.iso != nil }
        #expect(atFirst?.iso?.value == 800)

        await backend.disconnect()
        _ = await collectUntil(backend: backend, timeout: 5) { $0.connection == .disconnected }
        place.address = "127.0.0.1:\(b.port)"
        let two = Task.detached { await backend.connect() }
        defer { two.cancel() }
        let atSecond = await collectUntil(backend: backend) { $0.connection == .connected && $0.iso?.value == 1600 }
        #expect(atSecond?.iso?.value == 1600)
        #expect(await backend.host == "usb:0123")
        #expect(await backend.address == "127.0.0.1:\(b.port)")
    }

    @Test("Not found: the connection fails with what's wrong", .timeLimit(.minutes(1)))
    func notFound() async {
        let backend = BlackmagicCameraBackend(host: "usb:0123", findAddress: { throw BlackmagicUSBLink.Problem.notConnected })
        let connecting = Task.detached { await backend.connect() }
        defer { connecting.cancel() }
        let state = await collectUntil(backend: backend, timeout: 5) { $0.connection.isFailed }
        #expect(state?.connection == .failed(BlackmagicUSBLink.Problem.notConnected.description))
    }

    @Test("A disconnect while the camera's being found: the connect gives way", .timeLimit(.minutes(1)))
    func disconnectWhileFinding() async throws {
        let cam = FakeBlackmagicCamera()
        try await cam.start()
        defer { cam.stop() }
        let port = cam.port
        let backend = BlackmagicCameraBackend(host: "usb:0123", urlSession: URLSession(configuration: .ephemeral),
                                              findAddress: {
            try await Task.sleep(for: .milliseconds(300))
            return "127.0.0.1:\(port)"
        })
        let connecting = Task.detached { await backend.connect() }
        try await Task.sleep(for: .milliseconds(50))
        await backend.disconnect()
        await connecting.value
        #expect(await backend.state.connection == .disconnected)
        #expect(await backend.address == BlackmagicCameraBackend.notFoundYet)
    }

    @Test("Made from a saved usb: connection as the app makes it: looked for on USB, not at the saved name",
          .timeLimit(.minutes(1)))
    func madeForUSB() async {
        let backend = BlackmagicCameraBackend.make(BlackmagicConnection(host: "usb:0000not0a0camera0000", remoteControl: true),
                                                   password: "remote-pass")
        #expect(await backend.host == "usb:0000not0a0camera0000")
        #expect(await backend.address == BlackmagicCameraBackend.notFoundYet)
        let connecting = Task.detached { await backend.connect() }
        defer { connecting.cancel() }
        let state = await collectUntil(backend: backend, timeout: 15) { $0.connection.isFailed }
        #expect(state?.connection == .failed(BlackmagicUSBLink.Problem.notConnected.description))
    }
}

/// Where the fake camera is, changed between connects.
private final class Place: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    init(_ value: String) { self.value = value }
    var address: String {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private extension ConnectionState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
