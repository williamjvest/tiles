import Foundation

/// Whether an address is an ARRI camera's Web Remote, found by asking it: `all.cgi` answers with the camera's
/// variables (no login). Add Camera says what it found, the model when the camera names it (as text, or a number the page knows).
public enum ArriRemoteProbe {
    public enum Result: Sendable, Equatable {
        /// `all.cgi` answered with variables: an ARRI Web Remote. The model, when it's given as text.
        case arri(model: String?)
        /// Something answered, but not an ARRI Web Remote.
        case notArri
    }

    /// nil when the address couldn't be reached (off, wrong address, still joining the network).
    /// `timeout`: all.cgi is every variable, so give a HaLow link time to bring it.
    public static func probe(host: String, timeout: TimeInterval = 8) async -> Result? {
        switch await HTTPProbe.get(host: host, path: "/all.cgi", timeout: timeout, resourceTimeout: timeout * 2) {
        case nil: return nil
        case .noWebServer: return .notArri
        case .answered(let data, let http):
            guard http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let variables = json["variables"] as? [String: Any] else { return .notArri }
            // As text, or as a number the page script names (an ALEXA Mini sends 2).
            let model = ["SystemCameraType", "CameraType", "SystemCameraModel"].lazy
                .compactMap { name -> String? in
                    let value = (variables[name] as? [String: Any])?["value"]
                    if let text = value as? String { return text }
                    return (value as? NSNumber).flatMap { ArriTables.modelName(cameraType: $0.intValue) }
                }
                .first { !$0.isEmpty }
            return .arri(model: model)
        }
    }
}
