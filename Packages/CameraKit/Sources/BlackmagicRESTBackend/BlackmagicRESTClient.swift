import CameraCore
import Foundation

/// Thin URLSession wrapper for Blackmagic REST API calls.
///
/// Base URL: `http[s]://<host>/control/api/v1/` (REST API for Blackmagic Cameras, p.2)
/// All PUTs return 204 No Content on success.
/// 403 = cannot change in current state. 501 = not implemented on this device.
actor BlackmagicRESTClient {
    private(set) var baseURL: URL
    private let scheme: String
    private let session: URLSession
    /// Sent with every request when the camera has a login.
    private let authorization: String?
    /// The login is Remote Control's: a refusal is of the remote password, or Remote Control is off at the camera.
    private let remoteControl: Bool

    init(host: String, useHTTPS: Bool = false, session: URLSession = .shared, login: BlackmagicLogin? = nil) {
        scheme = useHTTPS ? "https" : "http"
        baseURL = Self.baseURL(scheme, host)
        self.session = session
        authorization = login?.authorization
        remoteControl = login?.user == BlackmagicConnection.remoteControlUser
    }

    /// Requests from now on go to `host`: a camera on a cable can be at another address after it's plugged in again.
    func setHost(_ host: String) { baseURL = Self.baseURL(scheme, host) }

    private static func baseURL(_ scheme: String, _ host: String) -> URL {
        URL(string: "\(scheme)://\(host)/control/api/v1/")!
    }

    private func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 10)
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        return request
    }

    // MARK: - GET

    func get<T: Decodable & Sendable>(_ path: String, as type: T.Type) async throws -> T {
        try JSONDecoder().decode(T.self, from: await get(path))
    }

    /// The response body as it came.
    func get(_ path: String) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = makeRequest(url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try checkStatus(response, data: data)
        return data
    }

    // MARK: - PUT

    @discardableResult
    func put(_ path: String, body: some Encodable) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = makeRequest(url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try checkStatus(response, data: data)
        return data
    }

    /// A body that isn't JSON: a streaming platform's XML.
    @discardableResult
    func putRaw(_ path: String, body: Data, contentType: String) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = makeRequest(url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try checkStatus(response, data: data)
        return data
    }

    /// PUT with no body: the camera's state saved as a preset.
    func putEmpty(_ path: String) async throws {
        var request = makeRequest(baseURL.appendingPathComponent(path))
        request.httpMethod = "PUT"
        let (data, response) = try await session.data(for: request)
        try checkStatus(response, data: data)
    }

    /// A file, the way the camera takes a preset: the bytes, named in Content-Disposition. Returns the camera's answer.
    func upload(_ path: String, data body: Data, filename: String) async throws -> Data {
        var request = makeRequest(baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("attachment; filename=\"\(filename)\"", forHTTPHeaderField: "Content-Disposition")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try checkStatus(response, data: data)
        return data
    }

    // MARK: - DELETE

    func delete(_ path: String) async throws {
        let url = baseURL.appendingPathComponent(path)
        var request = makeRequest(url)
        request.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: request)
        try checkStatus(response, data: data)
    }

    // MARK: - POST

    @discardableResult
    func post(_ path: String, body: (some Encodable)? = Optional<EmptyBody>.none) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = makeRequest(url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data, response) = try await session.data(for: request)
        try checkStatus(response, data: data)
        return data
    }

    // MARK: - Error checking

    private func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...204: return
        case 401: throw remoteControl ? BlackmagicError.remotePasswordRefused : BlackmagicError.login(sent: authorization != nil)
        case 403: throw BlackmagicError.forbidden(Self.reason(in: data))
        case 501: throw BlackmagicError.notImplemented
        default:
            throw BlackmagicError.http(http.statusCode, Self.reason(in: data))
        }
    }

    /// The camera's own words: `{"error": "Invalid state"}`, or the first of a 409's `details`.
    static func reason(in data: Data) -> String {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(decoding: data, as: UTF8.self)
        }
        if let details = body["details"] as? [[String: Any]], let message = details.first?["message"] as? String {
            return message
        }
        return body["error"] as? String ?? String(decoding: data, as: UTF8.self)
    }
}

enum BlackmagicError: LocalizedError, CustomStringConvertible {
    /// 403, with the camera's reason ("Stream control cannot be performed: …").
    case forbidden(String)
    case notImplemented
    case http(Int, String)
    case transportError(Error)
    /// The WebSocket didn't open, or didn't answer every subscribe request, in time.
    case noEvents
    /// The WebSocket closed after connecting.
    case eventsClosed
    /// A ping on the WebSocket got no answer.
    case noAnswer
    /// 401: the camera has a login, and Tiles sent none (`sent` false) or one it turned down.
    case login(sent: Bool)
    /// 401 through Remote Control: the remote password turned down, or Remote Control off at the camera.
    case remotePasswordRefused

    var description: String {
        switch self {
        case .forbidden(let reason): "Camera refused (403): \(reason)"
        case .notImplemented: "Not implemented on this device (501)"
        case .http(let code, let msg): "HTTP \(code): \(msg)"
        case .transportError(let e): "Network error: \(e.localizedDescription)"
        case .noEvents: "The camera's event connection didn't answer"
        case .eventsClosed: "The camera's event connection closed"
        case .noAnswer: "The camera stopped answering"
        case .login(sent: false): "The camera wants a login: add its user and password to this camera in Settings"
        case .remotePasswordRefused:
            "The camera turned down the remote password: check it in Settings, and that Remote Control is on at the camera (Setup, page 13)"
        case .login(sent: true): "The camera turned down the login: check the user and password in Settings"
        }
    }

    /// What a warning shows ("HTTP 400: Invalid state"), not "BlackmagicError error 0".
    var errorDescription: String? { description }
}

struct EmptyBody: Encodable {}

/// A camera's network access login (Blackmagic Camera Setup, or the camera's network menu), sent as HTTP Basic with
/// every request and the WebSocket's opening one. Sent whenever it's set: a camera without a login ignores it.
public struct BlackmagicLogin: Sendable, Equatable {
    public var user: String
    public var password: String

    public init(user: String, password: String) {
        self.user = user
        self.password = password
    }

    var authorization: String { "Basic " + Data("\(user):\(password)".utf8).base64EncodedString() }
}
