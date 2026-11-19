import Foundation
import Network
import os

// MARK: - Token store

/// Persists the pairing token for the control API in the Keychain.
open class ControlServerTokenStore: @unchecked Sendable {
    private let service = "com.toldwell.cameracontrol.apitoken"
    private let account = "control-api"
    private var _cached: String?

    public init() {}

    open func token() -> String {
        if let t = _cached { return t }
        let t = read() ?? { let f = newToken(); write(f); return f }()
        _cached = t
        return t
    }

    /// Whether `candidate` is the token, compared in constant time: how long a wrong one takes to turn down says nothing
    /// about how much of it was right.
    public final func matches(_ candidate: String?) -> Bool {
        guard let candidate else { return false }
        let given = Array(candidate.utf8), expected = Array(token().utf8)
        var difference = UInt8(given.count == expected.count ? 0 : 1)
        for i in 0..<max(given.count, expected.count) {
            difference |= (i < given.count ? given[i] : 0) ^ (i < expected.count ? expected[i] : 0)
        }
        return difference == 0
    }

    open func regenerate() -> String {
        let t = newToken()
        write(t)
        _cached = t
        return t
    }

    private func read() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ token: String) {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    private func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Server

/// Local control server for the Tiles Control API (API version 1).
///
/// WebSocket on `wsPort` (default 51800, `_twcc._tcp` Bonjour) and HTTP on `httpPort` (default 51801).
/// Off by default; the user enables it in Settings → Control API.
/// On iOS only runs while the app is foreground.
///
/// `wsPort: 0` / `httpPort: 0` assigns ephemeral ports — for tests only.
@MainActor
public final class ControlServer {

    public enum ServerError: Error {
        case listenerFailed(String)
    }

    // Fixed ports used by the app. Tests pass 0 to get ephemeral ports.
    public static let defaultWSPort: UInt16   = 51800
    public static let defaultHTTPPort: UInt16 = 51801

    // MARK: - Public state

    public private(set) var isRunning = false
    public private(set) var portError: String? = nil
    public private(set) var advertiseAddress: String = ""
    /// The actual port the WS listener bound to (0 until running).
    public private(set) var actualWSPort: UInt16 = 0
    /// The actual port the HTTP listener bound to (0 until running).
    public private(set) var actualHTTPPort: UInt16 = 0

    // MARK: - Dependencies

    let tokenStore: ControlServerTokenStore
    weak var store: DashboardStore?

    // MARK: - Configuration

    private let wsPort: UInt16
    private let httpPort: UInt16
    private let log = Logger(subsystem: "com.toldwell.cameracontrol", category: "ControlServer")

    // MARK: - Network.framework

    let nwQueue = DispatchQueue(label: "com.toldwell.twcc.controlserver")
    private var wsListener: NWListener?
    private var httpListener: NWListener?
    var wsClients: [UUID: ControlClient] = [:]
    var httpClients: [UUID: HTTPClient] = [:]

    // MARK: - State change publishing

    /// Last published snapshot per camera (for diff computation).
    var lastPublished: [UUID: CameraAPISnapshot] = [:]
    var storeObserverTask: Task<Void, Never>?
    /// Deadband: at most one broadcast per 5 ms.
    var pendingBroadcast: Task<Void, Never>?

    // MARK: - Server-side tracking for step accumulation and REC guard

    /// Latest value *requested* on each camera+field (not yet confirmed by the camera).
    /// Steps use this so five fast dial clicks move five options even while the camera is slow.
    var lastRequested: [UUID: [String: FieldValue]] = [:]

    /// Cameras with a REC command currently in-flight (prevents double-press).
    var recInFlight: Set<UUID> = []

    /// One camera+field's queue (contract: Coalescing). At most one set is in flight; a newer request waits behind
    /// it, replacing any older waiter, so a spun dial sends at most two sets however fast it turns.
    struct Lane {
        var sending: Int?
        var sentAt = Date.distantPast
        var queued: (seq: Int, cmd: CameraCommand, value: FieldValue)?
        var latest = 0
        var isIdle: Bool { sending == nil && queued == nil }
    }
    var lanes: [UUID: [String: Lane]] = [:]
    var laneSeq = 0

    /// The `drive` running for each camera's lens motor ("focus", "zoom"), so a newer one takes over from it.
    var drives: [UUID: [String: Task<Void, Never>]] = [:]

    /// Pages key used by the state observer to detect page list / current-page changes.
    var lastPagesKey = Data()
    /// The camera list as clients last got it (`camerasKey`).
    var lastCamerasKey = Data()
    /// The padlock as clients last got it (`hello`, `snapshot`, `lock`).
    var lastLocked: Bool?

    /// When `advertisesBonjour` is false the WS listener skips mDNS registration.
    /// Tests pass false so repeated start/stop cycles under a full suite don't serialize
    /// through mDNSResponder and delay the listener reaching .ready.
    public let advertisesBonjour: Bool

    public init(tokenStore: ControlServerTokenStore,
                store: DashboardStore,
                wsPort: UInt16 = ControlServer.defaultWSPort,
                httpPort: UInt16 = ControlServer.defaultHTTPPort,
                advertisesBonjour: Bool = true) {
        self.tokenStore = tokenStore
        self.store = store
        self.wsPort = wsPort
        self.httpPort = httpPort
        self.advertisesBonjour = advertisesBonjour
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard !isRunning else { return }
        portError = nil
        bindRetries = [:]
        try startWSListener()
        try startHTTPListener()
    }

    /// A port can still be held briefly after stop() (NWListener closes asynchronously), and iOS stops and
    /// restarts the server on every background/foreground, so a failed bind is retried every 250 ms for 3 s.
    private var bindRetries: [String: Int] = [:]

    private func retryBind(_ which: String, after error: NWError, restart: @escaping @MainActor () throws -> Void,
                           port: UInt16) {
        let tries = bindRetries[which, default: 0]
        guard tries < 12 else {
            portError = "Port \(port) is in use"
            log.error("[\(which)] listener failed after 12 retries: \(error)")
            return
        }
        bindRetries[which] = tries + 1
        log.error("[\(which)] listener bind failed (\(error)); retrying (\(tries + 1)/12)")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            try? restart()
        }
    }

    private func startWSListener() throws {
        let params = NWParameters.tcp
        // Reuse only for the fixed ports, so a restart can rebind at once. On an OS-assigned port (tests) it let the
        // kernel hand the listener's port to an outgoing connection, which then failed with EADDRINUSE (HTTP tests,
        // now and then, in full runs).
        params.allowLocalEndpointReuse = wsPort != 0
        let wsOpts = NWProtocolWebSocket.Options()
        wsOpts.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOpts, at: 0)
        // A client that vanished (out of radio range, asleep) is dropped within about half a minute instead of
        // collecting updates until TCP gives up: probes when the link is quiet, a limit on unacknowledged sends.
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 3
            tcp.connectionDropTime = 30
        }

        let port = NWEndpoint.Port(rawValue: wsPort)!
        guard let listener = try? NWListener(using: params, on: port) else {
            throw ServerError.listenerFailed("Failed to create WebSocket NWListener")
        }
        self.wsListener = listener

        if advertisesBonjour {
            listener.service = NWListener.Service(type: "_twcc._tcp")
        }

        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Task { @MainActor [weak self] in self?.acceptWS(conn) }
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.portError = nil
                    if let port = self.wsListener?.port {
                        self.actualWSPort = port.rawValue
                        self.advertiseAddress = self.localAddress(port: port.rawValue)
                    }
                    self.startStateObserver()
                case .failed(let error):
                    self.isRunning = false
                    self.wsListener?.cancel()
                    self.wsListener = nil
                    self.retryBind("WebSocket", after: error, restart: { try self.startWSListener() }, port: self.wsPort)
                case .cancelled:
                    self.isRunning = false
                default:
                    break
                }
            }
        }
        listener.start(queue: nwQueue)
    }

    private func startHTTPListener() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = httpPort != 0   // see startWSListener

        let port = NWEndpoint.Port(rawValue: httpPort)!
        guard let listener = try? NWListener(using: params, on: port) else {
            throw ServerError.listenerFailed("Failed to create HTTP NWListener")
        }
        self.httpListener = listener

        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Task { @MainActor [weak self] in self?.acceptHTTP(conn) }
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .ready = state {
                    if let port = self.httpListener?.port { self.actualHTTPPort = port.rawValue }
                }
                if case .failed(let error) = state {
                    self.httpListener?.cancel()
                    self.httpListener = nil
                    self.retryBind("HTTP", after: error, restart: { try self.startHTTPListener() }, port: self.httpPort)
                }
            }
        }
        listener.start(queue: nwQueue)
    }

    public func stop() {
        storeObserverTask?.cancel()
        storeObserverTask = nil
        pendingBroadcast?.cancel()
        pendingBroadcast = nil
        wsListener?.cancel()
        wsListener = nil
        httpListener?.cancel()
        httpListener = nil
        for (_, client) in wsClients { client.disconnect() }
        wsClients.removeAll()
        for (_, client) in httpClients { client.disconnect() }
        httpClients.removeAll()
        lastPublished.removeAll()
        lastCamerasKey = Data()
        lastLocked = nil
        isRunning = false
        portError = nil
        advertiseAddress = ""
        actualWSPort = 0
        actualHTTPPort = 0
    }

    /// Stops the server and waits (up to a second) until both listeners report `.cancelled`, so their ports are free
    /// again. Tests that rebind the same ports use it instead of a fire-and-forget stop.
    public func stopAndWait() async {
        let listeners = [wsListener, httpListener].compactMap { $0 }
        stop()
        for _ in 0..<100 {
            if listeners.allSatisfy({ if case .cancelled = $0.state { true } else { false } }) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Connections

    private func acceptWS(_ conn: NWConnection) {
        let id = UUID()
        let client = ControlClient(id: id, connection: conn, tokenStore: tokenStore, server: self)
        wsClients[id] = client
        client.start()
    }

    private func acceptHTTP(_ conn: NWConnection) {
        let id = UUID()
        let client = HTTPClient(id: id, connection: conn, tokenStore: tokenStore, server: self)
        httpClients[id] = client
        client.start()
    }

    func removeWS(_ id: UUID) { wsClients[id] = nil }
    func removeHTTP(_ id: UUID) { httpClients[id] = nil }

    /// Called when the token is regenerated: close all WS sockets so clients re-authenticate.
    public func closeAllWebSockets() {
        for (_, client) in wsClients { client.disconnect() }
        wsClients.removeAll()
    }

    // MARK: - Helpers

    private func localAddress(port p: UInt16) -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "localhost:\(p)" }
        defer { freeifaddrs(first) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let name = String(cString: cur.pointee.ifa_name)
            if (name == "en0" || name == "en1"), cur.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var addr = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(cur.pointee.ifa_addr, socklen_t(cur.pointee.ifa_addr.pointee.sa_len),
                            &addr, socklen_t(addr.count), nil, 0, NI_NUMERICHOST)
                let addrStr = addr.withUnsafeBufferPointer {
                    String(decoding: $0.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
                }
                return "\(addrStr):\(p)"
            }
            ptr = cur.pointee.ifa_next
        }
        return "localhost:\(p)"
    }
}
