import Foundation
import os

/// What Tiles has done with its cameras since it was opened: connects and their failures, links lost, live view
/// starting, its first frame and what stopped it. Kept in memory (the last 500 lines) and sent to the system log too.
/// Settings copies it: the one report a tester's iPad can give when nothing on screen says what went wrong.
public final class ActivityLog: @unchecked Sendable {
    public static let shared = ActivityLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let limit = 500
    private let logger = Logger(subsystem: "com.toldwell.twcc", category: "activity")

    /// One line, under `who`: a camera's host, say.
    public func note(_ who: String, _ what: String) {
        let time = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: Date())
        let line = String(format: "%02d:%02d:%02d.%03d ", time.hour ?? 0, time.minute ?? 0, time.second ?? 0,
                          (time.nanosecond ?? 0) / 1_000_000) + "\(who): \(what)"
        logger.notice("\(line, privacy: .public)")
        lock.withLock {
            lines.append(line)
            if lines.count > limit { lines.removeFirst(lines.count - limit) }
        }
    }

    public var text: String { lock.withLock { lines.joined(separator: "\n") } }
}
