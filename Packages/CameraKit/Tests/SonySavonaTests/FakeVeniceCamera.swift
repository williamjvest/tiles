import CryptoKit
import Foundation
import Network
import CameraKitTestSupport
@testable import SonySavona

/// An in-process VENICE 2 (MPC-3628, FW V4.00, savona-2.9.4): the page's login CGI, the
/// Savona WebSocket at `/linear` (MessagePack-RPC; one client), and the LUT upload CGI, on one port. It answers what the
/// real one answers and in its shapes: no `System.GetProperties`, menu switches as "0"/"1" (a bool gets nothing back), a
/// locked item that takes the write and changes nothing, maps reported one entry at a time, `Button.Assign` toggled by
/// the buttons' keys. Its state starts as the camera's own reading (`VeniceFixture`).
final class FakeVeniceCamera: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "fake-venice", qos: .userInitiated)
    private(set) var port: UInt16 = 0
    private var socket: NWConnection?

    private var props: [String: MPValue]
    private var lists: [String: [MPValue]]
    private var locks: [String: String]
    private var writes: [[String: MPValue]] = []
    private var pressed: [String] = []
    private var uploaded: [(fields: [String: String], fileName: String, size: Int)] = []
    private var turnedAway = 0
    let password = "testpass1234"
    /// The real one says nothing at all to `System.GetProperties` (the backend waits out 4 s). Off, it answers an error at
    /// once, which takes the same path faster.
    let silentPropertyList: Bool

    init(silentPropertyList: Bool = false) {
        self.silentPropertyList = silentPropertyList
        props = VeniceFixture.values
        lists = VeniceFixture.lists
        locks = VeniceFixture.statuses
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
        socket?.cancel()
    }

    // MARK: - For tests

    var setValues: [[String: MPValue]] { lock.withLock { writes } }
    var keysPressed: [String] { lock.withLock { pressed } }
    /// Keys the camera says nothing to (a name it doesn't know, as a wrong-shape request gets nothing).
    private var silent: Set<String> = []
    private var opensMoving = false
    func answerNothing(toKeys keys: Set<String>) { lock.withLock { silent = keys } }
    /// The audio meters as the camera sends them, several times a second: both properties, all four channels.
    func sendMeters(_ levels: [Int]) {
        let channels = Dictionary(uniqueKeysWithValues: levels.enumerated().map { ("ch.\($0.offset + 1)", MPValue.int(Int64($0.element))) })
        let coarse = channels.mapValues { MPValue.int(Int64(min(($0.number.map(Int.init) ?? 0) / 6, 3))) }
        lock.withLock {
            props["Output.Audio.dBLevel"] = .map(channels)
            props["Output.Audio.Level"] = .map(coarse)
        }
        notify("Notify.Property.Value.Changed", ["Output.Audio.Level": .map(coarse), "Output.Audio.dBLevel": .map(channels)])
    }
    /// Clients closed at once because another held the camera.
    var clientsTurnedAway: Int { lock.withLock { turnedAway } }
    var uploads: [(fields: [String: String], fileName: String, size: Int)] { lock.withLock { uploaded } }
    func value(_ name: String) -> MPValue? { lock.withLock { props[name] } }

    /// Before `start`: the camera as it reads in another setup (another imager mode, no list for a property).
    func preset(values: [String: MPValue] = [:], lists changed: [String: [MPValue]?] = [:]) {
        lock.withLock {
            props.merge(values) { _, new in new }
            for (name, list) in changed { lists[name] = list }
        }
    }

    /// A list that changes with no announcement: the camera answers the new one when asked, and notifies nothing.
    func quietlyRelist(_ name: String, _ list: [MPValue]) { lock.withLock { lists[name] = list } }

    /// Something changed on the camera body: its value, and the notification the camera sends.
    func bodyChange(_ changes: [String: MPValue]) {
        lock.withLock { for (k, v) in changes { props[k] = v } }
        notify("Notify.Property.Value.Changed", changes)
    }

    /// A lock changing on the camera (recording locks the imager mode, a menu item grays out).
    func lockChange(_ changes: [String: String]) {
        lock.withLock { for (k, v) in changes { locks[k] = v } }
        notify("Notify.Property.Status.Changed", changes.mapValues { .string($0) })
    }

    // MARK: - HTTP

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, Data())
    }

    private func readRequest(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil { conn.cancel() } else { self.readRequest(conn, buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let first = lines.removeFirst().split(separator: " ").map(String.init)
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let body = buffer[end.upperBound...]
            let length = Int(headers["content-length"] ?? "0") ?? 0
            if body.count < length {
                if done || error != nil { conn.cancel() } else { self.readRequest(conn, buffer) }
                return
            }
            self.route(conn, method: first.first ?? "", path: first.count > 1 ? first[1] : "/", headers: headers,
                       body: Data(body.prefix(length)))
        }
    }

    private func route(_ conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        if path.hasPrefix("/linear"), let key = headers["sec-websocket-key"] {
            let busy = lock.withLock { () -> Bool in
                if socket != nil { turnedAway += 1 }
                return socket != nil
            }
            if busy {  // the camera takes one client: a second is closed at once
                conn.cancel()
                return
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
                .base64EncodedString()
            let reply = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
            lock.withLock { socket = conn }
            conn.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
            readFrames(conn, Data(), Data())
            return
        }
        if path.hasPrefix("/cgi-bin/getsavonacred.cgi") {
            respond(conn, status: "200 OK", body: "\(Self.sha256("admin")):\(Self.sha256(password))")
            return
        }
        if method == "POST", path.hasPrefix("/cgi-bin/upload.cgi") {
            upload(conn, headers: headers, body: body)
            return
        }
        respond(conn, status: "404 Not Found", body: "")
    }

    private func respond(_ conn: NWConnection, status: String, body: String) {
        let text = "HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: Data(text.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    /// The page's upload form: csrf, DestinationID, then the file as FileName. The slot takes the file's name.
    private func upload(_ conn: NWConnection, headers: [String: String], body: Data) {
        guard let type = headers["content-type"], let range = type.range(of: "boundary=") else {
            respond(conn, status: "400 Bad Request", body: "")
            return
        }
        let boundary = Data(("--" + type[range.upperBound...]).utf8)
        var fields: [String: String] = [:]
        var fileName = ""
        var size = 0
        var rest = body[...]
        while let start = rest.range(of: boundary) {
            rest = rest[start.upperBound...]
            guard let headEnd = rest.range(of: Data("\r\n\r\n".utf8)), let next = rest.range(of: boundary) else { break }
            let head = String(decoding: rest[..<headEnd.lowerBound], as: UTF8.self)
            let content = rest[headEnd.upperBound..<next.lowerBound].dropLast(2)  // the CRLF before the boundary
            let name = head.components(separatedBy: "name=\"").dropFirst().first?.components(separatedBy: "\"").first ?? ""
            if let file = head.components(separatedBy: "filename=\"").dropFirst().first?.components(separatedBy: "\"").first {
                fileName = file
                size = content.count
            } else {
                fields[name] = String(decoding: content, as: UTF8.self)
            }
            rest = rest[next.lowerBound...]
        }
        let slot = Int(fields["DestinationID"] ?? "") ?? 0
        guard fields["csrf"]?.split(separator: ",").count == 4, (1...16).contains(slot), !fileName.isEmpty else {
            respond(conn, status: "400 Bad Request", body: "")
            return
        }
        let list: [MPValue] = lock.withLock {
            uploaded.append((fields, fileName, size))
            var list = lists["LUT.User3DLUT.LoadedList"] ?? []
            list[slot - 1] = .string(fileName)
            lists["LUT.User3DLUT.LoadedList"] = list
            return list
        }
        respond(conn, status: "200 OK", body: "OK")
        notify("Notify.Capability.Value.Changed", ["LUT.User3DLUT.LoadedList": [true, "", .array(list)]])
    }

    // MARK: - WebSocket

    private func readFrames(_ conn: NWConnection, _ buffer: Data, _ message: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            var message = message
            if let data { buffer.append(data) }
            while let frame = Self.frame(in: buffer) {
                buffer.removeFirst(frame.length)
                switch frame.opcode {
                case 0x8:
                    self.closed(conn)
                    return
                case 0x9:
                    self.sendFrame(conn, opcode: 0xA, frame.payload)
                case 0x0, 0x1, 0x2:
                    message.append(frame.payload)
                    if frame.fin {
                        self.received(MessagePack.decodeAll(message).values)
                        message = Data()
                    }
                default:
                    break
                }
            }
            if done || error != nil { self.closed(conn) } else { self.readFrames(conn, buffer, message) }
        }
    }

    private func closed(_ conn: NWConnection) {
        lock.withLock { if socket === conn { socket = nil } }
        conn.cancel()
    }

    private static func frame(in data: Data) -> (fin: Bool, opcode: UInt8, payload: Data, length: Int)? {
        let bytes = [UInt8](data.prefix(14))
        guard bytes.count >= 2 else { return nil }
        let fin = bytes[0] & 0x80 != 0
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }
            offset = 10
        }
        let maskOffset = offset
        if masked { offset += 4 }
        guard data.count >= offset + length else { return nil }
        let start = data.startIndex
        var payload = Data(data[(start + offset)..<(start + offset + length)])
        if masked {
            let key = [UInt8](data[(start + maskOffset)..<(start + maskOffset + 4)])
            payload = Data(payload.enumerated().map { $0.element ^ key[$0.offset % 4] })
        }
        return (fin, opcode, payload, offset + length)
    }

    private func sendFrame(_ conn: NWConnection, opcode: UInt8, _ payload: Data) {
        var head = Data([0x80 | opcode])
        if payload.count < 126 {
            head.append(UInt8(payload.count))
        } else if payload.count < 65_536 {
            head.append(126)
            head.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        } else {
            head.append(127)
            head.append(contentsOf: (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xFF) })
        }
        conn.send(content: head + payload, completion: .contentProcessed { _ in })
    }

    private func send(_ messages: [MPValue]) {
        guard let conn = lock.withLock({ socket }) else { return }
        sendFrame(conn, opcode: 0x2, messages.reduce(Data()) { $0 + MessagePack.encode($1) })
    }

    private func notify(_ name: String, _ changes: [String: MPValue]) {
        send([.array([.int(2), .string(name), .array([.map(changes)])])])
    }

    // MARK: - Savona

    private func received(_ frames: [MPValue]) {
        for frame in frames {
            guard let parts = frame.array, parts.count == 4, parts[0] == .int(0), let id = parts[1].number,
                  let method = parts[2].string, let params = parts[3].array else { continue }  // malformed: no answer
            handle(Int64(id), method, params.first)
        }
    }

    private func reply(_ id: Int64, error: MPValue = .null, _ result: MPValue = .null) {
        send([.array([.int(1), .int(id), error, result])])
    }

    private func handle(_ id: Int64, _ method: String, _ p0: MPValue?) {
        switch method {
        case "Alternate.Authentication.Basic":
            let ok = p0?["username"]?.string == Self.sha256("admin") && p0?["password"]?.string == Self.sha256(password)
            reply(id, error: ok ? .null : [403, "Authentication Failed"])
        case "Notify.Subscribe":
            reply(id, p0 ?? .null)
        case "System.GetProperties":
            // savona-2.9.4 has none: the real one says nothing; by default an error, which is the same path, faster.
            if !silentPropertyList { reply(id, error: [3003, "Method Not Found"]) }
        case "Property.GetValue":
            guard let names = p0?.map?.keys else { return }
            let found = lock.withLock { props.filter { names.contains($0.key) } }
            reply(id, .map(found))
        case "Property.GetStatus":
            guard let names = p0?.map?.keys else { return }
            let found = lock.withLock { locks.filter { names.contains($0.key) }.mapValues { MPValue.string($0) } }
            reply(id, .map(found))
        case "Capability.GetValue":
            guard let names = p0?.array?.compactMap(\.string) else { return }
            let found = lock.withLock { lists.filter { names.contains($0.key) }.mapValues { MPValue.array([true, "", .array($0)]) } }
            reply(id, .map(found))
        case "Property.SetValue":
            guard let changes = p0?.map else { return }
            // A menu switch takes "0"/"1": anything else gets no answer at all.
            if changes.contains(where: { $0.key.hasPrefix("P.System.Menu.") && $0.value.string == nil }) { return }
            reply(id)
            apply(changes)
        case "Button.SendKeys":
            guard let key = p0?.array?.first?.string else { return }
            if lock.withLock({ silent.contains(key) }) {
                lock.withLock { pressed.append(key) }
                return
            }
            reply(id)
            press(key)
        default:
            return  // anything else: no answer, as on the camera
        }
    }

    /// The menu item each menu property's lock is reported under, from the camera's own status names (`master.json`),
    /// written out here rather than taken from the code under test.
    static let menuItems = [
        "P.System.Menu.CamImagermode": "P.System.Menu.ProjectImagerMode.MenuItem",
        "P.System.Menu.AxsRecformatSelect": "P.System.Menu.AxsrecformatSet.MenuItem",
        "P.System.Menu.SystemFrequency": "P.System.Menu.FrequencySet.MenuItem",
        "P.System.Menu.RecOutDeanamoScaleSelect": "P.System.Menu.SxsOutputDeSqueeze.MenuItem",
        "P.System.Menu.ColorBar": "P.System.Menu.ColorBar.MenuItem",
        "P.System.Menu.FlipImage": "P.System.Menu.FlipImage.MenuItem",
        "Camera.Gain.ISOValue": "P.System.Menu.BaseIso.MenuItem",
    ]

    private func locked(_ name: String) -> Bool {
        locks[name] == "Locked" || Self.menuItems[name].map { locks[$0] == "Locked" } == true
    }

    /// The EI each base had last (the real one goes back to it on a switch; to the bottom of the range the first time).
    private var eiByBase: [String: MPValue] = ["ISO 3200": "800EI"]
    static let eiLists: [String: [MPValue]] = [
        "ISO 800": ["200EI", "250EI", "320EI", "400EI", "500EI", "640EI", "800EI", "1000EI", "1250EI", "1600EI", "2000EI",
                    "2500EI", "3200EI"],
        "ISO 3200": ["800EI", "1000EI", "1250EI", "1600EI", "2000EI", "2500EI", "3200EI", "4000EI", "5000EI", "6400EI",
                     "8000EI", "10000EI", "12800EI"],
    ]

    private func apply(_ changes: [String: MPValue]) {
        var notes: [[String: MPValue]] = []
        var capability: [String: MPValue]?
        lock.withLock {
            writes.append(changes)
            // An EI the camera doesn't list ("1600.0EI") changes nothing.
            if let ei = changes["Camera.Gain.ExposureIndex.Value"], lists["Camera.Gain.ExposureIndex.Value"]?.contains(ei) != true {
                return
            }
            // A base switch: the EI goes back to where it was on that base, and the list changes with it.
            if let base = changes["Camera.Gain.ISOValue"]?.string, let list = Self.eiLists[base],
               base != props["Camera.Gain.ISOValue"]?.string {
                if let old = props["Camera.Gain.ISOValue"]?.string { eiByBase[old] = props["Camera.Gain.ExposureIndex.Value"] }
                let ei = eiByBase[base] ?? list[0]
                props["Camera.Gain.ISOValue"] = .string(base)
                props["Camera.Gain.ExposureIndex.Value"] = ei
                lists["Camera.Gain.ExposureIndex.Value"] = list
                notes.append(["Camera.Gain.ISOValue": .string(base)])
                notes.append(["Camera.Gain.ExposureIndex.Value": ei])
                capability = ["Camera.Gain.ExposureIndex.Value": [true, "", .array(list)]]
                return
            }
            for (name, value) in changes where !locked(name) {
                if let entries = value.map, let old = props[name]?.map, old["cam"] == nil {
                    // A map written one entry at a time (a LUT slot), and reported the same way.
                    var merged = old
                    merged.merge(entries) { _, new in new }
                    props[name] = .map(merged)
                } else {
                    props[name] = value
                }
                notes.append([name: value])
            }
            // What follows from it on the camera.
            if let bars = changes["P.System.Menu.ColorBar"]?.string, !locked("P.System.Menu.ColorBar") {
                props["Camera.ColorBar.Enabled"] = .bool(bars == "1")
                notes.append(["Camera.ColorBar.Enabled": .bool(bars == "1")])
            }
            if changes["LUT.User3DLUT.FileID"] != nil || changes["LUT.Mode"] != nil,
               let id = props["LUT.User3DLUT.FileID"]?.unwrapped.number.map({ Int($0) - 1 }),
               let list = lists["LUT.User3DLUT.LoadedList"], list.indices.contains(id) {
                props["LUT.User3DLUT.FileName"] = ["cam": list[id]]
                notes.append(["LUT.User3DLUT.FileName": ["cam": list[id]]])
            }
        }
        for note in notes { notify("Notify.Property.Value.Changed", note) }
        if let capability { notify("Notify.Capability.Value.Changed", capability) }
    }

    /// An assignable button: its function toggles, and `Button.Assign` reports that slot alone.
    private func press(_ key: String) {
        var notes: [[String: MPValue]] = []
        var readyLater = false
        lock.withLock {
            pressed.append(key)
            if let playback = Self.playbackKeys[key] {
                // Playback, as a VENICE 2 reported it: InsideClips opens the last clip paused
                // (speed 0), and says it can play (PlaybackEnabled) a little later; Play plays a paused clip and pauses
                // a moving one, a 4× scan included; Forward and Rewind run at 4×; Home goes back to the live picture.
                var status = props["P.Clip.Mediabox.Status"]?.string ?? "Standby"
                var speed = props["P.Clip.Mediabox.Speed"]?.number ?? 0
                let total = props[Self.clipTotal]?.unwrapped.number.map { Int($0) }
                switch playback {
                case .open:
                    status = "Playing"; speed = opensMoving ? 1 : 0
                    props[Self.playbackEnabled] = ["selectClip": false]
                    notes.append([Self.playbackEnabled: ["selectClip": false]])
                    readyLater = true
                    // The last clip, where the camera numbers them (`numberClips`).
                    if let total {
                        props[Self.clipPosition] = ["main": .int(Int64(total))]
                        notes.append([Self.clipPosition: ["main": .int(Int64(total))]])
                    }
                case .step(let by) where status == "Playing":
                    // Next and Prev: the clip beside, paused at its start; never past either end.
                    guard let total, let at = props[Self.clipPosition]?.unwrapped.number.map({ Int($0) }) else { return }
                    let next = min(max(at + by, 1), total)
                    props[Self.clipPosition] = ["main": .int(Int64(next))]
                    props["P.Clip.Mediabox.Speed"] = .double(0)
                    notes.append([Self.clipPosition: ["main": .int(Int64(next))], "P.Clip.Mediabox.Speed": .double(0)])
                    return
                case .playPause where status == "Playing": speed = speed == 0 ? 1 : 0
                case .scan(let rate) where status == "Playing": speed = rate
                case .home: status = "Standby"; speed = 0
                default: return
                }
                props["P.Clip.Mediabox.Status"] = .string(status)
                props["P.Clip.Mediabox.Speed"] = .double(speed)
                notes.append(["P.Clip.Mediabox.Status": .string(status), "P.Clip.Mediabox.Speed": .double(speed)])
                return
            }
            if key == "Rec" {
                // The REC key toggles the take on the slot that records (media.5), reported one entry at a time.
                var media = props["Storage.Media.Recording"]?.map ?? [:]
                let next: MPValue = media["media.5"]?.string == "Recording" ? "NotRecording" : "Recording"
                media["media.5"] = next
                props["Storage.Media.Recording"] = .map(media)
                notes.append(["Storage.Media.Recording": ["media.5": next]])
                return
            }
            guard var slots = props["Button.Assign"]?.map, let entry = slots[key]?.array, let function = entry.first else { return }
            let on = entry.count > 1 && entry[1].string == "On"
            slots[key] = [function, .string(on ? "Off" : "On")]
            props["Button.Assign"] = .map(slots)
            notes.append(["Button.Assign": [key: [function, .string(on ? "Off" : "On")]]])
            if function.string == "ColorBar" {
                props["Camera.ColorBar.Enabled"] = .bool(!on)
                notes.append(["Camera.ColorBar.Enabled": .bool(!on)])
            }
        }
        for note in notes { notify("Notify.Property.Value.Changed", note) }
        if readyLater {
            // The clip can play a moment after it opens (the camera: about 5 s).
            DispatchQueue.global().asyncAfter(deadline: .now() + playbackReadyDelay) { [self] in
                lock.withLock { props[Self.playbackEnabled] = ["selectClip": true] }
                notify("Notify.Property.Value.Changed", [Self.playbackEnabled: ["selectClip": true]])
            }
        }
    }

    static let playbackEnabled = "Clip.Mediabox.PlaybackEnabled"
    /// How long after InsideClips the clip can play.
    var playbackReadyDelay: Double = 0.2

    private enum PlaybackKey { case open, playPause, scan(Double), home, step(Int) }
    private static let playbackKeys: [String: PlaybackKey] = [
        "InsideClips": .open, "Play": .playPause, "Forward": .scan(4), "Rewind": .scan(-4), "Home": .home,
        "Next": .step(1), "Prev": .step(-1),
    ]
    static let clipPosition = "Clip.Mediabox.AllClipPosition"
    static let clipTotal = "Clip.Mediabox.AllTotalClips"

    /// Before `start`: the camera numbers its clips in playback (`AllClipPosition` of `AllTotalClips`), as a VENICE 2
    /// does, under "main", -1 on the live picture (the 10/23 capture); InsideClips opens the last, and Next and Prev step.
    func numberClips(_ total: Int) {
        preset(values: [Self.clipPosition: ["main": -1], Self.clipTotal: ["main": .int(Int64(total))]])
    }

    /// The clip already moving when it opens: a VENICE that plays by itself mustn't be paused by a second Play.
    func opensPlaying() { lock.withLock { opensMoving = true } }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The real VENICE 2's reading (`master.json`, the properties Tiles uses).
enum VeniceFixture {
    static let userLUTs: [MPValue] = ["User_Look_1_Base.cube", "User_Look_2_Night.cube", "User_Look_3_Day.cube",
                                      "User_Cinema_A.cube", "Rec709_v2025_LUT5.cube",
                                      "SLOG3_Rec709_FC.cube", "s709.cube", "s709.cube", "s709.cube", "s709.cube",
                                      "s709.cube", "s709", "s709", "s709", "s709", "s709"]

    static let values: [String: MPValue] = [
        "System.ModelName": "PXW-X180",
        "Storage.Media.Recording": ["media.1": "NotRecording", "media.2": "NotRecording", "media.4": "NotRecording",
                                    "media.5": "NotRecording"],
        "Storage.Media.AvailableTime": ["media.1": 0, "media.2": 0, "media.4": 0, "media.5": 2770],
        "P.Clip.Mediabox.TimeCode.Value": "18:14:50:18",
        "Clip.Mediabox.ClipName": ["main": "B020C005\u{0}"],
        "P.Clip.Mediabox.Status": "Standby", "P.Clip.Mediabox.Speed": 0.0,
        "Camera.Gain.ExposureIndex.Value": "800EI", "Camera.Gain.ISOValue": "ISO 3200",
        "Camera.Shutter.Mode": "Angle", "Camera.Shutter.Angle.DisplayValue": "180.0",
        "Camera.Shutter.Speed.DisplayValue": "1/48.00",
        "Camera.NDFilter.Value": ["cam": 16], "Camera.NDFilter.Mode": ["cam": "Preset"], "Camera.NDFilter.Enabled": ["cam": true],
        "Camera.WhiteBalance.ColorTemperature.Value": "3200", "Camera.WhiteBalance.ColorTemperature.Tint.Value": "0",
        "Camera.WhiteBalance.ColorTemperature.Type": "Preset",
        "Camera.SlowAndQuickMotion.Enabled": false, "Camera.SlowAndQuickMotion.FrameRate": 24,
        "P.Clip.Mediabox.Video.Format.FrameRate": "23.98",
        "P.System.Menu.SystemFrequency": "5", "P.System.Menu.CamImagermode": "17", "P.System.Menu.AxsRecformatSelect": "3",
        "P.System.Menu.ShutterMode": "1", "P.System.Menu.FlipImage": "0", "P.System.Menu.FalseColor": "0",
        "P.System.Menu.ColorBar": "0", "Camera.ColorBar.Enabled": false,
        "P.System.Menu.RecOutDeanamoScaleSelect": "5", "P.System.Menu.SxsOutputDeSqueeze.Visiable": "1",
        "P.System.Menu.MarkerSdi12Onoff": "1", "P.System.Menu.MarkerSdi34Onoff": "1", "P.System.Menu.MarkerMonitorOnoff": "1",
        "P.System.Menu.MarkerVfOnoff": "1", "P.System.Menu.MarkerHdmiOnoff": "1",
        "P.System.Menu.SdiOsdDisplayInfoOnoff": "1", "P.System.Menu.MonitorOsdDisplayInfoOnoff": "1",
        "P.System.Menu.VfOsdDisplayInfoOnoff": "1", "P.System.Menu.HdmiOsdDisplayInfoOnoff": "1",
        "P.System.Menu.EvfZebraOnoff": "1", "P.System.Menu.PeakingOnoff": "0",
        "Output.Video.SDI.LUT.Value": ["sdi1": "Look", "sdi3": "Log"],
        "Output.Video.ViewFinder.LUT.Value": ["hdmi": "Look", "monitor": "Look", "vf": "s709"],
        "Output.Video.SDI.LUT.Value.LockStatus": ["sdi1": "Unlocked", "sdi3": "Unlocked"],
        "Output.Video.ViewFinder.LUT.Value.LockStatus": ["hdmi": "Unlocked", "monitor": "Unlocked", "vf": "Unlocked"],
        "LUT.Mode": ["cam": "User3D"], "LUT.Preset": ["cam": "s709"],
        "LUT.User3DLUT.FileID": ["cam": 5], "LUT.User3DLUT.FileName": ["cam": "Rec709_v2025_LUT5.cube"],
        "LUT.ART.FileID": ["cam": 1], "LUT.ART.FileName": ["cam": "s709"],
        "Button.Assign": ["Assignable.0": ["None", "Off"], "Assignable.1": ["Sdi34MlutBypass", "Off"],
                          "Assignable.2": ["FalseColorMonitor", "Off"], "Assignable.3": ["HAndVFlip", "Off"],
                          "Assignable.4": ["HAndVFlip", "Off"], "Assignable.5": ["None", "Off"],
                          "Assignable.6": ["None", "Off"], "Assignable.7": ["None", "Off"],
                          "VFAssignable.A": ["None", "Off"], "VFAssignable.B": ["FalseColorVF", "Off"],
                          "VFAssignable.C": ["FocusMagnifier", "Off"]],
        "P.System.Menu.OutputFormat.Info.Sdi34": "4", "P.System.Menu.OutputFormat.Info.Moni": "4",
        "P.System.Menu.OutputFormat.Info.Hdmi": "2", "P.System.Menu.MonitorOutSource": "0",
        "P.System.Menu.ClipnamingCameraid": "66", "P.System.Menu.ClipnamingReelNum": "24",
        "P.System.Menu.ClipnamingCameraposition": "0", "P.System.Menu.TimecodeDispTc": "3",
        "System.Battery.Active.Remain.Percentage": -1.0, "System.Battery.Active.Remain.Voltage": 14.6,
        "Network.Connection.KeepAlive": ["cam": true],
        // Frame line sets A and B: their user frame lines off, as the camera reads (master.json).
        "P.System.Menu.MarkerAUserBoxOnoff": "0", "P.System.Menu.MarkerAUserBox2Onoff": "0",
        "P.System.Menu.MarkerBUserBoxOnoff": "0", "P.System.Menu.MarkerBUserBox2Onoff": "0",
        // Each output's frame line set (SDI 1/2 on Line B, as the 2026-10-23 camera), the info set its overlay shows
        // (the VF Info B), and each set's audio meter (A on, B off).
        "P.System.Menu.MarkerSdi12Select": "1", "P.System.Menu.MarkerSdi34Select": "0",
        "P.System.Menu.MarkerMonitorSelect": "0", "P.System.Menu.MarkerVfSelect": "0", "P.System.Menu.MarkerHdmiSelect": "0",
        "P.System.Menu.SdiOsdDisplayInfoSelect": "0", "P.System.Menu.MonitorOsdDisplayInfoSelect": "0",
        "P.System.Menu.VfOsdDisplayInfoSelect": "1", "P.System.Menu.HdmiOsdDisplayInfoSelect": "0",
        "P.System.Menu.DisplayInfoAAudioLevelMeterOnoff": "1", "P.System.Menu.DisplayInfoBAudioLevelMeterOnoff": "0",
        // The audio meters as they first read, and S&Q at 1× ("1": it records sound).
        "Output.Audio.dBLevel": ["ch.1": 1, "ch.2": 1, "ch.3": 4, "ch.4": 4],
        "Output.Audio.Level": ["ch.1": 0, "ch.2": 0, "ch.3": 2, "ch.4": 2],
        "P.System.Menu.SandQPseudoFixed": "1",
    ]

    static let lists: [String: [MPValue]] = [
        "Camera.Gain.ExposureIndex.Value": ["800EI", "1000EI", "1250EI", "1600EI", "2000EI", "2500EI", "3200EI", "4000EI",
                                            "5000EI", "6400EI", "8000EI", "10000EI", "12800EI"],
        "Camera.Shutter.Angle": ["360.0", "180.0", "172.8", "144.0", "90.0", "45.0", "22.5", "11.2", "5.6"],
        "Camera.SlowAndQuickMotion.FrameRate": (8...30).map { MPValue.int(Int64($0)) },
        "Camera.WhiteBalance.ColorTemperature.Value": ["5500", "3200", "3600", "3800", "4000", "4200", "4300", "5000",
                                                       "5200", "5400", "5500", "5500", "5600", "5900", "7000", "8000", "15000"],
        "Camera.WhiteBalance.ColorTemperature.Tint.Value": ["0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "20", "0",
                                                            "0", "10", "0", "0"],
        "Camera.WhiteBalance.ColorTemperature.Type": ["Preset", "Preset", "User", "User", "User", "User", "Preset", "User",
                                                      "User", "User", "Preset", "User", "User", "User", "User", "User", "User"],
        "LUT.Mode": ["PresetLook", "User3D", "ART"],
        "LUT.Preset": ["s709", "R709_800%", "S-Gamut3.Cine/SLog3", "S-Gamut3/SLog3"],
        "LUT.User3DLUT.LoadedList": userLUTs,
        "LUT.ART.FileList": Array(repeating: "s709", count: 16),
        "Output.Video.SDI.LUT.Value.SDI1": ["Log", "Log(Legal)", "Look"],
        "Output.Video.SDI.LUT.Value.SDI3": ["Log", "Log(Legal)", "Look"],
        "Output.Video.ViewFinder.LUT.Value.HDMI": ["Log", "s709", "R709_800%", "Look", "HLG"],
        "Output.Video.ViewFinder.LUT.Value.Monitor": ["Log", "Log(Legal)", "s709", "R709_800%", "Look"],
        "Output.Video.ViewFinder.LUT.Value.VF": ["Log", "s709", "R709_800%", "Look"],
        "P.System.Menu.L3_IMAGER_MODE": ["13", "14", "15", "16", "17", "18", "19", "20", "21", "22", "23"],
        "P.System.Menu.L3_SYSTEM_FRAME_RATE": ["0", "1", "2", "3"],
        "P.System.Menu.L3_AXS_MAIN_REC_FORMAT": ["1", "3", "4", "5", "6", "7", "8", "9", "10"],
        "P.System.Menu.SxsOutputDeSqueeze.HighLightList": ["0", "1", "2", "3", "4", "5", "6"],
    ]

    static let statuses: [String: String] = [
        "Camera.Gain.ExposureIndex.Value": "Unlocked", "Camera.Gain.ISOValue": "Unlocked", "Camera.NDFilter.Value": "Unlocked",
        "Camera.Shutter.Angle.DisplayValue": "Unlocked", "Camera.Shutter.Speed.DisplayValue": "Unlocked",
        "Camera.Shutter.Mode": "Unlocked", "Camera.WhiteBalance.ColorTemperature.Value": "Unlocked",
        "Camera.WhiteBalance.ColorTemperature.Tint.Value": "Unlocked", "Camera.SlowAndQuickMotion.Enabled": "Unlocked",
        "Camera.SlowAndQuickMotion.FrameRate": "Unlocked", "Camera.ColorBar.Enabled": "Unlocked", "Camera.Iris.Value": "Locked",
        "P.System.Menu.ColorBar.MenuItem": "Locked", "P.System.Menu.SxsOutputDeSqueeze.MenuItem": "Unlocked",
        "P.System.Menu.ProjectImagerMode.MenuItem": "Unlocked", "P.System.Menu.AxsrecformatSet.MenuItem": "Unlocked",
        "P.System.Menu.FrequencySet.MenuItem": "Unlocked", "P.System.Menu.BaseIso.MenuItem": "Unlocked",
        "P.System.Menu.FlipImage.MenuItem": "Unlocked", "P.System.Menu.ClipNaming.MenuItem": "Unlocked",
        "P.System.Menu.CameraPosition.MenuItem": "Unlocked", "Control.LUT.AllItems": "Unlocked",
        "LUT.User3DLUT.LoadFile": "Unlocked",
    ]
}
