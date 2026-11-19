import Foundation

// MARK: - PlaybackClip

/// One clip as the Clips window lists it (`PlaybackState.clipListing`).
public struct PlaybackClip: Sendable, Equatable, Identifiable {
    /// Its place in the camera's order, from 0 (its clip number − 1): what `PlaybackCommand.goToClip` takes.
    public var id: Int
    /// As the camera names its file, e.g. "A001_11141530_C003". nil where only its number is known.
    public var name: String?
    /// How long it runs, in seconds, where the camera says.
    public var seconds: Double?

    public init(id: Int, name: String? = nil, seconds: Double? = nil) {
        self.id = id
        self.name = name
        self.seconds = seconds
    }
}

// MARK: - PlaybackState

/// Playback state reported by a camera. Non-nil on `CameraState` only when the camera's protocol
/// exposes playback controls — a camera without them gets nil and no tile.
public struct PlaybackState: Sendable, Equatable {
    // MARK: - Transport
    /// True when the camera is in playback mode (Output / playing); false when in live/InputPreview.
    /// nil = camera hasn't reported yet.
    public var isPlaying: Bool?
    /// The camera is showing recorded clips, not the live picture. Only cameras that have to be put into playback
    /// first (`capabilities.review`, the FX3) report it; nil elsewhere.
    public var inReview: Bool?

    // MARK: - Clip info
    /// Current clip name, e.g. "A001C003".
    public var clipName: String?
    /// 1-based clip number within the session.
    public var clipNumber: Int?
    /// Total number of clips.
    public var clipCount: Int?
    /// Position within the current clip, in seconds. nil = unknown.
    public var position: Double?
    /// Duration of the current clip, in seconds. nil = unknown.
    public var duration: Double?
    /// How fast it plays, where the camera says: 1 playing, 0 paused, 4 scanning forward at 4×, −15 back at 15× (an
    /// FX6's Movie Playing Speed).
    public var speed: Double?
    /// The clips the camera plays, in its order, where it gives the whole list (a Blackmagic camera's playback list,
    /// named from the files on its card). nil where it doesn't: `clipListing` numbers them then.
    public var clips: [PlaybackClip]?
    /// In review, the camera plays a list of clips it keeps itself, and the latest take on its card isn't on it (a
    /// Blackmagic camera whose list was built from clips in another format): Review shows an older clip. Pressing Play
    /// on the camera itself shows the latest one.
    public var latestTakeMissing = false

    // MARK: - Capability flags
    public var capabilities: PlaybackCapabilities

    public init(
        isPlaying: Bool? = nil,
        inReview: Bool? = nil,
        clipName: String? = nil,
        clipNumber: Int? = nil,
        clipCount: Int? = nil,
        position: Double? = nil,
        duration: Double? = nil,
        speed: Double? = nil,
        capabilities: PlaybackCapabilities = PlaybackCapabilities()
    ) {
        self.isPlaying = isPlaying
        self.inReview = inReview
        self.clipName = clipName
        self.clipNumber = clipNumber
        self.clipCount = clipCount
        self.position = position
        self.duration = duration
        self.speed = speed
        self.capabilities = capabilities
    }
}

/// Which playback commands this camera's protocol actually supports.
public struct PlaybackCapabilities: Sendable, Equatable {
    /// play / pause / togglePlay
    public var playPause: Bool = false
    /// stop (return to paused / live)
    public var stop: Bool = false
    /// next / previous clip
    public var nextPrevious: Bool = false
    /// skip(seconds) — seek to an exact position
    public var seek: Bool = false
    /// fast-forward / rewind (FF/REW, no exact position)
    public var fastForwardRewind: Bool = false
    /// rec-review
    public var recReview: Bool = false
    /// Back to the live picture (Blackmagic: transport mode InputPreview). Sony's way out is its Stop button.
    public var live: Bool = false
    /// The camera has to be put into playback (`.review`) and taken out again (`.live`), and only takes the other
    /// commands while it's there (`PlaybackState.inReview`). Sony bodies played through their own buttons: the FX3.
    public var review: Bool = false
    /// How fast ◀◀ and ▶▶ run, where the camera's speed is fixed and known (a VENICE's 4×): drawn under them. nil: not
    /// known, or not one speed.
    public var scanSpeed: Double?
    /// Plays a clip picked by its place (`PlaybackCommand.goToClip`): the Clips tile and window. A Blackmagic camera
    /// seeks to it; an FX5, a VENICE and an ALEXA step to it a clip at a time.
    public var goToClip: Bool = false

    public init() {}
    public init(playPause: Bool, stop: Bool, nextPrevious: Bool, seek: Bool,
                fastForwardRewind: Bool, recReview: Bool, live: Bool = false, review: Bool = false,
                scanSpeed: Double? = nil, goToClip: Bool = false) {
        self.playPause = playPause
        self.stop = stop
        self.nextPrevious = nextPrevious
        self.seek = seek
        self.fastForwardRewind = fastForwardRewind
        self.recReview = recReview
        self.live = live
        self.review = review
        self.scanSpeed = scanSpeed
        self.goToClip = goToClip
    }

    /// "4×": the scan speed as the buttons show it.
    public var scanSpeedLabel: String? {
        scanSpeed.map { ($0 == $0.rounded() ? String(Int($0)) : String(format: "%g", $0)) + "×" }
    }
}

// MARK: - PlaybackCommand

public enum PlaybackCommand: Sendable, Equatable {
    case togglePlay
    case play
    case pause
    /// Stop playback — on Blackmagic this pauses at the current position; on Sony it halts.
    case stop
    /// Return to live / InputPreview.
    case live
    /// Show recorded clips: put the camera into playback. Requires `review`; `.live` leaves.
    case review
    case next
    case previous
    /// Seek by offset in seconds (positive = forward, negative = backward). Requires `seek` capability.
    case skip(Double)
    /// Fast-forward (Sony FF button, no exact seek). Requires `fastForwardRewind` capability.
    case fastForward
    /// Rewind (Sony REW button). Requires `fastForwardRewind` capability.
    case rewind
    /// Fast-forward or rewind until `endScan` (an arrow held down). Cameras played through their own buttons.
    case scan(forward: Bool)
    /// Back to normal playback after `scan`.
    case endScan
    /// Rec-review (Sony only).
    case recReview
    /// Into review, and play the clip at this place in the camera's order, from 0 (`PlaybackClip.id`; its clip number
    /// − 1): the Clips window. A camera that seeks plays it from its start; one that steps opens each clip at its start,
    /// and the clip already open plays on from where it is. The last pick wins. Not during a take. Requires `goToClip`
    /// capability.
    case goToClip(Int)
}

extension PlaybackState {
    /// What the Clips window lists, in the camera's order: its own list (`clips`), else one entry per clip it numbers
    /// (`clipCount`), the open one named, where it plays a clip by its number (`capabilities.goToClip`). nil where it
    /// can't be listed now: an FX5 numbers its clips only while it's playing one back.
    public var clipListing: [PlaybackClip]? {
        if let clips { return clips }
        guard capabilities.goToClip, let count = clipCount, count > 0 else { return nil }
        return (0..<count).map { PlaybackClip(id: $0, name: $0 + 1 == clipNumber ? clipName : nil) }
    }
}
