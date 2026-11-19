import Foundation
import Network
import CameraKitTestSupport

/// An in-process ARRI Web Remote (plain HTTP, one request per connection): `all.cgi`, the page script with an ETag,
/// `update.cgi?id=` held open until something changes, `set.cgi` checked against each variable's range, flags and
/// read-only bit, and `call.cgi` with REC and playback acting on the variables as a camera would. Its long poll can
/// be missing (404) or answer in the flat shape, to rehearse the backend's fallbacks.
///
/// Session model matches the real camera: `all.cgi` assigns a session id (`sessionID`) that the client must reuse for
/// every `update.cgi?id=` poll. The camera echoes it unchanged in every answer. Sending a wrong id returns an
/// `{"ERROR": "Invalid id"}` response, forcing a new `all.cgi`. The internal `counter` tracks local changes and is
/// never sent to the client.
final class FakeArriCamera: @unchecked Sendable {
    enum UpdateShape { case nested, flat, counterOnly, missing }

    struct Config {
        var update: UpdateShape = .nested
        var servesScript = true
        var longPollSeconds: Double = 1.5
        var recDelay: Double = 0.15
        /// Variables named here trigger a software reload when written via set.cgi.
        /// The fake invalidates sessions, serves one all.cgi with SystemSoftwareIsRestarting true,
        /// then clears it so the next update answer carries false.
        var reloads: Set<String> = []
    }

    var config: Config
    private let lock = NSLock()
    /// The current session id, assigned by `all.cgi`. The client must echo this in `update.cgi?id=`.
    private var sessionID = 42
    /// Internal change sequence; not exposed to the client. The long poll uses it to know when to wake.
    private var counter = 0
    /// The change counter at the time of the last answered poll for each session id.
    private var lastAnsweredCounter: [Int: Int] = [:]
    private var variables: [String: [String: Any]]
    private var commands: [String: String]
    private var changes: [(counter: Int, name: String)] = []
    private var setBodies: [[String: Any]] = []
    private var callBodies: [[String: Any]] = []
    /// During a simulated reload: how many all.cgi calls should still report SystemSoftwareIsRestarting true (1 = one shot).
    private var reloadAllCgiRemaining = 0
    /// While > 0 the fake is mid-reload: update.cgi returns errors and all.cgi may report restarting.
    private var reloadDeadlineSeconds: Double = 0
    private var reloadStarted: Date?
    private var requested: [String] = []
    private var scriptsServed = 0
    private var notModified = 0
    private var allCgiCalls = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "fake-arri", qos: .userInitiated)
    private(set) var port: UInt16 = 0

    /// `extra` and `extraCommands` add or replace variables and commands, for a camera shaped unlike the fixture.
    init(config: Config = Config(), extra: [String: [String: Any]] = [:], extraCommands: [String: String] = [:]) {
        self.config = config
        variables = ArriFixture.variables().merging(extra) { _, new in new }
        commands = ArriFixture.commands.merging(extraCommands) { _, new in new }
    }

    var host: String { "127.0.0.1:\(port)" }

    func start() async throws {
        // On 127.0.0.1 (LoopbackListener), again if the system says the address is in use.
        try await LoopbackListener.retrying { [self] in
            listener?.cancel()
            try await startListening()
        }
    }

    private func startListening() async throws {
        let l = try LoopbackListener.make()
        listener = l
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let p = l.port?.rawValue { self?.port = p }
                    if !resumed { resumed = true; cont.resume() }
                case .failed(let e), .waiting(let e):
                    if !resumed { resumed = true; cont.resume(throwing: e) }
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - For tests

    /// A change made on the camera body (simulates a physical control change or an internal state transition).
    func change(_ name: String, _ value: Any) {
        lock.withLock {
            variables[name]?["value"] = value
            counter += 1
            changes.append((counter, name))
        }
    }

    /// Force the current session to expire. The next `update.cgi?id=<sessionID>` gets `{"ERROR": "Invalid id"}`.
    func expireSession() {
        lock.withLock {
            sessionID += 1000
        }
    }

    /// Directly change a variable's field (e.g. "max", "readonly") and record it as a change, simulating the
    /// camera narrowing a range or locking a setting during REC.
    func changeField(_ name: String, field: String, value: Any) {
        lock.withLock {
            variables[name]?[field] = value
            counter += 1
            changes.append((counter, name))
        }
    }

    /// Add or replace a variable (for test setup after the fake is constructed).
    func setVariable(_ name: String, _ fields: [String: Any]) {
        lock.withLock { variables[name] = fields }
    }

    /// Add a command id → name entry.
    func addCommand(_ id: String, name: String) {
        lock.withLock { commands[id] = name }
    }

    func value(_ name: String) -> Any? { lock.withLock { variables[name]?["value"] } }
    var sets: [[String: Any]] { lock.withLock { setBodies } }
    var calls: [[String: Any]] { lock.withLock { callBodies } }
    var paths: [String] { lock.withLock { requested } }
    var scriptBodiesServed: Int { lock.withLock { scriptsServed } }
    var notModifiedAnswers: Int { lock.withLock { notModified } }
    /// How many times `all.cgi` was served (including the initial connect).
    var allCgiCallCount: Int { lock.withLock { allCgiCalls } }

    // MARK: - HTTP

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, Data())
    }

    private func receive(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.handle(request, conn)
            } else if done || error != nil {
                conn.cancel()
            } else {
                self.receive(conn, buffer)
            }
        }
    }

    struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    static func parse(_ buffer: Data) -> Request? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private func handle(_ request: Request, _ conn: NWConnection) {
        lock.withLock { requested.append(request.path) }
        let path = request.path
        switch (request.method, path.split(separator: "?").first.map(String.init) ?? path) {
        case ("GET", "/all.cgi"):
            // Each all.cgi call opens a new session: assign a new sessionID and record the change counter at this moment.
            let doc: [String: Any] = lock.withLock {
                sessionID += 1
                lastAnsweredCounter[sessionID] = counter
                allCgiCalls += 1
                // After a simulated reload: the first all.cgi after the dead window reports restarting; subsequent ones don't.
                if reloadAllCgiRemaining > 0 {
                    reloadAllCgiRemaining -= 1
                } else if variables["SystemSoftwareIsRestarting"] != nil {
                    // Clear the flag so the next update answer carries false.
                    variables["SystemSoftwareIsRestarting"] = ["value": false, "type": "bool", "readonly": 1]
                    counter += 1
                    changes.append((counter, "SystemSoftwareIsRestarting"))
                }
                return ["id": sessionID, "variables": variables, "commands": commands]
            }
            reply(conn, json: doc)
        case ("GET", "/js/all-dg.min.js"):
            guard config.servesScript else { return reply(conn, status: 404, json: ["ERROR": "not found"]) }
            if request.headers["if-none-match"] == "\"fixture-1\"" {
                lock.withLock { notModified += 1 }
                return send(conn, status: 304, type: "application/javascript", body: Data(), headers: ["ETag": "\"fixture-1\""])
            }
            lock.withLock { scriptsServed += 1 }
            send(conn, status: 200, type: "application/javascript", body: Data(ArriFixture.script.utf8),
                 headers: ["ETag": "\"fixture-1\""])
        case ("GET", "/update.cgi"):
            guard config.update != .missing else { return reply(conn, status: 404, json: ["ERROR": "not found"]) }
            let clientID = Int(path.components(separatedBy: "id=").last ?? "") ?? 0
            // Wrong session id → Invalid id (the real camera does this when a session is gone).
            let currentSession = lock.withLock { sessionID }
            guard clientID == currentSession else {
                reply(conn, json: ["ERROR": "Invalid id: \(clientID)"])
                break
            }
            let deadline = Date().addingTimeInterval(config.longPollSeconds)
            Task.detached { [weak self] in
                guard let self else { return }
                // During a simulated reload dead window: close the connection with no answer (camera is unresponsive).
                let reloadDeadline: Date? = self.lock.withLock {
                    guard let started = self.reloadStarted, self.reloadDeadlineSeconds > 0 else { return nil }
                    return started.addingTimeInterval(self.reloadDeadlineSeconds)
                }
                if let reloadDeadline, Date() < reloadDeadline {
                    // Drop the connection to simulate the camera being mid-restart.
                    conn.cancel()
                    return
                }
                // Wait until there are new changes since this session's last answered counter.
                while Date() < deadline {
                    let (hasChanges, stillValid) = self.lock.withLock {
                        let last = self.lastAnsweredCounter[clientID] ?? 0
                        return (self.counter > last, self.sessionID == clientID)
                    }
                    if !stillValid { self.reply(conn, json: ["ERROR": "Invalid id: \(clientID)"]); return }
                    if hasChanges { break }
                    try? await Task.sleep(for: .milliseconds(15))
                }
                self.answerUpdate(sessionID: clientID, conn)
            }
        case ("POST", "/set.cgi"):
            let body = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            reply(conn, json: applySet(body))
        case ("POST", "/call.cgi"):
            let body = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            reply(conn, json: applyCall(body))
        default:
            reply(conn, status: 404, json: ["ERROR": "Unexpected endpoint"])
        }
    }

    private func answerUpdate(sessionID clientID: Int, _ conn: NWConnection) {
        let (changed, updatedFields): (Int, [String: Any]) = lock.withLock {
            let last = lastAnsweredCounter[clientID] ?? 0
            var out: [String: Any] = [:]
            for entry in changes where entry.counter > last {
                // Nested shape: include all stored fields for changed variables (value, type, min, max, readonly),
                // matching what the real ALEXA Mini sends.
                out[entry.name] = variables[entry.name] ?? ["value": NSNull()]
            }
            lastAnsweredCounter[clientID] = counter
            return (clientID, out)
        }
        switch config.update {
        case .flat:
            // Flat shape: values at the top level beside id, no nested dicts.
            var doc: [String: Any] = ["id": changed]
            for (name, fields) in updatedFields {
                doc[name] = (fields as? [String: Any])?["value"] ?? NSNull()
            }
            reply(conn, json: doc)
        case .counterOnly:
            reply(conn, json: ["id": changed])
        default:
            // Nested shape (the Mini's): {id, variables: {Name: {value, type, min, max, readonly, …}}}
            reply(conn, json: ["id": changed, "variables": updatedFields])
        }
    }

    private func applySet(_ body: [String: Any]) -> [String: Any] {
        lock.withLock { setBodies.append(body) }
        for (name, value) in body {
            guard let v = lock.withLock({ variables[name] }) else { return ["result": 0, "error": "Unknown \(name)"] }
            if (v["readonly"] as? Int ?? 0) == 1 { return ["result": 0, "error": "\(name) is read only"] }
            if v["type"] as? String == "bool" {
                guard value is Bool else { return ["result": 0, "error": "\(name) needs a bool"] }
                continue
            }
            guard let n = (value as? NSNumber)?.doubleValue else { return ["result": 0, "error": "\(name) needs a number"] }
            if let low = (v["min"] as? NSNumber)?.doubleValue, n < low { return ["result": 0, "error": "below range"] }
            if let high = (v["max"] as? NSNumber)?.doubleValue, n > high { return ["result": 0, "error": "above range"] }
            if v["type"] as? String == "enumint", let flags = v["properties"] as? [Int] {
                let index = Int(n)
                guard flags.indices.contains(index), flags[index] & 3 == 3 else { return ["result": 0, "error": "disabled"] }
            }
        }
        let triggersReload = config.reloads.contains { body[$0] != nil }
        for (name, value) in body { change(name, value) }
        if triggersReload { beginReload() }
        return ["result": 1]
    }

    /// Simulate a software reload: invalidate the session, hold update.cgi dead for ~0.5 s, then serve one
    /// all.cgi with SystemSoftwareIsRestarting true, then clear it so subsequent update answers carry false.
    private func beginReload() {
        lock.withLock {
            sessionID += 1000
            reloadStarted = Date()
            reloadDeadlineSeconds = 0.5
            reloadAllCgiRemaining = 1
            variables["SystemSoftwareIsRestarting"] = ["value": true, "type": "bool", "readonly": 1]
            counter += 1
            changes.append((counter, "SystemSoftwareIsRestarting"))
        }
    }

    private func applyCall(_ body: [String: Any]) -> [String: Any] {
        lock.withLock { callBodies.append(body) }
        guard let id = body["command"] as? String, let name = commands[id] else {
            return ["result": -1, "error": "Unknown command ID"]
        }
        let delay = config.recDelay
        switch name {
        case "RecordingStart":
            // Like the camera: rolling locks the sensor frame rate. Both the readonly flag and CameraState arrive
            // in the update answer, as the real ALEXA Mini sends them with their full variable dicts.
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                self.changeField("FPSNominal", field: "readonly", value: 1)
                self.change("CameraState", 1)
            }
        case "RecordingStop":
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                self.changeField("FPSNominal", field: "readonly", value: 0)
                self.change("CameraState", 0)
            }
        case "PlayBackPrepare":
            change("PlaybackClipIndex", 0)
            // An ALEXA Mini puts its own screen on its playback page too; PlayBackEnd leaves it there.
            if value("GuiMode") != nil { change("GuiMode", 2) }
        case "PlayBackGo":
            change("PlaybackSpeedEnum", 11)
        case "PlayBackStop":
            change("PlaybackSpeedEnum", 10)
        case "PlayBackEnd":
            change("PlaybackSpeedEnum", 10)
            change("PlaybackClipIndex", -1)
        case "AutoWB":
            // It measures for a moment, then reads the light it found.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { self.change("WBCurrentKelvin", 4870) }
        case "PlayBackSkipClip":
            let index = (value("PlaybackClipIndex") as? Int) ?? 0
            change("PlaybackClipIndex", id == ArriFixture.skipForward ? index + 1 : max(index - 1, 0))
        case "SensorFormatPrep":
            // Simulate the Mini's prepare command: bump the result count and report a firmware reload is needed.
            let current = (value("PrepareCommandResultCount") as? Int) ?? 0
            change("PrepareCommandResultCount", current + 1)
            change("PrepareCommandFWWillReload", true)
        default:
            break
        }
        return ["result": 0]
    }

    private func reply(_ conn: NWConnection, status: Int = 200, json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        send(conn, status: status, type: "application/json", body: data, headers: [:])
    }

    private func send(_ conn: NWConnection, status: Int, type: String, body: Data, headers: [String: String]) {
        let reason = [200: "OK", 304: "Not Modified", 404: "Not Found"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }
}
