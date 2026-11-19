import Foundation
import Network

// MARK: - HTTP client

@MainActor
final class HTTPClient {
    static let maxBodyBytes = 65_536

    let id: UUID
    private let connection: NWConnection
    private let tokenStore: ControlServerTokenStore
    private weak var server: ControlServer?
    private var receiveBuffer = Data()
    private var responseSent = false
    private let nwQueue: DispatchQueue

    init(id: UUID, connection: NWConnection, tokenStore: ControlServerTokenStore,
         server: ControlServer) {
        self.id = id
        self.connection = connection
        self.tokenStore = tokenStore
        self.server = server
        self.nwQueue = server.nwQueue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready: self.read()
                case .failed, .cancelled: self.server?.removeHTTP(self.id)
                default: break
                }
            }
        }
        connection.start(queue: nwQueue)
    }

    func disconnect() { connection.cancel() }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxBodyBytes) { [weak self] data, _, _, error in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if error != nil { self.server?.removeHTTP(self.id); return }
                if let data { self.receiveBuffer.append(data) }
                if self.receiveBuffer.count > Self.maxBodyBytes {
                    self.sendHTTP(status: 413, body: "{\"type\":\"error\",\"message\":\"request too large\"}")
                    return
                }
                if self.tryParseHTTP() { return }
                self.read()
            }
        }
    }

    @discardableResult
    private func tryParseHTTP() -> Bool {
        guard let headerEnd = receiveBuffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
        guard let headerSection = String(data: receiveBuffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            sendHTTP(status: 400, body: "{\"type\":\"error\",\"message\":\"bad request\"}")
            return true
        }
        let lines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendHTTP(status: 400, body: "{\"type\":\"error\",\"message\":\"bad request\"}")
            return true
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendHTTP(status: 400, body: "{\"type\":\"error\",\"message\":\"bad request\"}")
            return true
        }
        let method = String(parts[0])
        let pathAndQuery = String(parts[1])
        let path = pathAndQuery.components(separatedBy: "?").first ?? pathAndQuery

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                headers[String(kv[0]).trimmingCharacters(in: .whitespaces).lowercased()] =
                    String(kv[1]).trimmingCharacters(in: .whitespaces)
            }
        }

        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        let bodyStart = headerEnd.upperBound
        let available = receiveBuffer.count - bodyStart
        if available < contentLength { return false }

        let bodyData = Data(receiveBuffer[bodyStart ..< (bodyStart + contentLength)])
        receiveBuffer.removeAll()

        let token = headers["x-twcc-token"]

        if method == "GET" {
            server?.handleHTTPGet(path: path, token: token, client: self)
        } else if method == "POST" {
            server?.handleHTTPPost(path: path, token: token, body: bodyData, client: self)
        } else {
            sendHTTP(status: 405, body: "{\"type\":\"error\",\"message\":\"method not allowed\"}")
        }
        return true
    }

    func sendHTTP(status: Int, body: String) {
        guard !responseSent else { return }
        responseSent = true
        let resp = "HTTP/1.1 \(status) \(httpStatus(status))\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        // Hold the connection itself: the server drops this client as soon as the response is queued, so a weak self
        // here was nil by the time the bytes went out, the close never happened, and a client reading to EOF hung.
        let conn = connection
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    private func httpStatus(_ code: Int) -> String {
        switch code {
        case 200: "OK"; case 400: "Bad Request"; case 401: "Unauthorized"
        case 404: "Not Found"; case 405: "Method Not Allowed"
        case 413: "Payload Too Large"; case 503: "Service Unavailable"
        default: "Unknown"
        }
    }
}

// MARK: - ControlServer HTTP handlers

extension ControlServer {

    func handleHTTPGet(path: String, token: String?, client: HTTPClient) {
        guard tokenStore.matches(token) else {
            sendJSON(.error(requestID: nil, code: "auth", message: "bad token"), status: 401, to: client)
            return
        }
        guard path == "/state" else {
            sendJSON(.error(requestID: nil, code: "notFound", message: "not found"), status: 404, to: client)
            return
        }
        guard let store else {
            sendJSON(.error(requestID: nil, code: "serverError", message: "no store"), status: 503, to: client)
            return
        }
        sendJSON(stateSnapshot(store: store), status: 200, to: client)
    }

    func handleHTTPPost(path: String, token: String?, body: Data, client: HTTPClient) {
        guard tokenStore.matches(token) else {
            sendJSON(.error(requestID: nil, code: "auth", message: "bad token"), status: 401, to: client)
            return
        }

        if path == "/command" {
            guard let req = try? JSONDecoder().decode(WireCommandRequest.self, from: body) else {
                sendJSON(.error(requestID: nil, code: "badRequest", message: "invalid JSON"), status: 400, to: client)
                return
            }
            let waitForResult = req.wait != false

            if !waitForResult {
                dispatchCommand(req, replyTo: nil)
                sendJSON(.result(requestID: req.id, results: [
                    WireResultEntry(camera: "", status: "accepted", field: nil, value: nil, error: nil)
                ]), status: 200, to: client)
                return
            }

            // Wait for result (up to 6 s)
            let deadline = Date().addingTimeInterval(6)
            dispatchCommand(req, replyTo: nil) { [weak self] entries in
                let now = Date()
                guard let self else { return }
                let finalEntries: [WireResultEntry] = now > deadline
                    ? entries.map { WireResultEntry(camera: $0.camera, status: "timeout",
                                                     field: $0.field, value: nil, error: nil) }
                    : entries
                Task { @MainActor in
                    self.sendJSON(.result(requestID: req.id, results: finalEntries), status: 200, to: client)
                }
            }

            // Timeout guard
            Task {
                let delay = max(0, deadline.timeIntervalSince(Date()))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await MainActor.run {
                    // HTTPClient closes after first send, so double-send is harmless
                    self.sendJSON(.result(requestID: req.id, results: [
                        WireResultEntry(camera: "", status: "timeout", field: nil, value: nil, error: nil)
                    ]), status: 200, to: client)
                }
            }
            return
        }

        if path == "/app" {
            guard let req = try? JSONDecoder().decode(WireAppRequest.self, from: body) else {
                sendJSON(.error(requestID: nil, code: "badRequest", message: "invalid JSON"), status: 400, to: client)
                return
            }
            // The action's own answer: a refused one (a missing `enabled`, an unknown page) is a 400, not "confirmed".
            let reply = dispatchAppAction(req, replyToWS: nil)
            if case .error = reply {
                sendJSON(reply, status: 400, to: client)
            } else {
                sendJSON(reply, status: 200, to: client)
            }
            return
        }

        sendJSON(.error(requestID: nil, code: "notFound", message: "not found"), status: 404, to: client)
    }

    private func sendJSON(_ msg: WireMessage, status: Int, to client: HTTPClient) {
        let body = (try? String(data: JSONEncoder().encode(msg), encoding: .utf8)) ?? "{}"
        client.sendHTTP(status: status, body: body)
    }

    // Builds a /state snapshot without seeding lastPublished (read-only).
    private func stateSnapshot(store: DashboardStore) -> WireMessage {
        let cameras = store.cameras.map { APICameraFull(from: $0) }
        let pages = store.pages.map { APIPageEntry(from: $0, cameras: store.cameras(on: $0).map(\.id), currentPageID: store.currentPageID) }
        return .snapshot(cameras: cameras, pages: pages,
                         currentPageID: store.currentPageID?.uuidString, radio: nil, locked: store.controlsLocked)
    }
}
