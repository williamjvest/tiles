import Foundation

/// Connection parameters for a Blackmagic camera over the REST API.
///
/// Two ways in to the same API. **Network Access**, turned on in Blackmagic Camera Setup (Web Media Manager): HTTP, or
/// HTTPS with a generated certificate; a login is optional, and with one set a PYXIS 12K turns down HTTPS without it
/// (401) and still answers HTTP (Camera 10.3.1). **Remote Control**, turned on at the camera itself (Setup, page 13):
/// HTTPS on port 444 with the remote password, Network Access on or off (`remoteControl`).
///
/// HTTPS is optional. Click "Generate Certificate" in Blackmagic Camera Setup's network access
/// settings to enable it. The camera serves a self-signed certificate; the first fingerprint seen
/// is pinned automatically (trust-on-first-use), and you're only asked if it ever changes.
public struct BlackmagicConnection: Codable, Hashable, Sendable {
    /// IP address or mDNS hostname, e.g. `192.168.1.42` or `pyxis-12k.local`; or `usb:<serial>` for a camera on a USB
    /// cable, found there at each connect (`BlackmagicUSBLink`).
    public var host: String

    /// When true, connect over HTTPS/WSS instead of HTTP/WS.
    /// Requires "Generate Certificate" in Blackmagic Camera Setup → Network Access.
    public var useHTTPS: Bool

    /// SHA-256 fingerprint of the camera's self-signed TLS leaf certificate (hex, lowercase, no colons),
    /// e.g. `"68e0c1b3984fc778ddedba7e4f4c25c718c42c024d64af6bee7839a82cf4bb48"`.
    /// nil = trust-on-first-use: the first certificate seen is accepted and this value is saved.
    /// A mismatch stops the connection and surfaces `.fingerprintChanged`.
    public var pinnedCertificateFingerprint: String?

    /// The camera's login user, when it has one; its password is kept in the keychain with the camera's other secrets
    /// (`CredentialStore`). nil: no login, which is how most cameras are set.
    public var username: String?

    /// Through the camera's Remote Control rather than its Network Access: the password is the camera's remote password,
    /// and `address`, `user` and `secure` say where and how.
    public var remoteControl: Bool

    public init(host: String, useHTTPS: Bool = false, pinnedCertificateFingerprint: String? = nil, username: String? = nil,
                remoteControl: Bool = false) {
        self.host = host
        self.useHTTPS = useHTTPS
        self.pinnedCertificateFingerprint = pinnedCertificateFingerprint
        self.username = username
        self.remoteControl = remoteControl
    }

    // MARK: - Remote Control

    /// Remote Control's port and user name: the camera serves its REST API there, over HTTPS, to the remote password
    /// (what Blackmagic's Camera app sends).
    public static let remoteControlPort = 444
    public static let remoteControlUser = "BMD_RESTCONTROL_USERNAME"

    /// Where to connect: the address as entered; with Remote Control, its port 444 unless the address names a port.
    public var address: String { address(at: host) }

    /// `address` for the camera found at `host`: where a camera on a cable is, once it's been found there.
    public func address(at host: String) -> String {
        guard remoteControl else { return host }
        let port = Self.remoteControlPort
        if host.hasPrefix("[") { return host.contains("]:") ? host : "\(host):\(port)" }
        switch host.filter({ $0 == ":" }).count {
        case 0: return "\(host):\(port)"
        case 1: return host  // a name or IPv4 address with its port
        default: return "[\(host)]:\(port)"  // a bare IPv6 address
        }
    }

    /// The login's user name: the one entered, or with Remote Control Blackmagic's fixed one.
    public var user: String? { remoteControl ? Self.remoteControlUser : username }

    /// HTTPS as chosen, and always with Remote Control.
    public var secure: Bool { remoteControl || useHTTPS }

    // MARK: - Lenient Codable (old saved setups that only have `host` still decode)

    private enum CodingKeys: String, CodingKey {
        case host, useHTTPS, pinnedCertificateFingerprint, username, remoteControl
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        useHTTPS = (try? c.decodeIfPresent(Bool.self, forKey: .useHTTPS)) ?? false
        pinnedCertificateFingerprint = try? c.decodeIfPresent(String.self, forKey: .pinnedCertificateFingerprint)
        username = try? c.decodeIfPresent(String.self, forKey: .username)
        remoteControl = (try? c.decodeIfPresent(Bool.self, forKey: .remoteControl)) ?? false
    }
}

// MARK: - Over Bluetooth

/// A Blackmagic camera over Bluetooth LE (an URSA Mini Pro 12K, a Pocket camera; the PYXIS and URSA Cine take it too):
/// Blackmagic's camera control protocol, the same room's range. The address is this device's identifier for it,
/// which another phone or Mac doesn't share, so a camera is added on each device that drives it.
public struct BlackmagicBluetoothConnection: Codable, Hashable, Sendable {
    /// CoreBluetooth's identifier for the camera on this device.
    public var peripheralID: UUID
    /// As the camera advertises itself, e.g. "A:4363AC4D" or its model.
    public var name: String

    public init(peripheralID: UUID, name: String) {
        self.peripheralID = peripheralID
        self.name = name
    }
}

/// A Bluetooth camera's host is `bt:<identifier>`: the slot needs an address, and this one says what it is.
public enum BluetoothCameraAddress {
    public static let scheme = "bt:"

    public static func host(id: UUID) -> String { scheme + id.uuidString }

    /// The camera's identifier, when `host` is a Bluetooth camera's.
    public static func id(in host: String) -> UUID? {
        host.hasPrefix(scheme) ? UUID(uuidString: String(host.dropFirst(scheme.count))) : nil
    }
}
