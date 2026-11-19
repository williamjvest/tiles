import Foundation

/// One request / response / notification exchange on Sony's Savona API (VENICE, PXW): MessagePack-RPC arrays over a
/// WebSocket at `/linear` — `[0, id, method, params]` out, `[1, id, error, result]` back, `[2, name, data]` pushed.
///
/// Requests go one at a time, never pipelined: a VENICE can crash when two commands arrive while it is reconnecting on
/// a poor link, which is exactly the link Tiles runs on. While a request is out, the next
/// waits. A request that answers out of order (or never) is finished by id, so the chain can't jam.
///
/// Login tries what VENICE page traffic and the open-source clients show: the nonce/digest handshake
/// (`GetNonce` → HTTP-Digest `getsavonadigest.cgi` → `Alternate.Authentication.Digest`), then the older
/// basic-credential handshake (`getsavonacred.cgi` → `Alternate.Authentication.Basic`), then no login at all. HTTP
/// Digest and Basic challenges on the WebSocket handshake itself (a VENICE capture's `ws://user:pass@…/linear` shape)
/// are answered by the session's `URLSessionTaskDelegate`, so all three doors are covered.
public actor SavonaClient {
    public enum SavonaError: Error, Equatable, Sendable {
        case refused(String)
        case timeout(String)
        case closed
        case loginFailed(String)
        case badFrame(String)
    }

    public struct Notification: Sendable, Equatable {
        public var name: String
        public var data: MPValue
        public init(name: String, data: MPValue) {
            self.name = name
            self.data = data
        }
    }

    /// This connection's notifications. Each connect() makes a fresh stream: a failed attempt (or a canceled
    /// listener) finishes the old one for good, which left a reconnected session deaf (VENICE 2).
    public private(set) var updates: AsyncStream<Notification>
    private var noteContinuation: AsyncStream<Notification>.Continuation

    private let url: URL
    private let cgiBase: URL
    private let user: String?
    private let password: String?
    private let session: URLSession
    private let authDelegate: SavonaChallengeHandler?
    private let logger: @Sendable (String, String) -> Void

    private var task: URLSessionWebSocketTask?
    private var nextID: Int64 = 1
    private var pending: [Int64: CheckedContinuation<MPValue?, Error>] = [:]
    private var queue: [(id: Int64, frame: MPValue, timeout: Double)] = []
    private var busy = false
    private var receiveLoop: Task<Void, Never>?
    /// A message split across frames waits here for the rest (VENICE 2 splits and batches them).
    private var inbound = Data()
    private(set) public var closed = false
    /// The last frame the camera sent, for keep-alive decisions (`SavonaClient.keepAliveProperty`).
    public private(set) var lastInbound = Date()

    public init(host: String, user: String? = nil, password: String? = nil,
                logger: @escaping @Sendable (String, String) -> Void = { _, _ in }) {
        let clean = host.hasPrefix("ws") ? host : "ws://\(host)"
        url = URL(string: clean.hasSuffix("/linear") ? clean : clean + "/linear") ?? URL(string: "ws://127.0.0.1")!
        var base = URLComponents(string: clean) ?? URLComponents()
        base.query = nil
        base.path = ""
        cgiBase = base.url ?? URL(string: "http://127.0.0.1")!
        self.user = user
        self.password = password
        self.logger = logger
        let delegate = user.map { SavonaChallengeHandler(user: $0, password: password ?? "") }
        authDelegate = delegate
        session = delegate.map { URLSession(configuration: .ephemeral, delegate: $0, delegateQueue: nil) } ?? .shared
        let stream = AsyncStream.makeStream(of: Notification.self, bufferingPolicy: .bufferingNewest(256))
        updates = stream.stream
        noteContinuation = stream.continuation
    }

    deinit {
        noteContinuation.finish()
        receiveLoop?.cancel()
    }

    // MARK: - Connection

    /// Open the socket and log in. Throws `SavonaError` with what was tried when no door works.
    public func connect() async throws {
        closed = false
        inbound = Data()
        // Every connect asks the login CGI once, and it challenges every time: counted per connection, or a day of
        // HaLow reconnects ran the cap out and the seventh login "failed the password".
        authDelegate?.resetChallenges()
        let fresh = AsyncStream.makeStream(of: Notification.self, bufferingPolicy: .bufferingNewest(256))
        noteContinuation.finish()
        updates = fresh.stream
        noteContinuation = fresh.continuation
        let t = session.webSocketTask(with: URLRequest(url: url))
        t.maximumMessageSize = 16 * 1024 * 1024
        task = t
        t.resume()
        startReceiveLoop()
        try await t.sendPing()  // completes (or throws) once the handshake has — a 401 handshake dies here
        try await login()
        await subscribe()
    }

    private func login() async throws {
        // 1. VENICE 2's own page (rm.html, savona-2.9.4): the camera hands out SHA-256 credentials
        //    over HTTP auth, and they go back as Alternate.Authentication.Basic [{username, password}] — an array
        //    holding one map. A bare map, or GetNonce, gets no answer at all on that firmware.
        let (status2, text2) = await get(path: "/cgi-bin/getsavonacred.cgi")
        if status2 == 200, let colon = text2.firstIndex(of: ":") {
            let user = String(text2[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let pass = String(text2[text2.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !user.isEmpty {
                do {
                    _ = try await request("Alternate.Authentication.Basic",
                                          .array([.map(["username": .string(user), "password": .string(pass)])]),
                                          timeout: 4)
                    logger("savona", "login: basic credentials ok")
                    return
                } catch SavonaError.refused(let why) where why.hasPrefix("403") {
                    throw SavonaError.loginFailed("the camera refused the password (\(why))")
                } catch {
                    logger("savona", "login: basic credentials: \(shortError(error))")
                }
            }
        } else if status2 == 401 {
            throw SavonaError.loginFailed("the camera refused the password (HTTP 401)")
        }

        // 2. Older firmware: nonce over the socket, digest computed by an HTTP-Digest CGI, answer over the socket.
        let nonce = try? await request("Alternate.Authentication.GetNonce", .array([]), timeout: 4)
        if let nonce = nonce?["nonce"]?.string ?? nonce?.array?.first?["nonce"]?.string {
            let (status, text) = await get(path: "/cgi-bin/getsavonadigest.cgi", query: ["nonce": nonce])
            if status == 200, let pair = Self.keyValues(text) {
                _ = try await request("Alternate.Authentication.Digest",
                                      .array([.map(["cnonce": .string(pair["cnonce"] ?? ""),
                                                    "response": .string(pair["response"] ?? "")])]),
                                      timeout: 4)
                logger("savona", "login: nonce/digest ok")
                return
            }
            logger("savona", "login: getsavonadigest.cgi answered HTTP \(status)")
        }

        // 3. Maybe it just isn't locked. Prove the session works before calling it connected.
        _ = try await request("System.GetVersion", .array([]), timeout: 5)
        logger("savona", "login: none asked")
    }

    /// Ask for change notifications, in the page's shape: one argument, the list (a bare list gets no answer).
    private func subscribe() async {
        let kinds: MPValue = .array([.string("Notify.Properties"), .string("Notify.Process"), .string("Notify.Property")])
        if (try? await request("Notify.Subscribe", .array([kinds]), timeout: 6)) == nil {
            logger("savona", "Notify.Subscribe got no answer")
        }
    }

    public func close() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failPending(SavonaError.closed)
        noteContinuation.finish()
        receiveLoop?.cancel()
    }

    // MARK: - Requests (one at a time)

    /// A Savona request. `params` is whatever the method takes (`.array([...])` for most, a map for Basic auth).
    public func request(_ method: String, _ params: MPValue, timeout: Double = 8) async throws -> MPValue? {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MPValue?, Error>) in
            // The actor runs this synchronously before suspension, so `pending` can't miss the response race.
            pending[id] = continuation
            queue.append((id, .array([.int(0), .int(id), .string(method), params]), timeout))
            pump()
        }
    }

    /// Shorthand: read properties, `[{"Name": ["*"]}, …]`.
    public func get(_ names: [String], timeout: Double = 8) async throws -> [String: MPValue] {
        let selector: MPValue = .array([.map(Dictionary(uniqueKeysWithValues: names.map { ($0, MPValue.array(["*"])) }))])
        guard let result = try await request("Property.GetValue", selector, timeout: timeout) else { return [:] }
        return result.map ?? [:]
    }

    /// Shorthand: whether properties can be changed now, `{name: "Locked" | "Unlocked"}` (`Property.GetStatus`, asked as
    /// the page asks, `[{name: nil, …}]`). A menu item's lock is its own name, `….MenuItem`.
    public func statuses(_ names: [String], timeout: Double = 8) async throws -> [String: String] {
        let selector: MPValue = .array([.map(Dictionary(uniqueKeysWithValues: names.map { ($0, MPValue.null) }))])
        guard let result = try await request("Property.GetStatus", selector, timeout: timeout)?.map else { return [:] }
        return result.compactMapValues { $0.string ?? $0.unwrapped.string }
    }

    /// Shorthand: write one property.
    public func set(_ name: String, _ value: MPValue, timeout: Double = 8) async throws {
        _ = try await request("Property.SetValue", .array([.map([name: value])]), timeout: timeout)
    }

    /// Shorthand: press a key (`Button.SendKeys`, `[["Rec"]]` — the shape in the captured VENICE frames).
    public func sendKey(_ key: String, timeout: Double = 8) async throws {
        _ = try await request("Button.SendKeys", .array([.array([.string(key)])]), timeout: timeout)
    }

    /// What the VENICE page sends to hold its connection open (`Property.GetValue` on this property).
    public static let keepAliveProperty = "Network.Connection.KeepAlive"

    /// The camera's property names (`System.GetProperties`), whatever array shape it answers with.
    public func propertyNames() async throws -> [String] {
        let result = try await request("System.GetProperties", .array([]), timeout: 4)  // VENICE 2 doesn't answer it
        return Self.names(from: result)
    }

    nonisolated static func names(from result: MPValue?) -> [String] {
        var out: [String] = []
        func walk(_ v: MPValue) {
            switch v {
            case .string(let s): out.append(s)
            case .array(let a): a.forEach(walk)
            case .map(let m):
                if m.isEmpty { return }
                // A map of name → something is a name list too; a map inside an answer array is values, not names.
                if Set(m.keys) == Set(m.compactMap(\.value.string)) { m.keys.forEach { out.append($0) } } else {
                    m.keys.sorted().forEach { out.append($0) }
                }
            default: break
            }
        }
        walk(result ?? .null)
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// The camera's allowed values for a property (`Capability.GetValue` answers `[[name, kind, [values]]]`).
    public func options(for name: String, timeout: Double = 8) async -> [MPValue] {
        guard let result = try? await request("Capability.GetValue", .array([.array([.string(name)])]), timeout: timeout)
        else { return [] }
        // VENICE 2: {name: [true, "", [values]]}.
        if let entry = result.map?[name]?.array, entry.count >= 3, let list = entry[2].array { return list }
        guard let entries = result.array else { return [] }
        if let list = result.map?[name]?.array ?? result[name]?.array { return list }  // {name: [values]}
        var entry: MPValue? = entries.first(where: { $0.array?.first?.string == name })
        if entry == nil { entry = entries.first }
        return entry?[2]?.array ?? entry?[1]?.array ?? []
    }

    private func pump() {
        guard !busy, !queue.isEmpty, let next = queue.first else { return }
        busy = true
        queue.removeFirst()
        let t = task
        let timeout = next.timeout
        let id = next.id
        Task {
            do {
                guard let t else { throw SavonaError.closed }
                let data = MessagePack.encode(next.frame)
                try await t.send(.data(data))
            } catch {
                if let continuation = pending.removeValue(forKey: id) {
                    continuation.resume(throwing: SavonaError.refused("send: \(shortError(error))"))
                }
                self.pumpNext()
                return
            }
            // Nothing arrives (or the link is half dead): give up on this one so the queue can't jam.
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.expire(id: id, method: "")
        }
    }

    private func pumpNext() {
        busy = false
        pump()
    }

    private func expire(id: Int64, method: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: SavonaError.timeout(method.isEmpty ? "id \(id)" : method))
        pumpNext()
    }

    private func failPending(_ error: Error) {
        for (_, continuation) in pending { continuation.resume(throwing: error) }
        pending.removeAll()
        queue.removeAll()
        busy = false
    }

    // MARK: - Incoming

    private func startReceiveLoop() {
        guard let t = task else { return }
        receiveLoop = Task { [weak self] in
            while true {
                do {
                    let message = try await t.receive()
                    await self?.handle(message)
                } catch {
                    await self?.died(error)
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        lastInbound = Date()
        let data: Data
        switch message {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: return
        }
        let (frames, rest) = MessagePack.decodeAll(inbound + data)
        inbound = rest.count < (1 << 20) ? rest : Data()
        if frames.isEmpty && rest.isEmpty {
            logger("savona", "unparseable frame: \(String(decoding: data.prefix(64), as: UTF8.self))")
        }
        for frame in frames { handle(frame: frame) }
    }

    private func handle(frame: MPValue) {
        // [2, name, data] notifications carry a name where responses carry an id, so only the kind is common.
        guard case .array(let parts) = frame, parts.count >= 3, let kind = parts[0].number else {
            logger("savona", "unexpected message: \(frame.description.prefix(80))")
            return
        }
        switch Int(kind) {
        case 2:  // notification: [2, name, data] — three elements, no id
            guard let name = parts[1].string else { return }
            noteContinuation.yield(Notification(name: name, data: parts[2]))
        case 1:  // response: [1, id, error, result]
            guard parts.count >= 4, let id = parts[1].number,
                  let continuation = pending.removeValue(forKey: Int64(id)) else { return }
            let error = parts[2]
            let errorCode = error.isNull ? nil : (error.array?.first?.number ?? error[0]?.number)
            let errorText = error.isNull ? "" : (error.array?.dropFirst().compactMap { $0.string }.joined(separator: " ")
                ?? error[1]?.string ?? "")
            if let code = errorCode {
                continuation.resume(throwing: SavonaError.refused("\(Int(code)) \(errorText)"))
            } else {
                continuation.resume(returning: parts[3])
            }
            pumpNext()
        case 0:  // the camera asking us something; the page answers, we just log it
            logger("savona", "camera request: \(parts.dropFirst(2).map(\.description).joined(separator: " "))")
        default:
            logger("savona", "unknown frame kind \(Int(kind))")
        }
    }

    private func died(_ error: Error) {
        guard !closed else { return }
        closed = true
        logger("savona", "socket died: \(shortError(error))")
        failPending(SavonaError.closed)
        noteContinuation.finish()
    }

    // MARK: - HTTP (the login CGIs)

    private func get(path: String, query: [String: String] = [:]) async -> (Int, String) {
        var parts = URLComponents(url: cgiBase, resolvingAgainstBaseURL: false) ?? URLComponents()
        parts.path = path
        if !query.isEmpty { parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = parts.url else { return (0, "") }
        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, String(decoding: data, as: UTF8.self))
        } catch {
            return (0, shortError(error))
        }
    }

    /// A file to the camera the way its page's upload form posts one (rmt.html's HIDDEN_FORM_BIG6_UPLOAD_LUT_FILE,
    /// LUTConverter.js FILE_UPLOAD_REQ): multipart/form-data with `csrf` (four random 32-bit numbers, comma-joined, as
    /// the page makes them), the text fields, then the file under `fileField`. HTTP Digest, like the login CGI.
    /// Returns the HTTP status (0 when the request never got an answer) and the body.
    public func upload(path: String, fields: [(String, String)], fileField: String, fileName: String, data: Data,
                       timeout: Double = 180) async -> (Int, String) {
        var parts = URLComponents(url: cgiBase, resolvingAgainstBaseURL: false) ?? URLComponents()
        parts.path = path
        guard let url = parts.url else { return (0, "") }
        let boundary = "----TilesFormBoundary\(UInt64.random(in: 0...UInt64.max))"
        let csrf = (0..<4).map { _ in String(UInt32.random(in: 0...UInt32.max)) }.joined(separator: ",")
        var body = Data()
        func text(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        text("csrf", csrf)
        for (name, value) in fields { text(name, value) }
        body.append(Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n").utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        do {
            let (answer, response) = try await session.upload(for: request, from: body)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, String(decoding: answer.prefix(2000), as: UTF8.self))
        } catch {
            return (0, shortError(error))
        }
    }

    nonisolated private func shortError(_ error: Error) -> String {
        String(describing: error).prefix(160).description
    }

    nonisolated static func keyValues(_ text: String) -> [String: String]? {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let bits = line.split(separator: "=", maxSplits: 1)
            if bits.count == 2 { out[String(bits[0]).trimmingCharacters(in: .whitespaces)] =
                String(bits[1]).trimmingCharacters(in: .whitespaces) }
        }
        return out.isEmpty ? nil : out
    }
}

/// Answers HTTP Digest and Basic challenges (the login CGIs, and a Digest-authenticated WebSocket handshake) with the
/// camera's login. One retry per challenge, then the failure surfaces.
public final class SavonaChallengeHandler: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let user: String
    private let password: String
    /// How many challenges this delegate has answered, across tasks. A camera that keeps challenging is stuck, not asking.
    private let lock = NSLock()
    private var challengeCount = 0

    public init(user: String, password: String) {
        self.user = user
        self.password = password
    }

    /// A new connection's allowance (`SavonaClient.connect`).
    func resetChallenges() {
        lock.lock(); challengeCount = 0; lock.unlock()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodDefault, NSURLAuthenticationMethodNegotiate:
            lock.lock(); challengeCount += 1; let count = challengeCount; lock.unlock()
            if challenge.previousFailureCount > 1 || count > 6 {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(user: user, password: password, persistence: .none))
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

extension URLSessionWebSocketTask {
    /// `sendPing` as an awaitable.
    func sendPing() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
