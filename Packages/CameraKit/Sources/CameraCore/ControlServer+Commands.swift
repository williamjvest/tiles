import Foundation

// MARK: - Command dispatch

extension ControlServer {

    enum ResolvedTarget {
        case cameras([CameraController])
        case error(String, String) // code, message
    }

    func resolveTarget(_ target: WireTarget, store: DashboardStore) -> ResolvedTarget {
        switch target {
        case .cameraID(let id):
            guard let uuid = UUID(uuidString: id),
                  let cam = store.cameras.first(where: { $0.id == uuid }) else {
                return .error("unknownTarget", "Camera \(id) not found")
            }
            return .cameras([cam])
        case .camera(let label):
            guard let cam = store.cameras.first(where: { $0.slot.label == label }) else {
                return .error("unknownTarget", "Camera \(label) not found")
            }
            return .cameras([cam])
        case .pageID(let id):
            guard let uuid = UUID(uuidString: id),
                  let page = store.pages.first(where: { $0.id == uuid }) else {
                return .error("unknownTarget", "Page \(id) not found")
            }
            let cams = store.cameras(on: page)
            return .cameras(cams)
        case .currentPage:
            guard let page = store.currentPage else {
                return .error("unknownTarget", "No current page")
            }
            let cams = store.cameras(on: page)
            return .cameras(cams)
        case .all:
            return .cameras(store.cameras)
        }
    }

    // MARK: - Reply helper

    /// Carries the reply channel for a command (WS client, HTTP completion, or neither).
    @MainActor struct Reply {
        let requestID: String?
        let clientID: UUID?
        let httpCompletion: (([WireResultEntry]) -> Void)?

        func send(_ msg: WireMessage, server: ControlServer) {
            if let id = clientID { server.sendWS(msg, to: id) }
        }

        func complete(_ entries: [WireResultEntry]) {
            httpCompletion?(entries)
        }

        func reject(_ entries: [WireResultEntry], server: ControlServer) {
            send(.result(requestID: requestID, results: entries), server: server)
            complete(entries)
        }
    }

    func dispatchCommand(
        _ req: WireCommandRequest,
        replyTo clientID: UUID?,
        httpCompletion: (([WireResultEntry]) -> Void)? = nil
    ) {
        guard let store else {
            let err = WireMessage.error(requestID: req.id, code: "badRequest", message: "no store")
            if let id = clientID { sendWS(err, to: id) }
            return
        }

        guard let targetSpec = req.target else {
            let err = WireMessage.error(requestID: req.id, code: "badRequest", message: "target required")
            if let id = clientID { sendWS(err, to: id) }
            return
        }

        let resolved = resolveTarget(targetSpec, store: store)
        guard case .cameras(let cameras) = resolved else {
            if case .error(let code, let msg) = resolved {
                let err = WireMessage.error(requestID: req.id, code: code, message: msg)
                if let id = clientID { sendWS(err, to: id) }
            }
            return
        }

        if cameras.isEmpty {
            let result = WireMessage.result(requestID: req.id, results: [])
            if let id = clientID { sendWS(result, to: id) }
            let noCamera = WireResultEntry(camera: "", status: "rejected", field: nil, value: nil, error: "no cameras on target")
            httpCompletion?([noCamera])
            return
        }

        let followsApp = req.link?.followsApp ?? true
        let primaryCamera = cameras.first!
        let reply = Reply(requestID: req.id, clientID: clientID, httpCompletion: httpCompletion)

        switch req.command {
        case .set(let field, let rawValue):
            var value = rawValue
            // REC accepts string vocabulary ("recording"/"idle") as well as bool.
            if field == "record", case .string(let word) = rawValue, word == "recording" || word == "idle" {
                value = .bool(word == "recording")
            }
            dispatchSet(field: field, value: value,
                        primaryCamera: primaryCamera, allCameras: cameras,
                        followsApp: followsApp, reply: reply, store: store)
        case .step(let field, let by) where field == "ecsFrequency":
            // ECS steps relative to wherever it is (the camera's own Shutter ECS Number Step): no value to set.
            dispatchAction(field: field, cameras: cameras, reply: reply) { cam in
                guard cam.state.ecs?.canStep == true else { return "ECS off, or no steps on this camera" }
                cam.sendLocally(.stepECS(Int(by.rounded())))
                return nil
            }
        case .step(let field, let by):
            dispatchStep(field: field, by: by,
                         primaryCamera: primaryCamera, allCameras: cameras,
                         followsApp: followsApp, reply: reply, store: store)
        case .toggle(let field):
            dispatchToggle(field: field,
                           primaryCamera: primaryCamera, allCameras: cameras,
                           followsApp: followsApp, reply: reply, store: store)
        case .cycle(let field):
            dispatchCycle(field: field,
                          primaryCamera: primaryCamera, allCameras: cameras,
                          followsApp: followsApp, reply: reply, store: store)
        case .playback(let name, let by):
            dispatchPlayback(name: name, by: by, cameras: cameras, reply: reply)
        case .drive(let motor, let speed, let seconds):
            dispatchAction(field: motor, cameras: cameras, reply: reply) { cam in
                drive(motor, speed: speed, seconds: seconds, camera: cam)
            }
        case .press(let what, let button):
            dispatchAction(field: what, cameras: cameras, reply: reply) { cam in
                guard ["assignable", "autofocus", "still"].contains(what) else { return "unknown button kind" }
                guard cam.state.connection.isControllable else { return "camera not connected" }
                if what == "still" {
                    // The Grab Still tile: a still to the camera's card. What came of it is in the state, as lastStill.
                    guard cam.state.canGrabStill else { return "no still capture on this camera" }
                    cam.sendLocally(.grabStill)
                    return nil
                }
                if what == "autofocus" {
                    // The Autofocus tile's push: only on a camera that has one, and only while focus is manual.
                    guard cam.state.canAutoFocus else { return "no push autofocus on this camera" }
                    guard cam.state.canPushAutoFocus else { return "autofocus is on: set focusMode to MF to push it" }
                    cam.sendLocally(.autoFocus)
                    return nil
                }
                guard let button else { return "which button? (\"button\": 1–10)" }
                guard let found = cam.state.assignableButtons.first(where: { $0.id == button }) else { return "no such button" }
                guard found.isPressable else { return "not a function Tiles presses (\(found.function))" }
                cam.sendLocally(.pressAssignable(button))
                return nil
            }
        }
    }

    /// An action on each targeted camera, `accepted` once sent (a press or a drive has nothing to confirm), or `rejected`
    /// with why. Actions don't link.
    private func dispatchAction(field: String, cameras: [CameraController], reply: Reply,
                                perform: (CameraController) -> String?) {
        let entries = dedup(cameras).map { cam in
            let error = perform(cam)
            return WireResultEntry(camera: cam.slot.label, status: error == nil ? "accepted" : "rejected",
                                   field: field, value: nil, error: error)
        }
        reply.send(.result(requestID: reply.requestID, results: entries), server: self)
        reply.complete(entries)
    }

    /// A timed drive: the motor at `speed`, renewed as a held tile renews it, then stopped, after `seconds` (a second
    /// at most); speed 0 stops it at once. A newer drive of the same motor takes over: a deck holds a button by sending
    /// the drive again before the last one ends, and that one's end mustn't stop the motor under the newer one. The
    /// backend stops a motor on its own too if the renewals stop.
    private func drive(_ motor: String, speed: Int, seconds: Double, camera: CameraController) -> String? {
        guard camera.state.connection.isControllable else { return "camera not connected" }
        let lens = motor == "focus" ? camera.state.focusDrive : motor == "zoom" ? camera.state.zoomDrive : nil
        guard let lens, lens.isWritable else { return "no \(motor) drive on this camera" }
        guard (-lens.maxSpeed...lens.maxSpeed).contains(speed) else { return "speed is −\(lens.maxSpeed) to \(lens.maxSpeed)" }
        let command: (Int) -> CameraCommand = motor == "focus" ? { .driveFocus($0) } : { .driveZoom($0) }
        let duration = min(max(seconds, 0), 1)
        drives[camera.id]?[motor]?.cancel()
        drives[camera.id, default: [:]][motor] = Task { @MainActor [weak self] in
            // Renewed every 200 ms as a held tile does, and stopped at the end, not up to 200 ms after it.
            let end = ContinuousClock.now + .milliseconds(Int(duration * 1000))
            while speed != 0, !Task.isCancelled {
                let left = end - ContinuousClock.now
                guard left > .zero else { break }
                camera.sendLocally(command(speed))
                try? await Task.sleep(for: min(.milliseconds(200), left))
            }
            // Taken over: the newer drive carries on, and stops the motor when it ends.
            guard !Task.isCancelled else { return }
            camera.sendLocally(command(0))
            self?.drives[camera.id]?[motor] = nil
        }
        return nil
    }

    /// A transport command, to every targeted camera (playback doesn't link). `accepted` once it's sent, since a press
    /// has nothing to confirm; `rejected` when the camera doesn't take it now (`unsupported`: not in its `commands`).
    private func dispatchPlayback(name: String, by: Double?, cameras: [CameraController], reply: Reply) {
        let entries = dedup(cameras).map { cam in
            let error = sendPlayback(name, by: by, to: cam)
            return WireResultEntry(camera: cam.slot.label, status: error == nil ? "accepted" : "rejected",
                                   field: "playback", value: nil, error: error)
        }
        reply.send(.result(requestID: reply.requestID, results: entries), server: self)
        reply.complete(entries)
    }

    /// Sends one camera a transport command. Returns why it didn't, or nil.
    private func sendPlayback(_ name: String, by: Double?, to cam: CameraController) -> String? {
        let state = cam.state
        guard state.connection.isControllable else { return "camera not connected" }
        guard let pb = state.playback, APIPlayback.commands(state).contains(name) else { return "unsupported" }
        guard let command = PlaybackCommand(apiName: name, by: by) else { return "skip needs by, in seconds" }
        // Play and pause are absolute: on some cameras the button is a toggle, so one that's already there isn't pressed.
        if (command == .play && pb.isPlaying == true) || (command == .pause && pb.isPlaying == false) { return nil }
        cam.sendLocally(.playback(command))
        return nil
    }

    private func dispatchSet(
        field: String, value: FieldValue,
        primaryCamera: CameraController, allCameras: [CameraController],
        followsApp: Bool, reply: Reply, store: DashboardStore
    ) {
        guard let cmd = buildCommand(field: field, value: value, camera: primaryCamera) else {
            let entries = allCameras.map { cam in
                WireResultEntry(camera: cam.slot.label, status: "rejected", field: field,
                                value: nil, error: "field absent, not writable, or value out of range")
            }
            reply.reject(entries, server: self)
            return
        }

        let peers = fanOutCameras(from: primaryCamera, allCameras: allCameras,
                                  followsApp: followsApp, command: cmd, store: store)
        let allTargeted = allCameras.count > 1 ? allCameras : ([primaryCamera] + peers)
        let uniqueTargeted = dedup(allTargeted)

        if field == "record" {
            for cam in uniqueTargeted where recInFlight.contains(cam.id) {
                let entries = uniqueTargeted.map { c in
                    WireResultEntry(camera: c.slot.label, status: "rejected", field: field,
                                    value: nil, error: "REC change in progress")
                }
                reply.reject(entries, server: self)
                return
            }
        }

        // Update lastRequested now (before async) so rapid steps accumulate against the latest requested value.
        for cam in uniqueTargeted {
            lastRequested[cam.id, default: [:]][field] = value
            if field == "record" { recInFlight.insert(cam.id) }
        }

        // Fire commands to all targeted cameras concurrently.
        // Every targeted camera at once, as the app's own link fan-out does: one after another staggered a linked
        // REC by each camera's confirmation.
        let jobs = uniqueTargeted.enumerated().map { index, cam in
            (index, cam, cam.id == primaryCamera.id ? cmd : (buildCommand(field: field, value: value, camera: cam) ?? cmd))
        }
        Task {
            let entries = await withTaskGroup(of: (Int, WireResultEntry).self) { group in
                for (index, cam, camCmd) in jobs {
                    group.addTask { (index, await self.sendCommandAndWait(cmd: camCmd, field: field, value: value, camera: cam)) }
                }
                var collected: [(Int, WireResultEntry)] = []
                for await item in group { collected.append(item) }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
            let result = WireMessage.result(requestID: reply.requestID, results: entries)
            await MainActor.run { self.sendWS(result, to: reply.clientID) }
            reply.complete(entries)
        }
    }

    private func dispatchStep(
        field: String, by: Double,
        primaryCamera: CameraController, allCameras: [CameraController],
        followsApp: Bool, reply: Reply, store: DashboardStore
    ) {
        guard let resolvedValue = resolveStep(field: field, by: by, camera: primaryCamera) else {
            let entry = WireResultEntry(camera: primaryCamera.slot.label,
                                        status: "rejected", field: field, value: nil,
                                        error: "field absent or not steppable")
            reply.reject([entry], server: self)
            return
        }
        dispatchSet(field: field, value: resolvedValue,
                    primaryCamera: primaryCamera, allCameras: allCameras,
                    followsApp: followsApp, reply: reply, store: store)
    }

    private func dispatchToggle(
        field: String,
        primaryCamera: CameraController, allCameras: [CameraController],
        followsApp: Bool, reply: Reply, store: DashboardStore
    ) {
        if field == "record" {
            let recState = primaryCamera.state.recording.state
            if recState == .unknown {
                let entry = WireResultEntry(camera: primaryCamera.slot.label,
                                             status: "rejected", field: field, value: nil,
                                             error: "REC unknown")
                reply.reject([entry], server: self)
                return
            }
            if recInFlight.contains(primaryCamera.id) {
                let entry = WireResultEntry(camera: primaryCamera.slot.label,
                                             status: "rejected", field: field, value: nil,
                                             error: "REC change in progress")
                reply.reject([entry], server: self)
                return
            }
            // Mixed states on page/all → rejected
            if allCameras.count > 1 {
                let states = allCameras.map { $0.state.recording.state }
                if states.contains(.recording) && states.contains(.idle) {
                    let entry = WireResultEntry(camera: primaryCamera.slot.label,
                                                status: "rejected", field: field, value: nil,
                                                error: "mixed REC states — send set instead")
                    reply.reject([entry], server: self)
                    return
                }
            }
            let newValue: Bool = recState == .idle
            dispatchSet(field: field, value: .bool(newValue),
                        primaryCamera: primaryCamera, allCameras: allCameras,
                        followsApp: followsApp, reply: reply, store: store)
            return
        }

        guard let toggled = toggleValue(field: field, camera: primaryCamera) else {
            let entries = allCameras.map { cam in
                WireResultEntry(camera: cam.slot.label, status: "rejected", field: field,
                                value: nil, error: "field absent or not toggleable")
            }
            reply.reject(entries, server: self)
            return
        }
        dispatchSet(field: field, value: toggled,
                    primaryCamera: primaryCamera, allCameras: allCameras,
                    followsApp: followsApp, reply: reply, store: store)
    }

    private func dispatchCycle(
        field: String,
        primaryCamera: CameraController, allCameras: [CameraController],
        followsApp: Bool, reply: Reply, store: DashboardStore
    ) {
        guard let cycled = resolveCycle(field: field, camera: primaryCamera) else {
            let entry = WireResultEntry(camera: primaryCamera.slot.label,
                                         status: "rejected", field: field, value: nil,
                                         error: "field absent or not cyclable")
            reply.reject([entry], server: self)
            return
        }
        dispatchSet(field: field, value: cycled,
                    primaryCamera: primaryCamera, allCameras: allCameras,
                    followsApp: followsApp, reply: reply, store: store)
    }

    // MARK: - App actions

    /// Does an app action and answers it: to the WebSocket client that sent it, and as the return value for HTTP, which
    /// answered every action "confirmed" before and so told a client a padlock it refused had taken.
    @discardableResult
    func dispatchAppAction(_ req: WireAppRequest, replyToWS clientID: UUID?) -> WireMessage {
        func reply(_ message: WireMessage) -> WireMessage {
            if let id = clientID { sendWS(message, to: id) }
            return message
        }
        func confirmed(_ field: String, _ value: AnyCodable? = nil) -> WireMessage {
            reply(.result(requestID: req.id, results: [
                WireResultEntry(camera: "", status: "confirmed", field: field, value: value, error: nil)
            ]))
        }
        func refused(_ code: String, _ message: String) -> WireMessage {
            reply(.error(requestID: req.id, code: code, message: message))
        }
        guard let store else { return refused("badRequest", "no store") }
        switch req.action {
        case "showPage":
            guard let pageIDStr = req.pageID, let uuid = UUID(uuidString: pageIDStr) else {
                return refused("unknownTarget", "pageID required")
            }
            store.selectPage(uuid)
            let sent = confirmed("page")
            broadcastPagesChange(store: store)
            return sent
        case "setLinking":
            guard let pageIDStr = req.pageID, let uuid = UUID(uuidString: pageIDStr),
                  let enabled = req.enabled else {
                return refused("badRequest", "pageID and enabled required")
            }
            store.setLinking(enabled, on: uuid)
            return confirmed("linking")
        case "setLink":
            guard let pageIDStr = req.pageID, let uuid = UUID(uuidString: pageIDStr),
                  let groupStr = req.group, let group = LinkKind(rawValue: groupStr),
                  let enabled = req.enabled else {
                return refused("badRequest", "pageID, group, and enabled required")
            }
            store.setLink(group, enabled: enabled, on: uuid)
            return confirmed("link.\(groupStr)")
        case "setLocked":
            // The padlock. Locked, the app's tiles don't take a touch; the API's own commands still work.
            guard let enabled = req.enabled else { return refused("badRequest", "enabled required") }
            store.controlsLocked = enabled
            let sent = confirmed("locked", AnyCodable(enabled))
            broadcastLockChange(store: store)
            return sent
        default:
            return refused("badRequest", "unknown action: \(req.action)")
        }
    }

    // MARK: - Fan-out helpers

    private func fanOutCameras(
        from primary: CameraController,
        allCameras: [CameraController],
        followsApp: Bool,
        command: CameraCommand,
        store: DashboardStore
    ) -> [CameraController] {
        guard allCameras.count == 1, followsApp, let kind = LinkKind(command) else { return [] }
        return store.linkedPeers(of: primary.id, for: kind)
    }

    private func dedup(_ cameras: [CameraController]) -> [CameraController] {
        var seen = Set<UUID>()
        return cameras.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Command execution

    func sendCommandAndWait(
        cmd: CameraCommand, field: String, value: FieldValue, camera: CameraController
    ) async -> WireResultEntry {
        let label = await MainActor.run { camera.slot.label }
        var seenPending = false

        let precheck = await MainActor.run { () -> WireResultEntry? in
            let state = camera.state
            if !state.connection.isControllable {
                return WireResultEntry(camera: label, status: "rejected", field: field,
                                       value: nil, error: "camera not connected")
            }
            if case .record = cmd {
                if state.recording.state == .unknown {
                    return WireResultEntry(camera: label, status: "rejected", field: field,
                                           value: nil, error: "REC unknown")
                }
            }
            return nil
        }
        if let pre = precheck { return pre }

        func entry(_ status: String, _ error: String? = nil) -> WireResultEntry {
            WireResultEntry(camera: label, status: status, field: field,
                            value: status == "confirmed" ? resultValue(field: field, value: value) : nil, error: error)
        }

        // Join the camera+field lane: send now if nothing is in flight, else wait behind the set in flight, replacing
        // any older waiter. A value the camera already has, with nothing in the lane, is confirmed without sending.
        enum Start { case alreadyThere, joined }
        let (mySeq, start) = await MainActor.run { () -> (Int, Start) in
            self.laneSeq += 1
            let seq = self.laneSeq
            var lane = self.lanes[camera.id]?[field] ?? Lane()
            if lane.isIdle && self.fieldAlreadyAtValue(field: field, value: value, camera: camera) {
                return (seq, .alreadyThere)
            }
            lane.latest = seq
            if lane.sending == nil {
                lane.sending = seq
                lane.sentAt = Date()
                camera.sendLocally(cmd)
            } else {
                lane.queued = (seq, cmd, value)
            }
            self.lanes[camera.id, default: [:]][field] = lane
            return (seq, .joined)
        }
        if start == .alreadyThere {
            await MainActor.run { if field == "record" { self.recInFlight.remove(camera.id) } }
            return entry("confirmed")
        }

        let giveUp = Date().addingTimeInterval(15)
        while Date() < giveUp {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let (outcome, nowSeen) = await MainActor.run { () -> (WireResultEntry?, Bool) in
                guard camera.state.connection.isControllable else {
                    self.lanes[camera.id]?[field] = nil
                    if field == "record" { self.recInFlight.remove(camera.id) }
                    return (entry("failed", "disconnected"), seenPending)
                }
                var lane = self.lanes[camera.id]?[field] ?? Lane()
                defer { self.lanes[camera.id, default: [:]][field] = lane }
                if lane.sending == mySeq {
                    let seen = seenPending || self.pendingFieldValue(field: field, camera: camera) == value
                    var status = self.fieldAtValue(field: field, value: value, camera: camera,
                                                   allowNoFailBeforePending: !seen)
                    if status == nil && Date().timeIntervalSince(lane.sentAt) > 5 { status = "timeout" }
                    guard let status else { return (nil, seen) }
                    lane.sending = nil
                    if let next = lane.queued {
                        lane.queued = nil
                        lane.sending = next.seq
                        lane.sentAt = Date()
                        // Not again to a camera that already has it: Play and Pause are one toggle button on some.
                        if !self.fieldAlreadyAtValue(field: field, value: next.value, camera: camera) {
                            camera.sendLocally(next.cmd)
                        }
                    }
                    guard lane.latest == mySeq else { return (nil, seen) }
                    if field == "record" { self.recInFlight.remove(camera.id) }
                    if status == "confirmed" { self.lastRequested[camera.id]?.removeValue(forKey: field) }
                    // Contract: the changes showing the confirmed value arrive before the result.
                    self.broadcastStateChanges()
                    return (entry(status), seen)
                }
                if lane.queued?.seq == mySeq { return (nil, seenPending) }
                guard lane.isIdle else { return (nil, seenPending) }
                self.broadcastStateChanges()
                let endedHere = self.fieldAlreadyAtValue(field: field, value: value, camera: camera)
                return (entry(endedHere ? "confirmed" : "superseded"), seenPending)
            }
            seenPending = nowSeen
            if let outcome { return outcome }
        }
        await MainActor.run { if field == "record" { self.recInFlight.remove(camera.id) } }
        return entry("timeout")
    }

    // MARK: - Field descriptor table

    /// Descriptor for a single API field — current value, pending value, command builder, and operation support.
    private struct FieldDescriptor {
        /// Current camera value as FieldValue (nil if not available on this camera).
        var current: (CameraState) -> FieldValue?
        /// In-flight pending value (nil = none).
        var pending: (CameraState) -> FieldValue?
        /// Build a CameraCommand for the given value (nil = rejected).
        var build: (FieldValue, CameraState) -> CameraCommand?
        /// Ordered options for step/cycle, or nil if not steppable/cyclable.
        var options: ((CameraState) -> [FieldValue]?)?
        /// True if the field supports bool toggle (options must be [.bool(false), .bool(true)]).
        var toggleable: Bool = false
        /// True if step uses latestRequested accumulation rather than current value.
        var stepAccumulates: Bool = false
        /// Whether a change restarts the camera or its picture (the app asks first): camctl's shakedown leaves those.
        var restarts: ((CameraState) -> Bool)? = nil
    }

    // One row per API field. step/cycle/toggle are generic over this table.
    private static let fieldTable: [String: FieldDescriptor] = {
        // Helpers to build descriptors for the common Choice and Level patterns.
        func choiceInt(
            get: @escaping (CameraState) -> Choice<Int>?,
            cmd: @escaping (Int) -> CameraCommand,
            accumulates: Bool = false
        ) -> FieldDescriptor {
            FieldDescriptor(
                current: { s in get(s).map { .int($0.value) } },
                pending: { s in get(s)?.pending.map { .int($0) } },
                build: { val, s in
                    guard case .int(let i) = val, let ch = get(s), ch.isWritable,
                          ch.options.contains(i) else { return nil }
                    return cmd(i)
                },
                options: { s in get(s).map { $0.options.map { .int($0) } } },
                stepAccumulates: accumulates,
                restarts: { s in get(s).map { !$0.restartRequired.isEmpty } ?? false }
            )
        }
        func choiceDouble(
            get: @escaping (CameraState) -> Choice<Double>?,
            cmd: @escaping (Double) -> CameraCommand
        ) -> FieldDescriptor {
            FieldDescriptor(
                current: { s in get(s).map { .double($0.value) } },
                pending: { s in get(s)?.pending.map { .double($0) } },
                build: { val, s in
                    guard case .double(let d) = val, let ch = get(s), ch.isWritable,
                          ch.options.contains(d) else { return nil }
                    return cmd(d)
                },
                options: { s in get(s).map { $0.options.map { .double($0) } } },
                restarts: { s in get(s).map { !$0.restartRequired.isEmpty } ?? false }
            )
        }
        func choiceString(
            get: @escaping (CameraState) -> Choice<String>?,
            cmd: @escaping (String) -> CameraCommand
        ) -> FieldDescriptor {
            FieldDescriptor(
                current: { s in get(s).map { .string($0.value) } },
                pending: { s in get(s)?.pending.map { .string($0) } },
                build: { val, s in
                    guard case .string(let sv) = val, let ch = get(s), ch.isWritable,
                          ch.options.contains(sv) else { return nil }
                    return cmd(sv)
                },
                options: { s in get(s).map { $0.options.map { .string($0) } } },
                restarts: { s in get(s).map { !$0.restartRequired.isEmpty } ?? false }
            )
        }
        func choiceBool(
            get: @escaping (CameraState) -> Choice<Bool>?,
            cmd: @escaping (Bool) -> CameraCommand
        ) -> FieldDescriptor {
            FieldDescriptor(
                current: { s in get(s).map { .bool($0.value) } },
                pending: { s in get(s)?.pending.map { .bool($0) } },
                build: { val, s in
                    guard case .bool(let b) = val, let ch = get(s), ch.isWritable,
                          ch.options.contains(b) else { return nil }
                    return cmd(b)
                },
                options: { s in get(s).map { $0.options.map { .bool($0) } } },
                toggleable: true,
                restarts: { s in get(s).map { !$0.restartRequired.isEmpty } ?? false }
            )
        }
        func level(
            get: @escaping (CameraState) -> Level?,
            cmd: @escaping (Double) -> CameraCommand
        ) -> FieldDescriptor {
            FieldDescriptor(
                current: { s in get(s).map { .double($0.value) } },
                pending: { s in get(s)?.pending.map { .double($0) } },
                build: { val, s in
                    guard case .double(let d) = val, let lv = get(s), lv.isWritable,
                          lv.range.contains(d) else { return nil }
                    return cmd(d)
                },
                options: nil  // levels use clamp, not index
            )
        }

        var t: [String: FieldDescriptor] = [:]
        t["iso"]      = choiceInt(get: { $0.iso },     cmd: { .setISO($0) },     accumulates: true)
        t["baseISO"]  = choiceInt(get: { $0.baseISO }, cmd: { .setBaseISO($0) })
        t["shutterAngle"] = choiceDouble(get: { $0.shutterAngle }, cmd: { .setShutterAngle($0) })
        t["shutterSpeed"] = choiceString(get: { $0.shutterSpeed }, cmd: { .setShutterSpeed($0) })
        t["shutterMode"] = FieldDescriptor(
            current: { s in s.shutterMode.map { .string($0.value.rawValue) } },
            pending: { s in s.shutterMode?.pending.map { .string($0.rawValue) } },
            build: { val, s in
                guard case .string(let sv) = val, let mode = ShutterMode(rawValue: sv),
                      let ch = s.shutterMode, ch.isWritable,
                      ch.options.contains(mode) else { return nil }
                return .setShutterMode(mode)
            },
            options: { s in s.shutterMode.map { $0.options.map { .string($0.rawValue) } } }
        )
        t["wbPreset"] = choiceString(get: { $0.whiteBalance?.preset }, cmd: { .setWhiteBalancePreset($0) })
        t["kelvin"]   = level(get: { $0.whiteBalance?.kelvin }, cmd: { .setKelvin($0) })
        t["tint"]     = level(get: { $0.whiteBalance?.tint },   cmd: { .setTint($0) })
        t["iris"]     = choiceDouble(get: { $0.iris }, cmd: { .setIris($0) })
        t["ndPreset"] = choiceString(get: { $0.nd?.preset },    cmd: { .setNDPreset($0) })
        t["variableND"] = level(get: { $0.nd?.variable },       cmd: { .setVariableND($0) })
        t["frameRate"] = choiceString(get: { $0.frameRate?.project }, cmd: { .setFrameRate($0) })
        t["frameRateVariable"] = choiceBool(
            get: { $0.frameRate?.variable },
            cmd: { .setFrameRateVariable($0) }
        )
        t["resolution"] = choiceString(get: { $0.resolution }, cmd: { .setResolution($0) })
        t["codec"]      = choiceString(get: { $0.fileFormat },  cmd: { .setFileFormat($0) })
        t["bitrate"]    = choiceString(get: { $0.recordingSetting }, cmd: { .setRecordingSetting($0) })
        t["desqueeze"]  = choiceString(get: { $0.desqueeze }, cmd: { .setDesqueeze($0) })
        t["lut"]        = choiceString(get: { $0.lut },       cmd: { .setLUT($0) })
        t["look"]       = choiceBool(get: { $0.look },        cmd: { .setLook($0) })
        t["falseColor"] = choiceBool(get: { $0.falseColor },  cmd: { .setFalseColor($0) })
        t["focusMode"]  = choiceString(get: { $0.focusMode }, cmd: { .setFocusMode($0) })
        t["colorBars"]  = choiceBool(get: { $0.colorBars },   cmd: { .setColorBars($0) })
        t["imageFlip"]  = choiceBool(get: { $0.imageFlip },   cmd: { .setImageFlip($0) })
        t["hdmiInfo"]   = choiceBool(get: { $0.hdmiInfo },    cmd: { .setHDMIInfo($0) })
        t["gridLines"]  = choiceBool(get: { $0.gridLines },   cmd: { .setGridLines($0) })
        t["ndMode"]     = choiceString(get: { $0.ndMode },    cmd: { .setNDMode($0) })
        t["tally"]      = choiceString(get: { $0.tally },     cmd: { .setTally($0) })
        t["call"]       = choiceBool(get: { $0.call },        cmd: { .setCall($0) })
        t["colorGamut"] = choiceString(get: { $0.colorGamut }, cmd: { .setColorGamut($0) })
        t["shootingMode"] = choiceString(get: { $0.shootingMode }, cmd: { .setShootingMode($0) })
        t["gain"]       = choiceInt(get: { $0.gain },        cmd: { .setGain($0) })
        t["baseSensitivity"] = choiceString(get: { $0.baseSensitivity }, cmd: { .setBaseSensitivity($0) })
        t["steadyShot"] = choiceString(get: { $0.steadyShot }, cmd: { .setSteadyShot($0) })
        t["imagerMode"] = choiceString(get: { $0.imagerMode }, cmd: { .setImagerMode($0) })
        t["subjectRecognition"] = choiceString(get: { $0.subjectRecognition }, cmd: { .setSubjectRecognition($0) })
        t["focusArea"]  = choiceString(get: { $0.focusArea }, cmd: { .setFocusArea($0) })
        t["afTransitionSpeed"] = choiceInt(get: { $0.afTransitionSpeed }, cmd: { .setAFTransitionSpeed($0) })
        t["afSubjectShift"] = choiceInt(get: { $0.afSubjectShift }, cmd: { .setAFSubjectShift($0) })
        t["afAssist"]   = choiceBool(get: { $0.afAssist }, cmd: { .setAFAssist($0) })
        t["recordedLUT"] = choiceBool(get: { $0.recordedLUT }, cmd: { .setRecordedLUT($0) })
        t["proxy"]      = choiceBool(get: { $0.proxyRecording }, cmd: { .setProxyRecording($0) })
        t["ecs"]        = choiceBool(get: { $0.ecs?.on },    cmd: { .setECS($0) })
        t["irisAuto"]   = choiceBool(get: { $0.irisAuto },   cmd: { .setIrisAuto($0) })
        t["ndAuto"]     = choiceBool(get: { $0.ndAuto },     cmd: { .setNDAuto($0) })
        t["isoAuto"]    = choiceBool(get: { $0.isoAuto },    cmd: { .setISOAuto($0) })
        t["userFrameA"] = choiceString(get: { $0.userFrameLinesA }, cmd: { .setUserFrameLines(.a, $0) })
        t["userFrameB"] = choiceString(get: { $0.userFrameLinesB }, cmd: { .setUserFrameLines(.b, $0) })
        t["offSpeedRate"] = choiceDouble(get: { $0.frameRate?.variableRate }, cmd: { .setFrameRateVariableRate($0) })
        t["dynamicRange"] = choiceString(get: { $0.dynamicRange }, cmd: { .setDynamicRange($0) })
        t["timecodeDuration"] = choiceBool(get: { $0.timecodeShowsDuration }, cmd: { .setTimecodeShowsDuration($0) })
        // Playback's switch and play/pause as fields (`apiPlaybackMode`, `apiPlaying`), so a deck lights them as any other.
        t["playbackMode"] = choiceString(get: { $0.apiPlaybackMode }, cmd: { .playback($0 == "review" ? .review : .live) })
        t["playing"] = choiceBool(get: { $0.apiPlaying }, cmd: { .playback($0 ? .play : .pause) })
        // An overlay on every output: true only when all of them show it, so setting true reaches the rest.
        for overlay in ControlFields.everyOutputOverlays {
            t[overlay.rawValue] = choiceBool(get: { $0.monitoring?.onEverywhere(overlay) },
                                             cmd: { .setMonitorOverlay(overlay, $0, output: nil) })
        }
        t["zebraLevel"] = choiceInt(get: { $0.monitoring?.zebraLevel }, cmd: { .setZebraLevel($0) })
        t["frameGuideRatio"] = choiceString(get: { $0.monitoring?.frameGuideRatio }, cmd: { .setFrameGuideRatio($0) })
        t["clipFlag"] = FieldDescriptor(
            current: { s in s.clipFlag.map { .string($0.value.rawValue) } },
            pending: { s in s.clipFlag?.pending.map { .string($0.rawValue) } },
            build: { val, s in
                guard case .string(let sv) = val, let flag = ClipFlag(rawValue: sv),
                      let ch = s.clipFlag, ch.isWritable,
                      ch.options.contains(flag) else { return nil }
                return .setClipFlag(flag)
            },
            options: nil  // clipFlag not cyclable/steppable
        )
        return t
    }()

    // MARK: - Field value helpers

    private func resultValue(field: String, value: FieldValue) -> AnyCodable {
        if field == "record", case .bool(let b) = value {
            return AnyCodable(b ? "recording" : "idle")
        }
        return value.jsonValue
    }

    private func fieldAlreadyAtValue(field: String, value: FieldValue, camera: CameraController) -> Bool {
        guard let current = currentFieldValue(field: field, camera: camera) else { return false }
        return current == value
    }

    private func fieldAtValue(field: String, value: FieldValue, camera: CameraController,
                               allowNoFailBeforePending: Bool = false) -> String? {
        guard let current = currentFieldValue(field: field, camera: camera) else { return nil }
        if current == value { return "confirmed" }
        let pending = pendingFieldValue(field: field, camera: camera)
        if pending == nil && allowNoFailBeforePending { return nil }
        if pending == nil { return "failed" }
        return nil // still pending
    }

    // MARK: - buildCommand

    func buildCommand(field: String, value: FieldValue, camera: CameraController) -> CameraCommand? {
        guard camera.state.connection.isControllable else { return nil }
        if field == "record" {
            guard case .bool(let b) = value else { return nil }
            return .record(b)
        }
        return ControlServer.fieldTable[field]?.build(value, camera.state)
    }

    // MARK: - Step / cycle / toggle

    private func latestRequested(field: String, camera: CameraController) -> FieldValue? {
        lastRequested[camera.id]?[field] ?? currentFieldValue(field: field, camera: camera)
    }

    private func resolveStep(field: String, by: Double, camera: CameraController) -> FieldValue? {
        let s = camera.state
        guard let desc = ControlServer.fieldTable[field] else { return nil }

        // Fields without options are level fields: clamp by their step size.
        if desc.options == nil {
            guard let cur = desc.current(s), case .double = cur else { return nil }
            // Retrieve range and step from the underlying Level to clamp correctly.
            let lv: Level? = field == "kelvin" ? s.whiteBalance?.kelvin
                           : field == "tint"   ? s.whiteBalance?.tint
                           :                     s.nd?.variable
            guard let lv, lv.isWritable else { return nil }
            let clamped = max(lv.range.lowerBound, min(lv.range.upperBound, lv.shown + by * lv.step))
            return .double(clamped)
        }

        // Choice fields: step by index through the options list.
        guard let opts = desc.options?(s), !opts.isEmpty else { return nil }
        let base: FieldValue = desc.stepAccumulates
            ? (latestRequested(field: field, camera: camera) ?? (desc.current(s) ?? opts[0]))
            : (desc.current(s) ?? opts[0])
        let idx = opts.firstIndex(of: base) ?? 0
        return opts[max(0, min(idx + Int(by), opts.count - 1))]
    }

    private func resolveCycle(field: String, camera: CameraController) -> FieldValue? {
        guard let desc = ControlServer.fieldTable[field],
              let opts = desc.options?(camera.state), !opts.isEmpty else { return nil }
        let cur = desc.current(camera.state) ?? opts[0]
        let idx = opts.firstIndex(of: cur) ?? 0
        return opts[(idx + 1) % opts.count]
    }

    private func toggleValue(field: String, camera: CameraController) -> FieldValue? {
        guard let desc = ControlServer.fieldTable[field], desc.toggleable else { return nil }
        guard let cur = desc.current(camera.state), case .bool(let b) = cur else { return nil }
        return .bool(!b)
    }

    // MARK: - currentFieldValue / pendingFieldValue

    func currentFieldValue(field: String, camera: CameraController) -> FieldValue? {
        let s = camera.state
        if field == "record" {
            switch s.recording.state {
            case .recording: return .bool(true)
            case .idle: return .bool(false)
            case .unknown: return nil
            }
        }
        return ControlServer.fieldTable[field]?.current(s)
    }

    func pendingFieldValue(field: String, camera: CameraController) -> FieldValue? {
        if field == "record" {
            let s = camera.state
            return s.recording.request != nil ? .bool(s.recording.request == .start) : nil
        }
        return ControlServer.fieldTable[field]?.pending(camera.state)
    }
}

// MARK: - sendWS overload for optional clientID

private extension ControlServer {
    func sendWS(_ msg: WireMessage, to clientID: UUID?) {
        guard let id = clientID else { return }
        sendWS(msg, to: id)
    }
}

// MARK: - The shakedown's view of the fields

/// One API field as a camera reads it now, for camctl's shakedown (docs/testing.md): its value and the options it steps
/// through, as text, and whether the app would set it now.
public struct FieldReading: Sendable, Equatable {
    public let name: String
    public let value: String
    public let options: [String]
    public let isWritable: Bool
    /// A change restarts the camera or its picture: the app asks first.
    public let restarts: Bool
}

extension ControlServer {
    /// Every API field the camera has now, by name: the table the API sets them through, so a shakedown changes each
    /// control the way the app and a deck do.
    public static func fieldReadings(_ state: CameraState) -> [FieldReading] {
        fieldTable.keys.sorted().compactMap { name in
            guard let desc = fieldTable[name], let current = desc.current(state) else { return nil }
            return FieldReading(name: name, value: current.shakedownText,
                                options: (desc.options?(state) ?? []).map(\.shakedownText),
                                isWritable: desc.build(current, state) != nil, restarts: desc.restarts?(state) ?? false)
        }
    }

    /// The command that sets `field` to the option shown as `text` (one of its `options`), as the API would send it.
    public static func command(field: String, option text: String, state: CameraState) -> CameraCommand? {
        guard let desc = fieldTable[field],
              let option = desc.options?(state)?.first(where: { $0.shakedownText == text }) else { return nil }
        return desc.build(option, state)
    }
}

extension FieldValue {
    /// As camctl's shakedown prints it and finds an option by.
    var shakedownText: String {
        switch self {
        case .bool(let b): b ? "on" : "off"
        case .int(let i): String(i)
        case .double(let d): d == d.rounded() ? String(Int(d)) : String(d)
        case .string(let s): s
        }
    }
}
