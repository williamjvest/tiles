import CameraKitTestSupport
import Foundation
import Network
import Testing
@testable import CameraCore

// MARK: - Message queue actor

private actor MessageQueue {
    private var messages: [Data] = []
    private var waiters: [(id: UUID, cont: CheckedContinuation<Data?, Never>)] = []

    func enqueue(_ data: Data) {
        if waiters.isEmpty {
            messages.append(data)
        } else {
            waiters.removeFirst().cont.resume(returning: data)
        }
    }

    func dequeue(timeoutSeconds: Double) async -> Data? {
        if !messages.isEmpty { return messages.removeFirst() }
        let id = UUID()
        return await withCheckedContinuation { cont in
            waiters.append((id: id, cont: cont))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                await self?.expire(id: id)
            }
        }
    }

    private func expire(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: idx).cont.resume(returning: nil)
        }
    }
}

// MARK: - WebSocket test client

/// A WebSocket test client on URLSession. Apple's NWConnection WebSocket client aborts with ECONNABORTED on some hosts
/// (even against a minimal Network.framework server), so the suite couldn't tell a server bug from a client one.
/// URLSession's client talks to the server fine there.
private final class WSClient: @unchecked Sendable {
    private var task: URLSessionWebSocketTask?
    private let queue = MessageQueue()

    func connect(port: UInt16) async {
        // ::1, not 127.0.0.1: the server listens on every address on a port the system picks, which can be one another
        // app holds on 127.0.0.1 alone: a test's messages then never came.
        let t = URLSession.shared.webSocketTask(with: URL(string: "ws://[::1]:\(port)/")!)
        task = t
        t.resume()
        startReceiving()
    }

    /// The next receive is armed only after this message is queued, so messages keep the server's order.
    private func startReceiving() {
        task?.receive { [weak self] result in
            guard let self, case .success(let message) = result else { return }
            let data: Data? = switch message {
            case .string(let text): Data(text.utf8)
            case .data(let bytes): bytes
            @unknown default: nil
            }
            Task {
                if let data { await self.queue.enqueue(data) }
                self.startReceiving()
            }
        }
    }

    func send(_ obj: some Encodable) throws {
        sendRaw(try JSONEncoder().encode(obj))
    }

    /// 15 s: the full suite runs ~240 tests at once, and a busy main actor made 5 s too short for a hello.
    func next(timeout: Double = 15) async -> Data? {
        await queue.dequeue(timeoutSeconds: timeout)
    }

    func sendRaw(_ data: Data) {
        task?.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    func disconnect() { task?.cancel(with: .goingAway, reason: nil) }
}

// MARK: - HTTP test helpers

private final class HTTPReader: @unchecked Sendable {
    let conn: NWConnection
    let state: HTTPState
    let cont: CheckedContinuation<(Int, String), Error>

    init(conn: NWConnection, state: HTTPState, cont: CheckedContinuation<(Int, String), Error>) {
        self.conn = conn; self.state = state; self.cont = cont
    }

    func readAll() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if let data { state.buf.append(data) }
            if isComplete || error != nil {
                guard !state.resumed else { return }
                state.resumed = true
                if let raw = String(data: state.buf, encoding: .utf8),
                   let headerEnd = raw.range(of: "\r\n\r\n") {
                    let statusLine = raw.components(separatedBy: "\r\n").first ?? ""
                    let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "0") ?? 0
                    let bodyStr = String(raw[headerEnd.upperBound...])
                    cont.resume(returning: (status, bodyStr))
                } else {
                    cont.resume(throwing: URLError(.badServerResponse))
                }
                return
            }
            readAll()
        }
    }
}

private final class HTTPState: @unchecked Sendable {
    var buf = Data()
    var resumed = false
}

private func httpRequest(
    method: String,
    path: String,
    token: String?,
    body: String? = nil,
    port: UInt16,
    splitAfter splitAt: Int = 0
) async throws -> (Int, String) {
    // A connect turned down with EADDRINUSE is the test machine's, not the server's: try again from a local port of
    // our own choosing, since the system picks the same colliding one every time (LoopbackTCP).
    var attempt = 0
    while true {
        attempt += 1
        do {
            return try await httpRequestOnce(method: method, path: path, token: token, body: body, port: port,
                                             splitAfter: splitAt, freshLocalPort: attempt > 1)
        } catch NWError.posix(.EADDRINUSE) where attempt < 10 {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private func httpRequestOnce(
    method: String,
    path: String,
    token: String?,
    body: String? = nil,
    port: UInt16,
    splitAfter splitAt: Int = 0,
    freshLocalPort: Bool = false
) async throws -> (Int, String) {
    return try await withCheckedThrowingContinuation { cont in
        let q = DispatchQueue(label: "HTTPTestClient")
        let conn = LoopbackTCP.connection(to: port, host: "::1", freshLocalPort: freshLocalPort)
        let state = HTTPState()
        let reader = HTTPReader(conn: conn, state: state, cont: cont)

        conn.stateUpdateHandler = { [conn] connState in
            // A port nobody listens on leaves the connection in .waiting(refused), not .failed: resume with an error
            // so the test fails in a second instead of sitting out its time limit.
            switch connState {
            case .waiting(let error), .failed(let error):
                guard !state.resumed else { return }
                state.resumed = true
                if case .posix(.EADDRINUSE) = error {
                    // Which local port collided (scripts/test-flake-hunt.sh logs carry it). See LoopbackTCP.
                    let local = conn.currentPath?.localEndpoint.map { "\($0)" } ?? "none"
                    FileHandle.standardError.write(Data("EADDRINUSE-DIAG local=\(local) remote=[::1]:\(port)\n".utf8))
                }
                conn.cancel()
                cont.resume(throwing: error)
                return
            case .ready:
                break
            default:
                return
            }
            let bodyBytes = body.map { Data($0.utf8) } ?? Data()
            var req = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\n"
            if let token { req += "X-TWCC-Token: \(token)\r\n" }
            req += "Content-Length: \(bodyBytes.count)\r\n\r\n"
            let headerData = Data(req.utf8)

            if splitAt > 0 && bodyBytes.count > 0 {
                let firstChunk = Data(bodyBytes.prefix(splitAt))
                let rest = Data(bodyBytes.dropFirst(splitAt))
                conn.send(content: headerData + firstChunk, completion: .idempotent)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    conn.send(content: rest, completion: .idempotent)
                }
            } else {
                conn.send(content: headerData + bodyBytes, completion: .idempotent)
            }
            reader.readAll()
        }
        conn.start(queue: q)
    }
}

// MARK: - In-memory token store (avoids Keychain dependency in tests)

/// A non-Keychain token store for testing. Holds a fixed in-memory token.
final class TestTokenStore: ControlServerTokenStore, @unchecked Sendable {
    private let _token: String
    init(token: String = "test-token-\(UUID().uuidString)") { self._token = token; super.init() }
    override public func token() -> String { _token }
    override public func regenerate() -> String { _token }
}

@Test("The token matches only itself: not a prefix, not one longer, not a near miss, not none")
func tokenMatches() {
    let store = TestTokenStore(token: "abc123")
    #expect(store.matches("abc123"))
    for wrong in ["abc12", "abc1234", "abd123", "", "ABC123"] { #expect(!store.matches(wrong), "\(wrong)") }
    #expect(!store.matches(nil))
}

// MARK: - Server factory (ephemeral ports — never binds 51800/51801)

/// Makes a server on random ports so tests never collide with each other or a running app.
/// Finds two unused TCP ports below the ephemeral range (49152–65535), with a simple availability check. Not inside it:
/// the server binds these with reuse (so a restart rebinds at once), and the kernel then handed the same port to
/// other tests' outgoing connections, which failed with EADDRINUSE and left the full run hanging now and then.
private func freePorts() -> (UInt16, UInt16) {
    var used = Set<UInt16>()
    func nextFree() -> UInt16 {
        for _ in 0..<1000 {
            let candidate = UInt16.random(in: 30000...39999)
            guard !used.contains(candidate) else { continue }
            // Quick check: can we bind this port?
            let s = socket(AF_INET, SOCK_STREAM, 0)
            guard s >= 0 else { used.insert(candidate); continue }
            var addr = sockaddr_in()
            addr.sin_family = UInt8(AF_INET)
            addr.sin_port = candidate.bigEndian
            addr.sin_addr.s_addr = 0
            var reuseopt: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &reuseopt, socklen_t(MemoryLayout<Int32>.size))
            let bindResult = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(s)
            if bindResult == 0 {
                used.insert(candidate)
                return candidate
            }
        }
        // Fallback: something in the same range
        return UInt16.random(in: 30000...39999)
    }
    return (nextFree(), nextFree())
}

private struct TestServer {
    let server: ControlServer
    let tokenStore: TestTokenStore
    let wsPort: UInt16
    let httpPort: UInt16
    let store: DashboardStore
}

/// A server on random ephemeral ports over one demo FX3 ("T") and two pages.
/// `connected`: starts the camera and waits until it reports its fields.
/// `fixedPorts`: probes two free ports up front (only needed for the restart test).
private func makeServer(connected: Bool = false, fixedPorts: Bool = false, store given: DashboardStore? = nil) async throws -> TestServer {
    // OS-assigned ports (0) avoid races with other suites' fake cameras. Only the restart test needs
    // fixed ports chosen up front.
    let (wsPort, httpPort): (UInt16, UInt16) = fixedPorts ? freePorts() : (0, 0)
    let tokenStore = TestTokenStore()
    let camera = SavedCamera(slot: CameraSlot(label: "T", color: .red, host: "demo"), demoBody: .fx3)
    let made: DashboardStore
    if let given { made = given } else {
        made = await DashboardStore(
            cameras: [camera],
            pages: [CameraPage(name: "All", showsAllCameras: true), CameraPage(name: "T", cameraIDs: [camera.slot.id])],
            startCameras: connected
        )
    }
    let store = made
    if connected {
        for _ in 0..<500 {
            let ready = await MainActor.run {
                store.cameras.first?.state.connection == .connected && store.cameras.first?.state.iso != nil
            }
            if ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    // advertisesBonjour: false — mDNSResponder serializes registrations and delays .ready by seconds.
    let server = await ControlServer(tokenStore: tokenStore, store: store, wsPort: wsPort, httpPort: httpPort,
                                     advertisesBonjour: false)
    try await MainActor.run { try server.start() }
    for _ in 0..<1000 {
        try await Task.sleep(for: .milliseconds(10))
        let (running, ws, http) = await MainActor.run { (server.isRunning, server.actualWSPort, server.actualHTTPPort) }
        if running && ws != 0 && http != 0 {
            return TestServer(server: server, tokenStore: tokenStore, wsPort: ws, httpPort: http, store: store)
        }
    }
    throw ControlServer.ServerError.listenerFailed("makeServer timed out waiting for isRunning (ports \(wsPort)/\(httpPort))")
}


/// A camera with overlays output by output, like a Blackmagic body: it sets an overlay on every output when told to,
/// and keeps what it was sent.
private actor MonitoringBackend: CameraBackend {
    nonisolated let updates: AsyncStream<CameraState>
    private let continuation: AsyncStream<CameraState>.Continuation
    private var state: CameraState
    private(set) var sent: [CameraCommand] = []

    init(state: CameraState) {
        (updates, continuation) = AsyncStream.makeStream(of: CameraState.self, bufferingPolicy: .bufferingNewest(8))
        self.state = state
    }

    func connect() async { continuation.yield(state) }
    func disconnect() async {}
    func send(_ command: CameraCommand) async {
        sent.append(command)
        guard case .setMonitorOverlay(let overlay, let on, nil) = command, var monitoring = state.monitoring else { return }
        for index in monitoring.outputs.indices where monitoring.outputs[index].overlays[overlay] != nil {
            monitoring.outputs[index].overlays[overlay] = Choice(on, options: [false, true])
        }
        state.monitoring = monitoring
        continuation.yield(state)
    }
}

/// A camera that plays back like a BURANO: Live | Review, and play and pause on one toggle button (Sony's Play Pause,
/// VENICE's Play). Keeps what it was sent.
private actor PlaybackBackend: CameraBackend {
    nonisolated let updates: AsyncStream<CameraState>
    private let continuation: AsyncStream<CameraState>.Continuation
    private var state: CameraState
    private(set) var sent: [CameraCommand] = []

    init() {
        (updates, continuation) = AsyncStream.makeStream(of: CameraState.self, bufferingPolicy: .bufferingNewest(8))
        var state = CameraState()
        state.connection = .connected
        state.recording = RecordingControl(state: .idle)
        state.playback = PlaybackState(
            isPlaying: false, inReview: false, clipName: "A001C003", clipNumber: 3, clipCount: 12,
            capabilities: PlaybackCapabilities(playPause: true, stop: true, nextPrevious: true, seek: false,
                                               fastForwardRewind: true, recReview: true, review: true))
        self.state = state
    }

    func connect() async { continuation.yield(state) }
    func disconnect() async {}
    func send(_ command: CameraCommand) async {
        sent.append(command)
        guard case .playback(let cmd) = command, var pb = state.playback else { return }
        switch cmd {
        case .play, .pause, .togglePlay: pb.isPlaying = !(pb.isPlaying ?? false)
        case .review: pb.inReview = true; pb.isPlaying = true
        case .live: pb.inReview = false; pb.isPlaying = false
        default: break
        }
        state.playback = pb
        continuation.yield(state)
    }
}

/// A connected server over one `PlaybackBackend` camera.
private func makePlaybackServer() async throws -> (TestServer, PlaybackBackend) {
    let backend = PlaybackBackend()
    let camera = SavedCamera(slot: CameraSlot(label: "A", color: .red, host: "burano"),
                             connection: .blackmagic(BlackmagicConnection(host: "burano")))
    let store = await DashboardStore(cameras: [camera], pages: [CameraPage(name: "All", showsAllCameras: true)],
                                     startCameras: true, makeBackend: { _, _ in backend })
    for _ in 0..<500 {
        if await MainActor.run(body: { store.cameras.first?.state.playback != nil }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    return (try await makeServer(store: store), backend)
}

// MARK: - Raw-wire helpers (what Stream Deck and Companion actually see)

/// Reads messages as raw JSON until `done` says so or the deadline passes. Reading a fixed count, or decoding into the
/// server's own types and stopping at the first that didn't decode, made these tests fail on a busy wire.
private func collect(_ client: WSClient, seconds: Double = 15,
                     until done: ([[String: Any]]) -> Bool) async -> [[String: Any]] {
    var messages: [[String: Any]] = []
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        guard let data = await client.next(timeout: max(0.05, deadline.timeIntervalSinceNow)) else { break }
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { messages.append(object) }
        if done(messages) { break }
    }
    return messages
}

/// Auth + subscribe; returns the snapshot's first camera and the snapshot's pages.
private func subscribed(_ client: WSClient, token: String) async throws -> (camera: [String: Any], pages: [[String: Any]]) {
    client.sendRaw(Data(#"{"type":"auth","token":"\#(token)","id":"a"}"#.utf8))
    _ = await collect(client) { $0.contains { $0["type"] as? String == "hello" } }
    client.sendRaw(Data(#"{"type":"subscribe","id":"s"}"#.utf8))
    let snap = await collect(client) { $0.contains { $0["type"] as? String == "snapshot" } }
    let snapshot = try #require(snap.first { $0["type"] as? String == "snapshot" })
    let camera = try #require((snapshot["cameras"] as? [[String: Any]])?.first)
    return (camera, snapshot["pages"] as? [[String: Any]] ?? [])
}

private func results(_ messages: [[String: Any]], id: String) -> [[String: Any]] {
    messages.first { $0["type"] as? String == "result" && $0["id"] as? String == id }?["results"] as? [[String: Any]] ?? []
}

// MARK: - Tests

@Suite("ControlServer", .serialized)
struct ControlServerTests {

    // MARK: WebSocket tests

    @Test("Bad token returns error and closes WS connection", .timeLimit(.minutes(1)))
    func badTokenRejectsWS() async throws {
        let s = try await makeServer()
        defer { Task { @MainActor in s.server.stop() } }

        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }

        client.sendRaw(Data(#"{"type":"auth","id":"r1","token":"bad-token"}"#.utf8))
        let data = await client.next()
        let msg = try #require(data.flatMap { try? JSONDecoder().decode(WireMessage.self, from: $0) })
        guard case .error(_, let code, let text) = msg else {
            Issue.record("Expected error, got: \(msg)"); return
        }
        #expect(code == "auth" || text.localizedLowercase.contains("bad") || text.localizedLowercase.contains("token"))
    }

    @Test("Good token returns hello", .timeLimit(.minutes(1)))
    func goodTokenReturnsHello() async throws {
        let s = try await makeServer()
        defer { Task { @MainActor in s.server.stop() } }
        let token = s.tokenStore.token()

        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }

        client.sendRaw(Data(#"{"type":"auth","id":"r2","token":"\#(token)"}"#.utf8))
        let data = try #require(await client.next())
        let msg = try JSONDecoder().decode(WireMessage.self, from: data)
        guard case .hello(_, _, _, _, let cameras, _, _, _, _) = msg else {
            Issue.record("Expected hello, got: \(msg)"); return
        }
        #expect(cameras.count == 1)
    }

    @Test("Subscribe sends snapshot then changes only", .timeLimit(.minutes(1)))
    func subscribeOnlyReceivesChanges() async throws {
        let s = try await makeServer()
        defer { Task { @MainActor in s.server.stop() } }
        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }
        _ = try await subscribed(client, token: s.tokenStore.token())
        // Nothing changes on an idle store, so nothing may follow the snapshot.
        let extra = await collect(client, seconds: 0.5) { !$0.isEmpty }
        #expect(extra.isEmpty, "Unexpected message after the snapshot: \(extra.map { $0["type"] ?? "?" })")

    }

    @Test("Renaming or removing a camera sends the camera list", .timeLimit(.minutes(1)))
    func cameraListFollowsRenameAndRemoval() async throws {
        let s = try await makeServer()
        defer { Task { @MainActor in s.server.stop() } }
        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }
        let (camera, _) = try await subscribed(client, token: s.tokenStore.token())
        let id = try #require(UUID(uuidString: camera["id"] as? String ?? ""))
        let cameraList = { (messages: [[String: Any]]) in
            messages.last { $0["type"] as? String == "cameras" }?["cameras"] as? [[String: Any]]
        }

        await MainActor.run { s.store.updateCamera(id, label: "U", color: .red, host: "demo", demoBody: .fx3) }
        let renamed = await collect(client) { cameraList($0) != nil }
        #expect(cameraList(renamed)?.map { $0["label"] as? String } == ["U"])

        await MainActor.run { s.store.removeCamera(id) }
        let removed = await collect(client) { cameraList($0) != nil }
        #expect(cameraList(removed)?.isEmpty == true)
    }

    @Test("A client subscribing doesn't swallow a change the others haven't been sent", .timeLimit(.minutes(1)))
    func subscribingFlushesPendingChanges() async throws {
        let s = try await makeServer()
        defer { Task { @MainActor in s.server.stop() } }
        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }
        let (camera, _) = try await subscribed(client, token: s.tokenStore.token())
        let id = try #require(UUID(uuidString: camera["id"] as? String ?? ""))

        // One main-actor turn: the observer can't run between the rename and the second client's snapshot.
        await MainActor.run {
            s.store.updateCamera(id, label: "U", color: .red, host: "demo", demoBody: .fx3)
            _ = s.server.currentSnapshot(store: s.store)
        }
        let messages = await collect(client) { $0.contains { $0["type"] as? String == "cameras" } }
        let list = messages.last { $0["type"] as? String == "cameras" }?["cameras"] as? [[String: Any]]
        #expect(list?.first?["label"] as? String == "U")
    }
    @Test("Unauthenticated subscribe returns auth error", .timeLimit(.minutes(1)))
    func unauthSubscribeReturnsError() async throws {
        let s = try await makeServer()
        defer { Task { @MainActor in s.server.stop() } }

        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }

        client.sendRaw(Data(#"{"type":"subscribe"}"#.utf8))
        let data = await client.next()
        let msg = try #require(data.flatMap { try? JSONDecoder().decode(WireMessage.self, from: $0) })
        if case .error(_, let code, _) = msg {
            #expect(code == "auth")
        } else {
            Issue.record("Expected error for unauthenticated subscribe, got: \(msg)")
        }
    }

    @Test("Inline token command accepted without prior auth", .timeLimit(.minutes(1)))
    func inlineTokenCommandAccepted() async throws {
        let s = try await makeServer()
        defer { Task { @MainActor in s.server.stop() } }
        let token = s.tokenStore.token()

        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }

        // The contract's command with an inline token, on a socket that never sent auth: it must get a result.
        client.sendRaw(Data(#"{"type":"command","id":"inline","token":"\#(token)","target":{"camera":"T"},"command":{"set":"record","value":false}}"#.utf8))
        let messages = await collect(client) { !results($0, id: "inline").isEmpty }
        #expect(messages.contains { $0["type"] as? String == "result" && $0["id"] as? String == "inline" },
                "an inline-token command gets a result, not an auth error")
    }

    @Test("Inline bad token returns auth error", .timeLimit(.minutes(1)))
    func inlineBadTokenReturnsError() async throws {
        let s = try await makeServer()
        defer { Task { @MainActor in s.server.stop() } }

        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }

        client.sendRaw(Data(#"{"type":"command","id":"x","token":"not-the-token","target":{"camera":"T"},"command":{"set":"record","value":false}}"#.utf8))

        let response = await client.next()
        let decoded = try #require(response.flatMap { try? JSONDecoder().decode(WireMessage.self, from: $0) })
        if case .error(_, let code, _) = decoded {
            #expect(code == "auth")
        } else {
            Issue.record("Expected error for bad inline token, got: \(decoded)")
        }
    }

    @Test("Ping returns pong", .timeLimit(.minutes(1)))
    func pingPong() async throws {
        let s = try await makeServer()
        defer { Task { @MainActor in s.server.stop() } }
        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }
        client.sendRaw(Data(#"{"type":"auth","token":"\#(s.tokenStore.token())","id":"a"}"#.utf8))
        _ = await collect(client) { $0.contains { $0["type"] as? String == "hello" } }
        client.sendRaw(Data(#"{"type":"ping","id":"ping-1"}"#.utf8))
        let messages = await collect(client) { $0.contains { $0["type"] as? String == "pong" } }
        #expect(messages.contains { $0["type"] as? String == "pong" && $0["id"] as? String == "ping-1" })

    }

    @Test("Server stop sets isRunning = false", .timeLimit(.minutes(1)))
    func serverStops() async throws {
        let s = try await makeServer()
        let running = await s.server.isRunning
        #expect(running)
        await MainActor.run { s.server.stop() }
        let stopped = await s.server.isRunning
        #expect(!stopped)
    }

    @Test("Same ports after stop/start", .timeLimit(.minutes(1)))
    func samePortsAfterRestart() async throws {
        let s = try await makeServer(fixedPorts: true)
        // stopAndWait ensures the NWListener reaches .canceled (kernel socket released) before we rebind.
        await s.server.stopAndWait()

        // Restart on the same ephemeral ports
        try await MainActor.run { try s.server.start() }
        defer { Task { @MainActor in s.server.stop() } }

        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(10))
            if await s.server.isRunning { break }
        }

        let portError = await s.server.portError
        let running = await s.server.isRunning
        #expect(portError == nil, "Expected no port error after restart, got: \(portError ?? "")")
        #expect(running)
    }

    // MARK: HTTP tests

    @Test("HTTP GET /state with good token returns 200", .timeLimit(.minutes(1)))
    func httpGetStateGoodToken() async throws {
        let s = try await makeServer()
        defer { Task { @MainActor in s.server.stop() } }
        let token = s.tokenStore.token()

        let (status, body) = try await httpRequest(method: "GET", path: "/state",
                                                     token: token, port: s.httpPort)
        #expect(status == 200)
        #expect(body.contains("cameras"))
    }

    /// Stream Deck's current-page keys resolve the camera from the page's list; an All page listed none, so REC refused.
    @Test("An All page lists its cameras", .timeLimit(.minutes(1)))
    func allPageListsItsCameras() async throws {
        let s = try await makeServer()
        defer { Task { @MainActor in s.server.stop() } }
        let token = s.tokenStore.token()
        let (status, body) = try await httpRequest(method: "GET", path: "/state", token: token, port: s.httpPort)
        #expect(status == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let pages = try #require(json["pages"] as? [[String: Any]])
        let all = try #require(pages.first { $0["name"] as? String == "All" })
        let cameraID = await MainActor.run { s.store.cameras[0].id.uuidString }
        #expect(all["cameras"] as? [String] == [cameraID])
    }

    @Test("HTTP GET /state without token returns 401", .timeLimit(.minutes(1)))
    func httpGetStateNoToken() async throws {
        let s = try await makeServer()
        defer { Task { @MainActor in s.server.stop() } }

        let (status, _) = try await httpRequest(method: "GET", path: "/state",
                                                  token: nil, port: s.httpPort)
        #expect(status == 401)
    }

    @Test("HTTP POST /command with valid target returns 200 result", .timeLimit(.minutes(1)))
    func httpPostCommandReachesMockCamera() async throws {
        let s = try await makeServer()
        defer { Task { @MainActor in s.server.stop() } }
        let token = s.tokenStore.token()

        // Use a valid set command to a real target
        let bodyJSON = #"{"target":{"all":true},"command":{"toggle":"falseColor"}}"#
        let (status, body) = try await httpRequest(method: "POST", path: "/command",
                                                    token: token, body: bodyJSON, port: s.httpPort)
        #expect(status == 200)
        #expect(body.contains("result") || body.contains("status"))
    }

    @Test("HTTP body split across two TCP writes still parses", .timeLimit(.minutes(1)))
    func httpBodySplitAcrossPackets() async throws {
        let s = try await makeServer()
        defer { Task { @MainActor in s.server.stop() } }
        let token = s.tokenStore.token()

        let bodyJSON = #"{"target":{"all":true},"command":{"toggle":"falseColor"}}"#
        let (status, _) = try await httpRequest(method: "POST", path: "/command",
                                                 token: token, body: bodyJSON, port: s.httpPort,
                                                 splitAfter: 5)
        #expect(status == 200)
    }

    @Test("HTTP POST /command without token returns 401", .timeLimit(.minutes(1)))
    func httpPostCommandNoToken() async throws {
        let s = try await makeServer()
        defer { Task { @MainActor in s.server.stop() } }

        let (status, _) = try await httpRequest(method: "POST", path: "/command",
                                                  token: nil,
                                                  body: #"{"target":{"all":true},"command":{"toggle":"falseColor"}}"#,
                                                  port: s.httpPort)
        #expect(status == 401)
    }

    @Test("Port-in-use sets portError", .timeLimit(.minutes(1)))
    func portInUseReportsError() async throws {
        // Start first server; then try a second server on the same WS port.
        let s1 = try await makeServer()
        defer { Task { @MainActor in s1.server.stop() } }

        let tokenStore2 = TestTokenStore()
        let store2 = await DashboardStore(cameras: [], pages: [], startCameras: false)
        // Same WS port (testing the conflict), OS-assigned HTTP port.
        let server2 = await ControlServer(tokenStore: tokenStore2, store: store2,
                                          wsPort: s1.wsPort, httpPort: 0)
        try? await MainActor.run { try server2.start() }
        defer { Task { @MainActor in server2.stop() } }

        // The server retries a busy port for about 3 s (a stop/start can find its own port still closing) before
        // it reports it.
        for _ in 0..<60 where await server2.portError == nil {
            try await Task.sleep(for: .milliseconds(100))
        }

        let portError = await server2.portError
        #expect(portError != nil, "Expected portError when port is in use")
        if let e = portError {
            #expect(e.contains(String(s1.wsPort)) || e.contains("in use"), "portError should name the port: \(e)")
        }
    }

    // MARK: Field shape tests

    @Test("snapshot contains cameras with fields", .timeLimit(.minutes(1)))
    func snapshotContainsFields() async throws {
        let s = try await makeServer()
        defer { Task { @MainActor in s.server.stop() } }
        let token = s.tokenStore.token()

        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }

        client.sendRaw(Data(#"{"type":"auth","token":"\#(token)"}"#.utf8))
        _ = await client.next() // hello

        client.sendRaw(Data(#"{"type":"subscribe"}"#.utf8))
        let snap = await client.next()
        let snapData = try #require(snap)
        let msg = try JSONDecoder().decode(WireMessage.self, from: snapData)
        guard case .snapshot(let cameras, _, _, _, _) = msg else {
            Issue.record("Expected snapshot, got \(msg)"); return
        }
        #expect(!cameras.isEmpty)
        // Camera T is an FX3 demo — should have iso field
        let cam = try #require(cameras.first)
        #expect(cam.fields["record"] != nil, "record field should always be present")
    }

    @Test("An overlay on every output: true only when all show it, so setting true reaches the rest", .timeLimit(.minutes(1)))
    func everyOutputOverlay() async throws {
        var state = CameraState()
        state.connection = .connected
        state.recording = RecordingControl(state: .idle)
        state.monitoring = MonitoringState(outputs: [
            MonitorOutput(id: "LCD", name: "LCD", overlays: [.zebra: Choice(true, options: [false, true])]),
            MonitorOutput(id: "MainSDI", name: "SDI", overlays: [.zebra: Choice(false, options: [false, true])]),
        ])
        let backend = MonitoringBackend(state: state)
        let camera = SavedCamera(slot: CameraSlot(label: "B", color: .blue, host: "pyxis"),
                                 connection: .blackmagic(BlackmagicConnection(host: "pyxis")))
        let store = await DashboardStore(cameras: [camera], pages: [CameraPage(name: "All", showsAllCameras: true)],
                                         startCameras: true, makeBackend: { _, _ in backend })
        for _ in 0..<500 {
            if await MainActor.run(body: { store.cameras.first?.state.monitoring != nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let s = try await makeServer(store: store)
        defer { Task { @MainActor in s.server.stop() } }
        let token = s.tokenStore.token()

        // Zebra is on the LCD only, so "true" isn't already there: the command goes out, to every output.
        let (status, body) = try await httpRequest(method: "POST", path: "/command", token: token,
                                                   body: #"{"target":{"all":true},"command":{"set":"zebra","value":true}}"#,
                                                   port: s.httpPort)
        #expect(status == 200)
        #expect(body.contains("confirmed"))
        #expect(await backend.sent == [.setMonitorOverlay(.zebra, true, output: nil)])
    }

    /// A deck holds a focus key by sending the drive again before the last one ends: the older drive's end mustn't
    /// stop the motor under the newer one, and letting go stops it once, at once.
    @Test("drive: a newer drive takes over without a stop between; speed 0 stops it once", .timeLimit(.minutes(1)))
    func driveTakeover() async throws {
        var state = CameraState()
        state.connection = .connected
        state.recording = RecordingControl(state: .idle)
        state.focusDrive = LensDrive(maxSpeed: 8)
        let backend = MonitoringBackend(state: state)
        let camera = SavedCamera(slot: CameraSlot(label: "B", color: .blue, host: "fx6"),
                                 connection: .blackmagic(BlackmagicConnection(host: "fx6")))
        let store = await DashboardStore(cameras: [camera], pages: [CameraPage(name: "All", showsAllCameras: true)],
                                         startCameras: true, makeBackend: { _, _ in backend })
        for _ in 0..<500 {
            if await MainActor.run(body: { store.cameras.first?.state.focusDrive != nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let s = try await makeServer(store: store)
        defer { Task { @MainActor in s.server.stop() } }
        let token = s.tokenStore.token()
        func drive(_ speed: Int) async throws {
            let (status, _) = try await httpRequest(method: "POST", path: "/command", token: token,
                                                    body: #"{"target":{"all":true},"command":{"drive":"focus","speed":\#(speed),"seconds":1.5}}"#,
                                                    port: s.httpPort)
            #expect(status == 200)
        }

        // Each drive outlasts the gap to the next by more than a second: at 0.5 s with 250 ms gaps, a busy machine (a
        // 30-run flake hunt) let one run out between them, and it stopped twice.
        for _ in 0..<3 {
            try await drive(3)
            try await Task.sleep(for: .milliseconds(250))
        }
        try await drive(0)
        try await Task.sleep(for: .milliseconds(1700))  // past every drive's end
        let speeds = await backend.sent.compactMap { command -> Int? in
            if case .driveFocus(let speed) = command { speed } else { nil }
        }
        #expect(speeds.last == 0)
        #expect(speeds.filter { $0 == 0 }.count == 1)
        #expect(speeds.dropLast().allSatisfy { $0 == 3 } && speeds.count > 3)
    }

    /// Push autofocus over the API, as the Autofocus tile pushes it: sent to a camera that has one while its focus is
    /// manual; refused, saying why, with autofocus on or on a camera with no push.
    @Test("press autofocus: sent while focus is manual, refused with AF on or no push", .timeLimit(.minutes(1)))
    func pressAutofocus() async throws {
        func send(_ adjust: (inout CameraState) -> Void) async throws -> (sent: [CameraCommand], body: String) {
            var state = CameraState()
            state.connection = .connected
            state.recording = RecordingControl(state: .idle)
            adjust(&state)
            let backend = MonitoringBackend(state: state)
            let camera = SavedCamera(slot: CameraSlot(label: "F", color: .orange, host: "fx5"),
                                     connection: .blackmagic(BlackmagicConnection(host: "fx5")))
            let store = await DashboardStore(cameras: [camera], pages: [CameraPage(name: "All", showsAllCameras: true)],
                                             startCameras: true, makeBackend: { _, _ in backend })
            for _ in 0..<500 {
                if await MainActor.run(body: { store.cameras.first?.state.connection == .connected }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let s = try await makeServer(store: store)
            defer { Task { @MainActor in s.server.stop() } }
            let (status, body) = try await httpRequest(method: "POST", path: "/command", token: s.tokenStore.token(),
                                                       body: #"{"target":{"all":true},"command":{"press":"autofocus"}}"#,
                                                       port: s.httpPort)
            #expect(status == 200)
            try await Task.sleep(for: .milliseconds(100))
            return (await backend.sent, body)
        }
        let manual = try await send { $0.canAutoFocus = true; $0.focusMode = Choice("MF", options: ["AF", "MF"]) }
        #expect(manual.sent == [.autoFocus] && manual.body.contains("accepted"))
        let auto = try await send {
            $0.canAutoFocus = true; $0.focusMode = Choice("AF", options: ["AF", "MF"]); $0.focusIsAuto = true
        }
        #expect(auto.sent.isEmpty && auto.body.contains("autofocus is on"))
        let none = try await send { $0.canAutoFocus = false }
        #expect(none.sent.isEmpty && none.body.contains("no push autofocus"))
    }

    /// Every field the API has.
    static let allFieldNames: Set<String> = [
        "record", "iso", "baseISO", "shutterAngle", "shutterSpeed", "shutterMode",
        "ndPreset", "variableND", "wbPreset", "kelvin", "tint", "iris",
        "frameRateVariable", "clipFlag", "imageFlip", "colorBars", "falseColor", "look", "hdmiInfo", "gridLines",
        "frameRate", "resolution", "codec", "bitrate", "desqueeze", "lut", "focusMode",
        "offSpeedRate", "dynamicRange", "zebra", "focusAssist", "frameGuides", "frameGrids", "safeArea", "cleanFeed",
        "statusText", "zebraLevel", "frameGuideRatio", "ndMode", "tally", "call", "colorGamut",
        "timecodeDuration", "playbackMode", "playing", "userFrameA", "userFrameB",
        "shootingMode", "gain", "baseSensitivity", "recordedLUT", "proxy", "ecs", "irisAuto", "ndAuto", "isoAuto",
        "steadyShot", "imagerMode", "subjectRecognition", "focusArea", "afTransitionSpeed", "afSubjectShift", "afAssist",
    ]

    @Test("Every API field is in docs/control-api.md's field table, and nothing else is")
    func fieldsAreDocumented() throws {
        let doc = try String(contentsOf: NoMediaFormattingTests.root.appendingPathComponent("docs/control-api.md"),
                             encoding: .utf8)
        // The rows of "All fields", every name in each row's first cell.
        let table = doc.components(separatedBy: "### All fields").dropFirst().first?
            .components(separatedBy: "\n#").first ?? ""
        let documented = Set(table.split(separator: "\n").filter { $0.hasPrefix("| `") }.flatMap { row in
            row.split(separator: "|").first.map { $0.split(separator: "`").enumerated().filter { $0.offset % 2 == 1 }
                .map { String($0.element) } } ?? []
        })
        #expect(documented.count > 40)
        #expect(Self.allFieldNames.subtracting(documented).isEmpty,
                "API fields not in the doc: \(Self.allFieldNames.subtracting(documented).sorted())")
        #expect(documented.subtracting(Self.allFieldNames).isEmpty,
                "documented, not API fields: \(documented.subtracting(Self.allFieldNames).sorted())")
    }

    @Test("CameraCommand completeness — every case has an API field", .timeLimit(.minutes(1)))
    func cameraCommandFieldCoverage() {
        // Every CameraCommand case must have a corresponding API field name.
        // This test fails if a new CameraCommand case is added without updating the field map.
        let allFieldNames = Self.allFieldNames
        // Not here: setMonitorOverlay for one output (the app's Monitoring sheet), clip naming, pressCameraButton
        // (Camera Menu's presses are actions, not settings), autoFocus (an action) and setAudio (a channel's, as an
        // output's overlay is the Monitoring sheet's). Playback's presses are the `playback` command; an FX6's ECS
        // steps, focus and zoom drives and assignable buttons are `step` "ecsFrequency", `drive` and `press`.
        // Build what the server supports by checking toSwift coverage
        let testCommands: [(String, CameraCommand)] = [
            ("record", .record(true)),
            ("iso", .setISO(800)),
            ("baseISO", .setBaseISO(800)),
            ("shutterAngle", .setShutterAngle(180)),
            ("shutterSpeed", .setShutterSpeed("1/50")),
            ("shutterMode", .setShutterMode(.angle)),
            ("ndPreset", .setNDPreset("Clear")),
            ("variableND", .setVariableND(0.5)),
            ("wbPreset", .setWhiteBalancePreset("5600K")),
            ("kelvin", .setKelvin(5600)),
            ("tint", .setTint(0)),
            ("iris", .setIris(2.8)),
            ("frameRateVariable", .setFrameRateVariable(false)),
            ("clipFlag", .setClipFlag(.none)),
            ("imageFlip", .setImageFlip(false)),
            ("hdmiInfo", .setHDMIInfo(false)),
            ("gridLines", .setGridLines(false)),
            ("colorBars", .setColorBars(false)),
            ("falseColor", .setFalseColor(false)),
            ("look", .setLook(true)),
            ("frameRate", .setFrameRate("23.98")),
            ("resolution", .setResolution("3840x2160")),
            ("codec", .setFileFormat("XAVC S-I 4K")),
            ("bitrate", .setRecordingSetting("240M 4:2:2 10bit")),
            ("desqueeze", .setDesqueeze("Off")),
            ("lut", .setLUT("s709")),
            ("focusMode", .setFocusMode("MF")),
            ("offSpeedRate", .setFrameRateVariableRate(60)),
            ("dynamicRange", .setDynamicRange("Film")),
            ("zebra", .setMonitorOverlay(.zebra, true, output: nil)),
            ("focusAssist", .setMonitorOverlay(.focusAssist, true, output: nil)),
            ("frameGuides", .setMonitorOverlay(.frameGuides, true, output: nil)),
            ("frameGrids", .setMonitorOverlay(.frameGrids, true, output: nil)),
            ("safeArea", .setMonitorOverlay(.safeArea, true, output: nil)),
            ("cleanFeed", .setMonitorOverlay(.cleanFeed, true, output: nil)),
            ("statusText", .setMonitorOverlay(.statusText, true, output: nil)),
            ("zebraLevel", .setZebraLevel(95)),
            ("frameGuideRatio", .setFrameGuideRatio("2.39:1")),
            ("ndMode", .setNDMode("Variable")),
            ("tally", .setTally("Red")),
            ("call", .setCall(true)),
            ("colorGamut", .setColorGamut("S-Gamut3")),
            ("timecodeDuration", .setTimecodeShowsDuration(true)),
            ("userFrameA", .setUserFrameLines(.a, "1")),
            ("userFrameB", .setUserFrameLines(.b, "1 + 2")),
            ("playbackMode", .playback(.review)),
            ("playing", .playback(.play)),
            ("shootingMode", .setShootingMode("Cine EI")),
            ("gain", .setGain(6)),
            ("baseSensitivity", .setBaseSensitivity("High")),
            ("recordedLUT", .setRecordedLUT(false)),
            ("proxy", .setProxyRecording(true)),
            ("ecs", .setECS(true)),
            ("irisAuto", .setIrisAuto(true)),
            ("ndAuto", .setNDAuto(true)),
            ("isoAuto", .setISOAuto(true)),
            ("steadyShot", .setSteadyShot("Active")),
            ("imagerMode", .setImagerMode("S35 3.2K 16:9")),
            ("subjectRecognition", .setSubjectRecognition("Human Priority AF")),
            ("focusArea", .setFocusArea("Zone")),
            ("afTransitionSpeed", .setAFTransitionSpeed(3)),
            ("afSubjectShift", .setAFSubjectShift(2)),
            ("afAssist", .setAFAssist(false)),
        ]
        let coveredFields = Set(testCommands.map(\.0))
        let missing = allFieldNames.subtracting(coveredFields)
        #expect(missing.isEmpty, "CameraCommand cases with no API field: \(missing)")
    }

    // MARK: - Regression tests for reported bugs (phase 2 review)

    @Test("changes carries fields.iso after set — changes arrive before result", .timeLimit(.minutes(1)))
    func changesCarriesFieldsAfterSet() async throws {
        let s = try await makeServer(connected: true)
        defer { Task { @MainActor in s.server.stop() } }
        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }
        let (camera, _) = try await subscribed(client, token: s.tokenStore.token())
        let cameraID = try #require(camera["id"] as? String)
        let iso = try #require((camera["fields"] as? [String: Any])?["iso"] as? [String: Any])
        let options = iso["options"] as? [Int] ?? []
        let target = try #require(options.first { $0 != iso["value"] as? Int })
        client.sendRaw(Data(#"{"type":"command","id":"chg","target":{"cameraID":"\#(cameraID)"},"command":{"set":"iso","value":\#(target)}}"#.utf8))
        let messages = await collect(client) { !results($0, id: "chg").isEmpty }
        let resultIndex = try #require(messages.firstIndex { $0["type"] as? String == "result" && $0["id"] as? String == "chg" })
        let changeIndex = messages.firstIndex {
            $0["type"] as? String == "changes" && $0["cameraID"] as? String == cameraID
                && (((($0["update"] as? [String: Any])?["fields"] as? [String: Any])?["iso"] as? [String: Any])?["value"] as? Int) == target
        }
        #expect(results(messages, id: "chg").first?["status"] as? String == "confirmed")
        #expect(changeIndex != nil, "no changes message carried the new ISO")
        if let changeIndex { #expect(changeIndex < resultIndex, "the changes message must come before the result") }

    }
    @Test("second REC while one is pending → rejected", .timeLimit(.minutes(1)))
    func recDoublePressPrevented() async throws {
        let s = try await makeServer(connected: true)
        defer { Task { @MainActor in s.server.stop() } }
        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }
        let (camera, _) = try await subscribed(client, token: s.tokenStore.token())
        let cameraID = try #require(camera["id"] as? String)
        for id in ["rec1", "rec2"] {
            client.sendRaw(Data(#"{"type":"command","id":"\#(id)","link":false,"target":{"cameraID":"\#(cameraID)"},"command":{"toggle":"record"}}"#.utf8))
        }
        let messages = await collect(client, seconds: 12) { !results($0, id: "rec1").isEmpty && !results($0, id: "rec2").isEmpty }
        #expect(results(messages, id: "rec1").first?["status"] as? String == "confirmed")
        #expect(results(messages, id: "rec1").first?["value"] as? String == "recording")
        #expect(results(messages, id: "rec2").first?["status"] as? String == "rejected")
        client.sendRaw(Data(#"{"type":"command","id":"stop","link":false,"target":{"cameraID":"\#(cameraID)"},"command":{"set":"record","value":"idle"}}"#.utf8))
        _ = await collect(client, seconds: 12) { !results($0, id: "stop").isEmpty }

    }
    @Test("REC result value uses string vocabulary", .timeLimit(.minutes(1)))
    func recResultUsesStringVocabulary() async throws {
        let s = try await makeServer(connected: true)
        defer { Task { @MainActor in s.server.stop() } }
        let token = s.tokenStore.token()

        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }

        client.sendRaw(Data(#"{"type":"auth","token":"\#(token)"}"#.utf8))
        _ = await client.next() // hello
        client.sendRaw(Data(#"{"type":"subscribe"}"#.utf8))
        let snapMsg = try #require(await client.next())
        let snap = try JSONDecoder().decode(WireMessage.self, from: snapMsg)
        guard case .snapshot(let cameras, _, _, _, _) = snap, let cam = cameras.first else {
            Issue.record("No camera"); return
        }

        // Toggle REC on
        let env = WireClientEnvelope(type: "command", id: "recvoc", target: .cameraID(cam.id), command: .toggle("record"))
        client.sendRaw(try JSONEncoder().encode(env))

        var recResult: WireResultEntry? = nil
        for _ in 0..<8 {
            if let d = await client.next(timeout: 8),
               let m = try? JSONDecoder().decode(WireMessage.self, from: d),
               case .result(let rid, let entries) = m, rid == "recvoc" {
                recResult = entries.first
                break
            }
        }
        let entry = try #require(recResult, "Did not receive REC result")
        #expect(entry.status == "confirmed", "REC should confirm: \(entry)")
        // Value must be "recording" (string), not true (bool)
        if let v = entry.value {
            let jsonStr = (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? ""
            #expect(jsonStr.contains("recording"), "REC result value must be 'recording', got: \(jsonStr)")
        }
    }

    @Test("showPage broadcasts pages message with updated current", .timeLimit(.minutes(1)))
    func showPageBroadcastsPages() async throws {
        let s = try await makeServer()
        defer { Task { @MainActor in s.server.stop() } }
        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }
        let (_, pages) = try await subscribed(client, token: s.tokenStore.token())
        let target = try #require(pages.first { $0["current"] as? Bool != true }?["id"] as? String)
        client.sendRaw(Data(#"{"type":"app","id":"pg","action":"showPage","pageID":"\#(target)"}"#.utf8))
        let messages = await collect(client) { messages in
            messages.contains { message in
                message["type"] as? String == "pages" && (message["pages"] as? [[String: Any]] ?? []).contains {
                    $0["id"] as? String == target && $0["current"] as? Bool == true
                }
            }
        }
        #expect(messages.contains { $0["type"] as? String == "result" && $0["id"] as? String == "pg" })
        #expect(messages.contains { $0["type"] as? String == "pages" }, "showPage must be followed by a pages message")

    }
    @Test("step accumulates against latest requested value", .timeLimit(.minutes(2)))
    func stepAccumulation() async throws {
        let s = try await makeServer(connected: true)
        defer { Task { @MainActor in s.server.stop() } }
        let token = s.tokenStore.token()

        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }

        client.sendRaw(Data(#"{"type":"auth","token":"\#(token)"}"#.utf8))
        _ = await client.next() // hello
        client.sendRaw(Data(#"{"type":"subscribe"}"#.utf8))
        let snapMsg = try #require(await client.next())
        let snap = try JSONDecoder().decode(WireMessage.self, from: snapMsg)
        guard case .snapshot(let cameras, _, _, _, _) = snap, let cam = cameras.first,
              case .choice(let isoField) = cam.fields["iso"],
              isoField.options.count >= 7 else {
            Issue.record("Need camera with ≥7 ISO options"); return
        }

        let opts = isoField.options
        let startIdx = 1  // second option
        let startVal = opts[startIdx]
        guard let startFieldVal = FieldValue.from(startVal) else {
            Issue.record("Cannot convert iso option to FieldValue"); return
        }

        // First: set iso to start value
        let setEnv = WireClientEnvelope(type: "command", id: "s0", target: .cameraID(cam.id),
                                         command: .set("iso", startFieldVal))
        client.sendRaw(try JSONEncoder().encode(setEnv))
        // Wait for confirmation
        for _ in 0..<20 { if let d = await client.next(timeout: 5), let m = try? JSONDecoder().decode(WireMessage.self, from: d), case .result(let rid, _) = m, rid == "s0" { break } }

        // Send 3 fast steps
        let step1 = WireClientEnvelope(type: "command", id: "st1", target: .cameraID(cam.id), command: .step("iso", 1.0))
        let step2 = WireClientEnvelope(type: "command", id: "st2", target: .cameraID(cam.id), command: .step("iso", 1.0))
        let step3 = WireClientEnvelope(type: "command", id: "st3", target: .cameraID(cam.id), command: .step("iso", 1.0))
        client.sendRaw(try JSONEncoder().encode(step1))
        client.sendRaw(try JSONEncoder().encode(step2))
        client.sendRaw(try JSONEncoder().encode(step3))

        // Wait for step3 result
        var step3Result: WireResultEntry? = nil
        for _ in 0..<30 {
            if let d = await client.next(timeout: 8),
               let m = try? JSONDecoder().decode(WireMessage.self, from: d),
               case .result(let rid, let entries) = m, rid == "st3" {
                step3Result = entries.first; break
            }
        }
        let entry = try #require(step3Result, "Did not receive step3 result")
        let expectedIdx = min(startIdx + 3, opts.count - 1)
        let expectedVal = opts[expectedIdx]
        #expect(entry.status == "confirmed" || entry.status == "timeout",
                "step3 should confirm or timeout, got: \(entry.status)")
        if entry.status == "confirmed" {
            #expect(entry.value == expectedVal, "3 fast steps from \(startVal) should reach \(expectedVal), got: \(String(describing: entry.value))")
        }
    }
}

// MARK: - Playback, the padlock and the VENICE's time display

extension ControlServerTests {

    @Test("Playback goes out whole, and a transport command is accepted only when the camera takes it", .timeLimit(.minutes(1)))
    func playbackCommands() async throws {
        let (s, backend) = try await makePlaybackServer()
        defer { Task { @MainActor in s.server.stop() } }
        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }
        let (camera, _) = try await subscribed(client, token: s.tokenStore.token())
        let playback = try #require(camera["playback"] as? [String: Any])
        #expect(playback["clip"] as? String == "A001C003")
        #expect(playback["clipNumber"] as? Int == 3)
        #expect(playback["clipCount"] as? Int == 12)
        #expect(playback["commands"] as? [String] == ["recReview", "review"], "live: Rec Review and into review only")
        let fields = try #require(camera["fields"] as? [String: Any])
        #expect((fields["playbackMode"] as? [String: Any])?["value"] as? String == "live")
        #expect((fields["playbackMode"] as? [String: Any])?["writable"] as? Bool == true)
        #expect((fields["playing"] as? [String: Any])?["writable"] as? Bool == false, "no playing until it's in review")

        func send(_ id: String, _ command: String) {
            client.sendRaw(Data(#"{"type":"command","id":"\#(id)","target":{"camera":"A"},"command":\#(command)}"#.utf8))
        }
        func playbackChange(_ messages: [[String: Any]]) -> [String: Any]? {
            messages.last { $0["type"] as? String == "changes" && ($0["update"] as? [String: Any])?["playback"] != nil }
                .flatMap { ($0["update"] as? [String: Any])?["playback"] as? [String: Any] }
        }

        send("rv", #"{"playback":"review"}"#)
        let reviewed = await collect(client) { !results($0, id: "rv").isEmpty && playbackChange($0) != nil }
        #expect(results(reviewed, id: "rv").first?["status"] as? String == "accepted")
        let inReview = try #require(playbackChange(reviewed))
        #expect(inReview["commands"] as? [String] == ["togglePlay", "play", "pause", "stop", "next", "previous",
                                                       "fastForward", "rewind", "scanForward", "scanBackward",
                                                       "endScan", "live"])

        // Playing now: play isn't pressed again (the button's a toggle, so it would pause).
        let sentBefore = await backend.sent.count
        send("pl", #"{"playback":"play"}"#)
        let played = await collect(client) { !results($0, id: "pl").isEmpty }
        #expect(results(played, id: "pl").first?["status"] as? String == "accepted")
        try await Task.sleep(for: .milliseconds(200))
        #expect(await backend.sent.count == sentBefore, "play while playing must not press the toggle")

        send("ps", #"{"playback":"pause"}"#)
        _ = await collect(client) { !results($0, id: "ps").isEmpty }
        for _ in 0..<100 where await backend.sent.last != .playback(.pause) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await backend.sent.last == .playback(.pause))

        send("sk", #"{"playback":"skip","by":5}"#)
        send("zz", #"{"playback":"moonwalk"}"#)
        let refused = await collect(client) { !results($0, id: "sk").isEmpty && !results($0, id: "zz").isEmpty }
        #expect(results(refused, id: "sk").first?["status"] as? String == "rejected")
        #expect(results(refused, id: "sk").first?["error"] as? String == "unsupported", "a BURANO can't seek")
        #expect(results(refused, id: "zz").first?["error"] as? String == "unsupported")
    }

    @Test("playing and playbackMode set and confirm like any field, and a value already there isn't sent", .timeLimit(.minutes(1)))
    func playbackFields() async throws {
        let (s, backend) = try await makePlaybackServer()
        defer { Task { @MainActor in s.server.stop() } }
        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }
        _ = try await subscribed(client, token: s.tokenStore.token())
        func send(_ id: String, _ command: String) {
            client.sendRaw(Data(#"{"type":"command","id":"\#(id)","target":{"camera":"A"},"command":\#(command)}"#.utf8))
        }

        send("rv", #"{"set":"playbackMode","value":"review"}"#)
        let reviewed = await collect(client) { !results($0, id: "rv").isEmpty }
        #expect(results(reviewed, id: "rv").first?["status"] as? String == "confirmed")
        #expect(results(reviewed, id: "rv").first?["value"] as? String == "review")

        // In review it plays (as a BURANO's Play does), so playing true is already there: nothing is sent.
        let sentBefore = await backend.sent.count
        send("p1", #"{"set":"playing","value":true}"#)
        let already = await collect(client) { !results($0, id: "p1").isEmpty }
        #expect(results(already, id: "p1").first?["status"] as? String == "confirmed")
        #expect(await backend.sent.count == sentBefore)

        send("p2", #"{"toggle":"playing"}"#)
        let paused = await collect(client) { !results($0, id: "p2").isEmpty }
        #expect(results(paused, id: "p2").first?["status"] as? String == "confirmed")
        #expect(results(paused, id: "p2").first?["value"] as? Bool == false)
        #expect(await backend.sent.last == .playback(.pause))

        send("lv", #"{"cycle":"playbackMode"}"#)
        let live = await collect(client) { !results($0, id: "lv").isEmpty }
        #expect(results(live, id: "lv").first?["value"] as? String == "live")
        #expect(await backend.sent.last == .playback(.live))
    }

    @Test("A camera that isn't connected takes no transport command", .timeLimit(.minutes(1)))
    func playbackOffline() async throws {
        let s = try await makeServer()
        defer { Task { @MainActor in s.server.stop() } }
        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }
        _ = try await subscribed(client, token: s.tokenStore.token())
        client.sendRaw(Data(#"{"type":"command","id":"rv","target":{"camera":"T"},"command":{"playback":"review"}}"#.utf8))
        let messages = await collect(client) { !results($0, id: "rv").isEmpty }
        #expect(results(messages, id: "rv").first?["status"] as? String == "rejected")
        #expect(results(messages, id: "rv").first?["error"] as? String == "camera not connected")
    }

    @Test("The padlock: hello and snapshot carry it, setLocked sets it, and the app's own is broadcast", .timeLimit(.minutes(1)))
    func lockOverTheAPI() async throws {
        let s = try await makeServer()
        defer { Task { @MainActor in s.server.stop() } }
        let token = s.tokenStore.token()
        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }

        client.sendRaw(Data(#"{"type":"auth","token":"\#(token)","id":"a"}"#.utf8))
        let hello = await collect(client) { $0.contains { $0["type"] as? String == "hello" } }
        #expect(hello.first { $0["type"] as? String == "hello" }?["locked"] as? Bool == false)
        client.sendRaw(Data(#"{"type":"subscribe","id":"s"}"#.utf8))
        let snap = await collect(client) { $0.contains { $0["type"] as? String == "snapshot" } }
        #expect(snap.first { $0["type"] as? String == "snapshot" }?["locked"] as? Bool == false)

        client.sendRaw(Data(#"{"type":"app","id":"lk","action":"setLocked","enabled":true}"#.utf8))
        let locked = await collect(client) {
            !results($0, id: "lk").isEmpty && $0.contains { $0["type"] as? String == "lock" }
        }
        #expect(results(locked, id: "lk").first?["status"] as? String == "confirmed")
        #expect(locked.last { $0["type"] as? String == "lock" }?["locked"] as? Bool == true)
        #expect(await MainActor.run { s.store.controlsLocked })

        // The padlock in the app.
        await MainActor.run { s.store.controlsLocked = false }
        let unlocked = await collect(client) { $0.contains { $0["type"] as? String == "lock" } }
        #expect(unlocked.last { $0["type"] as? String == "lock" }?["locked"] as? Bool == false)

        client.sendRaw(Data(#"{"type":"app","id":"bad","action":"setLocked"}"#.utf8))
        let bad = await collect(client) { $0.contains { $0["type"] as? String == "error" } }
        #expect(bad.first { $0["type"] as? String == "error" }?["code"] as? String == "badRequest")

        let (status, body) = try await httpRequest(method: "GET", path: "/state", token: token, port: s.httpPort)
        #expect(status == 200)
        #expect(body.contains(#""locked":false"#))

        // Over HTTP, a refused action is a 400, not "confirmed".
        let (refused, refusedBody) = try await httpRequest(method: "POST", path: "/app", token: token,
                                                           body: #"{"action":"setLocked"}"#, port: s.httpPort)
        #expect(refused == 400)
        #expect(refusedBody.contains("badRequest"))
        #expect(await MainActor.run { !s.store.controlsLocked })
        let (taken, takenBody) = try await httpRequest(method: "POST", path: "/app", token: token,
                                                       body: #"{"action":"setLocked","enabled":true}"#, port: s.httpPort)
        #expect(taken == 200)
        #expect(takenBody.contains(#""field":"locked""#) && takenBody.contains("confirmed"))
        #expect(await MainActor.run { s.store.controlsLocked })
    }

    @Test("A VENICE's time display: timecode or the take's duration", .timeLimit(.minutes(1)))
    func timecodeDuration() async throws {
        let camera = SavedCamera(slot: CameraSlot(label: "V", color: .blue, host: "demo"), demoBody: .venice2)
        let store = await DashboardStore(cameras: [camera], pages: [CameraPage(name: "All", showsAllCameras: true)],
                                         startCameras: true)
        for _ in 0..<500 {
            if await MainActor.run(body: { store.cameras.first?.state.timecodeShowsDuration != nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let s = try await makeServer(store: store)
        defer { Task { @MainActor in s.server.stop() } }
        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }
        let (snapshotCamera, _) = try await subscribed(client, token: s.tokenStore.token())
        let field = try #require((snapshotCamera["fields"] as? [String: Any])?["timecodeDuration"] as? [String: Any])
        #expect(field["value"] as? Bool == false)
        client.sendRaw(Data(#"{"type":"command","id":"tc","target":{"camera":"V"},"command":{"toggle":"timecodeDuration"}}"#.utf8))
        let messages = await collect(client) { !results($0, id: "tc").isEmpty }
        #expect(results(messages, id: "tc").first?["status"] as? String == "confirmed")
        #expect(results(messages, id: "tc").first?["value"] as? Bool == true)
        #expect(await MainActor.run { store.cameras.first?.state.timecodeShowsDuration?.value } == true)
    }

    @Test("A VENICE's user frame lines in sets A and B, set like any picker", .timeLimit(.minutes(1)))
    func userFrameLines() async throws {
        let camera = SavedCamera(slot: CameraSlot(label: "V", color: .blue, host: "demo"), demoBody: .venice2)
        let store = await DashboardStore(cameras: [camera], pages: [CameraPage(name: "All", showsAllCameras: true)],
                                         startCameras: true)
        for _ in 0..<500 {
            if await MainActor.run(body: { store.cameras.first?.state.userFrameLinesA != nil }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let s = try await makeServer(store: store)
        defer { Task { @MainActor in s.server.stop() } }
        let client = WSClient()
        await client.connect(port: s.wsPort)
        defer { client.disconnect() }
        let (snapshotCamera, _) = try await subscribed(client, token: s.tokenStore.token())
        let fields = try #require(snapshotCamera["fields"] as? [String: Any])
        let a = try #require(fields["userFrameA"] as? [String: Any])
        #expect(a["value"] as? String == "Off")
        // In the order the camera's User Frame Disp. button steps them, so a deck's cycle goes as the camera's does.
        #expect(a["options"] as? [String] == ["1 + 2", "1", "2", "Off"])
        #expect(fields["userFrameB"] != nil)
        client.sendRaw(Data(#"{"type":"command","id":"uf","target":{"camera":"V"},"command":{"set":"userFrameA","value":"1 + 2"}}"#.utf8))
        let messages = await collect(client) { !results($0, id: "uf").isEmpty }
        #expect(results(messages, id: "uf").first?["status"] as? String == "confirmed")
        #expect(await MainActor.run { store.cameras.first?.state.userFrameLinesA?.value } == "1 + 2")
        // A deck's cycle steps on as the camera's own button does: from 1 + 2 to 1.
        client.sendRaw(Data(#"{"type":"command","id":"cy","target":{"camera":"V"},"command":{"cycle":"userFrameA"}}"#.utf8))
        let cycled = await collect(client) { !results($0, id: "cy").isEmpty }
        #expect(results(cycled, id: "cy").first?["status"] as? String == "confirmed")
        #expect(await MainActor.run { store.cameras.first?.state.userFrameLinesA?.value } == "1")
        // Not one of its options: turned down, nothing sent.
        client.sendRaw(Data(#"{"type":"command","id":"bad","target":{"camera":"V"},"command":{"set":"userFrameB","value":"3"}}"#.utf8))
        let refused = await collect(client) { !results($0, id: "bad").isEmpty }
        #expect(results(refused, id: "bad").first?["status"] as? String != "confirmed")
        #expect(await MainActor.run { store.cameras.first?.state.userFrameLinesB?.value } == "Off")
    }
}

// MARK: - Playback names and shapes

@Suite("Playback in the API")
struct PlaybackAPITests {
    private func caps(review: Bool = false, seek: Bool = false, ff: Bool = false, recReview: Bool = false,
                      live: Bool = false, stop: Bool = false) -> PlaybackCapabilities {
        PlaybackCapabilities(playPause: true, stop: stop, nextPrevious: true, seek: seek, fastForwardRewind: ff,
                             recReview: recReview, live: live, review: review)
    }

    @Test("An FX3 says nothing about playing, so it gets the toggle and not play or pause")
    func fx3() {
        let fx3 = caps(review: true, ff: true)
        #expect(APIPlayback.commands(PlaybackState(inReview: false, capabilities: fx3), recordingIdle: true) == ["review"])
        #expect(APIPlayback.commands(PlaybackState(inReview: false, capabilities: fx3), recordingIdle: false) == [],
                "no way into review while recording")
        #expect(APIPlayback.commands(PlaybackState(inReview: true, capabilities: fx3), recordingIdle: true)
                == ["togglePlay", "next", "previous", "fastForward", "rewind", "scanForward", "scanBackward", "endScan", "live"])
    }

    @Test("A Blackmagic seeks, and a camera without review keeps its Live button")
    func blackmagicAndLive() {
        let bm = PlaybackState(isPlaying: false, inReview: true, capabilities: caps(review: true, seek: true))
        #expect(APIPlayback.commands(bm, recordingIdle: true) == ["togglePlay", "play", "pause", "next", "previous", "skip", "live"])
        let arri = PlaybackState(isPlaying: true, capabilities: caps(ff: true, live: true, stop: true))
        #expect(APIPlayback.commands(arri, recordingIdle: true)
                == ["togglePlay", "play", "pause", "stop", "next", "previous", "fastForward", "rewind", "live"])
    }

    @Test("A VENICE is offered nothing its backend would turn into the clip list")
    func venice() throws {
        var state = MockCameraBackend.veniceSampleState()
        state.recording = RecordingControl(state: .idle)
        #expect(CameraProfile.isVenice(state.model))
        for inReview in [true, false] {
            state.playback?.inReview = inReview
            let commands = APIPlayback.commands(state)
            // Its backend sends InsideClips for anything it has no key for (VeniceCameraBackend.play).
            for name in ["skip", "recReview", "endScan", "scanForward", "scanBackward"] {
                #expect(!commands.contains(name), "\(name), in review: \(inReview)")
            }
            #expect(commands.contains(inReview ? "fastForward" : "review"))
        }
    }

    @Test("Every name the contract lists is a command, and skip needs its seconds")
    func names() {
        let names = ["togglePlay", "play", "pause", "stop", "next", "previous", "fastForward", "rewind", "scanForward",
                     "scanBackward", "endScan", "recReview", "review", "live"]
        for name in names { #expect(PlaybackCommand(apiName: name, by: nil) != nil, "\(name)") }
        #expect(PlaybackCommand(apiName: "skip", by: -5) == .skip(-5))
        #expect(PlaybackCommand(apiName: "skip", by: nil) == nil)
        #expect(PlaybackCommand(apiName: "scanForward", by: nil) == .scan(forward: true))
        #expect(PlaybackCommand(apiName: "moonwalk", by: nil) == nil)
    }

    @Test("changes carries playback whole, null when it goes, and nothing when it didn't change")
    func changesEncoding() throws {
        func json(_ u: CameraChangesUpdate) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(u)) as? [String: Any])
        }
        var gone = CameraChangesUpdate()
        gone.playbackChanged = true
        #expect(try json(gone)["playback"] is NSNull)
        #expect(try json(CameraChangesUpdate(latencyMs: 40))["playback"] == nil)
        #expect(!gone.isEmpty)
        var state = CameraState()
        state.connection = .connected
        state.recording = RecordingControl(state: .idle)
        state.playback = PlaybackState(isPlaying: false, inReview: false, clipName: "A001", capabilities: caps(review: true))
        var whole = CameraChangesUpdate()
        whole.playbackChanged = true
        whole.playback = APIPlayback(state)
        let sent = try #require(try json(whole)["playback"] as? [String: Any])
        #expect(sent["clip"] as? String == "A001")
        #expect(sent["commands"] as? [String] == ["review"])
        state.connection = .disconnected
        #expect(APIPlayback(state)?.commands == [], "offline, a camera takes no commands")
    }
}

// MARK: - Wire command decoding

@Suite("Wire commands")
struct WireCommandDecodingTests {
    private func op(_ json: String) throws -> WireCommandOp {
        try JSONDecoder().decode(WireCommandOp.self, from: Data(json.utf8))
    }

    @Test("set, step, toggle and cycle decode as the contract writes them")
    func decodesTheContractForms() throws {
        guard case .set("iso", .int(800)) = try op(#"{"set":"iso","value":800}"#) else { Issue.record("set"); return }
        guard case .set("record", .string("recording")) = try op(#"{"set":"record","value":"recording"}"#) else { Issue.record("set REC"); return }
        guard case .step("iso", -1) = try op(#"{"step":"iso","by":-1}"#) else { Issue.record("step"); return }
        guard case .toggle("record") = try op(#"{"toggle":"record"}"#) else { Issue.record("toggle"); return }
        guard case .cycle("wbPreset") = try op(#"{"cycle":"wbPreset"}"#) else { Issue.record("cycle"); return }
        guard case .playback("next", nil) = try op(#"{"playback":"next"}"#) else { Issue.record("playback"); return }
        guard case .playback("skip", -5) = try op(#"{"playback":"skip","by":-5}"#) else { Issue.record("skip"); return }
        guard case .drive("focus", -2, 0.5) = try op(#"{"drive":"focus","speed":-2,"seconds":0.5}"#) else {
            Issue.record("drive"); return
        }
        // A drive without seconds runs half a second, never open-ended.
        guard case .drive("zoom", 3, 0.5) = try op(#"{"drive":"zoom","speed":3}"#) else { Issue.record("drive default"); return }
        guard case .press("assignable", 2) = try op(#"{"press":"assignable","button":2}"#) else { Issue.record("press"); return }
        guard case .press("autofocus", nil) = try op(#"{"press":"autofocus"}"#) else { Issue.record("autofocus"); return }
    }

    @Test("link is \"app\" or false")
    func decodesLink() throws {
        let app = try JSONDecoder().decode(WireLink.self, from: Data(#""app""#.utf8))
        let thisCameraOnly = try JSONDecoder().decode(WireLink.self, from: Data("false".utf8))
        #expect(app.followsApp)
        #expect(!thisCameraOnly.followsApp)
    }
}
