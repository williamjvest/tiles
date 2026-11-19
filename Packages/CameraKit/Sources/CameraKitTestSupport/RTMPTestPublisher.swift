import Foundation
import Network

/// A camera's livestream as the tests send it: an RTMP publisher that connects to a receiver, shakes hands, publishes
/// and sends FLV video tags, as a PYXIS or an FX5 does to Tiles' receiver.
public final class RTMPTestPublisher: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let chunkSize = 4096

    public init(port: UInt16) async throws {
        let queue = DispatchQueue(label: "test-publisher")
        self.queue = queue
        connection = try await Self.connect(port, queue: queue)
    }

    /// Connected to the receiver. A connect the system turns down with EADDRINUSE is tried again from a local port of
    /// our own choosing (LoopbackTCP: the system keeps picking the colliding one). Network.framework leaves it .waiting
    /// rather than failing it, and this waited for .ready or .failed: the whole run hung past the test's time limit.
    private static func connect(_ port: UInt16, queue: DispatchQueue) async throws -> NWConnection {
        var attempt = 0
        while true {
            attempt += 1
            let connection = LoopbackTCP.connection(to: port, freshLocalPort: attempt > 1)
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let once = Once()
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready: if once.take() { continuation.resume() }
                        case .failed(let error), .waiting(let error): if once.take() { continuation.resume(throwing: error) }
                        default: break
                        }
                    }
                    connection.start(queue: queue)
                }
                return connection
            } catch NWError.posix(.EADDRINUSE) where attempt < 10 {
                connection.cancel()
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                connection.cancel()
                throw error
            }
        }
    }

    public func close() { connection.cancel() }

    public func handshake() async throws {
        try await send(Data([3]) + Data((0 ..< 1536).map { _ in UInt8.random(in: 0 ... 255) }))
        let s0s1s2 = try await receive(1 + 1536 + 1536)
        try await send(s0s1s2.subdata(in: 1 ..< 1537)) // C2: S1 echoed
    }

    public func publish(app: String, stream: String) async throws {
        try await send(Self.chunks(csid: 2, type: 1, streamID: 0, timestamp: 0, payload: Self.uint32(UInt32(chunkSize)), chunkSize: 128))
        try await command(csid: 3, streamID: 0, [.string("connect"), .number(1),
                                                 .object([("app", .string(app)), ("type", .string("nonprivate")),
                                                          ("tcUrl", .string("rtmp://127.0.0.1/\(app)"))])])
        try await command(csid: 3, streamID: 0, [.string("releaseStream"), .number(2), .null, .string(stream)])
        try await command(csid: 3, streamID: 0, [.string("FCPublish"), .number(3), .null, .string(stream)])
        try await command(csid: 3, streamID: 0, [.string("createStream"), .number(4), .null])
        try await command(csid: 4, streamID: 1, [.string("publish"), .number(5), .null, .string(stream), .string(app)])
    }

    public func video(_ tag: Data, timestamp: UInt32) async throws {
        try await send(Self.chunks(csid: 6, type: 9, streamID: 1, timestamp: timestamp, payload: tag, chunkSize: chunkSize))
    }

    /// AMF0, as far as a publisher's commands need it.
    enum AMF0 {
        case number(Double)
        case string(String)
        case null
        case object([(String, AMF0)])

        func encode(into data: inout Data) {
            switch self {
            case .number(let n):
                data.append(0x00)
                withUnsafeBytes(of: n.bitPattern.bigEndian) { data.append(contentsOf: $0) }
            case .string(let s):
                data.append(0x02)
                RTMPTestPublisher.appendShortString(s, to: &data)
            case .null:
                data.append(0x05)
            case .object(let fields):
                data.append(0x03)
                for (key, value) in fields {
                    RTMPTestPublisher.appendShortString(key, to: &data)
                    value.encode(into: &data)
                }
                data.append(contentsOf: [0x00, 0x00, 0x09])
            }
        }
    }

    static func appendShortString(_ s: String, to data: inout Data) {
        let bytes = Array(s.utf8)
        data.append(UInt8(bytes.count >> 8 & 0xFF))
        data.append(UInt8(bytes.count & 0xFF))
        data.append(contentsOf: bytes)
    }

    private func command(csid: UInt8, streamID: UInt32, _ values: [AMF0]) async throws {
        var payload = Data()
        for value in values { value.encode(into: &payload) }
        try await send(Self.chunks(csid: csid, type: 20, streamID: streamID, timestamp: 0, payload: payload, chunkSize: chunkSize))
    }

    /// A message as a type 0 chunk and type 3 continuations.
    public static func chunks(csid: UInt8, type: UInt8, streamID: UInt32, timestamp: UInt32, payload: Data, chunkSize: Int) -> Data {
        var out = Data([csid & 0x3F]) + uint24(timestamp) + uint24(UInt32(payload.count)) + Data([type])
        out += Data([UInt8(streamID & 0xFF), UInt8(streamID >> 8 & 0xFF), UInt8(streamID >> 16 & 0xFF), UInt8(streamID >> 24)])
        var offset = 0
        repeat {
            if offset > 0 { out.append(0xC0 | (csid & 0x3F)) }
            let n = min(chunkSize, payload.count - offset)
            out += payload.subdata(in: payload.startIndex + offset ..< payload.startIndex + offset + n)
            offset += n
        } while offset < payload.count
        return out
    }

    static func uint24(_ v: UInt32) -> Data { Data([UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
    static func uint32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func receive(_ count: Int) async throws -> Data {
        var data = Data()
        while data.count < count {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - data.count) { content, _, _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: content ?? Data()) }
                }
            }
            if chunk.isEmpty { throw URLError(.networkConnectionLost) }
            data += chunk
        }
        return data
    }
}

/// The tags of an FLV file: a camera's livestream as recorded (`Tests/BlackmagicRESTTests/Fixtures/pyxis-stream.flv`,
/// a PYXIS 12K's).
public enum FLVFixture {
    public struct Tag: Sendable {
        public let type: UInt8
        public let timestamp: UInt32
        public let data: Data
    }

    public static func tags(in url: URL) throws -> [Tag] {
        let b = [UInt8](try Data(contentsOf: url))
        var tags: [Tag] = []
        var at = Int(b[5]) << 24 | Int(b[6]) << 16 | Int(b[7]) << 8 | Int(b[8]) // the header's own length
        at += 4 // PreviousTagSize0
        while at + 11 <= b.count {
            let size = Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3])
            let timestamp = UInt32(b[at + 4]) << 16 | UInt32(b[at + 5]) << 8 | UInt32(b[at + 6]) | UInt32(b[at + 7]) << 24
            let start = at + 11
            guard start + size <= b.count else { break }
            tags.append(Tag(type: b[at] & 0x1F, timestamp: timestamp, data: Data(b[start ..< start + size])))
            at = start + size + 4
        }
        return tags
    }

    /// The PYXIS 12K's stream, from any test target: found by this file's path.
    public static var pyxisStream: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/BlackmagicRESTTests/Fixtures/pyxis-stream.flv")
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
