/// twcc-api-demo — runs the real ControlServer on 51800/51801 with the demo lineup.
///
/// Usage:
///   swift run twcc-api-demo
///   TWCC_API_TOKEN=mytoken swift run twcc-api-demo
///
/// Connects A=BURANO, B=FX6, C=FX3, D=FX30 with the mock backend.
/// WebSocket: ws://localhost:51800/  HTTP: http://localhost:51801/

import Foundation
import CameraCore

@MainActor
func run() async {
    let token = ProcessInfo.processInfo.environment["TWCC_API_TOKEN"] ?? "demo-token"

    // Token store that always returns the env token (no Keychain needed in the demo harness).
    let tokenStore = DemoTokenStore(token: token)

    let (cameras, pages) = DashboardStore.demoLineup()
    let store = DashboardStore(
        cameras: cameras,
        pages: pages,
        startCameras: true,
        makeBackend: { camera, _ in
            MockCameraBackend(body: camera.demoBody ?? .fx3,
                              label: camera.slot.label,
                              heartbeat: .seconds(2))
        }
    )

    let server = ControlServer(tokenStore: tokenStore, store: store)
    do {
        try server.start()
    } catch {
        print("[twcc-api-demo] Failed to start: \(error)")
        exit(1)
    }

    // Await startup instead of busy-waiting
    for _ in 0..<50 where !server.isRunning {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    guard server.isRunning else {
        print("[twcc-api-demo] Server did not start in 5 s")
        exit(1)
    }

    print("Tiles Control API — Demo Harness")
    print("WebSocket   ws://\(server.advertiseAddress)")
    print("HTTP        http://\(server.advertiseAddress)")
    print("Token       \(token)")
    print("Cameras: A=BURANO  B=FX6  C=FX3  D=FX30")
    print(#"Auth:  {"type":"auth","token":"\#(token)"}"#)
    print(#"Sub:   {"type":"subscribe"}"#)
    print(#"Set:   {"type":"command","target":{"camera":"C"},"command":{"set":"iso","value":800}}"#)
    print("Ctrl+C to stop")

    // Keep running until Ctrl+C
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        src.setEventHandler {
            src.cancel()
            cont.resume()
        }
        src.resume()
    }

    print("\n[twcc-api-demo] Stopping…")
    server.stop()
}

/// A token store that returns a fixed token (for the demo — no Keychain).
final class DemoTokenStore: ControlServerTokenStore, @unchecked Sendable {
    private let _token: String
    init(token: String) { self._token = token; super.init() }
    override public func token() -> String { _token }
    override public func regenerate() -> String { _token }
}

Task { @MainActor in await run() }
RunLoop.main.run()
