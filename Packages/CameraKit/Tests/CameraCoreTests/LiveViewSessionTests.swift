// LiveViewSessionTests.swift — inline live view session: one stream, visibility gating.

import Testing
import Foundation
@testable import CameraCore

// MARK: - FetchCountingProvider

/// Counts startLiveView / liveViewFrame / stopLiveView calls.
private actor FetchCountingProvider: LiveViewProvider {
    var startCount = 0
    var fetchCount = 0
    var stopCount = 0
    var shouldBlock = false   // if true, liveViewFrame sleeps indefinitely

    var liveViewAvailable: Bool { true }

    func startLiveView(quality: LiveViewQuality) async throws { startCount += 1 }

    func liveViewFrame() async throws -> Data {
        if shouldBlock {
            // Block until canceled
            try await Task.sleep(for: .seconds(300))
        }
        fetchCount += 1
        return MockCameraBackend.syntheticJPEG
    }

    func stopLiveView() async { stopCount += 1 }
}

/// Fails every liveViewFrame call until `failCount` is zero, then succeeds. Used to exercise the
/// error-recovery / retry path: the session must reset and resume after a transient failure.
private actor FailOnceThenSucceedProvider: LiveViewProvider {
    var failCount: Int
    var fetchCount = 0
    var startCount = 0
    var stopCount = 0
    var liveViewAvailable: Bool { true }

    init(failCount: Int = 1) { self.failCount = failCount }

    func startLiveView(quality: LiveViewQuality) async throws { startCount += 1 }
    func liveViewFrame() async throws -> Data {
        if failCount > 0 {
            failCount -= 1
            throw LiveViewError.unavailable
        }
        fetchCount += 1
        return MockCameraBackend.syntheticJPEG
    }
    func stopLiveView() async { stopCount += 1 }
}

/// A camera whose live view takes a moment to switch off, and which serves no frames while it's off: the shape of the
/// tile → sheet handover, or a page flipped away and straight back.
private actor SlowStopProvider: LiveViewProvider {
    var on = false
    var log: [String] = []
    var fetchCount = 0
    var liveViewAvailable: Bool { true }
    func startLiveView(quality: LiveViewQuality) async throws { on = true; log.append("start") }
    func liveViewFrame() async throws -> Data {
        guard on else { throw LiveViewError.unavailable }
        fetchCount += 1
        return MockCameraBackend.syntheticJPEG
    }
    func stopLiveView() async {
        try? await Task.sleep(for: .milliseconds(120))
        on = false
        log.append("stop")
    }
}

/// Remembers the quality each start asked for.
private actor QualityRecordingProvider: LiveViewProvider {
    var qualities: [LiveViewQuality] = []
    var stopCount = 0
    var liveViewAvailable: Bool { true }
    var liveViewConfig: LiveViewConfig { get async { .cabled } }
    func startLiveView(quality: LiveViewQuality) async throws { qualities.append(quality) }
    func liveViewFrame() async throws -> Data { MockCameraBackend.syntheticJPEG }
    func stopLiveView() async { stopCount += 1 }
}

// MARK: - SimpleDelegate

private final class SimpleDelegate: LiveViewSessionDelegate, @unchecked Sendable {
    var frames: [LiveViewFrame] = []
    var errors: [Error] = []

    func liveViewSession(_ session: LiveViewSession, didReceive frame: LiveViewFrame) {
        frames.append(frame)
    }
    func liveViewSession(_ session: LiveViewSession, didFail error: Error) {
        errors.append(error)
    }
}

// MARK: - Tests

@Suite("LiveViewSession", .serialized)
struct LiveViewSessionTests {

    // MARK: No fetch without subscriber

    @Test("No fetches without a subscriber", .timeLimit(.minutes(1)))
    func noFetchWithoutSubscriber() async throws {
        let provider = FetchCountingProvider()
        _ = LiveViewSession(provider: provider)

        // Negative check: no subscriber was ever added, nothing should start.
        try await Task.sleep(for: .milliseconds(100))

        let fetches = await provider.fetchCount
        #expect(fetches == 0, "Expected 0 fetches with no subscriber, got \(fetches)")
    }

    // MARK: 2 — Fetch starts on subscribe; stops on unsubscribe

    @Test("Fetch starts on subscribe and stops on unsubscribe", .timeLimit(.minutes(1)))
    func fetchStartsAndStops() async throws {
        let provider = FetchCountingProvider()
        let session = LiveViewSession(provider: provider)
        let delegate = SimpleDelegate()

        await session.subscribe(delegate)

        // Wait for at least one frame.
        for _ in 0..<200 { if await provider.fetchCount > 0 { break }; try await Task.sleep(nanoseconds: 10_000_000) }

        let fetchesDuringStream = await provider.fetchCount
        #expect(fetchesDuringStream > 0, "Expected frames while subscribed")
        let stopBefore = await provider.stopCount
        #expect(stopBefore == 0, "stopLiveView should not have been called yet")

        await session.unsubscribe(delegate)

        // Wait for stopLiveView.
        for _ in 0..<200 { if await provider.stopCount >= 1 { break }; try await Task.sleep(nanoseconds: 10_000_000) }

        let stopAfter = await provider.stopCount
        #expect(stopAfter >= 1, "stopLiveView should be called after last unsubscribe")

        // Negative check: no fetches for 100 ms after stop.
        let fetchAfterStop = await provider.fetchCount
        try await Task.sleep(for: .milliseconds(100))
        let fetchAfterWait = await provider.fetchCount
        #expect(fetchAfterWait == fetchAfterStop, "Fetches should have stopped after unsubscribe")
    }

    // MARK: 3 — Two consumers → one stream

    @Test("Two consumers share one stream (fetch count not doubled)", .timeLimit(.minutes(1)))
    func twoConsumersOneStream() async throws {
        let provider = FetchCountingProvider()
        let session = LiveViewSession(provider: provider)
        let d1 = SimpleDelegate()
        let d2 = SimpleDelegate()

        await session.subscribe(d1)
        await session.subscribe(d2)

        for _ in 0..<200 { if d1.frames.count > 0 && d2.frames.count > 0 { break }; try await Task.sleep(nanoseconds: 10_000_000) }

        let fetches = await provider.fetchCount
        let d1Frames = d1.frames.count
        let d2Frames = d2.frames.count

        // Both delegates received frames from the same fetches
        #expect(d1Frames > 0, "d1 should receive frames")
        #expect(d2Frames > 0, "d2 should receive frames")
        // Each fetch was delivered to both — but the fetch was not doubled
        #expect(fetches > 0)
        // If the stream were duplicated, fetches would be ≥ d1Frames + d2Frames.
        // With a single stream, fetches ≈ max(d1Frames, d2Frames).
        #expect(fetches < d1Frames + d2Frames + 2, "Fetch count should not be doubled by two consumers")

        await session.unsubscribe(d1)
        await session.unsubscribe(d2)
    }

    // MARK: 4 — Last unsubscribe → stopLiveView

    @Test("Removing last subscriber stops the camera's live view", .timeLimit(.minutes(1)))
    func lastUnsubscribeStopsCamera() async throws {
        let provider = FetchCountingProvider()
        let session = LiveViewSession(provider: provider)
        let d1 = SimpleDelegate()
        let d2 = SimpleDelegate()

        await session.subscribe(d1)
        await session.subscribe(d2)
        for _ in 0..<200 { if await provider.fetchCount > 0 { break }; try await Task.sleep(nanoseconds: 10_000_000) }

        // Remove first — stream should continue
        await session.unsubscribe(d1)
        // Negative check: stop must not fire while d2 is still subscribed.
        try await Task.sleep(for: .milliseconds(50))
        let stopAfterFirst = await provider.stopCount
        #expect(stopAfterFirst == 0, "stopLiveView should not fire while a second consumer remains")

        // Remove second — now it must stop
        await session.unsubscribe(d2)
        for _ in 0..<200 { if await provider.stopCount >= 1 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let stopAfterSecond = await provider.stopCount
        #expect(stopAfterSecond >= 1, "stopLiveView must fire after the last subscriber leaves")
    }

    // MARK: 5 — Resubscribe after pause restarts cleanly

    @Test("Resubscribe after full unsubscribe restarts the stream", .timeLimit(.minutes(1)))
    func resubscribeRestartsStream() async throws {
        let provider = FetchCountingProvider()
        let session = LiveViewSession(provider: provider)
        let delegate = SimpleDelegate()

        await session.subscribe(delegate)
        for _ in 0..<200 { if await provider.fetchCount > 0 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        await session.unsubscribe(delegate)
        for _ in 0..<200 { if await provider.stopCount >= 1 { break }; try await Task.sleep(nanoseconds: 10_000_000) }

        let fetchesAfterStop = await provider.fetchCount
        let startAfterStop = await provider.startCount

        // Re-subscribe
        await session.subscribe(delegate)
        for _ in 0..<200 { if await provider.fetchCount > fetchesAfterStop { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        await session.unsubscribe(delegate)
        for _ in 0..<200 { if await provider.stopCount >= 2 { break }; try await Task.sleep(nanoseconds: 10_000_000) }

        let fetchesAfterRestart = await provider.fetchCount
        let startAfterRestart = await provider.startCount

        #expect(fetchesAfterRestart > fetchesAfterStop, "Resubscribe should produce new frames")
        #expect(startAfterRestart > startAfterStop, "startLiveView should be called again on resubscribe")
    }

    @Test("Unsubscribe then straight back: the old stop lands before the new start", .timeLimit(.minutes(1)))
    func quickResubscribeKeepsTheStreamOn() async throws {
        let provider = SlowStopProvider()
        let session = LiveViewSession(provider: provider)
        let tile = SimpleDelegate(), sheet = SimpleDelegate()
        await session.subscribe(tile)
        try await Task.sleep(for: .milliseconds(60))
        await session.unsubscribe(tile)   // the tile lets go as the sheet opens...
        await session.subscribe(sheet)    // ...and the sheet takes over at once
        try await Task.sleep(for: .milliseconds(500))
        #expect(await provider.log == ["start", "stop", "start"])
        #expect(await provider.on, "the camera's live view must be on while the sheet watches")
        #expect(sheet.errors.isEmpty)
        await session.unsubscribe(sheet)
    }

    // MARK: 7 — Error recovery: provider that fails once resumes delivering frames

    @Test("BUG: fetch-error recovery — stream recovers after a transient failure", .timeLimit(.minutes(1)))
    func fetchErrorRecovery() async throws {
        // The provider fails the first liveViewFrame call, then succeeds. Without the fix, fetchTask is
        // never cleared on error, so resubscribing after the delegate is gone can't start a new loop.
        // With the fix, the loop retries after a backoff and the delegate sees frames again.
        let provider = FailOnceThenSucceedProvider(failCount: 1)
        let session = LiveViewSession(provider: provider)
        let delegate = SimpleDelegate()

        await session.subscribe(delegate)

        // Wait long enough for: first attempt (fails), backoff (1 s), retry start, at least one frame.
        try await Task.sleep(for: .seconds(2))

        let fetches = await provider.fetchCount
        #expect(fetches > 0, "Session must recover from the transient error and deliver frames")
        // The provider's stopLiveView must have been called between the error and the retry.
        let stops = await provider.stopCount
        #expect(stops >= 1, "stopLiveView must be called to clean up before retrying")

        await session.unsubscribe(delegate)
    }

    @Test("New settings restart a running stream with them", .timeLimit(.minutes(1)))
    func settingsRestartTheStream() async throws {
        let provider = QualityRecordingProvider()
        let session = LiveViewSession(provider: provider)
        let delegate = SimpleDelegate()
        await session.subscribe(delegate)
        for _ in 0..<200 { if await provider.qualities.count > 0 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(await provider.qualities == [.high], "a cable's own choice until one is made")

        await session.apply(LiveViewSettings(quality: .low))
        for _ in 0..<200 { if await provider.qualities.count > 1 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(await provider.qualities == [.high, .low])
        #expect(await provider.stopCount == 1, "the camera's live view is stopped before it starts again")

        await session.apply(LiveViewSettings(quality: .low))  // the same again changes nothing
        try await Task.sleep(for: .milliseconds(50))
        #expect(await provider.qualities == [.high, .low])
        await session.unsubscribe(delegate)
    }
}
