import Foundation
import CryptoKit

/// URLSession delegate that handles server trust for Blackmagic cameras' self-signed TLS certificates.
///
/// Trust-on-first-use (TOFU): if no fingerprint is pinned yet, the presented certificate is accepted
/// and its fingerprint is reported via `onFingerprintObserved`. If a fingerprint is pinned, the
/// presented certificate must match or the challenge is rejected and `onFingerprintMismatch` fires.
///
/// Only the leaf certificate's SHA-256 fingerprint is compared (DER-encoded, lowercase hex).
/// This matches the form shown in Blackmagic Camera Setup.
public final class BlackmagicTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {

    /// Currently-pinned fingerprint (hex, lowercase, no colons). nil = trust-on-first-use mode.
    public var pinnedFingerprint: String?

    /// Called when no pin is set and a new certificate is accepted. The caller saves this as the pin.
    public var onFingerprintObserved: ((String) -> Void)?

    /// Called when the presented certificate doesn't match the pinned fingerprint.
    /// The new (observed) fingerprint is passed so the UI can prompt the user.
    public var onFingerprintMismatch: ((String) -> Void)?

    public override init() { super.init() }

    public func urlSession(_ session: URLSession,
                           didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Extract the leaf (first) certificate.
        guard let leaf = (SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate])?.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let observed = sha256Hex(SecCertificateCopyData(leaf) as Data)

        if let pinned = pinnedFingerprint {
            if observed == pinned {
                // Pinned match — accept.
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                // Mismatch — reject and surface for the UI.
                onFingerprintMismatch?(observed)
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        } else {
            // No pin yet: accept, report, and pin it here too. The saved pin only reaches the next connection, so
            // without this any certificate would have been accepted until the camera reconnected.
            pinnedFingerprint = observed
            onFingerprintObserved?(observed)
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        }
    }

    // MARK: - Helpers

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Fingerprint helpers

/// Normalize a hex fingerprint to lowercase, no colons.
public func normalisedFingerprint(_ fp: String) -> String {
    fp.lowercased().replacingOccurrences(of: ":", with: "")
}
