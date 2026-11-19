import Foundation

/// A Sony VENICE or VENICE 2 over its Web Remote's protocol (Savona: `SonySavona/VeniceCameraBackend`). Both bodies are
/// the goal; only VENICE 2 has been tested. The camera's Technical > Authentication login — `admin` and
/// the password set there (there is no factory password; 8+ characters, letters and numbers) — with the password kept
/// in the `CredentialStore`, like every camera's.
public struct VeniceConnection: Codable, Hashable, Sendable {
    public var host: String
    /// Technical > Authentication's user name, `admin` by default.
    public var username: String?

    public init(host: String, username: String? = "admin") {
        self.host = host
        self.username = username
    }

    private enum CodingKeys: String, CodingKey { case host, username }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? "admin"
    }
}
