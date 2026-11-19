import CameraCore
import Foundation

// A Blackmagic camera's audio, from its API documentation (AudioControl, Camera 10.1): no camera has been checked yet.
// The channels are counted at /audio/channels; each one's settings are at /audio/channel/{i}/{leaf}, and its input's
// gain range and switches at /audio/channel/{i}/input/description. The API has no meters.

/// GET /audio/channels: `{"channels": 2}`.
struct AudioChannelsResponse: Decodable, Sendable {
    var channels: Int?
}

/// One of GET /audio/channel/{i}/supportedInputs: `[{"input": "XLR1 - Mic", "available": true}, …]`.
struct AudioSupportedInput: Decodable, Sendable, Equatable {
    var input: String
    /// It can be switched to from the channel's current input.
    var available: Bool?
}

/// GET /audio/channel/{i}/input/description: `{"description": {"gainRange": {"Min", "Max"}, "capabilities": [...]}}`.
struct AudioInputDescriptionResponse: Decodable, Sendable {
    var description: AudioInputDescription?
}

struct AudioInputDescription: Decodable, Sendable, Equatable {
    var gainRange: GainRange?
    /// An array of objects in the documentation, each with any of the switches: read as one set, whichever way the
    /// camera splits them.
    var capabilities: [Capability]?

    struct GainRange: Decodable, Sendable, Equatable {
        var min: Double?
        var max: Double?
        private enum CodingKeys: String, CodingKey { case min = "Min", max = "Max" }
    }

    struct Capability: Decodable, Sendable, Equatable {
        var phantomPower: Bool?
        var lowCutFilter: Bool?
        var padding: Padding?
        private enum CodingKeys: String, CodingKey {
            case phantomPower = "PhantomPower", lowCutFilter = "LowCutFilter", padding = "Padding"
        }
    }

    struct Padding: Decodable, Sendable, Equatable {
        var available: Bool?
        /// The input always has it on.
        var forced: Bool?
        var value: Double?
    }

    var hasPhantomPower: Bool { capabilities?.contains { $0.phantomPower == true } == true }
    var hasLowCutFilter: Bool { capabilities?.contains { $0.lowCutFilter == true } == true }
    var padding: Padding? { capabilities?.lazy.compactMap(\.padding).first }
}

/// What one channel has reported: its settings (subscribed, or read when a subscription brought none) and its input's
/// choices and description (read: the API's notification list has neither).
struct AudioReport: Sendable, Equatable {
    var input: String?
    var inputs: [AudioSupportedInput] = []
    var description: AudioInputDescription?
    var gain: Double?
    var phantomPower: Bool?
    var padding: Bool?
    var lowCutFilter: Bool?
    var available: Bool?
}

enum BlackmagicAudio {
    /// A channel's settings, each its own property, subscribed after connect.
    static let leaves = ["input", "level", "phantomPower", "padding", "lowCutFilter", "available"]

    /// /audio/channel/{i}/{leaf}.
    static func path(_ channel: Int, _ leaf: String) -> String { "/audio/channel/\(channel)/\(leaf)" }

    /// The channel and leaf of an /audio/channel/{i}/{leaf} property; nil for any other.
    static func parse(_ property: String) -> (channel: Int, leaf: String)? {
        let parts = property.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == "audio", parts[1] == "channel", let channel = Int(parts[2]) else { return nil }
        return (channel, parts[3])
    }

    /// One reported value into a channel's report. False for a leaf that isn't one of `leaves`.
    static func apply(_ leaf: String, _ value: Any, to report: inout AudioReport) -> Bool {
        let dict = value as? [String: Any]
        switch leaf {
        case "input": report.input = dict?["input"] as? String ?? report.input
        case "level": report.gain = (dict?["gain"] as? NSNumber)?.doubleValue ?? report.gain
        case "phantomPower": report.phantomPower = dict?["enabled"] as? Bool ?? report.phantomPower
        case "padding": report.padding = dict?["enabled"] as? Bool ?? report.padding
        case "lowCutFilter": report.lowCutFilter = dict?["enabled"] as? Bool ?? report.lowCutFilter
        case "available": report.available = dict?["available"] as? Bool ?? report.available
        default: return false
        }
        return true
    }

    /// The channel as Tiles shows it; nil for one that has reported neither an input nor a gain.
    static func channel(_ id: Int, _ report: AudioReport) -> AudioChannel? {
        guard report.input != nil || report.gain != nil else { return nil }
        var channel = AudioChannel(id: id, isAvailable: report.available ?? true)
        if let input = report.input {
            var options = report.inputs.filter { $0.available != false }.map(\.input)
            if !options.contains(input) { options.insert(input, at: 0) }
            channel.input = Choice(input, options: options, isWritable: options.count > 1)
        }
        if let gain = report.gain {
            if let low = report.description?.gainRange?.min, let high = report.description?.gainRange?.max, high > low {
                channel.gain = Level(min(max(gain, low), high), range: low...high, step: 1)
            } else {
                // No range to move it in: shown, not set.
                channel.gain = Level(gain, range: gain...gain, step: 1, isWritable: false)
            }
        }
        // The switches only where the input's description says it has them: the API answers a GET for any input and
        // turns down a PUT for one without (400).
        if report.description?.hasPhantomPower == true {
            channel.phantomPower = Choice(report.phantomPower ?? false, options: [false, true])
        }
        if report.description?.hasLowCutFilter == true {
            channel.lowCut = Choice(report.lowCutFilter ?? false, options: [false, true])
        }
        if let pad = report.description?.padding, pad.available == true || pad.forced == true {
            let forced = pad.forced == true
            channel.pad = Choice(forced || report.padding == true, options: [false, true], isWritable: !forced)
        }
        return channel
    }
}

struct AudioInputBody: Encodable { let input: String }
struct AudioGainBody: Encodable { let gain: Double }
struct AutoFocusBody: Encodable {
    struct Position: Encodable { let x: Double; let y: Double }
    /// The middle of the picture, which the camera also uses when none is sent: said rather than left to an empty body.
    let position = Position(x: 0.5, y: 0.5)
}
