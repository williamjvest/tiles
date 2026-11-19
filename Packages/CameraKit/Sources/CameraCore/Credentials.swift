import Foundation
import Security

/// Where camera passwords live: the Keychain on a device, memory in previews and tests. Never in
/// UserDefaults alongside the rest of the setup.
public protocol CredentialStore: Sendable {
    func password(for cameraID: UUID) -> String?
    func setPassword(_ password: String?, for cameraID: UUID)
}

public struct KeychainCredentialStore: CredentialStore {
    let service: String

    public init(service: String = "com.toldwell.cameracontrol.camera") {
        self.service = service
    }

    public func password(for cameraID: UUID) -> String? {
        var query = baseQuery(cameraID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String?, for cameraID: UUID) {
        SecItemDelete(baseQuery(cameraID) as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var item = baseQuery(cameraID)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    private func baseQuery(_ cameraID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: cameraID.uuidString,
        ]
    }
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [UUID: String] = [:]

    public init() {}

    public func password(for cameraID: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return passwords[cameraID]
    }

    public func setPassword(_ password: String?, for cameraID: UUID) {
        lock.lock(); defer { lock.unlock() }
        passwords[cameraID] = password?.isEmpty == false ? password : nil
    }
}

/// How the app reaches a camera.
public enum CameraConnection: Codable, Hashable, Sendable {
    /// Simulated, for building and testing the UI without hardware.
    case demo(MockBody)
    /// A Sony body over PTP-IP.
    case sony(SonyConnection)
    /// A Blackmagic camera over the REST/WebSocket API (PYXIS 12K, URSA Cine, etc.).
    /// Requires "Network Access" enabled in Blackmagic Camera Setup.
    case blackmagic(BlackmagicConnection)
    /// A Blackmagic camera over Bluetooth LE (`BlackmagicBluetoothConnection`).
    case blackmagicBluetooth(BlackmagicBluetoothConnection)
    /// A Sony VENICE / VENICE 2 over its Web Remote's protocol (`VeniceConnection`).
    case venice(VeniceConnection)
    /// An ARRI camera (ALEXA Mini, Mini LF, ALEXA 35, AMIRA) over its Web Remote (`ArriConnection`).
    case arri(ArriConnection)

    public var demoBody: MockBody? {
        if case .demo(let body) = self { return body }
        return nil
    }

    public var sony: SonyConnection? {
        if case .sony(let connection) = self { return connection }
        return nil
    }

    public var blackmagic: BlackmagicConnection? {
        if case .blackmagic(let connection) = self { return connection }
        return nil
    }

    public var blackmagicBluetooth: BlackmagicBluetoothConnection? {
        if case .blackmagicBluetooth(let connection) = self { return connection }
        return nil
    }

    public var venice: VeniceConnection? {
        if case .venice(let connection) = self { return connection }
        return nil
    }

    public var arri: ArriConnection? {
        if case .arri(let connection) = self { return connection }
        return nil
    }
}

public struct SonyConnection: Codable, Hashable, Sendable {
    /// Access Authentication user name. Empty or nil means pairing: approve the device once on the
    /// camera's screen. The password lives in the `CredentialStore`.
    public var username: String?
    /// The SSH host key fingerprint the user matched against the camera's Access Authen. Info screen,
    /// e.g. `SHA256:kexL4…`. nil until the first connection is confirmed.
    public var trustedFingerprint: String?

    public init(username: String? = nil, trustedFingerprint: String? = nil) {
        self.username = username
        self.trustedFingerprint = trustedFingerprint
    }

    public var usesAccessAuthentication: Bool { !(username ?? "").isEmpty }
}

/// Stand-in for real cameras in builds that don't include the Sony backend (previews, tests).
public actor UnavailableBackend: CameraBackend {
    public nonisolated let updates: AsyncStream<CameraState>
    private nonisolated let continuation: AsyncStream<CameraState>.Continuation
    private let reason: String

    public init(reason: String) {
        let stream = AsyncStream.makeStream(of: CameraState.self, bufferingPolicy: .bufferingNewest(2))
        updates = stream.stream
        continuation = stream.continuation
        self.reason = reason
    }

    public func connect() async {
        var state = CameraState()
        state.connection = .failed(reason)
        continuation.yield(state)
    }

    public func disconnect() async {
        var state = CameraState()
        state.connection = .disconnected
        continuation.yield(state)
    }

    public func send(_ command: CameraCommand) async {}
}
