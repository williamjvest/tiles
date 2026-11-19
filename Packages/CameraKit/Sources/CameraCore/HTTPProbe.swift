import Foundation

/// One plain-HTTP GET to an address, as Add Camera's probes ask it what it is (`ArriRemoteProbe`, `SonyRemoteProbe`).
enum HTTPProbe {
    enum Outcome {
        case answered(Data, HTTPURLResponse)
        /// Something is at the address, but no web server: refused, dropped, or not HTTP.
        case noWebServer
    }

    /// nil when the address couldn't be reached (off, wrong address, still joining the network) or isn't a network
    /// address at all (a USB or Bluetooth camera's).
    static func get(host: String, path: String, timeout: TimeInterval,
                    resourceTimeout: TimeInterval? = nil) async -> Outcome? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.hasPrefix("usb:"), !trimmed.hasPrefix("bt:"),
              let url = URL(string: "http://\(trimmed)\(path)") else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = resourceTimeout ?? timeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return nil }
            return .answered(data, http)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .networkConnectionLost, .badServerResponse: return .noWebServer
            default: return nil
            }
        } catch {
            return nil
        }
    }
}
