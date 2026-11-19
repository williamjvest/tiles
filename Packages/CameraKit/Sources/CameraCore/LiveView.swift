// LiveView.swift — vendor-neutral live view protocol and configuration.
// DashboardUI depends only on this; it never imports SonyPTP.
//
// Mechanism:
//   Live view goes over the existing PTP command channel, not a second connection.
//   When Live View Status (0xD221) == 0x01 (Enabled):
//     1. GetObjectInfo(0xFFFFC002) — once per session, primes the handle.
//     2. GetObject(0xFFFFC002)    — one call per frame; returns LiveView Dataset.
//   LiveView Dataset: Offset(4) + ImageSize(4) + FocalOffset(4) + FocalSize(4) + Reserved + JPEG.
//   If response is 0x200F (Access_Denied): frame not ready, retry.
//   If response is 0x2009 (Invalid_Object_Handle): live view not enabled.
//   Max fps: 30; do not call more than twice within 33 ms.
//   LiveViewURL (0xD278) is for pan/tilt cameras only (BRC-AM7, FR7) — not used here.

import Foundation

// MARK: - LiveViewProvider

/// A backend that can stream live view frames via GetObject(0xFFFFC002).
///
/// `liveViewFrame()` fetches one frame via the existing PTP command channel.
/// Callers must not call it concurrently with itself or with a REC/set command.
/// The implementation handles quality restore on `stopLiveView()`.
public protocol LiveViewProvider: AnyObject, Sendable {
    /// Whether Live View Status (0xD221) reports Enabled (0x01).
    var liveViewAvailable: Bool { get async }

    /// Before the first frame: set the image quality (remembering the camera's own, which `stopLiveView` restores)
    /// and read the live-view ObjectInfo once, as the protocol asks.
    func startLiveView(quality: LiveViewQuality) async throws

    /// Fetch one JPEG frame. Throws `LiveViewError` on failure.
    func liveViewFrame() async throws -> Data
    /// One frame as the session hands it on: the JPEG from `liveViewFrame()` unless the provider decodes a video stream
    /// itself (a Blackmagic camera's livestream), which gives the picture.
    func liveViewPicture() async throws -> LiveViewFrame

    /// Restore any camera setting changed for live view (e.g. 0xD26A quality). Call on sheet close.
    func stopLiveView() async

    /// How fast, at what quality, and for how long to stream: the link decides. Default: `LiveViewConfig()`.
    var liveViewConfig: LiveViewConfig { get async }
}

extension LiveViewProvider {
    public var liveViewConfig: LiveViewConfig { get async { LiveViewConfig() } }
    public func liveViewPicture() async throws -> LiveViewFrame { LiveViewFrame(jpeg: try await liveViewFrame()) }
}

// MARK: - LiveViewError

public enum LiveViewError: LocalizedError, Sendable {
    case unavailable
    case noData        // camera says retry (0x200F) or imageSize=0
    case disconnected
    /// The camera answered a live view request with this PTP response code.
    case refused(UInt16)
    /// A frame came, but no picture could be found in it: what came.
    case badFrame(String)
    /// The camera wouldn't start the stream live view comes through: the step and its reason.
    case streamRefused(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "The camera has no live picture to send"
        case .noData: "The camera hasn't sent a frame"
        case .disconnected: "Not connected"
        case .refused(let code): "The camera refused live view (0x\(String(code, radix: 16, uppercase: true)))"
        case .badFrame(let what): "A frame came without a picture in it (\(what))"
        case .streamRefused(let why): "The camera wouldn't start its stream: \(why)"
        }
    }
}

// MARK: - LiveViewQuality

/// Live View Image Quality (0xD26A). Low = smallest frames for bandwidth-constrained links.
public enum LiveViewQuality: UInt8, Codable, CaseIterable, Sendable {
    case low  = 0x01
    case high = 0x02
}

// MARK: - LiveViewSettings

/// What the viewer chose for one camera's live view. nil leaves it to the link: High as fast as the camera goes on a
/// cable, Low at 1 fps over a network.
public struct LiveViewSettings: Codable, Hashable, Sendable {
    public var quality: LiveViewQuality?
    public var framesPerSecond: Double?

    public init(quality: LiveViewQuality? = nil, framesPerSecond: Double? = nil) {
        self.quality = quality
        self.framesPerSecond = framesPerSecond
    }

    /// The rates offered. 30 is the most the camera serves.
    public static let frameRates: [Double] = [1, 2, 5, 10, 15, 24, 30]

    /// The link's config with these choices applied.
    public func applied(to config: LiveViewConfig) -> LiveViewConfig {
        var config = config
        if let quality { config.quality = quality }
        // A stream comes at the camera's own rate: asking for fewer only drops pictures, not data.
        if let framesPerSecond, framesPerSecond > 0, !config.isStream { config.frameInterval = 1 / framesPerSecond }
        return config
    }
}

// MARK: - LiveViewConfig

/// Tuning knobs for the on-demand live view tile.
public struct LiveViewConfig: Sendable {
    /// Target frame interval (seconds). 1 fps default.
    public var frameInterval: TimeInterval = 1.0
    /// How long the viewer stays open before showing "Keep watching"; nil: until it's closed.
    public var autoStopSeconds: TimeInterval? = 20.0
    /// Quality to request. Low = smaller frames.
    public var quality: LiveViewQuality = .low
    /// The camera sends video at its own rate (a Blackmagic livestream), so there's no frame rate to choose and the
    /// session takes frames as they come.
    public var isStream = false
    public init() {}

    /// A camera's livestream: frames as they come, at Low unless chosen, until the viewer is closed (stopping a
    /// Blackmagic stream shows Review on the camera for a moment, so it isn't stopped and restarted on a timer).
    public static let stream: LiveViewConfig = {
        var config = LiveViewConfig()
        config.frameInterval = 0
        config.autoStopSeconds = nil
        config.isStream = true
        return config
    }()

    /// A camera on a cable: frames cost no network, so as fast as the camera makes them (24 fps, within the limit of
    /// two calls per 33 ms), at High quality, with no time limit.
    public static let cabled: LiveViewConfig = {
        var config = LiveViewConfig()
        config.frameInterval = 1.0 / 24
        config.quality = .high
        config.autoStopSeconds = nil
        return config
    }()
}

