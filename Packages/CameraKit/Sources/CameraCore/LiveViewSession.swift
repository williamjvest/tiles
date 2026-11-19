import CoreGraphics
import Foundation

// MARK: - LiveViewFrame

/// One live view frame: a JPEG as a Sony camera sends it, or a picture already decoded from a video stream (a
/// Blackmagic camera's livestream).
public struct LiveViewFrame: @unchecked Sendable {
    public let jpeg: Data?
    /// Immutable once made, so it crosses actors safely (CGImage isn't marked Sendable).
    public let image: CGImage?

    public init(jpeg: Data) {
        self.jpeg = jpeg
        image = nil
    }

    public init(image: CGImage) {
        jpeg = nil
        self.image = image
    }
}

// MARK: - LiveViewSessionDelegate

/// Consumers implement this to receive frames (called on the session's actor executor).
public protocol LiveViewSessionDelegate: AnyObject, Sendable {
    func liveViewSession(_ session: LiveViewSession, didReceive frame: LiveViewFrame)
    func liveViewSession(_ session: LiveViewSession, didFail error: Error)
}

// MARK: - LiveViewSession

/// Reference-counted, per-camera live view stream actor.
///
/// One actor per camera. Consumers call subscribe() / unsubscribe(). 0→1 starts the fetch loop;
/// 1→0 stops it and calls stopLiveView() on the provider. Two consumers share one stream.
/// On fetch error the loop retries with backoff (1 s, 2 s, 4 s … 30 s) while subscribers remain.
public actor LiveViewSession {

    // MARK: Subscriptions

    private struct Subscription {
        weak var delegate: (any LiveViewSessionDelegate)?
    }
    private var subscriptions: [ObjectIdentifier: Subscription] = [:]

    // MARK: State

    private let provider: any LiveViewProvider
    private var fetchTask: Task<Void, Never>?
    /// The last stop, still running. A new start waits for it: otherwise a quick unsubscribe/subscribe (the tile
    /// handing over to the sheet, a page flipped away and back) can land the old stop after the new start and leave
    /// the loop fetching from a camera whose live view was just switched off.
    private var stopTask: Task<Void, Never>?
    private var settings: LiveViewSettings

    public init(provider: any LiveViewProvider, settings: LiveViewSettings = LiveViewSettings()) {
        self.provider = provider
        self.settings = settings
    }

    // MARK: - Public API

    /// Adds a consumer. Starts the fetch loop on 0→1 transition.
    public func subscribe(_ delegate: any LiveViewSessionDelegate) {
        let key = ObjectIdentifier(delegate)
        subscriptions[key] = Subscription(delegate: delegate)
        startFetching()
    }

    /// Removes a consumer. Stops the fetch loop on 1→0 transition.
    public func unsubscribe(_ delegate: any LiveViewSessionDelegate) {
        subscriptions.removeValue(forKey: ObjectIdentifier(delegate))
        pruneDeadSubscriptions()
        if subscriptions.isEmpty {
            stopFetching()
        }
    }

    /// New choices for picture quality and frame rate. A stream that's running restarts with them.
    public func apply(_ settings: LiveViewSettings) {
        guard settings != self.settings else { return }
        self.settings = settings
        guard fetchTask != nil else { return }
        stopFetching()
        startFetching()
    }

    // MARK: - Private

    private func startFetching() {
        guard fetchTask == nil else { return }
        let provider = self.provider
        let settings = self.settings
        let pendingStop = stopTask
        stopTask = nil
        fetchTask = Task { [weak self] in
            await pendingStop?.value
            let config = settings.applied(to: await provider.liveViewConfig)
            var retryDelay: Double = 1
            while !Task.isCancelled {
                // Start (or restart after a stop) the camera's live view.
                do {
                    try await provider.startLiveView(quality: config.quality)
                } catch {
                    await self?.broadcastError(error)
                    // Error on start: back off and retry while subscribers remain; a camera that's away, as soon as
                    // it's back.
                    let hasSubscribers = await self?.hasSubscribers ?? false
                    guard hasSubscribers else { return }
                    await Self.pause(&retryDelay, provider: provider)
                    continue
                }
                retryDelay = 1
                // Fetch loop.
                var faulted = false
                // A camera that never has a frame ready says so (once), and the loop keeps asking.
                var lastFrame = Date()
                var saidNoFrames = false
                while !Task.isCancelled {
                    guard await provider.liveViewAvailable else {
                        await self?.broadcastError(LiveViewError.unavailable)
                        faulted = true
                        break
                    }
                    let t0 = Date()
                    do {
                        let frame = try await provider.liveViewPicture()
                        if Task.isCancelled { break }
                        lastFrame = Date()
                        await self?.broadcastFrame(frame)
                        let elapsed = Date().timeIntervalSince(t0)
                        let wait = config.frameInterval - elapsed
                        if wait > 0 {
                            try? await Task.sleep(for: .seconds(wait))
                        }
                    } catch is CancellationError {
                        break
                    } catch LiveViewError.noData {
                        // 0x200F / empty image: the camera has no frame ready yet. Try again.
                        if !saidNoFrames, Date().timeIntervalSince(lastFrame) > 5 {
                            saidNoFrames = true
                            await self?.broadcastError(LiveViewError.noData)
                        }
                        try? await Task.sleep(for: .seconds(config.frameInterval))
                    } catch {
                        await self?.broadcastError(error)
                        faulted = true
                        break
                    }
                }
                guard faulted, !Task.isCancelled else { break }
                // After an error, stop the camera's live view in order (matching what stopFetching does),
                // then retry after a backoff while subscribers remain.
                await provider.stopLiveView()
                let hasSubscribers = await self?.hasSubscribers ?? false
                guard hasSubscribers else { break }
                await Self.pause(&retryDelay, provider: provider)
            }
        }
    }

    /// Before trying again: the backoff (doubling to 30 s), or for a camera that's away, until it's offered again
    /// (checked every second), so live view comes back with the connection rather than up to 30 s later.
    private static func pause(_ retryDelay: inout Double, provider: any LiveViewProvider) async {
        guard await provider.liveViewAvailable else {
            while !Task.isCancelled, await !provider.liveViewAvailable {
                try? await Task.sleep(for: .seconds(1))
            }
            return
        }
        try? await Task.sleep(for: .seconds(retryDelay))
        retryDelay = min(retryDelay * 2, 30)
    }

    private func stopFetching() {
        let running = fetchTask
        running?.cancel()
        fetchTask = nil
        let provider = self.provider
        // After the loop has let go (a frame request in flight finishes first), then switch the camera's live view off.
        stopTask = Task { await running?.value; await provider.stopLiveView() }
    }

    private var hasSubscribers: Bool { !subscriptions.isEmpty }

    private func broadcastFrame(_ frame: LiveViewFrame) {
        pruneDeadSubscriptions()
        for sub in subscriptions.values {
            sub.delegate?.liveViewSession(self, didReceive: frame)
        }
    }

    private func broadcastError(_ error: Error) {
        pruneDeadSubscriptions()
        for sub in subscriptions.values {
            sub.delegate?.liveViewSession(self, didFail: error)
        }
    }

    private func pruneDeadSubscriptions() {
        subscriptions = subscriptions.filter { $0.value.delegate != nil }
    }
}

