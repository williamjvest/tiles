import Foundation

/// Timecode that runs locally from the last value the camera reported, so the link never carries a
/// per-frame poll. Backends resync it periodically.
///
/// Drop-frame timecode isn't handled yet: 29.97 DF will drift until the next resync.
public struct TimecodeClock: Sendable, Equatable {
    /// Frame count since 00:00:00:00 at `anchor`.
    public var frames: Int
    public var anchor: Date
    /// Nominal frames per second used for counting (24, 25, 30, …).
    public var rate: Int
    /// Real frames per second used for elapsed time (23.976 for "24" on most cameras).
    public var fps: Double
    public var isRunning: Bool

    public init(frames: Int, anchor: Date, rate: Int, fps: Double, isRunning: Bool) {
        self.frames = frames
        self.anchor = anchor
        self.rate = max(rate, 1)
        self.fps = fps > 0 ? fps : Double(max(rate, 1))
        self.isRunning = isRunning
    }

    public init(hours: Int, minutes: Int, seconds: Int, frames: Int, rate: Int, fps: Double, anchor: Date, isRunning: Bool) {
        let nominal = max(rate, 1)
        self.init(
            frames: ((hours * 60 + minutes) * 60 + seconds) * nominal + frames,
            anchor: anchor, rate: nominal, fps: fps, isRunning: isRunning
        )
    }

    public func frames(at date: Date) -> Int {
        guard isRunning else { return frames }
        let elapsed = max(0, date.timeIntervalSince(anchor))
        return frames + Int((elapsed * fps).rounded(.down))
    }

    /// `HH:MM:SS:FF`, wrapping at 24 hours.
    public func string(at date: Date) -> String {
        let total = frames(at: date) % (rate * 86_400)
        let seconds = total / rate
        return String(format: "%02d:%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60, total % rate)
    }
}
