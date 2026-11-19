import Foundation
import Network
import CameraCore
import SSHTunnel

extension SonyCameraBackend {
    // MARK: - Pairing approval wait

    /// The camera answered Init with "rejected": no approval yet. Ask again every second on a fresh connection
    /// (the rejected one is closed first). Retrying on the transport that was rejected never got through, even once
    /// the camera would have accepted: a fake camera test sat in "approve on camera" for 40 s after it started
    /// accepting.
    func waitForApprovalAndRetry(host: String, config: PTPIPTransportConfig, guid: UUID, attempt mine: Int) async {
        for _ in 0..<60 {  // try for ~60 seconds
            try? await Task.sleep(for: .seconds(1))
            guard attempt == mine, state.connection == .awaitingApproval else { return }
            // Detach the rejected transport before closing it, so its "disconnected" doesn't end the wait.
            let rejected = self.transport
            self.transport = nil
            await rejected?.disconnect()
            guard attempt == mine else { return }
            let transport = makeTransport(host: host, config: config)
            do {
                try await transport.connect(guid: guid, friendlyName: identityStore.friendlyName)
                guard attempt == mine else { return }
                await runSession(transport: transport, attempt: mine)
                return
            } catch PTPError.authenticationFailed {
                continue  // still waiting
            } catch {
                fail(error.localizedDescription, attempt: mine); return
            }
        }
        fail("Pairing timed out", attempt: mine)
    }

    // MARK: - Property fetch

    enum FetchKind: Int, Comparable {
        case changed, full
        static func < (a: FetchKind, b: FetchKind) -> Bool { a.rawValue < b.rawValue }
    }

    /// One fetch in flight at a time. Anything asked for meanwhile runs right after it; a full read wins over a
    /// changed-only one. Dropping a request was harmless with a 0.2 s poll; with events doing the work it would
    /// leave stale values or stale option lists until the safety poll.
    /// Runs `kind`, then whatever was queued while it ran. Returns why the first fetch failed, or nil.
    /// A changed-only fetch with nothing read yet becomes a full one: a diff of nothing stays nothing.
    @discardableResult
    func requestFetch(_ kind: FetchKind) async -> String? {
        guard let transport else { return "no connection" }
        guard sessionReady else { return "session not open yet" }
        guard !fetchInFlight else { pendingFetch = max(pendingFetch ?? kind, kind); return nil }
        fetchInFlight = true
        defer { fetchInFlight = false }
        var next: FetchKind? = kind
        var firstProblem: String?
        var isFirst = true
        while let current = next {
            pendingFetch = nil
            let problem: String?
            if current == .full || rawProps.isEmpty {
                problem = await fetchAllPropsOnce(transport)
            } else {
                await fetchChangedPropsOnce(transport)
                problem = nil
            }
            if isFirst { firstProblem = problem; isFirst = false }
            fetchGeneration += 1
            next = pendingFetch
        }
        return firstProblem
    }

    func fetchAllProps() async { await requestFetch(.full) }

    /// Returns nil when the camera's settings were read, otherwise why not.
    func fetchAllPropsOnce(_ transport: any PTPTransport) async -> String? {
        do {
            // Not timed for the latency: a full read is every property (about 8 KB from an FX5 or FX6), which over HaLow
            // takes several times a changed-only read's round trip and made a good link read slow. The changed-only
            // reads, small and frequent, are the latency.
            let (resp, data) = try await transport.execute(
                opCode: SDIOOpCode.getAllExtDevicePropInfo.rawValue,
                params: [GetAllPropParam1.allData.rawValue, sdioExtendedCodesFlag]
            )
            guard resp.responseCode == PTPResponseCode.ok.rawValue else {
                return String(format: "the camera answered 0x%04X", resp.responseCode)
            }
            let parsed = try parseSDIDevicePropInfoArray(data)
            rawProps = Dictionary(parsed.map { ($0.code, $0) }, uniquingKeysWith: { _, last in last })
            applyProps(Array(rawProps.values))
            return nil
        } catch {
            return "\(error)"
        }
    }

    func fetchChangedProps() async { await requestFetch(.changed) }

    func fetchChangedPropsOnce(_ transport: any PTPTransport) async {
        do {
            let t0 = Date()
            let (resp, data) = try await transport.execute(
                opCode: SDIOOpCode.getAllExtDevicePropInfo.rawValue,
                params: [GetAllPropParam1.changedOnly.rawValue, sdioExtendedCodesFlag]
            )
            recordLatency(Date().timeIntervalSince(t0))
            guard resp.responseCode == PTPResponseCode.ok.rawValue, !data.isEmpty else { return }
            let changed = try parseSDIDevicePropInfoArray(data)
            for prop in changed { rawProps[prop.code] = prop }
            applyProps(Array(rawProps.values))
        } catch {}
    }

    func recordLatency(_ interval: TimeInterval) {
        recentLatencies.append(interval * 1000.0)
        if recentLatencies.count > 8 { recentLatencies.removeFirst() }
    }

    func applyProps(_ props: [SDIDevicePropInfo]) {
        // Don't run or emit when already in a terminal state.
        switch state.connection { case .failed, .disconnected: return; default: break }
        let before = state
        let mapper = StateMapper(props: props, controls: sessionInfo?.extDeviceInfo.controlCodes ?? [])

        // Preserve REC request/failure across refreshes [Architecture rule 6]
        let prevRec = state.recording
        let newRec = mapper.recordingState()

        if prevRec.request != nil {
            var merged = newRec
            merged.request = prevRec.request
            merged.failure = prevRec.failure
            state.recording = merged
        } else {
            state.recording = newRec
            // Camera stopped recording externally (card full, camera-side stop, etc.) — clear take start time.
            if prevRec.state == .recording && newRec.state == .idle {
                state.takeStartedAt = nil
            }
        }

        mapper.map(into: &state, lutNames: lutNames, baseISONames: baseISONames, assignableNames: assignableNames,
                   subjectNames: subjectNames)
        // A stream goes over the network: on a cable, only Live View Status gives a picture. And live view through the
        // stream is offered only where the config has it on (`SonyBackendConfig.streamLiveView`).
        if isUSB || !config.streamLiveView, !mapper.liveViewEnabled() { state.hasLiveView = false }
        // What the camera warns of, into the Activity Log as it starts (the Label tile shows it meanwhile).
        for alert in state.alerts where !before.alerts.contains(alert) { ActivityLog.shared.note(host, alert) }
        // Most fetches change nothing the app shows: the FX3 reports its exposure meter whenever the picture changes.
        // So nothing is published then, and the latency average (it moves on every fetch) goes out with a real change
        // or every 5 s, rather than redrawing every tile on each report.
        if !recentLatencies.isEmpty, state != before || latencyPublishedAt.map({ $0.timeIntervalSinceNow < -5 }) ?? true {
            state.latencyMilliseconds = Int(recentLatencies.reduce(0, +) / Double(recentLatencies.count))
            latencyPublishedAt = Date()
        }
        guard state != before else { return }
        emit()
    }

    // MARK: - Event handling [Architecture rule 5]

    func handleEvent(_ event: ParsedEvent, from transport: ObjectIdentifier) {
        guard isCurrent(transport) else { return }
        switch event.eventCode {
        case PTPEventCode.devicePropChanged.rawValue:
            scheduleBatchFetch()
        case PTPEventCode.movieRecOperationResults.rawValue: // Param1: 1 = OK, 2 = NG
            // NG (no card, card full, ...) fails the pending request now instead of waiting out the timeout.
            if event.params.first == 0x0000_0002, state.recording.request != nil {
                recConfirmTask?.cancel()
                ActivityLog.shared.note(host, "REC \(state.recording.request == .start ? "start" : "stop") refused by the "
                    + "camera (no card, card full, or a setting that won't record): \(recordingReport)")
                state.recording.request = nil
                state.recording.failure = RecordingControl.Failure.refused
                emit()
            }
            scheduleBatchFetch()
        case PTPEventCode.cautionDisplayEvent.rawValue:
            scheduleBatchFetch()
        case PTPEventCode.operationResults.rawValue:        // Param1: operation << 16 | property, Param2: result
            let property = UInt16(truncatingIfNeeded: event.params.first ?? 0)
            let naming: Set<UInt16> = [SDIPropCode.fileTitleName.rawValue, SDIPropCode.fileCameraID.rawValue,
                                       SDIPropCode.fileReelNumber.rawValue]
            if naming.contains(property), let result = event.params.dropFirst().first, result != 0x0000_0001 {
                state.fileNaming?.failure = switch result {
                case 0x0000_0011: "The camera didn't take that length."
                case 0x0000_0003: "The camera didn't take that value."
                default: String(format: "The camera refused it (0x%02X).", result)
                }
                emit()
            }
            scheduleBatchFetch()
        case PTPEventCode.controlUploadDataResult.rawValue: // SDIE_ControlUploadDataResult
            // param1 = result, param2 = ControlType (0x00020000 = BaseLookImport)
            if let cont = pendingLUTImportStreamContinuation {
                pendingLUTImportStreamContinuation = nil
                let rawResult = event.params.first ?? 0
                cont.yield(LUTImportResult(rawValue: rawResult) ?? .unknown)
                cont.finish()
            }
            scheduleBatchFetch()
        default:
            break
        }
    }

    /// Batch prop-changed events: wait `batchWindow`, then do one diff fetch. [Architecture rule 5]
    func scheduleBatchFetch() {
        batchTask?.cancel()
        batchTask = Task {
            try? await Task.sleep(for: .seconds(config.eventBatchWindow))
            guard !Task.isCancelled else { return }
            await fetchChangedProps()
        }
    }

    // MARK: - Fallback poll loop

    func startPollLoop() {
        // Cancel any pre-existing loop so a reconnect never runs two concurrent loops.
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled && state.connection == .connected {
                try? await Task.sleep(for: .seconds(config.pollInterval))
                guard !Task.isCancelled, state.connection == .connected, !fetchInFlight else { continue }
                await fetchChangedProps()
            }
        }
    }

    // MARK: - Transport state changes

    func handleTransportStateChange(_ transportState: PTPTransportState, from transport: ObjectIdentifier) {
        guard isCurrent(transport) else { return }
        switch transportState {
        case .failed, .disconnected:
            recConfirmTask?.cancel()
            failPendingRec()
            reviewPhase = .unknown   // a new connection puts the camera back in Record mode
            scanning = false
        default:
            break
        }
        switch transportState {
        case .failed(let msg):
            // Only emit if not already in a terminal state (.failed or .disconnected).
            // A transport that fires .failed then .disconnected must not double-emit.
            guard state.connection != .disconnected else { return }
            if case .failed(_) = state.connection { return }
            state.connection = .failed(msg)
            emit()
        case .disconnected:
            // If we're already .failed, keep that richer status rather than downgrading to .disconnected.
            if case .failed(_) = state.connection { return }
            state.connection = .disconnected
            emit()
        default:
            break
        }
    }
}

