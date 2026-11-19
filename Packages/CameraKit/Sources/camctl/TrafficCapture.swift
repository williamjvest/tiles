// Traffic capture for --record <file>: captures raw PTP-IP bytes from both channels.
// Format: newline-delimited JSON records with direction, channel, timestamp, hex bytes.

import Foundation
import SonyPTP

// MARK: - JSON traffic log format

struct TrafficRecord: Codable {
    let timestamp: Double  // seconds since epoch
    let direction: String  // "sent" or "received"
    let channel: String    // "command" or "event"
    let hex: String        // raw bytes as hex string
}

public final class FileTrafficRecorder: TrafficRecorder, @unchecked Sendable {
    private let fileHandle: FileHandle
    private let lock = NSLock()

    public init(path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: path) else {
            throw NSError(domain: "camctl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot open capture file: \(path)"])
        }
        self.fileHandle = fh
    }

    public func record(direction: TrafficDirection, channel: TrafficChannel, data: Data) {
        let record = TrafficRecord(
            timestamp: Date().timeIntervalSince1970,
            direction: direction == .sent ? "sent" : "received",
            channel: channel == .command ? "command" : "event",
            hex: data.map { String(format: "%02x", $0) }.joined()
        )
        guard let encoded = try? JSONEncoder().encode(record),
              var line = String(data: encoded, encoding: .utf8) else { return }
        line += "\n"
        lock.lock()
        fileHandle.write(Data(line.utf8))
        lock.unlock()
    }
}
