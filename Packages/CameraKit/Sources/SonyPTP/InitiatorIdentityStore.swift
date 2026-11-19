// InitiatorIdentityStore — stable GUID per device, persisted across launches.
// [Architecture rule 4]

import Foundation
import Security

// MARK: - Protocol

/// Stores and retrieves the stable initiator GUID for a given camera host.
/// The GUID is stable per device; camera stores up to 20 paired GUIDs.
public protocol InitiatorIdentityStore: Sendable {
    /// Returns an existing GUID for `host`, or generates and persists a new one.
    func guid(for host: String) throws -> UUID
    /// Friendly name sent to camera during Init_Command_Request
    var friendlyName: String { get }
}

// MARK: - File-based store (camctl)

/// Reads/writes GUIDs to `~/.config/camctl/identity.json`.
/// [Architecture rule 4: file store for camctl]
public struct FileIdentityStore: InitiatorIdentityStore {
    public let friendlyName: String
    private let path: URL

    public init(friendlyName: String = "camctl", directory: URL? = nil) {
        self.friendlyName = friendlyName
        if let dir = directory {
            self.path = dir.appendingPathComponent("identity.json")
        } else {
            #if os(macOS)
            let configDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/camctl")
            #else
            let configDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("camctl")
            #endif
            self.path = configDir.appendingPathComponent("identity.json")
        }
    }

    public func guid(for host: String) throws -> UUID {
        var map = loadMap()
        if let existing = map[host] {
            return existing
        }
        let newGUID = UUID()
        map[host] = newGUID
        try saveMap(map)
        return newGUID
    }

    private func loadMap() -> [String: UUID] {
        guard let data = try? Data(contentsOf: path),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded.compactMapValues { UUID(uuidString: $0) }
    }

    private func saveMap(_ map: [String: UUID]) throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoded = map.mapValues { $0.uuidString }
        let data = try JSONEncoder().encode(encoded)
        try data.write(to: path, options: .atomic)
    }
}

// MARK: - Keychain-based store (app)

/// Persists initiator GUIDs in the Keychain, one item per camera host.
/// Uses Generic Password items keyed by service + account.
public struct KeychainInitiatorIdentityStore: InitiatorIdentityStore {
    public let friendlyName: String
    let service: String

    public init(friendlyName: String = "Tiles", service: String = "com.toldwell.cameracontrol.guid") {
        self.friendlyName = friendlyName
        self.service = service
    }

    public func guid(for host: String) throws -> UUID {
        if let existing = readGUID(host: host) { return existing }
        let newGUID = UUID()
        writeGUID(newGUID, host: host)
        return newGUID
    }

    private func readGUID(host: String) -> UUID? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return UUID(uuidString: str)
    }

    private func writeGUID(_ guid: UUID, host: String) {
        let data = Data(guid.uuidString.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}

// MARK: - In-memory store (tests)

/// Generates fresh GUIDs each time; useful in tests and fake camera.
public struct EphemeralIdentityStore: InitiatorIdentityStore {
    public let friendlyName: String
    private let fixedGUID: UUID

    public init(friendlyName: String = "test", guid: UUID = UUID()) {
        self.friendlyName = friendlyName
        self.fixedGUID = guid
    }

    public func guid(for host: String) throws -> UUID { fixedGUID }
}

