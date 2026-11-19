import Foundation
import Observation

/// UI-facing handle on one camera: holds the latest state and forwards commands to the backend.
@MainActor
@Observable
public final class CameraController: Identifiable {
    public nonisolated let id: UUID
    public internal(set) var slot: CameraSlot
    public private(set) var state: CameraState
    /// The camera's audio meters, 0…1 per channel (`CameraState.audioMeters`), kept out of `state`: they change several
    /// times a second, and every tile reads `state`. Only the Audio tile reads these. Nil without a live link.
    public private(set) var audioMeters: [Double]?

    @ObservationIgnored private let backend: any CameraBackend

    /// Non-nil when the backend supports LUT file import (real Sony cameras; the mock in demo mode).
    /// DashboardUI uses this to show the "Load LUT onto camera…" button only when it's meaningful.
    public var lutImporter: (any LUTImportCapable)? { backend as? (any LUTImportCapable) }
    @ObservationIgnored private var listener: Task<Void, Never>?
    /// Called with the camera's SSH fingerprint when a connection reports one (trust on first use).
    @ObservationIgnored var onFingerprintObserved: ((String) -> Void)?
    /// The last LUT the camera reported that isn't a false color one: what turning False Color off goes back to.
    /// Kept here, not in the tile: a tile is rebuilt on layout changes and would lose its memory.
    @ObservationIgnored public private(set) var lutBeforeFalseColor: String?
    /// Called after every command the user sends from this camera's tiles, so linked cameras can follow.
    @ObservationIgnored var onCommand: ((CameraCommand) -> Void)?
    /// When the take now rolling started, as Tiles knows it, whoever started it (`timeTake`).
    @ObservationIgnored private var takeStart: Date?
    /// This link has seen the camera not recording, so a take that starts now is seen starting.
    @ObservationIgnored private var sawStopped = false

    /// Reconnects after the link drops. See `scheduleReconnect`.
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryDelay: Double
    /// Starting retry delay in seconds. Default is 1 s (1, 2, 4, 8, then every 10 s). Tests inject a smaller value.
    @ObservationIgnored private let initialRetryDelay: Double
    /// The app is in the background: stay disconnected until `resume()`.
    @ObservationIgnored private var isSuspended = false

    /// What this camera reported the last time it was connected (saved with the camera).
    public private(set) var lastSeen: CameraProfile?
    /// A simulated camera, so the dashboard can say so (a new user's first camera may be the demo).
    public internal(set) var isDemo = false
    /// Called when what the camera reports changes, so the store can save it.
    @ObservationIgnored var onProfileChanged: ((CameraProfile) -> Void)?

    public init(slot: CameraSlot, backend: any CameraBackend, initialState: CameraState = CameraState(),
                lastSeen: CameraProfile? = nil, initialRetryDelay: Double = 1) {
        self.id = slot.id
        self.slot = slot
        self.backend = backend
        var initial = initialState
        audioMeters = initial.audioMeters
        initial.audioMeters = nil
        self.state = initial
        self.lastSeen = lastSeen
        self.initialRetryDelay = initialRetryDelay
        self.retryDelay = initialRetryDelay
    }

    /// What this camera has: its live report, else what it reported last time, else nil (nothing known yet).
    public var profile: CameraProfile? {
        guard state.hasReported else { return lastSeen }
        return CameraProfile(model: state.model ?? lastSeen?.model,
                             offered: Set(WidgetKind.allCases.filter { state.offers($0) }),
                             make: state.make ?? lastSeen?.make,
                             // Its outputs come a moment after connect: until then, the ones it had.
                             outputs: state.monitoring.map { $0.outputs.map(TileOutput.init) } ?? lastSeen?.outputs,
                             // A Blackmagic camera's LUTs as Tiles has learned them (its backend starts from these).
                             luts: (state.make ?? lastSeen?.make) == .blackmagic ? (state.lut?.options ?? lastSeen?.luts) : nil)
    }

    /// What an automatic page lays out for this camera: its profile, without the HaLow tile until this device has found
    /// a HaLow node (the tile shows the node; with none it's empty). A page the user arranged keeps its HaLow tile.
    public var templateProfile: CameraProfile? {
        guard var profile = self.profile, !haLowAvailable else { return self.profile }
        profile.offered.remove(.haLow)
        return profile
    }

    /// This device has found a HaLow node, now or on an earlier run (`DashboardStore.haLowSeen`).
    public var haLowAvailable = false

    /// Whether an automatic page shows the tile for `kind`. With nothing known yet, everything shows. The Lock tile always
    /// does: it's the app's, and a camera last seen by a build from before it has no `.lock` in its saved profile, which
    /// would hide a page's Lock tile until the camera next connected.
    public func offers(_ kind: WidgetKind) -> Bool {
        kind == .lock || (profile?.offered.contains(kind) ?? true)
    }

    /// Whether a page shows this tile in use: the camera has its control and, for a tile set to one output, that
    /// output too, once the camera has said which outputs it has.
    public func offers(_ widget: PageWidget) -> Bool {
        guard offers(widget.kind) else { return false }
        guard !widget.targets.isEmpty, let outputs = state.monitoring?.outputs else { return true }
        return widget.targets.contains { target in outputs.contains { $0.id == target.id } }
    }

    /// Called when a state arrives that this controller's store wants to inspect (e.g. FX3 auto-page).
    @ObservationIgnored var onStateUpdated: ((CameraController) -> Void)?

    /// Starts listening and connects. Call once: the backend's update stream has a single consumer.
    public func start() {
        guard listener == nil else { return }
        let updates = backend.updates
        listener = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                // A round trip is only true of a live link. A backend that loses one keeps its last average, and the
                // Latency is only meaningful on a live link: anything but connected shows none.
                var next = update
                if next.connection != .connected { next.latencyMilliseconds = nil }
                self.timeTake(&next)
                // The meters, out of the state into `audioMeters`. A change in them alone (a VENICE sends them several
                // times a second) goes no further: the page and the store have nothing new.
                let meters = next.connection == .connected ? next.audioMeters : nil
                next.audioMeters = nil
                let metersChanged = meters != self.audioMeters
                if metersChanged { self.audioMeters = meters }
                if metersChanged && next == self.state { continue }
                if let fingerprint = next.observedFingerprint, fingerprint != self.state.observedFingerprint {
                    self.onFingerprintObserved?(fingerprint)
                }
                if next != self.state { self.state = next }   // an equal state still makes every tile redraw
                if let lut = next.lut?.value, !isFalseColorLUT(lut) { self.lutBeforeFalseColor = lut }
                if next.hasReported, let profile = self.profile, profile != self.lastSeen {
                    self.lastSeen = profile
                    self.onProfileChanged?(profile)
                }
                self.followConnection(next.connection)
                self.onStateUpdated?(self)
            }
        }
        let backend = self.backend
        Task { await backend.connect() }
    }

    /// Gives every take its start, whoever started it. A backend that times its own REC says when (Tiles' REC on a Sony
    /// or an ARRI, a demo camera); a take started at the camera (its own button, a trigger, another app) is timed from
    /// the moment Tiles saw it start. Tiles' own REC times itself through the backend; a take started at the camera
    /// (its own button, a trigger, another app) is timed this way, as is every take on a VENICE or a PYXIS.
    /// A take still rolling when a dropped link comes back keeps its start. One already rolling when Tiles first saw
    /// the camera has none: its length would be made up (the Timecode tile shows it as unknown).
    private func timeTake(_ next: inout CameraState) {
        guard next.connection == .connected else {
            // The link is down, coming up or resyncing: what the camera is doing isn't known. The start is kept for a
            // take still rolling when it's back; a take that starts meanwhile isn't seen starting.
            sawStopped = false
            next.takeStartedAt = nil
            return
        }
        switch next.recording.state {
        case .recording:
            if let started = next.takeStartedAt {
                takeStart = started
            } else if takeStart == nil, sawStopped, next.recording.request != .start {
                takeStart = Date()  // a start Tiles asked for is the backend's to time, once the camera confirms it
            }
            next.takeStartedAt = takeStart
        case .idle:
            takeStart = nil
            sawStopped = true
            next.takeStartedAt = nil
        case .unknown:
            next.takeStartedAt = nil
        }
    }

    public func disconnect() {
        retryTask?.cancel()
        retryTask = nil
        listener?.cancel()
        listener = nil  // also tells a retry that's already past its sleep not to reconnect
        let backend = self.backend
        Task { await backend.disconnect() }
    }

    /// The app is going to the background. iOS suspends it and the sockets die anyway, so close cleanly now:
    /// that also frees the camera, which serves one controller at a time. A take in progress keeps rolling
    /// (a dropped session doesn't stop REC on the FX3).
    public func suspend() {
        ActivityLog.shared.note(slot.host, "app going to the background: closing")
        isSuspended = true
        retryTask?.cancel()
        retryTask = nil
        let backend = self.backend
        Task { await backend.disconnect() }
    }

    /// Back in the foreground: reconnect straight away. Values stay grayed out until the camera reports.
    public func resume() {
        guard isSuspended else { return }
        ActivityLog.shared.note(slot.host, "app back: reconnecting")
        isSuspended = false
        retryDelay = 1
        let backend = self.backend
        Task { await backend.connect() }
    }

    private func followConnection(_ connection: ConnectionState) {
        switch connection {
        case .connected:
            retryDelay = initialRetryDelay
            retryTask?.cancel()
            retryTask = nil
        case .failed, .disconnected:
            scheduleReconnect()
        default:
            break  // connecting, awaiting approval, or a changed fingerprint that the user has to decide on
        }
    }

    /// The camera is back (plugged in again): a link that's down reconnects now, not when its retry comes round.
    public func reconnectNow() {
        guard !isSuspended, listener != nil else { return }
        switch state.connection {
        case .failed, .disconnected: break
        default: return
        }
        retryTask?.cancel()
        retryTask = nil
        retryDelay = initialRetryDelay
        ActivityLog.shared.note(slot.host, "plugged back in, or tapped: reconnecting")
        let backend = self.backend
        Task { await backend.connect() }
    }

    /// The link dropped: try again after 1, 2, 4, 8 s, then every 10 s (a try is a few small requests, and a camera
    /// that comes back shouldn't wait long). Not while suspended, and only one retry pending.
    private func scheduleReconnect() {
        guard !isSuspended, listener != nil, retryTask == nil else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 10)
        let backend = self.backend
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.listener != nil, !self.isSuspended else { return }
            self.retryTask = nil
            await backend.connect()
        }
    }

    /// The live view capability of this camera's backend, or nil if the backend doesn't support it.
    /// DashboardUI calls this when the live view sheet opens; it never imports SonyPTP.
    public var liveViewProvider: (any LiveViewProvider)? { backend as? any LiveViewProvider }

    /// Shared live view session for this camera. Created lazily the first time a consumer subscribes.
    /// The tile and the full sheet both use this, so they never fetch in parallel.
    @ObservationIgnored private var _liveViewSession: LiveViewSession?

    /// Returns the shared session if this camera has a live view provider; nil otherwise.
    public var liveViewSession: LiveViewSession? {
        guard let provider = liveViewProvider else { return nil }
        if _liveViewSession == nil { _liveViewSession = LiveViewSession(provider: provider, settings: liveViewSettings) }
        return _liveViewSession
    }

    /// Picture quality and frame rate chosen for this camera's live view. A stream that's running picks them up at
    /// once; the store saves them with the camera.
    public var liveViewSettings = LiveViewSettings() {
        didSet {
            guard liveViewSettings != oldValue else { return }
            onLiveViewSettingsChanged?(liveViewSettings)
            guard let session = _liveViewSession else { return }
            let settings = liveViewSettings
            Task { await session.apply(settings) }
        }
    }
    @ObservationIgnored var onLiveViewSettingsChanged: ((LiveViewSettings) -> Void)?

    /// Sends a command from this camera's tiles; linked cameras on the current page follow.
    public func send(_ command: CameraCommand) {
        sendLocally(command)
        onCommand?(command)
    }

    /// Sends to this camera only (used for link fan-out, so it can't echo back round the group).
    func sendLocally(_ command: CameraCommand) {
        let backend = self.backend
        Task { await backend.send(command) }
    }
}
