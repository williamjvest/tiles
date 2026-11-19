import Foundation

/// Which way a Sony camera at an address is controlled, found by asking it: a VENICE (and the Savona family: FX9, PXW)
/// serves its Web Remote page, `/rm.html`, behind its login; an FX3, FX6 or BURANO has no web server there and is
/// driven over Camera Remote (PTP-IP). Add Camera picks the protocol from this, and the picker stays as an override.
public enum SonyRemoteProbe {
    public enum Result: Sendable, Equatable {
        /// `/rm.html` answered (200, or 401 for its login): the Web Remote protocol.
        case webRemote
        /// Nothing listening for HTTP, or no Web Remote page: Camera Remote.
        case cameraRemote
    }

    /// nil when the camera couldn't be reached (off, wrong address, still joining the network): leave the choice alone.
    public static func probe(host: String, timeout: TimeInterval = 3) async -> Result? {
        switch await HTTPProbe.get(host: host, path: "/rm.html", timeout: timeout) {
        case nil: return nil
        case .noWebServer: return .cameraRemote  // the address answers, but not with a web server
        case .answered(_, let http): return http.statusCode == 200 || http.statusCode == 401 ? .webRemote : .cameraRemote
        }
    }
}
