import Foundation

/// HTTP to one camera's Web Remote: the calls the camera's own page makes, nothing pipelined beyond what the page
/// itself does (one long poll open while settings are sent). Every short request is timed, so the dashboard can show
/// the link's latency; the long poll isn't, since it waits on purpose.
public final class ArriClient: Sendable {
    public let host: String
    /// http://host (with any :port typed), no trailing slash.
    public let base: URL
    private let session: URLSession
    private let longSession: URLSession
    private let cacheDirectory: URL?
    private let timings = Timings()

    /// `cacheDirectory`: where the page script is kept between connections (it's the biggest thing the camera sends,
    /// and asked for again only with the camera's own validators). Nil keeps nothing.
    public init(host: String, timeout: TimeInterval = 8,
                cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("ArriWebRemote", isDirectory: true)) throws {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(" "),
              let base = URL(string: "http://\(trimmed)"), base.host != nil else { throw ArriError.badAddress(host) }
        self.host = trimmed
        self.base = base
        self.cacheDirectory = cacheDirectory
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 3
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 2
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        let long = URLSessionConfiguration.ephemeral
        long.timeoutIntervalForRequest = 45
        long.timeoutIntervalForResource = 50
        long.requestCachePolicy = .reloadIgnoringLocalCacheData
        long.httpMaximumConnectionsPerHost = 1
        longSession = URLSession(configuration: long)
    }

    deinit {
        session.invalidateAndCancel()
        longSession.invalidateAndCancel()
    }

    // MARK: - The calls

    /// `all.cgi`: every variable and command, and the session id. Each call opens a new session on the camera.
    public func all() async throws -> (snapshot: ArriSnapshot, bytes: Int) {
        let data = try await get("/all.cgi")
        return (try ArriSnapshot(data: data), data.count)
    }

    /// `update.cgi?id=`: blocks until the camera has something to report for this session, then answers with only the
    /// changed fields. The session id `id` is echoed back unchanged — pass the same one every poll. Nil when the local
    /// timeout ran out first (a quiet camera, not a fault). Throws `ArriError.camera` when the camera answers
    /// `{"ERROR": "…Invalid id…"}`, signaling the session is gone.
    public func update(after id: Int, timeout: TimeInterval = 30) async throws -> Data? {
        var request = URLRequest(url: url("/update.cgi?id=\(id)"), timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await longSession.data(for: request)
            try Self.check(response, data)
            return data
        } catch let error as URLError where error.code == .timedOut {
            return nil
        }
    }

    /// `set.cgi`: one or more variables. Throws unless the camera answers `result: 1`.
    public func set(_ values: [String: ArriValue]) async throws {
        let body = values.mapValues(\.json)
        let data = try await post("/set.cgi", body)
        let json = try Self.object(data)
        let result = (json["result"] as? NSNumber)?.intValue
        guard result == 1 else { throw ArriError.refused(Self.reason(json, result)) }
    }

    /// `call.cgi`: runs a command by the camera's ID for it. A result of 0 or more is accepted.
    @discardableResult
    public func call(_ commandID: String, set values: [String: ArriValue] = [:]) async throws -> Int {
        let data = try await post("/call.cgi", ["command": commandID, "set": values.mapValues(\.json)])
        let json = try Self.object(data)
        guard let result = (json["result"] as? NSNumber)?.intValue, result >= 0 else {
            throw ArriError.refused(Self.reason(json, (json["result"] as? NSNumber)?.intValue))
        }
        return result
    }

    /// The page's script, for the enums' labels. Kept per camera (`key`: its serial number when it gives one) and
    /// asked for again with the camera's ETag / Last-Modified, so a reconnect over HaLow costs a 304, not the script.
    public func pageScript(key: String?) async throws -> (text: String, bytes: Int) {
        let file = cacheFile(key: key)
        var cached: CachedScript?
        if let file, let data = try? Data(contentsOf: file) {
            cached = try? JSONDecoder().decode(CachedScript.self, from: data)
        }
        // The biggest thing the camera sends: given the long session's minute, not the short one's 24 s, over HaLow.
        var request = URLRequest(url: url("/js/all-dg.min.js"), timeoutInterval: 30)
        if let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = cached?.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        let start = Date()
        let (data, response) = try await longSession.data(for: request)
        timings.add(Date().timeIntervalSince(start))
        let http = response as? HTTPURLResponse
        if http?.statusCode == 304, let cached { return (cached.text, 0) }
        try Self.check(response, data)
        let text = String(decoding: data, as: UTF8.self)
        if let file, http?.value(forHTTPHeaderField: "ETag") != nil || http?.value(forHTTPHeaderField: "Last-Modified") != nil {
            let entry = CachedScript(text: text, etag: http?.value(forHTTPHeaderField: "ETag"),
                                     lastModified: http?.value(forHTTPHeaderField: "Last-Modified"))
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(entry).write(to: file, options: .atomic)
        }
        return (text, data.count)
    }

    /// A GET of any path on the camera (all.cgi, and camctl's raw requests).
    public func get(_ path: String) async throws -> Data {
        let start = Date()
        let (data, response) = try await session.data(from: url(path))
        timings.add(Date().timeIntervalSince(start))
        try Self.check(response, data)
        return data
    }

    public func post(_ path: String, _ body: Any) async throws -> Data {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard JSONSerialization.isValidJSONObject(body) else { throw ArriError.badResponse("a request body JSON can't carry") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let start = Date()
        let (data, response) = try await session.data(for: request)
        timings.add(Date().timeIntervalSince(start))
        try Self.check(response, data)
        return data
    }

    /// The mean of the last four short round trips, in milliseconds.
    public var latencyMilliseconds: Int? { timings.mean.map { Int($0 * 1000) } }

    // MARK: - Helpers

    private func url(_ path: String) -> URL {
        URL(string: path, relativeTo: base)!.absoluteURL
    }

    private func cacheFile(key: String?) -> URL? {
        guard let cacheDirectory else { return nil }
        let raw = "\(host)-\(key ?? "any")"
        let safe = String(raw.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" })
        return cacheDirectory.appendingPathComponent("\(safe).json")
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ArriError.badResponse("not HTTP") }
        guard (200...299).contains(http.statusCode) else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["ERROR"] as? String ?? json["error"] as? String {
                throw ArriError.camera("\(message) (HTTP \(http.statusCode))")
            }
            throw ArriError.http(http.statusCode)
        }
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ArriError.badResponse("not a JSON object")
        }
        if let message = json["ERROR"] as? String { throw ArriError.camera(message) }
        return json
    }

    static func reason(_ json: [String: Any], _ result: Int?) -> String {
        (json["error"] as? String) ?? (json["ERROR"] as? String) ?? "result \(result.map(String.init) ?? "missing")"
    }

    private struct CachedScript: Codable {
        var text: String
        var etag: String?
        var lastModified: String?
    }

    private final class Timings: @unchecked Sendable {
        private let lock = NSLock()
        private var recent: [TimeInterval] = []
        func add(_ t: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            recent.append(t)
            if recent.count > 4 { recent.removeFirst(recent.count - 4) }
        }
        var mean: TimeInterval? {
            lock.lock(); defer { lock.unlock() }
            return recent.isEmpty ? nil : recent.reduce(0, +) / Double(recent.count)
        }
    }
}
