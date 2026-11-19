import CoreGraphics
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers

/// A camera's livestream as live view: Tiles is the RTMP server the camera streams to, and decodes what it sends
/// (H.264) into pictures. A Blackmagic camera streams to it through a streaming platform Tiles adds
/// (`BlackmagicLiveView.swift`); an FX5 through a stream destination Tiles sets (`SonyCameraBackend+LiveStream.swift`).
public final class RTMPLiveStream: @unchecked Sendable {
    private let receiver: RTMPReceiver
    private let decoder = AVCDecoder()
    private let publishing = PublishMark()
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<CGImage?, Never>] = [:]
    private var frames = 0

    public init(trace: (@Sendable (String) -> Void)? = nil) {
        let decoder = self.decoder
        let publishing = self.publishing
        receiver = RTMPReceiver(trace: trace) { event in
            switch event {
            case .video(let timestamp, let payload): decoder.decode(flvVideo: payload, timestamp: timestamp)
            case .publishing: publishing.mark()
            case .ended: break
            }
        }
        decoder.onImage = { [weak self] image in self?.deliver(image) }
    }

    /// Whether the camera has connected and begun publishing to the receiver since `start`.
    public func published(since start: ContinuousClock.Instant) -> Bool {
        publishing.last.map { $0 >= start } ?? false
    }

    /// Listens for the camera, on the port it listened on before if it can (the camera's platform names it), else
    /// 1935, else any free port. Returns the port; already listening, just the port.
    public func listen() async throws -> UInt16 {
        if receiver.isListening { return receiver.port }
        let preferred = receiver.port == 0 ? 1935 : receiver.port
        // A listener just closed lets its port go a moment later: a few tries before another port (which the camera's
        // platform doesn't name, so live view would start the stream over).
        for _ in 0 ..< 5 {
            if let port = try? await receiver.start(port: preferred) { return port }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return try await receiver.start(port: 0)
    }

    /// Stops listening; a picture being waited for comes back empty.
    public func close() {
        receiver.stop()
        resumeAll(with: nil)
    }

    /// The next picture, or nil after `timeout` (or a stop).
    public func nextFrame(timeout: Duration) async -> CGImage? {
        let id = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            lock.lock()
            waiters[id] = continuation
            lock.unlock()
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.expire(id)
            }
        }
    }

    public var frameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    private func deliver(_ image: CGImage) {
        lock.lock()
        frames += 1
        lock.unlock()
        resumeAll(with: image)
    }

    private func resumeAll(with image: CGImage?) {
        lock.lock()
        let waiting = waiters.values
        waiters = [:]
        lock.unlock()
        waiting.forEach { $0.resume(returning: image) }
    }

    private func expire(_ id: UUID) {
        lock.lock()
        let expired = waiters.removeValue(forKey: id)
        lock.unlock()
        expired?.resume(returning: nil)
    }

    /// This device's address on the way to `host` (the interface a connection to the camera leaves by), which is
    /// where the camera has to stream to.
    public static func localAddress(toward host: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let lookup = AddressLookup(connection: NWConnection(host: NWEndpoint.Host(host), port: 443, using: .udp),
                                       continuation: continuation)
            lookup.start()
        }
    }

    public static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}


/// When a publisher last began publishing to the receiver, set from the receiver's queue.
private final class PublishMark: @unchecked Sendable {
    private let lock = NSLock()
    private var at: ContinuousClock.Instant?

    func mark() { lock.withLock { at = .now } }
    var last: ContinuousClock.Instant? { lock.withLock { at } }
}

/// A UDP "connection" to the camera, which sends nothing: once it's ready, its local endpoint is the address the
/// camera can reach this device at.
private final class AddressLookup: @unchecked Sendable {
    private let connection: NWConnection
    private var continuation: CheckedContinuation<String?, Never>?
    private let queue = DispatchQueue(label: "tiles.local-address")

    init(connection: NWConnection, continuation: CheckedContinuation<String?, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                if case .hostPort(let local, _)? = connection.currentPath?.localEndpoint {
                    finish("\(local)".split(separator: "%").first.map(String.init))
                } else {
                    finish(nil)
                }
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [self] in finish(nil) }
    }

    /// On the queue only, so once.
    private func finish(_ address: String?) {
        guard let continuation else { return }
        self.continuation = nil
        connection.cancel()
        continuation.resume(returning: address)
    }
}
