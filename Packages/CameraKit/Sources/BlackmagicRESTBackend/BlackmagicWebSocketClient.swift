import Foundation

/// URLSessionWebSocketTask wrapper.
///
///   connect to ws[s]://<host>/control/api/v1/event/websocket
///   send {"type":"request","data":{"action":"subscribe","properties":[...]}}
///   receive {"type":"response","data":{"action":"subscribe","properties":[...],"success":true,"values":{property: value}}}
///   receive {"type":"event","data":{"action":"propertyValueChanged","property":"...","value":...}}
actor BlackmagicWebSocketClient {
    private var url: URL
    private let scheme: String
    private var task: URLSessionWebSocketTask?
    private let session: URLSession

    /// What connect subscribes to, with the first display's /monitoring/{name}/displayLUT and falseColor. The rest of
    /// the monitoring (every output's overlays) is subscribed after connect.
    ///
    /// Not /transports/0/timecode or /transports/0/playback: a PYXIS pushes the first every other frame and the second
    /// every frame while playing (~20–30 kbit/s each). The app runs its own timecode clock, reads the playback position
    /// when a command needs it, and takes play/pause from /transports/0/play.
    static let baseSubscribeProperties: [String] = [
        "/transports/0/record",
        "/video/iso",
        "/video/supportedISOs",
        "/video/shutter",
        "/video/shutter/measurement",
        "/video/supportedShutters",
        "/video/whiteBalance",
        "/video/whiteBalance/description",
        "/video/whiteBalanceTint",
        "/video/whiteBalanceTint/description",
        "/video/ndFilter",
        "/video/supportedNDFilters",
        "/system/format",
        "/system/codecFormat",
        // Not /system/supportedCodecFormats: not in the subscribable list; read once over REST on connect.
        "/lens/iris",
        "/lens/iris/description",
        "/media/workingset",
        "/camera/power",
        "/camera/colorBars",
        "/transports/0",
        "/transports/0/play",
        "/transports/0/clipIndex",
        "/timelines/0",
        "/slates/nextClip",
        "/system/dynamicRange",
        "/system/supportedDynamicRanges",
    ]

    /// The camera's login, on the opening request.
    private let authorization: String?

    init(host: String, useHTTPS: Bool = false, session: URLSession = .shared, login: BlackmagicLogin? = nil) {
        scheme = useHTTPS ? "wss" : "ws"
        url = Self.url(scheme, host)
        self.session = session
        authorization = login?.authorization
    }

    /// The next connect goes to `host` (as the REST client's `setHost`).
    func setHost(_ host: String) { url = Self.url(scheme, host) }

    private static func url(_ scheme: String, _ host: String) -> URL {
        URL(string: "\(scheme)://\(host)/control/api/v1/event/websocket")!
    }

    // MARK: - Connect

    func connect() {
        task?.cancel(with: .goingAway, reason: nil)
        var request = URLRequest(url: url)
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let t = session.webSocketTask(with: request)
        task = t
        t.resume()
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    enum PingResult: Sendable {
        case pong(Duration)
        /// No pong within the timeout: the link has stalled.
        case noAnswer
        /// The socket is gone; the receive loop reports that.
        case closed
    }

    /// One ping and what came of it.
    func ping(timeout: Duration) async -> PingResult {
        guard let task else { return .closed }
        let start = ContinuousClock.now
        let answered = Once()
        return await withCheckedContinuation { continuation in
            task.sendPing { error in
                if answered.claim() { continuation.resume(returning: error == nil ? .pong(ContinuousClock.now - start) : .closed) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if answered.claim() { continuation.resume(returning: .noAnswer) }
            }
        }
    }

    // MARK: - Subscribe

    /// One request per property: a camera refuses a whole subscribe request over one property it hasn't got (a PYXIS
    /// 12K answers `Property "/video/ndFilter" not found`, success false, and then pushes nothing at all).
    func subscribe(_ properties: [String]) async throws {
        for property in properties {
            let msg: [String: Any] = [
                "type": "request",
                "data": ["action": "subscribe", "properties": [property]] as [String: Any],
            ]
            let data = try JSONSerialization.data(withJSONObject: msg)
            try await task?.send(.string(String(decoding: data, as: UTF8.self)))
        }
    }

    // MARK: - Receive loop

    /// Yields decoded WS events. Call this after `connect()`.
    func receiveEvents() -> AsyncStream<WSEvent> {
        // Capture the current task strongly so the loop doesn't see nil after actor hop.
        guard let currentTask = task else {
            return AsyncStream { $0.finish() }
        }
        return AsyncStream { continuation in
            let receiveTask = Task {
                while true {
                    do {
                        let message = try await currentTask.receive()
                        let event: WSEvent?
                        switch message {
                        case .string(let s):
                            event = BlackmagicWebSocketClient.parseEvent(Data(s.utf8))
                        case .data(let d):
                            event = BlackmagicWebSocketClient.parseEvent(d)
                        @unknown default:
                            event = nil
                        }
                        if let event { continuation.yield(event) }
                    } catch {
                        continuation.finish()
                        return
                    }
                }
            }
            // Cancel the receive loop when the stream is torn down.
            continuation.onTermination = { _ in receiveTask.cancel() }
        }
    }

    // MARK: - Parse

    static func parseEvent(_ data: Data) -> WSEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type_ = obj["type"] as? String else { return nil }

        let inner = obj["data"] as? [String: Any]

        if type_ == "event", inner?["action"] as? String == "websocketOpened" { return .opened }

        if type_ == "event", inner?["action"] as? String == "propertyValueChanged",
           let property = inner?["property"] as? String,
           let value = inner?["value"] {
            return .propertyChanged(property: property, value: value)
        }

        if type_ == "response" {
            return .subscribeResult(success: inner?["success"] as? Bool ?? true, error: inner?["errorMessage"] as? String,
                                    properties: inner?["properties"] as? [String] ?? [],
                                    values: inner?["values"] as? [String: Any] ?? [:])
        }

        return nil
    }
}

/// True for the first caller only: the pong and the timeout race to answer a ping.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}

enum WSEvent: @unchecked Sendable {
    case opened
    /// The camera's answer to a subscribe request: the property and (mostly) its current value, or a refusal naming it.
    case subscribeResult(success: Bool, error: String?, properties: [String], values: [String: Any])
    case propertyChanged(property: String, value: Any)
}
