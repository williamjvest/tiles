import Foundation

/// Which way into a Blackmagic camera answers at an address, found by asking it: Remote Control on the camera's port 444
/// (HTTPS, asking for the remote password), or Network Access (its REST API on port 80). Add Camera picks the way in
/// from it, Remote Control first, and says what it found.
public enum BlackmagicAccessProbe {
    public enum Result: Sendable, Equatable {
        /// Port 444 asked for the remote password, or let the request through: Remote Control is on.
        case remoteControl
        /// Not that, but the REST API answered on port 80: Network Access.
        case networkAccess
        /// Something is at the address, but neither answered as a Blackmagic camera's API.
        case neither
    }

    /// nil when the address couldn't be reached, or names a port of its own (it has said which way in already).
    public static func probe(host: String, timeout: TimeInterval = 6) async -> Result? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(":"), !trimmed.contains("/"),
              let remote = URL(string: "https://\(trimmed):\(BlackmagicConnection.remoteControlPort)/control/api/v1/system/product")
        else { return nil }
        return await probe(remote: remote, networkHost: trimmed, timeout: timeout)
    }

    /// The two asked at once: `remote`, the product path on Remote Control's port, and `networkHost`, the address (and in
    /// tests a port) the REST API answers on with Network Access.
    static func probe(remote: URL, networkHost: String, timeout: TimeInterval) async -> Result? {
        async let remoteAnswer = remoteControlAnswers(remote, timeout: timeout)
        async let networkAnswer = HTTPProbe.get(host: networkHost, path: "/control/api/v1/system/product", timeout: timeout)
        let (byRemote, byNetwork) = await (remoteAnswer, networkAnswer)
        if byRemote == true { return .remoteControl }
        switch byNetwork {
        case .answered(_, let http) where http.statusCode == 200: return .networkAccess
        case nil where byRemote == nil: return nil
        default: return .neither
        }
    }

    /// True when Remote Control's port answers as the camera's API (401 to no password, or 200); false when nothing
    /// there does; nil when there's no telling (no answer in time).
    private static func remoteControlAnswers(_ url: URL, timeout: TimeInterval) async -> Bool? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: AnyCertificate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 401 || http.statusCode == 200
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .networkConnectionLost, .badServerResponse, .secureConnectionFailed: return false
            default: return nil
            }
        } catch {
            return nil
        }
    }
}

/// The probe sends nothing secret and reads only a status code, so a camera's self-signed certificate is fine here
/// (the connection itself pins it on first use).
private final class AnyCertificate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}
