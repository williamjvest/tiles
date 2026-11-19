import Foundation
import Network

/// A minimal RTMP server for one publisher: a Blackmagic camera's livestream, which is how its picture reaches Tiles
/// (the camera's API has no preview image). Only what a camera's push needs: the handshake, the chunk stream,
/// connect / createStream / publish, and video messages. Audio and metadata are dropped.
///
/// The simple handshake (S1 with a zero version, S2 echoing C1): clients that offer the digest handshake fall back to
/// it with a server that doesn't, as FFmpeg and Blackmagic's encoders do.
public final class RTMPReceiver: @unchecked Sendable {
    public enum Event: Sendable {
        /// A publisher connected and started publishing.
        case publishing
        /// A video message: an FLV video tag body, and its timestamp in milliseconds.
        case video(timestamp: UInt32, payload: Data)
        /// The publisher went away.
        case ended
    }

    private let queue = DispatchQueue(label: "tiles.rtmp-receiver")
    private let onEvent: @Sendable (Event) -> Void
    /// Each step of each connection as it happens, for tools (`camctl rtmp-listen --trace`); the app sets none.
    private let trace: (@Sendable (String) -> Void)?
    private var listener: NWListener?
    private var connection: NWConnection?
    private var session: RTMPSession?
    // On the queue only.
    private var listeningPort: UInt16 = 0
    private var listening = false

    /// The port it listens on, or listened on last (0 before it ever has).
    public var port: UInt16 { queue.sync { listeningPort } }
    /// Listening now: false before a start, after a stop, and once the system has closed the listener (an iOS app
    /// sent to the background, say).
    public var isListening: Bool { queue.sync { listening } }

    public init(trace: (@Sendable (String) -> Void)? = nil, onEvent: @escaping @Sendable (Event) -> Void) {
        self.trace = trace
        self.onEvent = onEvent
    }

    /// Listens on `port` (1935, RTMP's own), or any free port with 0. Returns the port once it's listening.
    public func start(port requested: UInt16 = 1935) async throws -> UInt16 {
        // Reused at once: live view coming back listens on the port the camera's platform names. Only a fixed port: on
        // an OS-assigned one (tests) reuse let the kernel hand the listener's port to an outgoing connection, which
        // then failed with EADDRINUSE and left the full test run hanging now and then.
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = requested != 0
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: requested) ?? .any)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let port = listener.port?.rawValue ?? requested
                    self?.listeningPort = port
                    self?.listening = true
                    if once.take() { continuation.resume(returning: port) }
                case .failed(let error), .waiting(let error):
                    // A listener stopped for a newer one says so late: only the current one counts. One left waiting
                    // (a port it can't have) fails too, so `listen` tries another instead of waiting for good.
                    if self?.listener === listener { self?.listening = false }
                    if once.take() {
                        if case .waiting = state { listener.cancel() }
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if self?.listener === listener { self?.listening = false }
                default:
                    break
                }
            }
            queue.async { self.listener = listener }
            listener.start(queue: queue)
        }
    }

    /// Stops listening and drops the publisher. Synchronous, so a start straight after finds the port free; never call
    /// it on the receiver's own queue.
    public func stop() {
        queue.sync {
            connection?.cancel()
            connection = nil
            session = nil
            listener?.cancel()
            listener = nil
            listening = false
        }
    }

    /// A new publisher replaces the old one: a camera that reconnects after a dropout opens a new connection.
    private func accept(_ connection: NWConnection) {
        trace?("accepted \(connection.endpoint)")
        self.connection?.cancel()
        self.connection = connection
        let session = RTMPSession(send: { [weak connection] data in
            connection?.send(content: data, completion: .contentProcessed { _ in })
        }, trace: trace, onEvent: onEvent)
        self.session = session
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                self?.trace?("connection \(connection.map { "\($0.endpoint)" } ?? "") \(state)")
                guard let self, let connection, self.connection === connection else { return }
                self.connection = nil
                self.session = nil
                self.onEvent(.ended)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, session: session)
    }

    private func receive(on connection: NWConnection, session: RTMPSession) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self, weak connection] data, _, done, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty {
                do { try session.feed(data) } catch {
                    connection.cancel()
                    return
                }
            }
            if done || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, session: session)
            }
        }
    }
}

/// Resumes a continuation once, from callbacks that may fire more than once.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

enum RTMPError: Error {
    case malformed(String)
}

/// One RTMP connection, fed the bytes as they arrive. Confined to the receiver's queue: its callbacks are the only
/// place it's used, which is what makes it safe to hand to them.
final class RTMPSession: @unchecked Sendable {
    private enum Stage { case handshake, c2, chunks }
    private struct ChunkStream {
        var timestamp: UInt32 = 0
        var delta: UInt32 = 0
        var length = 0
        var type: UInt8 = 0
        var streamID: UInt32 = 0
        var extended = false
        var payload = Data()
    }

    private static let handshakeSize = 1536
    private let send: (Data) -> Void
    private let onEvent: (RTMPReceiver.Event) -> Void
    private let trace: ((String) -> Void)?
    private var videoMessages = 0
    private var stage = Stage.handshake
    private var buffer = Data()
    private var chunkStreams: [UInt32: ChunkStream] = [:]
    private var inChunkSize = 128
    private let outChunkSize = 4096
    /// Bytes received, and the publisher's acknowledgement window: it waits for an acknowledgement every window.
    private var received: UInt64 = 0
    private var acknowledged: UInt64 = 0
    private var ackWindow: UInt64 = 0

    init(send: @escaping (Data) -> Void, trace: ((String) -> Void)? = nil, onEvent: @escaping (RTMPReceiver.Event) -> Void) {
        self.send = send
        self.trace = trace
        self.onEvent = onEvent
    }

    func feed(_ data: Data) throws {
        buffer.append(data)
        received += UInt64(data.count)
        loop: while true {
            switch stage {
            case .handshake:
                // C0 (the version) and C1: answer with S0, S1 and S2 (C1 echoed).
                guard buffer.count >= 1 + Self.handshakeSize else { break loop }
                let c1 = buffer.subdata(in: buffer.startIndex + 1 ..< buffer.startIndex + 1 + Self.handshakeSize)
                buffer.removeFirst(1 + Self.handshakeSize)
                var s1 = Data(count: Self.handshakeSize)
                for i in 8 ..< Self.handshakeSize { s1[i] = UInt8.random(in: 0 ... 255) }
                send(Data([3]) + s1 + c1)
                trace?("C0 C1 in (C1 version \(c1[4]).\(c1[5]).\(c1[6]).\(c1[7])), S0 S1 S2 out")
                stage = .c2
            case .c2:
                guard buffer.count >= Self.handshakeSize else { break loop }
                buffer.removeFirst(Self.handshakeSize)
                trace?("C2 in")
                stage = .chunks
            case .chunks:
                guard try readChunk() else { break loop }
            }
        }
        if ackWindow > 0, received - acknowledged >= ackWindow {
            acknowledged = received
            sendControl(type: 3, payload: Self.uint32(UInt32(truncatingIfNeeded: received)))
        }
    }

    /// Reads one chunk if the whole of it has arrived; false when more bytes are needed. Nothing is consumed until the
    /// whole chunk is there.
    private func readChunk() throws -> Bool {
        let bytes = [UInt8](buffer.prefix(18 + inChunkSize))
        guard !bytes.isEmpty else { return false }
        var at = 0
        let format = bytes[0] >> 6
        var csid = UInt32(bytes[0] & 0x3F)
        at = 1
        if csid == 0 {
            guard bytes.count >= 2 else { return false }
            csid = 64 + UInt32(bytes[1]); at = 2
        } else if csid == 1 {
            guard bytes.count >= 3 else { return false }
            csid = 64 + UInt32(bytes[1]) + UInt32(bytes[2]) << 8; at = 3
        }
        let headerLength = [11, 7, 3, 0][Int(format)]
        guard bytes.count >= at + headerLength else { return false }
        var stream = chunkStreams[csid] ?? ChunkStream()
        let starting = stream.payload.isEmpty
        var field: UInt32 = 0
        if format <= 2 {
            field = Self.uint24(bytes, at)
        }
        if format <= 1 {
            stream.length = Int(Self.uint24(bytes, at + 3))
            stream.type = bytes[at + 6]
        }
        if format == 0 {
            stream.streamID = UInt32(bytes[at + 7]) | UInt32(bytes[at + 8]) << 8 | UInt32(bytes[at + 9]) << 16 | UInt32(bytes[at + 10]) << 24
        }
        at += headerLength
        // An extended timestamp follows a header whose timestamp field is 0xFFFFFF, and every chunk continuing it.
        if format <= 2 { stream.extended = field == 0xFFFFFF }
        if stream.extended {
            guard bytes.count >= at + 4 else { return false }
            field = Self.uint32(bytes, at)
            at += 4
        }
        if starting {
            switch format {
            case 0: stream.timestamp = field; stream.delta = 0
            case 1, 2: stream.delta = field; stream.timestamp &+= field
            default: stream.timestamp &+= stream.delta
            }
        }
        guard stream.length >= 0, stream.length <= 16 << 20 else { throw RTMPError.malformed("message length \(stream.length)") }
        let size = min(inChunkSize, stream.length - stream.payload.count)
        guard bytes.count >= at + size else { return false }
        stream.payload.append(contentsOf: bytes[at ..< at + size])
        buffer.removeFirst(at + size)
        if stream.payload.count >= stream.length {
            let payload = stream.payload
            stream.payload = Data()
            chunkStreams[csid] = stream
            handle(type: stream.type, streamID: stream.streamID, timestamp: stream.timestamp, payload: payload)
        } else {
            chunkStreams[csid] = stream
        }
        return true
    }

    private func handle(type: UInt8, streamID: UInt32, timestamp: UInt32, payload: Data) {
        let bytes = [UInt8](payload)
        switch type {
        case 1: // Set Chunk Size
            if bytes.count >= 4 { inChunkSize = max(1, Int(Self.uint32(bytes, 0) & 0x7FFF_FFFF)) }
        case 5: // Window Acknowledgement Size
            if bytes.count >= 4 { ackWindow = UInt64(Self.uint32(bytes, 0)) }
        case 4: // User Control: answer a ping (6) with a pong (7)
            if bytes.count >= 6, bytes[1] == 6 { sendControl(type: 4, payload: Data([0, 7]) + Data(bytes[2 ..< 6])) }
        case 20, 17: // AMF0 command; an AMF3 command starts with a 0 byte and then is AMF0
            command(type == 17 ? Array(bytes.dropFirst()) : bytes, streamID: streamID)
        case 9:
            videoMessages += 1
            if let trace, videoMessages <= 3 || videoMessages % 100 == 0 {
                trace("video \(videoMessages): \(bytes.prefix(2).map { String(format: "%02x", $0) }.joined()) \(bytes.count) B")
            }
            onEvent(.video(timestamp: timestamp, payload: payload))
        default:
            if let trace, type != 8 { trace("message type \(type), \(bytes.count) B") }
        }
    }

    private func command(_ bytes: [UInt8], streamID: UInt32) {
        var reader = AMF0Reader(bytes)
        guard case .string(let name)? = reader.next() else { return }
        let transaction: Double
        if case .number(let n)? = reader.next() { transaction = n } else { transaction = 0 }
        trace?("command \(name) (\(Int(transaction))) on stream \(streamID)")
        switch name {
        case "connect":
            sendControl(type: 5, payload: Self.uint32(5_000_000))
            sendControl(type: 6, payload: Self.uint32(5_000_000) + Data([2]))
            sendControl(type: 1, payload: Self.uint32(UInt32(outChunkSize)))
            sendCommand(streamID: 0, [
                .string("_result"), .number(transaction),
                .object([("fmsVer", .string("FMS/3,0,1,123")), ("capabilities", .number(31))]),
                .object([("level", .string("status")), ("code", .string("NetConnection.Connect.Success")),
                         ("description", .string("Connection succeeded.")), ("objectEncoding", .number(0))]),
            ])
        case "createStream":
            sendCommand(streamID: 0, [.string("_result"), .number(transaction), .null, .number(1)])
        case "publish":
            sendCommand(streamID: 1, [
                .string("onStatus"), .number(0), .null,
                .object([("level", .string("status")), ("code", .string("NetStream.Publish.Start")),
                         ("description", .string("Start publishing"))]),
            ])
            onEvent(.publishing)
        case "deleteStream", "FCUnpublish":
            break
        default:
            // releaseStream, FCPublish and the like: answered so the publisher carries on.
            if transaction > 0 { sendCommand(streamID: 0, [.string("_result"), .number(transaction), .null, .undefined]) }
        }
    }

    // MARK: Sending

    private func sendControl(type: UInt8, payload: Data) {
        sendMessage(csid: 2, type: type, streamID: 0, payload: payload)
    }

    private func sendCommand(streamID: UInt32, _ values: [AMF0Value]) {
        var payload = Data()
        for value in values { value.encode(into: &payload) }
        sendMessage(csid: 3, type: 20, streamID: streamID, payload: payload)
    }

    /// A message as chunks: a type 0 header, then type 3 headers between `outChunkSize` pieces. The chunk size this
    /// side uses is announced in `connect`'s answer, before anything larger goes out.
    private func sendMessage(csid: UInt8, type: UInt8, streamID: UInt32, payload: Data) {
        var out = Data([csid & 0x3F])
        out += Data([0, 0, 0]) // timestamp
        out += Self.uint24(UInt32(payload.count))
        out.append(type)
        out += Data([UInt8(streamID & 0xFF), UInt8(streamID >> 8 & 0xFF), UInt8(streamID >> 16 & 0xFF), UInt8(streamID >> 24)])
        var offset = 0
        while offset < payload.count {
            if offset > 0 { out.append(0xC0 | (csid & 0x3F)) }
            let size = min(type == 1 ? 128 : outChunkSize, payload.count - offset)
            out += payload.subdata(in: payload.startIndex + offset ..< payload.startIndex + offset + size)
            offset += size
        }
        send(out)
    }

    // MARK: Bytes

    static func uint24(_ b: [UInt8], _ at: Int) -> UInt32 { UInt32(b[at]) << 16 | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) }
    static func uint32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }
    static func uint24(_ v: UInt32) -> Data { Data([UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
    static func uint32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
}

/// The AMF0 values RTMP's commands use.
enum AMF0Value {
    case number(Double)
    case boolean(Bool)
    case string(String)
    case object([(String, AMF0Value)])
    case null
    case undefined

    func encode(into data: inout Data) {
        switch self {
        case .number(let n):
            data.append(0x00)
            data += RTMPSession.uint32(UInt32(n.bitPattern >> 32)) + RTMPSession.uint32(UInt32(truncatingIfNeeded: n.bitPattern))
        case .boolean(let b):
            data += Data([0x01, b ? 1 : 0])
        case .string(let s):
            data.append(0x02)
            Self.key(s, into: &data)
        case .object(let properties):
            data.append(0x03)
            for (key, value) in properties {
                Self.key(key, into: &data)
                value.encode(into: &data)
            }
            data += Data([0, 0, 0x09])
        case .null:
            data.append(0x05)
        case .undefined:
            data.append(0x06)
        }
    }

    private static func key(_ s: String, into data: inout Data) {
        let utf8 = Array(s.utf8)
        data += Data([UInt8(utf8.count >> 8 & 0xFF), UInt8(utf8.count & 0xFF)]) + Data(utf8)
    }
}

/// Reads the leading AMF0 values of a command: its name, transaction and (skipped) objects.
struct AMF0Reader {
    private let bytes: [UInt8]
    private var at = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func next() -> AMF0Value? {
        guard at < bytes.count else { return nil }
        let marker = bytes[at]
        at += 1
        switch marker {
        case 0x00:
            guard at + 8 <= bytes.count else { return nil }
            let bits = UInt64(RTMPSession.uint32(bytes, at)) << 32 | UInt64(RTMPSession.uint32(bytes, at + 4))
            at += 8
            return .number(Double(bitPattern: bits))
        case 0x01:
            guard at < bytes.count else { return nil }
            defer { at += 1 }
            return .boolean(bytes[at] != 0)
        case 0x02:
            return readString().map { .string($0) }
        case 0x03, 0x08:
            if marker == 0x08 { at += 4 } // an ECMA array's count
            var properties: [(String, AMF0Value)] = []
            while at + 3 <= bytes.count {
                if bytes[at] == 0, bytes[at + 1] == 0, bytes[at + 2] == 0x09 { at += 3; break }
                guard let key = readString(), let value = next() else { return nil }
                properties.append((key, value))
            }
            return .object(properties)
        case 0x05:
            return .null
        case 0x06:
            return .undefined
        default:
            return nil
        }
    }

    private mutating func readString() -> String? {
        guard at + 2 <= bytes.count else { return nil }
        let length = Int(bytes[at]) << 8 | Int(bytes[at + 1])
        at += 2
        guard at + length <= bytes.count else { return nil }
        defer { at += length }
        return String(decoding: bytes[at ..< at + length], as: UTF8.self)
    }
}
