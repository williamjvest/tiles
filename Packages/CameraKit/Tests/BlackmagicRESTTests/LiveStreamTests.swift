@testable import BlackmagicRESTBackend
@testable import CameraCore
import CoreGraphics
import CameraKitTestSupport
import Foundation
import Network
import Testing

/// Live view through a Blackmagic camera's livestream: the RTMP server Tiles runs and the H.264 decoding behind it,
/// fed 1.5 s of what a PYXIS 12K streamed (1080p24, H.264 Main, recorded through FFmpeg).
@Suite("Blackmagic live view: RTMP and H.264", .serialized, .rtmpPort)
struct LiveStreamTests {
    typealias FLVTag = FLVFixture.Tag

    static func fixtureTags() throws -> [FLVTag] {
        let url = try #require(Bundle.module.url(forResource: "pyxis-stream", withExtension: "flv"))
        return try FLVFixture.tags(in: url)
    }

    /// Pictures from a decoder, safe to read from the test.
    final class Pictures: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [CGImage] = []
        func add(_ image: CGImage) { lock.lock(); images.append(image); lock.unlock() }
        var all: [CGImage] { lock.lock(); defer { lock.unlock() }; return images }

        func wait(for count: Int, seconds: Double = 5) async -> [CGImage] {
            let deadline = Date().addingTimeInterval(seconds)
            while all.count < count, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            return all
        }
    }

    @Test("The camera's own stream decodes: 1920×1080 pictures, from the first keyframe on")
    func decodesTheCamerasStream() async throws {
        let tags = try Self.fixtureTags().filter { $0.type == 9 }
        #expect(tags.count > 30)
        let decoder = AVCDecoder()
        let pictures = Pictures()
        decoder.onImage = { pictures.add($0) }
        for tag in tags { decoder.decode(flvVideo: tag.data, timestamp: tag.timestamp) }
        // Every frame but the configuration record, and the last, which the decoder holds for the one after it (a wait
        // for that one sat out the whole 5 s every run).
        let images = await pictures.wait(for: tags.count - 2)
        #expect(images.count >= tags.count - 2, "decode failures \(decoder.failures)")
        #expect(images.first.map { ($0.width, $0.height) } ?? (0, 0) == (1920, 1080))
    }

    @Test("An RTMP publisher's video reaches the decoder through the server", .timeLimit(.minutes(1)))
    func rtmpEndToEnd() async throws {
        let decoder = AVCDecoder()
        let pictures = Pictures()
        decoder.onImage = { pictures.add($0) }
        let published = Pictures() // counts publish events as 1×1 stand-ins
        let videos = Pictures()    // and video messages
        let receiver = RTMPReceiver { event in
            switch event {
            case .video(let timestamp, let payload):
                videos.add(Self.dot)
                decoder.decode(flvVideo: payload, timestamp: timestamp)
            case .publishing: published.add(Self.dot)
            case .ended: break
            }
        }
        let port = try await receiver.start(port: 0)
        defer { receiver.stop() }

        let client = try await Publisher(port: port)
        defer { client.close() }
        try await client.handshake()
        try await client.publish(app: "live", stream: "tiles")
        let tags = try Self.fixtureTags().filter { $0.type == 9 }
        for tag in tags { try await client.video(tag.data, timestamp: tag.timestamp) }

        #expect(await published.wait(for: 1).count == 1)
        let images = await pictures.wait(for: 10)
        // Rarely one picture comes, of the 36: a decode failure on either side. Rerun once to confirm.
        #expect(images.count >= 10, "\(videos.all.count) of \(tags.count) video messages in, decode failures \(decoder.failures)")
        #expect(images.first.map { ($0.width, $0.height) } ?? (0, 0) == (1920, 1080))
    }

    @Test("Chunks split anywhere in the stream still make whole messages")
    func chunkBoundaries() throws {
        var messages: [(UInt32, Data)] = []
        var sent = Data()
        let session = RTMPSession(send: { sent.append($0) }, onEvent: { event in
            if case .video(let timestamp, let payload) = event { messages.append((timestamp, payload)) }
        })
        // Handshake, then a 300-byte video message in 128-byte chunks, fed one byte at a time.
        var stream = Data([3]) + Data(count: 1536)
        stream += Data(count: 1536) // C2
        let payload = Data((0 ..< 300).map { UInt8($0 & 0xFF) })
        stream += Publisher.chunks(csid: 6, type: 9, streamID: 1, timestamp: 40, payload: payload, chunkSize: 128)
        for byte in stream { try session.feed(Data([byte])) }
        #expect(sent.count == 1 + 1536 + 1536)   // S0, S1, S2
        #expect(messages.count == 1)
        #expect(messages.first?.0 == 40 && messages.first?.1 == payload)
    }

    static let dot: CGImage = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()

    @Test("Tiles' streaming platform: one server at this device, Low and High profiles, H.264 only")
    func platformXML() {
        let xml = BlackmagicLiveStream.platformXML(url: "rtmp://203.0.113.156:1935/live")
        #expect(xml.contains("<name>Tiles</name>"))
        #expect(xml.contains("<url>rtmp://203.0.113.156:1935/live</url>"))
        #expect(xml.contains("<name>Tiles Low</name>") && xml.contains("<name>Tiles High</name>"))
        #expect(!xml.contains("H265"))
    }
}

/// The shared test publisher (CameraKitTestSupport), as these tests have always called it.
typealias Publisher = RTMPTestPublisher
