// PTP-IP transport over two NWConnection TCP channels (command + event).
// All PTP operations are serialized through TransactionGate — one transaction
// on the wire at a time. The serial DispatchQueue guards mutable state.
//
// Timeouts are configurable with defaults sized for slow mesh (~4.4 Mbit/s, 17–55 ms RTT).
// [Architecture rule 2]

import Foundation
import Network
import os

// MARK: - Transport Configuration

public struct PTPIPTransportConfig: Sendable {
    /// PTP-IP port
    public var port: NWEndpoint.Port = 15740
    /// Connect timeout — generous for slow mesh
    public var connectTimeout: TimeInterval = 15.0
    /// Per-transaction timeout
    public var transactionTimeout: TimeInterval = 30.0
    /// Keepalive probe interval (send Probe_Request if no traffic for this long)
    public var probeInterval: TimeInterval = 4.0
    /// How long to wait for anything back after a probe before declaring the link dead. With the probe interval,
    /// a link that goes quiet is noticed within about 8 s (a pulled cable took 30+ s: nothing waited for the answer).
    public var probeTimeout: TimeInterval = 4.0

    public init() {}
}

// MARK: - Traffic recorder (for --record fixture captures)

public protocol TrafficRecorder: Sendable {
    func record(direction: TrafficDirection, channel: TrafficChannel, data: Data)
}

public enum TrafficDirection { case sent, received }
public enum TrafficChannel   { case command, event }

// MARK: - PTPIPTransport

/// Manages two TCP connections (command + event) and serializes all PTP transactions.
/// Not an actor: all mutation happens on `queue` (a serial DispatchQueue).
public final class PTPIPTransport: PTPTransport, @unchecked Sendable {

    // MARK: - State

    public typealias State = PTPTransportState

    private let host: String
    private let config: PTPIPTransportConfig
    private let queue = DispatchQueue(label: "sony-ptp.transport", qos: .userInitiated)
    /// One PTP transaction on the wire at a time, start to finish. The queue only guards state.
    private let gate = TransactionGate()
    private var cmdConnection: NWConnection?
    private var evtConnection: NWConnection?
    private var txCounter: UInt32 = 1
    private var connectionNumber: UInt32 = 0
    private var probeTimer: DispatchSourceTimer?
    /// When the probe now waiting for an answer went out; nil when none is.
    private var probeSentAt: Date?
    private var lastTrafficTime = Date()

    public private(set) var state: State = .idle
    public var onStateChange: (@Sendable (State) -> Void)?
    public var onEvent: (@Sendable (ParsedEvent) -> Void)?
    public var recorder: (any TrafficRecorder)?

    // Pending response continuations keyed by transactionID
    private var pendingTransactions: [UInt32: CheckedContinuation<(ParsedCmdResponse, Data), Error>] = [:]
    // Pending timeout work items keyed by transactionID
    private var pendingTimeouts: [UInt32: DispatchWorkItem] = [:]
    // Accumulate multi-packet data phases
    private var dataAccumulators: [UInt32: Data] = [:]

    public init(host: String, config: PTPIPTransportConfig = PTPIPTransportConfig()) {
        self.host = host
        self.config = config
    }

    // MARK: - Connection

    public func connect(guid: UUID, friendlyName: String) async throws {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: config.port
        )
        let params = NWParameters.tcp
        params.prohibitedInterfaceTypes = []

        // Step 1: Command channel
        let cmd = try await openReady(to: endpoint, using: params) { self.cmdConnection = $0 }

        // Step 2: Send Init_Command_Request; receive Init_Command_Ack
        let initReq = buildInitCommandRequest(guid: guid, friendlyName: friendlyName)
        try await sendRaw(initReq, on: cmd, channel: .command)
        let ackPacket = try await receiveOnePacket(from: cmd, channel: .command)
        switch parsePTPIPPacket(ackPacket) {
        case .initCommandAck(let ack):
            connectionNumber = ack.connectionNumber
        case .initFail(let reason):
            if reason == .rejected {
                // Camera is showing our friendly name and waiting for pairing approval.
                // State is left as .connected because the session layer surfaces .awaitingApproval;
                // changing it here would fire a premature state-change callback to the backend.
                throw PTPError.authenticationFailed
            }
            throw PTPError.disconnected
        default:
            throw PTPError.unexpectedPacket("Expected Init_Command_Ack")
        }

        // Step 3: Event channel
        let evt = try await openReady(to: endpoint, using: params) { self.evtConnection = $0 }

        // Step 4: Send Init_Event_Request (ConnectionNumber) [CIPA DC-005-2005 §3.2.2]
        let evtReq = buildInitEventRequestPacket(connectionNumber: connectionNumber)
        try await sendRaw(evtReq, on: evt, channel: .event)
        let evtAck = try await receiveOnePacket(from: evt, channel: .event)
        switch parsePTPIPPacket(evtAck) {
        case .initEventAck:
            break
        default:
            throw PTPError.unexpectedPacket("Expected Init_Event_Ack")
        }

        setStateOnQueue(.connected)

        // Start event reader loop
        startEventReader()
        startProbeTimer()
    }

    /// A connect the system turned down with EADDRINUSE: the local port it picked collided (loopback, now and then,
    /// in full test runs). Network.framework leaves such a connection in .waiting rather than failing it.
    private struct LocalPortInUse: Error {}

    /// A new connection to `endpoint`, ready, within the connect timeout. One that waits on EADDRINUSE is replaced at
    /// once by one from a local port of our own choosing: a new connection left to the system got the same colliding
    /// port every time (all 30 retries; netstat showed that port's 4-tuple to the camera in TIME_WAIT).
    /// Anything else is waited out as before. `track` hears each attempt, so a disconnect meanwhile can cancel it.
    private func openReady(to endpoint: NWEndpoint, using params: NWParameters,
                           track: (NWConnection) -> Void) async throws -> NWConnection {
        let deadline = Date().addingTimeInterval(config.connectTimeout)
        var parameters = params
        while true {
            let connection = NWConnection(to: endpoint, using: parameters)
            track(connection)
            do {
                try await waitReady(connection, timeout: max(0.1, deadline.timeIntervalSinceNow))
                return connection
            } catch is LocalPortInUse where Date() < deadline {
                connection.cancel()
                parameters = Self.withOwnLocalPort(params, toward: endpoint)
                try await Task.sleep(for: .milliseconds(20))
            } catch is LocalPortInUse {
                connection.cancel()
                throw PTPError.timeout
            }
        }
    }

    /// `params` bound to a random port in the ephemeral range, on the loopback or any address of the camera's family.
    /// A host given by name keeps the system's choice: its family isn't known before it's looked up.
    static func withOwnLocalPort(_ params: NWParameters, toward endpoint: NWEndpoint) -> NWParameters {
        guard case .hostPort(let host, _) = endpoint else { return params }
        let local: NWEndpoint.Host
        switch host {
        case .ipv4(let address): local = .ipv4(address.isLoopback ? .loopback : .any)
        case .ipv6(let address): local = .ipv6(address.isLoopback ? .loopback : .any)
        case .name(let name, _) where name == "localhost": local = .ipv4(.loopback)
        default: return params
        }
        let copy = params.copy()
        copy.requiredLocalEndpoint = .hostPort(host: local, port: NWEndpoint.Port(rawValue: UInt16.random(in: 49152...65535))!)
        return copy
    }

    /// Wait for an NWConnection to reach .ready, with a connect timeout.
    private func waitReady(_ connection: NWConnection, timeout: TimeInterval? = nil) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resolved = OSAllocatedUnfairLock(initialState: false)
            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    resolved.withLock { flag in
                        if !flag { flag = true; cont.resume() }
                    }
                case .failed(let err):
                    resolved.withLock { flag in
                        if !flag { flag = true; cont.resume(throwing: err) }
                    }
                case .waiting(.posix(.EADDRINUSE)):
                    resolved.withLock { flag in
                        if !flag { flag = true; cont.resume(throwing: LocalPortInUse()) }
                    }
                case .cancelled:
                    resolved.withLock { flag in
                        if !flag { flag = true; cont.resume(throwing: PTPError.disconnected) }
                    }
                default: break
                }
            }
            connection.start(queue: self.queue)

            self.queue.asyncAfter(deadline: .now() + (timeout ?? self.config.connectTimeout)) {
                resolved.withLock { flag in
                    if !flag { flag = true; cont.resume(throwing: PTPError.timeout) }
                }
            }
        }
    }

    // MARK: - Disconnect

    public func disconnect() async {
        queue.async { [weak self] in self?.teardown() }
        // Give teardown a moment to cancel pending transactions before the caller proceeds.
        // (The 100 ms budget is sufficient for all 60 pairing-retry disconnect calls.)
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func teardown() {
        probeTimer?.cancel()
        probeTimer = nil
        cmdConnection?.cancel()
        evtConnection?.cancel()
        cmdConnection = nil
        evtConnection = nil
        // Cancel all pending timeouts, then fail their transactions
        for (_, item) in pendingTimeouts { item.cancel() }
        pendingTimeouts.removeAll()
        let pending = pendingTransactions
        pendingTransactions = [:]
        for (_, cont) in pending {
            cont.resume(throwing: PTPError.disconnected)
        }
        setStateOnQueue(.disconnected)
    }

    // MARK: - Serial transaction execution

    /// Execute a PTP operation: send Cmd_Request, optional data phase, receive response + optional data.
    /// Serialized via TransactionGate.
    public func execute(opCode: UInt16, params: [UInt32], sendData: Data?) async throws -> (ParsedCmdResponse, Data) {
        try await gate.run { [self] in
            try await self.executeUnserialized(opCode: opCode, params: params, sendData: sendData)
        }
    }

    private func executeUnserialized(
        opCode: UInt16,
        params: [UInt32] = [],
        sendData: Data? = nil
    ) async throws -> (ParsedCmdResponse, Data) {

        // Allocate txID, build the packet, register the continuation, arm the timeout — all in one queue hop.
        return try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self, let cmd = self.cmdConnection, self.state == .connected else {
                    cont.resume(throwing: PTPError.disconnected); return
                }
                let txID = self.nextTxID()
                let phaseInfo: DataPhaseInfo = sendData != nil ? .dataToResponder : .noDataOrUnknown
                let tx = PTPTransaction(opCode: opCode, transactionID: txID, params: params, dataPhase: phaseInfo)
                let cmdPkt = buildCmdRequest(tx)

                // Register continuation first so the response can never arrive unmatched
                self.pendingTransactions[txID] = cont

                // Cancellable timeout: canceled when the response arrives
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingTimeouts.removeValue(forKey: txID)
                    if let p = self.pendingTransactions.removeValue(forKey: txID) {
                        p.resume(throwing: PTPError.timeout)
                    }
                }
                self.pendingTimeouts[txID] = timeout
                self.queue.asyncAfter(deadline: .now() + self.config.transactionTimeout, execute: timeout)

                // Send from async context so NWConnection's async send can be awaited
                let capturedData = sendData
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.sendRaw(cmdPkt, on: cmd, channel: .command)
                        if let data = capturedData {
                            let startPkt = buildStartData(transactionID: txID, totalLength: UInt64(data.count))
                            try await self.sendRaw(startPkt, on: cmd, channel: .command)
                            let endPkt = buildEndData(transactionID: txID, data: data)
                            try await self.sendRaw(endPkt, on: cmd, channel: .command)
                        }
                    } catch {
                        self.queue.async { [weak self] in
                            guard let self else { return }
                            self.pendingTimeouts.removeValue(forKey: txID)?.cancel()
                            if let p = self.pendingTransactions.removeValue(forKey: txID) {
                                p.resume(throwing: error)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Command channel reader loop

    /// Drives the command channel receive loop (called after connection is established)
    public func startReceiving() {
        // Snapshot the connection and event handler on the queue before spawning the Task.
        queue.async { [weak self] in
            guard let self, let cmd = self.cmdConnection else { return }
            Task { [weak self, cmd] in
                guard let self else { return }
                do {
                    while true {
                        let raw = try await self.receiveOnePacket(from: cmd, channel: .command)
                        self.queue.async { self.handleCommandPacket(parsePTPIPPacket(raw)) }
                    }
                } catch {
                    self.queue.async { self.handleLinkFailure(error) }
                }
            }
        }
    }

    private func handleCommandPacket(_ pkt: IncomingPacket) {
        lastTrafficTime = Date()
        switch pkt {
        case .cmdResponse(let resp):
            pendingTimeouts.removeValue(forKey: resp.transactionID)?.cancel()
            guard let cont = pendingTransactions.removeValue(forKey: resp.transactionID) else { return }
            let data = dataAccumulators.removeValue(forKey: resp.transactionID) ?? Data()
            cont.resume(returning: (resp, data))

        case .startData:
            break  // totalLength unused; data accumulates via dataChunk/endData

        case .dataChunk(let txID, let payload):
            dataAccumulators[txID, default: Data()].append(payload)

        case .endData(let txID, let payload):
            dataAccumulators[txID, default: Data()].append(payload)

        case .probeResponse:
            break

        case .probeRequest:
            if let cmd = cmdConnection {
                Task { try? await self.sendRaw(buildProbeResponse(), on: cmd, channel: .command) }
            }

        default:
            break
        }
    }

    // MARK: - Event channel reader loop

    private func startEventReader() {
        // Snapshot the connection and event handler on the queue before spawning the Task.
        queue.async { [weak self] in
            guard let self, let evt = self.evtConnection else { return }
            let onEvent = self.onEvent
            Task { [weak self, evt, onEvent] in
                guard let self else { return }
                do {
                    while true {
                        let raw = try await self.receiveOnePacket(from: evt, channel: .event)
                        switch parsePTPIPPacket(raw) {
                        case .event(let e):
                            self.queue.async { self.lastTrafficTime = Date() }
                            onEvent?(e)
                        case .probeRequest:
                            // The camera checks we're alive; answer on the same connection.
                            try await self.sendRaw(buildProbeResponse(), on: evt, channel: .event)
                        default:
                            break
                        }
                    }
                } catch {
                    self.queue.async { self.handleLinkFailure(error) }
                }
            }
        }
    }

    // MARK: - Keepalive probe

    private func startProbeTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let tick = min(1, config.probeInterval, config.probeTimeout)
        timer.schedule(deadline: .now() + tick, repeating: tick)
        timer.setEventHandler { [weak self] in self?.sendProbeIfNeeded() }
        timer.resume()
        probeTimer = timer
    }

    /// Probes a quiet link, and fails it when nothing at all comes back within `probeTimeout`. Over the SSH tunnel
    /// the probe's own send always succeeds (it goes to a local socket), so only the answer says the camera is there.
    private func sendProbeIfNeeded() {
        guard state == .connected, let cmd = cmdConnection else { return }
        let now = Date()
        if let sent = probeSentAt, lastTrafficTime < sent {
            if now.timeIntervalSince(sent) >= config.probeTimeout { handleLinkFailure(PTPError.timeout) }
            return
        }
        probeSentAt = nil
        guard now.timeIntervalSince(lastTrafficTime) >= config.probeInterval else { return }
        probeSentAt = now
        let probe = buildProbeRequest()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sendRaw(probe, on: cmd, channel: .command)
            } catch {
                self.queue.async { self.handleLinkFailure(error) }
            }
        }
    }

    // MARK: - Link failure

    private func handleLinkFailure(_ error: Error) {
        guard state == .connected else { return }
        setStateOnQueue(.failed(error.localizedDescription))
        teardown()
    }

    // MARK: - Low-level send/receive

    /// Send raw bytes on an NWConnection. Errors are thrown.
    func sendRaw(_ data: Data, on connection: NWConnection, channel: TrafficChannel) async throws {
        recorder?.record(direction: .sent, channel: channel, data: data)
        return try await withCheckedThrowingContinuation { cont in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// Receive exactly one PTP-IP packet (reads 8-byte header then remainder).
    func receiveOnePacket(from connection: NWConnection, channel: TrafficChannel) async throws -> Data {
        // Read 8-byte header to get Length
        let header = try await receiveExact(8, from: connection)
        guard header.count == 8 else { throw PTPError.disconnected }
        let length = header.readLE(UInt32.self, at: 0)
        guard length >= 8 else { throw PTPError.malformedData("Packet length \(length) < 8") }
        let bodyLen = Int(length) - 8
        var full = header
        if bodyLen > 0 {
            let body = try await receiveExact(bodyLen, from: connection)
            full.append(body)
        }
        recorder?.record(direction: .received, channel: channel, data: full)
        return full
    }

    private func receiveExact(_ count: Int, from connection: NWConnection) async throws -> Data {
        var accumulated = Data()
        while accumulated.count < count {
            let remaining = count - accumulated.count
            let chunk = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                    if let error { cont.resume(throwing: error); return }
                    if let data { cont.resume(returning: data); return }
                    if isComplete { cont.resume(throwing: PTPError.disconnected); return }
                    cont.resume(returning: Data())
                }
            }
            if chunk.isEmpty { throw PTPError.disconnected }
            accumulated.append(chunk)
        }
        return accumulated
    }

    // MARK: - Helpers

    private func nextTxID() -> UInt32 {
        let id = txCounter
        txCounter &+= 1
        if txCounter == 0 { txCounter = 1 }
        return id
    }

    private func setStateOnQueue(_ newState: State) {
        state = newState
        let cb = onStateChange
        // Hop to main so the callback fires outside the serial queue and can't deadlock it.
        DispatchQueue.main.async { cb?(newState) }
    }
}


/// Runs async operations strictly one after another. PTP-IP allows a single outstanding transaction per
/// session, and actor/queue isolation alone doesn't stop two callers from interleaving packets on the wire.
actor TransactionGate {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

