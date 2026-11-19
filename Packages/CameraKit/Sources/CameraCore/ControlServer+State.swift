import Foundation

// MARK: - CameraAPISnapshot

/// Flat snapshot of a camera for change detection.
struct CameraAPISnapshot: Equatable {
    var connection: String
    var latencyMs: Int?
    var battery: Int?
    var mediaMinutes: Int?
    var fields: [String: APIFieldAny]
    var playback: APIPlayback?

    @MainActor
    init(from cam: CameraController) {
        self.connection = cam.state.connection.apiString
        self.latencyMs = cam.state.latencyMilliseconds
        self.battery = cam.state.batteryPercent
        self.mediaMinutes = cam.state.mediaRemainingMinutes
        self.fields = APIFieldAny.fields(from: cam.state)
        self.playback = APIPlayback(cam.state)
    }

    /// Returns only the changed properties as a `CameraChangesUpdate`.
    func diff(from old: CameraAPISnapshot?) -> CameraChangesUpdate {
        var u = CameraChangesUpdate()
        guard let old else {
            // First publish: send everything
            u.connection = connection
            u.latencyMs = latencyMs
            u.battery = battery
            u.mediaMinutes = mediaMinutes
            u.fields = fieldDiff(old: [:])
            u.playbackChanged = playback != nil
            u.playback = playback
            return u
        }
        if connection != old.connection { u.connection = connection }
        if latencyMs != old.latencyMs { u.latencyMs = latencyMs }
        if battery != old.battery { u.battery = battery }
        if mediaMinutes != old.mediaMinutes { u.mediaMinutes = mediaMinutes }
        let changedFields = fieldDiff(old: old.fields)
        if !changedFields.isEmpty { u.fields = changedFields }
        // Whole, or null when it goes: a client never has to merge a half.
        if playback != old.playback {
            u.playbackChanged = true
            u.playback = playback
        }
        return u
    }

    /// Produces a map of field name → FieldFragment for every field that changed.
    private func fieldDiff(old: [String: APIFieldAny]) -> [String: FieldFragment] {
        var result: [String: FieldFragment] = [:]
        let allKeys = Set(fields.keys).union(old.keys)
        for key in allKeys {
            let newField = fields[key]
            let oldField = old[key]
            guard newField != oldField else { continue }
            result[key] = fragment(from: newField)
        }
        return result
    }

    private func fragment(from field: APIFieldAny?) -> FieldFragment {
        var frag = FieldFragment()
        switch field {
        case .choice(let c):
            frag.value = c.value
            frag.hasPending = true
            frag.pendingValue = c.pending  // nil → encodes as null (pending cleared)
            frag.writable = c.writable
        case .level(let l):
            frag.value = AnyCodable(l.value)
            frag.hasPending = true
            frag.pendingValue = l.pending.map { AnyCodable($0) }
            frag.writable = l.writable
        case .record(let r):
            frag.value = AnyCodable(r.value)
            frag.request = r.request
            frag.startedAt = r.startedAt
            frag.failure = r.failure
        case nil:
            break
        }
        return frag
    }
}

// MARK: - ControlServer state observer & broadcast

extension ControlServer {

    func startStateObserver() {
        storeObserverTask?.cancel()
        storeObserverTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms poll
                guard let self else { return }
                // Skip the diff when nobody is subscribed — avoids work proportional to camera count.
                guard !self.wsClients.filter({ $0.value.isSubscribed }).isEmpty else { continue }
                self.scheduleBroadcast()
            }
        }
    }

    /// 5 ms deadband: coalesce multiple rapid state changes into one broadcast.
    func scheduleBroadcast() {
        guard pendingBroadcast == nil else { return }
        pendingBroadcast = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000)
            guard let self else { return }
            self.pendingBroadcast = nil
            self.broadcastStateChanges()
        }
    }

    func broadcastStateChanges() {
        guard let store else { return }
        var pagesDirty = false
        var camerasDirty = false

        for cam in store.cameras {
            let snap = CameraAPISnapshot(from: cam)
            let cid = cam.id
            guard snap != lastPublished[cid] else { continue }

            let diff = snap.diff(from: lastPublished[cid])
            lastPublished[cid] = snap

            if diff.isEmpty { continue }

            // A connection change goes out in the camera list too.
            if diff.connection != nil { camerasDirty = true }

            // broadcast changes message
            let msg = WireMessage.changes(
                camera: cam.slot.label,
                cameraID: cid.uuidString,
                update: diff,
                removed: nil
            )
            broadcastWS(msg)
        }

        // A camera added, removed, renamed, recolored or moved changes the list itself.
        let camerasKey = Self.camerasKey(store.cameras)
        if camerasKey != lastCamerasKey {
            lastCamerasKey = camerasKey
            camerasDirty = true
            let ids = Set(store.cameras.map(\.id))
            lastPublished = lastPublished.filter { ids.contains($0.key) }
        }
        if camerasDirty {
            broadcastCameraList(store: store)
        }

        // Always check pages for changes (includes currentPageID changes)
        let pagesSnap = store.pages.map { APIPageEntry(from: $0, cameras: store.cameras(on: $0).map(\.id), currentPageID: store.currentPageID) }
        let pagesKey = Self.pagesKey(pagesSnap, current: store.currentPageID)
        if pagesKey != lastPagesKey {
            lastPagesKey = pagesKey
            pagesDirty = true
        }
        if pagesDirty {
            broadcastWS(WireMessage.pages(pages: pagesSnap, currentPageID: store.currentPageID?.uuidString))
        }

        // The padlock, from the app (its padlock or Lock tile) as well as the API.
        if store.controlsLocked != lastLocked { broadcastLockChange(store: store) }
    }

    func broadcastLockChange(store: DashboardStore) {
        lastLocked = store.controlsLocked
        broadcastWS(WireMessage.lock(locked: store.controlsLocked))
    }

    /// The page list as clients see it, current page included. Hello, snapshot and the observer must all use this:
    /// hello/snapshot keyed only the ids, so the first tick after every subscribe sent a spurious `pages`, and a page
    /// renamed or linked in the app (same ids) never reached clients at all.
    static func pagesKey(_ pages: [APIPageEntry], current: UUID?) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return ((try? encoder.encode(pages)) ?? Data()) + Data((current?.uuidString ?? "").utf8)
    }

    /// The camera list as clients see it, without the live values `changes` carries: who, in what order, and how each
    /// is named and shown.
    static func camerasKey(_ cameras: [CameraController]) -> Data {
        Data(cameras.map { [$0.id.uuidString, $0.slot.label, $0.slot.color.rawValue, $0.state.model ?? "", "\($0.isDemo)"]
            .joined(separator: "\t") }.joined(separator: "\n").utf8)
    }

    func broadcastCameraList(store: DashboardStore) {
        let cameras = store.cameras.map { APICameraFull(from: $0) }
        broadcastWS(WireMessage.cameras(cameras: cameras))
    }

    func broadcastPagesChange(store: DashboardStore) {
        let pages = store.pages.map { APIPageEntry(from: $0, cameras: store.cameras(on: $0).map(\.id), currentPageID: store.currentPageID) }
        lastPagesKey = Self.pagesKey(pages, current: store.currentPageID)
        broadcastWS(WireMessage.pages(pages: pages, currentPageID: store.currentPageID?.uuidString))
    }

    func broadcastWS(_ msg: WireMessage) {
        guard let data = try? JSONEncoder().encode(msg) else { return }
        for (_, client) in wsClients where client.isSubscribed {
            client.send(data: data)
        }
    }

    func sendWS(_ msg: WireMessage, to clientID: UUID) {
        guard let data = try? JSONEncoder().encode(msg) else { return }
        wsClients[clientID]?.send(data: data)
    }

    // MARK: Snapshot helpers

    /// Seeds what the observer diffs against, then returns the current cameras+pages. Anything not yet broadcast goes
    /// to the clients already subscribed first: seeding over it would lose it for them.
    private func seedAndBuild(store: DashboardStore) -> (cameras: [APICameraFull], pages: [APIPageEntry]) {
        broadcastStateChanges()
        lastCamerasKey = Self.camerasKey(store.cameras)
        let cameras = store.cameras.map { cam -> APICameraFull in
            lastPublished[cam.id] = CameraAPISnapshot(from: cam)
            return APICameraFull(from: cam)
        }
        let pages = store.pages.map { APIPageEntry(from: $0, cameras: store.cameras(on: $0).map(\.id), currentPageID: store.currentPageID) }
        lastPagesKey = Self.pagesKey(pages, current: store.currentPageID)
        lastLocked = store.controlsLocked
        return (cameras, pages)
    }

    func currentSnapshot(store: DashboardStore) -> WireMessage {
        let (cameras, pages) = seedAndBuild(store: store)
        return .snapshot(cameras: cameras, pages: pages,
                         currentPageID: store.currentPageID?.uuidString, radio: nil, locked: store.controlsLocked)
    }

    func helloMessage(requestID: String?, store: DashboardStore) -> WireMessage {
        let (cameras, pages) = seedAndBuild(store: store)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return .hello(requestID: requestID, api: 1, app: "Tiles", appVersion: version,
                      cameras: cameras, pages: pages,
                      currentPageID: store.currentPageID?.uuidString, radio: nil, locked: store.controlsLocked)
    }
}
