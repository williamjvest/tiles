// FakePTPIPCamera — in-process NWListener fake that runs the PTP-IP connect sequence
// and serves a small property set. Used by all backend end-to-end tests.

import Foundation
import Network
import CameraKitTestSupport
import Testing
@testable import SonyPTP

// MARK: - Fake camera state

public final class FakePTPIPCamera: @unchecked Sendable {

    public struct Config {
        /// Whether to reject Init_Command_Request (simulates user denying pairing)
        public var rejectInit: Bool = false
        /// Delay before sending Init_Command_Ack (simulates camera approval wait)
        public var approvalDelay: TimeInterval = 0
        /// Whether SDIO_OpenSession returns Parameter_Not_Supported (FX6/BURANO-style)
        public var sdioOpenSessionUnsupported: Bool = false
        /// If true: SDIO_OpenSession returns 0x201E (Session_Already_Open) — mirrors FX3 behavior
        public var sdioOpenSessionAlreadyOpen: Bool = false
        /// Recording state to report
        public var recordingState: UInt8 = 0x00  // Not Recording
        /// Where the body reports REC: 0xD21D (the FX3), or the recorder's status 0xE010 as an FX6/BURANO does,
        /// which don't have 0xD21D. `recordingState` holds it either way, in 0xD21D terms.
        public var recordingStateSource: RecordingStateSource = .movieRecordingState
        /// How long to hold recording in "Waiting" state before confirming (0=instant)
        public var recConfirmDelay: TimeInterval = 0
        /// How long the recorder (0xE010) says Stopping after a stop before it's Ready, as a body closing a long take.
        public var stopDelay: TimeInterval = 0
        /// If true: REC commands are accepted but recording state never changes (timeout test)
        public var neverConfirmRec: Bool = false
        /// REC stops (Movie Rec Up, or the toggle while recording) answered OK and then not acted on, this many times:
        /// an FX5 kept rolling after a linked stop until REC was pressed again.
        public var ignoredStops = 0
        /// If true: the camera answers REC with SDIE_MovieRecOperationResults NG (no card, card full)
        public var rejectRec: Bool = false
        /// SDIControlCode list reported by SDIO_GetExtDeviceInfo. Default = a real FX3: Hold 0xD2C8, no toggle 0xF001.
        public var controlCodes: [UInt16] = [SDIControlCode.movieRecButtonHold.rawValue]
        /// An FX5's streaming (Network → Stream, fixtures/fx5-propinfo-2026-11-14.bin): its stream properties,
        /// SDIO_Get/SetStreamSettingList, and the Stream button (list it in `controlCodes`), which publishes the PYXIS's
        /// recorded stream to the destination picked. `streamSettingOn`: Network → Stream → Setting (Off reads Inactive).
        public var streaming = false
        public var streamSettingOn = true
        /// Already streaming, to this destination (Video Stream number 1–3), as one an app that went away left.
        public var streamingTo: (slot: Int, url: String, key: String)? = nil
        /// SDIO_SetStreamSettingList of one destination turned down (0x2006): it wants the whole list.
        public var wantsWholeStreamList = false
        /// How long it takes to answer SDIO_SetStreamSettingList.
        public var streamSetDelay: TimeInterval = 0
        /// If > 0: drops TCP after this many transactions (dead-link test)
        public var killAfterTransactions: Int = 0
        /// Initial property values, keyed by SDIPropCode.rawValue. Override before calling start().
        public var fakePropData: [UInt16: Data] = [:]
        /// Properties left out of the camera's list: an FX5 has no Focus Mode 0x500A, say.
        public var omitPropCodes: Set<UInt16> = []
        /// An extra property's enum list, where it's more than its value alone (an FX5's six Subject Recognition AFs).
        public var fakePropLists: [UInt16: [Data]] = [:]
        /// Its names for its Subject Recognition AF values, served as display list 0x15.
        public var subjectNames: [UInt8: String] = [:]
        /// Result to fire in SDIE_ControlUploadDataResult (0xC214) for LUT import tests.
        /// .unknown = don't fire the event (simulates timeout).
        public var lutImportResult: LUTImportResult = .ok
        /// Delay before sending the 0xC214 event (simulates camera processing time).
        public var lutImportDelay: TimeInterval = 0.05
        /// Whether Live View Status (0xD221) is Enabled. Controls GetObject(0xFFFFC002) responses.
        public var liveViewEnabled: Bool = true
        /// Report Exposure Index (0xD022, UINT16) as the enabled ISO property, as the FX3 does in Cine EI.
        public var exposureIndex: Bool = false
        /// Answer this many full property dumps (GetAllExtDevicePropInfo, allData) with Device_Busy first.
        public var failFullPropFetches: Int = 0
        /// The FX3 over HaLow: a prop-changed event right after SDIO_Connect phase 2 and a slow
        /// GetExtDeviceInfo, so an event-driven read goes out before phase 3. Like the FX3, a property read before
        /// phase 3 is never answered.
        public var eventBeforeSessionReady: Bool = false
        /// Like a real FX3: Camera Button Function 0xD309 with Playback, ENTER and the arrows in 0xD208,
        /// and Camera Operating Mode 0xD0BC. Playback toggles the mode, first stopping a playing clip; ENTER plays and
        /// pauses in Playback. In Record mode the arrows and ENTER are shooting shortcuts: see `shortcutPresses`.
        public var buttonPlayback: Bool = false
        /// The body's name in its device info.
        public var model = "ILME-FX3"
        /// An FX6's Movie Play buttons (fixtures/fx6-playback-buttons-2026-10-29.jsonl), with Camera Operating Mode
        /// 0xD0BC and Movie Playing Speed 0xD030 served: on the live picture Prev opens the last take, paused, and
        /// Play Pause does nothing; in Playback Play plays, Play Pause only pauses, and Stop goes back to live.
        public var fx6Playback = false
        /// With `fx6Playback`: start in Playback, paused (0) or playing (1).
        public var fx6StartSpeed: Int32? = nil
        /// With `fx6Playback`, an FX5's: this many takes on the card, with Playback Contents Number and Total
        /// (0xD09E/0xD09F) served, disabled on the live picture. Prev there opens the take before the last, as an FX5's
        /// did (docs/fx5-controls.md); Next and Prev in Playback step through them.
        public var takes: UInt32? = nil
        /// With `takes`: the take Playback was left on. Prev on the live picture opens the one before it; nil, the
        /// newest, as after a cut.
        public var parkedTake: UInt32? = nil
        /// With `fx6Playback`: Prev presses on the live picture the camera ignores first, as an FX5 did once just
        /// after a cut.
        public var ignoredPrevs = 0
        /// An FX6 with an autofocus lens: Focus Speed Range 0xD008 (INT8, −8…8) and Follow Focus Position 0xE089 served;
        /// list Focus Operation (0xD2EF) in `controlCodes` too.
        public var fx6Lens = false
        /// Assignable buttons by number (1–9), each set to a function index (`assignableNames` names them), served as
        /// an FX6 does: assignment 0xE013+n, press 0xE028+n, indicator 0xE034+n.
        public var assignables: [Int: UInt8] = [:]
        /// SDIO_GetDisplayStringList type 0x0B (Button.Assign.ShortDisplayList): function index → short name.
        public var assignableNames: [UInt8: String] = [:]
        /// A wedged link, as far as one command goes: this many of a control's 0 (a stop) answered General Error.
        public var failedStops: [UInt16: Int] = [:]
        /// This many Ups (0x0001) to a property answered General Error: a button whose release didn't land.
        public var failedUps: [UInt16: Int] = [:]
        public init() {}
    }

    public enum RecordingStateSource: Sendable { case movieRecordingState, recorderMainStatus }

    /// `recordingState` (0xD21D terms) as an FX6/BURANO's recorder status 0xE010: Not Recording and
    /// Failed → Ready, Recording → Recording, Waiting → PreparingToRecord.
    private var recorderMainStatus: UInt8 {
        if stopping { return 0x05 }
        switch config.recordingState { case 0x01: return 0x04; case 0x03: return 0x02; default: return 0x01 }
    }
    /// The recorder closing a take (`Config.stopDelay`).
    private var stopping = false

    private var recordingStateCode: UInt16 {
        config.recordingStateSource == .movieRecordingState
            ? SDIPropCode.movieRecordingState.rawValue : SDIPropCode.recorderMainStatus.rawValue
    }

    public var config: Config
    public private(set) var connectionGUID: UUID? = nil
    @Locked public private(set) var lastTransactions: [FakeTransaction] = []
    /// Set to true when the initiator sends SDIO_SetExtDevicePropValue 0xD25A = 0x01
    public private(set) var positionKeySetToPCRemote: Bool = false
    /// Every SDIO_ControlDevice received, in order: control code and raw data phase.
    @Locked public private(set) var controls: [(code: UInt16, data: Data)] = []
    /// Camera Button Function presses (0xD309), in order: button id and ON (true) or OFF.
    @Locked public private(set) var buttonPresses: [(id: UInt16, on: Bool)] = []
    /// Arrows or ENTER pressed in Record mode, where a real FX3 runs its shooting shortcuts (peaking, zebras).
    public private(set) var shortcutPresses = 0
    /// Camera Operating Mode: 0x01 Record, 0x02 Playback (with `buttonPlayback`).
    public private(set) var operatingMode: UInt8 = 0x01
    /// With `fx6Playback`: Movie Playing Speed's numerator, nil on the live picture.
    public private(set) var fx6Speed: Int32?
    /// With `takes`: the take Playback has open (from 1), 0 on the live picture.
    public private(set) var takeNumber: UInt32 = 0
    private var prevsIgnored = 0
    public private(set) var clipPlaying = false
    /// A clip is open (playing or paused), not its own screen.
    private var clipOpen = false
    /// Which clip Playback shows: the arrows move it on a clip's own screen.
    public private(set) var clipIndex = 0

    /// The open clip plays to its end: the camera goes back to the clip's own screen, and says nothing.
    public func endClip() {
        clipOpen = false
        clipPlaying = false
    }
    /// Every SDIO_SetExtDevicePropValue received, in order: prop code and written data. The records a test polls while
    /// the camera works are `@Locked`.
    @Locked public private(set) var propWrites: [(code: UInt16, data: Data)] = []
    /// With `streaming`: the destinations (RTMP/RTMPS 1–3, SRT-Caller 1–3), each SDIO_SetStreamSettingList received
    /// (its Video Stream number and the list it sent), Stream Status, and the publisher while it streams.
    @Locked public private(set) var streamList = StreamSettingList(version: 100, streams:
        (0 ..< 3).map { _ in .init(protocolBits: StreamSettingList.StreamSetting.rtmp, permission: 0x01, url: "", key: "") }
        + (0 ..< 3).map { _ in .init(protocolBits: StreamSettingList.StreamSetting.srt, permission: 0x02, url: "", port: 7001,
                                     latency: 120, ttl: 64, cipherType: 0x01, cipherKey: "", mode: 0x02) })
    @Locked public private(set) var streamSets: [(slot: UInt32, list: StreamSettingList)] = []
    public private(set) var streamStatus: UInt8 = 0x02
    private var publishing: Task<Void, Never>?
    /// Last SDIUploadDataset received (for LUT import tests).
    public private(set) var lastUploadDataset: Data? = nil
    /// Last BaseLookImport Dataset received (slot index).
    public private(set) var lastImportSlot: UInt16? = nil

    private var listener: NWListener?
    private var cmdConnection: NWConnection?
    private var evtConnection: NWConnection?
    private let queue = DispatchQueue(label: "fake-camera", qos: .userInteractive)
    private var sessionID: UInt32 = 0
    private var phase3Done = false
    /// Property reads that arrived before SDIO_Connect phase 3 (with `eventBeforeSessionReady`, never answered).
    public private(set) var propReadsBeforeSessionReady = 0
    private var txCounter: UInt32 = 0
    private var transactionCount: Int = 0

    /// The port the listener is bound to (assigned by OS)
    public var port: UInt16 = 0

    public init(config: Config = Config()) {
        self.config = config
        if config.fx6Playback, let speed = config.fx6StartSpeed { operatingMode = 0x02; fx6Speed = speed }
    }

    // MARK: - Start / Stop

    public func start() async throws {
        // On 127.0.0.1 (LoopbackListener), again if the system says the address is in use.
        try await LoopbackListener.retrying { [self] in
            listener?.cancel()
            try await startListening()
        }
    }

    private func startListening() async throws {
        // Seed instance prop data from config overrides set before start().
        for (code, value) in config.fakePropData { fakePropData[code] = value }
        if let to = config.streamingTo {
            streamList.streams[to.slot - 1].url = to.url
            streamList.streams[to.slot - 1].key = to.key
            var target = Data(); target.appendLE(UInt16(to.slot))
            fakePropData[SDIPropCode.targetStreamingDestinationSelect.rawValue] = target
            streamStatus = 0x03
        }
        let params = NWParameters.tcp
        let l = try LoopbackListener.make(params)
        self.listener = l

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            l.newConnectionHandler = { [weak self] conn in
                self?.acceptConnection(conn)
            }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = l.port?.rawValue { self?.port = port }
                    if !resumed { resumed = true; cont.resume() }
                case .failed(let e), .waiting(let e):
                    // Left waiting (a port it can't have), it would never be ready: fail, not hang.
                    if !resumed { resumed = true; cont.resume(throwing: e) }
                default:
                    break
                }
            }
            l.start(queue: self.queue)
        }
    }

    public func stop() {
        publishing?.cancel()
        listener?.cancel()
        cmdConnection?.cancel()
        evtConnection?.cancel()
    }

    // MARK: - Connection acceptance

    private func acceptConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        // Which channel it is, from its first packet as PTP-IP has it: an Init Command Request opens a session, replacing
        // one a previous connect left whose connections this side hasn't seen close yet; an Init Event Request is its
        // event channel. Taken by order of arrival, a new session's command connection got the old one's event slot or
        // was dropped as a third, and the second of two overlapping connects failed with "Connection reset by peer"
        // (once in a full run).
        receivePacket(from: conn) { [weak self] data in
            guard let self else { return }
            guard let data, data.count >= 8 else { conn.cancel(); return }
            switch data.readLE(UInt32.self, at: 4) {
            case PTPIPPacketType.initCommandRequest.rawValue:
                if let old = self.cmdConnection, old !== conn { old.cancel() }
                self.cmdConnection = conn
                self.processCommandPacket(data, conn: conn)
            case PTPIPPacketType.initEventRequest.rawValue:
                if let old = self.evtConnection, old !== conn { old.cancel() }
                self.evtConnection = conn
                self.ackEventChannel(on: conn)
                self.handleEventChannel(conn)
            default:
                conn.cancel()
            }
        }
    }

    // MARK: - Command channel handler

    private func processCommandPacket(_ data: Data, conn: NWConnection) {
        // Dispatch directly via raw packet type — parsePTPIPPacket interprets in initiator context.
        handleRawCommandPacket(data, conn: conn)
    }

    private func handleRawCommandPacket(_ data: Data, conn: NWConnection) {
        guard data.count >= 8 else { return }
        let packetType = data.readLE(UInt32.self, at: 4)
        let payload = data.dropFirst(8)

        switch packetType {
        case PTPIPPacketType.initCommandRequest.rawValue:
            // Parse GUID
            if payload.count >= 16 {
                connectionGUID = UUID(bytes: Data(payload[payload.startIndex..<payload.startIndex+16]))
            }
            if config.rejectInit {
                sendInitFail(reason: .rejected, on: conn)
                // A rejected initiator doesn't hold the command slot: its next connection is a new command channel.
                if cmdConnection === conn { cmdConnection = nil }
                return
            }
            if config.approvalDelay > 0 {
                queue.asyncAfter(deadline: .now() + config.approvalDelay) {
                    self.sendInitCommandAck(on: conn)
                    self.continueCommandChannel(conn)
                }
            } else {
                sendInitCommandAck(on: conn)
                continueCommandChannel(conn)
            }

        default:
            break
        }
    }

    private func continueCommandChannel(_ conn: NWConnection) {
        receivePacket(from: conn) { [weak self] data in
            guard let self else { return }
            guard let data else { if self.cmdConnection === conn { self.cmdConnection = nil }; return }
            self.handlePTPOperation(data, conn: conn)
        }
    }

    private func handlePTPOperation(_ data: Data, conn: NWConnection) {
        guard data.count >= 8 else { return }
        let packetType = data.readLE(UInt32.self, at: 4)
        let payload = data.dropFirst(8)

        switch packetType {
        case PTPIPPacketType.cmdRequest.rawValue:
            guard payload.count >= 10 else { break }
            let opCode = payload.readLE(UInt16.self, at: 4)
            let txID = payload.readLE(UInt32.self, at: 6)
            let params: [UInt32] = (0..<min(5, (payload.count - 10) / 4)).map {
                payload.readLE(UInt32.self, at: 10 + $0 * 4)
            }
            lastTransactions.append(FakeTransaction(opCode: opCode, txID: txID, params: params, data: Data()))

            transactionCount += 1
            if config.killAfterTransactions > 0 && transactionCount >= config.killAfterTransactions {
                conn.cancel(); evtConnection?.cancel(); return
            }

            // If there's a data phase incoming (DataPhaseInfo = dataToResponder)
            let phaseInfo = payload.readLE(UInt32.self, at: 0)
            if phaseInfo == DataPhaseInfo.dataToResponder.rawValue {
                // Drain incoming data packets then dispatch, then continue reading
                drainDataPhase(txID: txID, conn: conn) { [weak self] inData in
                    guard let self else { return }
                    self.dispatchOperation(opCode: opCode, txID: txID, params: params, data: inData, conn: conn)
                    // Continue reading after full data phase is drained
                    self.receivePacket(from: conn) { [weak self] data in
                        guard let self else { return }
                        guard let data else { if self.cmdConnection === conn { self.cmdConnection = nil }; return }
                        self.handlePTPOperation(data, conn: conn)
                    }
                }
                return  // Don't fall through to the trailing receivePacket below

            } else {
                dispatchOperation(opCode: opCode, txID: txID, params: params, data: Data(), conn: conn)
            }

        case PTPIPPacketType.probeRequest.rawValue:
            sendPacket(buildPTPIPPacket(type: .probeResponse, payload: Data()), on: conn)

        default:
            break
        }

        // Continue reading (for non-data-phase operations)
        receivePacket(from: conn) { [weak self] data in
            guard let self else { return }
            guard let data else { if self.cmdConnection === conn { self.cmdConnection = nil }; return }
            self.handlePTPOperation(data, conn: conn)
        }
    }

    private func drainDataPhase(txID: UInt32, conn: NWConnection, completion: @escaping (Data) -> Void) {
        var accumulated = Data()
        func drain() {
            receivePacket(from: conn) { [weak self] data in
                guard self != nil, let data else { completion(accumulated); return }
                let pt = data.readLE(UInt32.self, at: 4)
                let payload = data.dropFirst(8)
                switch pt {
                case PTPIPPacketType.startData.rawValue:
                    drain()  // continue
                case PTPIPPacketType.data.rawValue:
                    accumulated.append(Data(payload.dropFirst(4)))
                    drain()
                case PTPIPPacketType.endData.rawValue:
                    accumulated.append(Data(payload.dropFirst(4)))
                    completion(accumulated)
                default:
                    // Unexpected: pass through
                    completion(accumulated)
                }
            }
        }
        drain()
    }

    private func dispatchOperation(opCode: UInt16, txID: UInt32, params: [UInt32], data: Data, conn: NWConnection) {
        switch opCode {
        case PTPOpCode.getDeviceInfo.rawValue:
            sendDataResponse(responsePayload: buildFakeDeviceInfo(), txID: txID,
                             responseCode: PTPResponseCode.ok.rawValue, conn: conn)

        case PTPOpCode.openSession.rawValue:
            sessionID = params.first ?? 1
            sendResponse(code: PTPResponseCode.ok.rawValue, txID: txID, on: conn)

        case PTPOpCode.closeSession.rawValue:
            sendResponse(code: PTPResponseCode.ok.rawValue, txID: txID, on: conn)

        case SDIOOpCode.connect.rawValue:
            // SDIO_Connect: respond with Data(0) + OK
            let phase = params.first ?? 0
            if phase == 3 { phase3Done = true }
            sendDataResponse(responsePayload: Data(count: 8), txID: txID, responseCode: PTPResponseCode.ok.rawValue, conn: conn)
            if config.eventBeforeSessionReady, phase == 2 {
                sendEvent(ParsedEvent(eventCode: PTPEventCode.devicePropChanged.rawValue, transactionID: 0, params: []))
            }

        case SDIOOpCode.getExtDeviceInfo.rawValue:
            // Return a minimal SDIExtDeviceInfo
            let infoData = buildFakeExtDeviceInfo()
            if config.eventBeforeSessionReady {
                // Late, as over the mesh: long enough for the backend's event batch window to run out first.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [self] in
                    sendDataResponse(responsePayload: infoData, txID: txID, responseCode: PTPResponseCode.ok.rawValue, conn: conn, responseParams: [0x0310])
                }
            } else {
                sendDataResponse(responsePayload: infoData, txID: txID, responseCode: PTPResponseCode.ok.rawValue, conn: conn, responseParams: [0x0310])  // vendorCodeVersion = 3.10
            }

        case SDIOOpCode.openSession.rawValue:
            if config.sdioOpenSessionUnsupported {
                sendResponse(code: PTPResponseCode.parameterNotSupported.rawValue, txID: txID, on: conn)
            } else if config.sdioOpenSessionAlreadyOpen {
                // Mirror FX3: 0x201E Session_Already_Open — initiator must treat as success
                sendResponse(code: PTPResponseCode.sessionAlreadyOpen.rawValue, txID: txID, params: [1], on: conn)
            } else {
                sendResponse(code: PTPResponseCode.ok.rawValue, txID: txID, on: conn)
            }

        case SDIOOpCode.getAllExtDevicePropInfo.rawValue:
            if config.eventBeforeSessionReady, !phase3Done {
                propReadsBeforeSessionReady += 1
                return  // the FX3 sits on it
            }
            if params.first == GetAllPropParam1.allData.rawValue, config.failFullPropFetches > 0 {
                config.failFullPropFetches -= 1
                sendResponse(code: PTPResponseCode.deviceBusy.rawValue, txID: txID, on: conn)
                return
            }
            let allData = buildFakePropInfoArray()
            sendDataResponse(responsePayload: allData, txID: txID, responseCode: PTPResponseCode.ok.rawValue, conn: conn)

        case SDIOOpCode.setExtDevicePropValue.rawValue:
            let propCode = params.first.map { UInt16($0 & 0xFFFF) }
            if let pc = propCode, data.first == 0x01, let n = config.failedUps[pc], n > 0 {
                config.failedUps[pc] = n - 1
                propWrites.append((code: pc, data: data))
                sendResponse(code: PTPResponseCode.generalError.rawValue, txID: txID, on: conn)
                return
            }
            if let pc = propCode { applyFakePropWrite(code: pc, data: data) }
            sendResponse(code: PTPResponseCode.ok.rawValue, txID: txID, on: conn)

        case SDIOOpCode.controlDevice.rawValue:
            let ctrlCode = params.first.map { UInt16($0 & 0xFFFF) }
            handleFakeControl(code: ctrlCode, data: data, txID: txID, conn: conn)

        case SDIOOpCode.getStreamSettingList.rawValue where config.streaming:
            sendDataResponse(responsePayload: streamList.encoded(permissions: true), txID: txID,
                             responseCode: PTPResponseCode.ok.rawValue, conn: conn)

        case SDIOOpCode.setStreamSettingList.rawValue where config.streaming:
            // One destination's list, for the Video Stream number in parameter 1, or the whole list. Result 0: OK.
            guard let slot = params.first, (1 ... 6).contains(slot),
                  let sent = try? StreamSettingList.parse(data, permissions: false) else {
                sendResponse(code: PTPResponseCode.ok.rawValue, txID: txID, params: [1], on: conn)
                return
            }
            streamSets.append((slot, sent))
            if sent.streams.count == 1, config.wantsWholeStreamList {
                sendResponse(code: PTPResponseCode.parameterNotSupported.rawValue, txID: txID, on: conn)
                return
            }
            let permissions = streamList.streams.map(\.permission)
            if sent.streams.count == 1 {
                streamList.streams[Int(slot) - 1] = sent.streams[0]
            } else if sent.streams.count == streamList.streams.count {
                streamList.streams = sent.streams
            }
            for i in streamList.streams.indices { streamList.streams[i].permission = permissions[i] }
            queue.asyncAfter(deadline: .now() + config.streamSetDelay) { [self] in
                sendResponse(code: PTPResponseCode.ok.rawValue, txID: txID, params: [0], on: conn)
            }

        case SDIOOpCode.uploadData.rawValue:
            // SDIO_UploadData (0x921A): accept and store the dataset
            lastUploadDataset = data
            sendResponse(code: PTPResponseCode.ok.rawValue, txID: txID, on: conn)

        case SDIOOpCode.controlUploadData.rawValue:
            // SDIO_ControlUploadData (0x921B): parse slot and fire SDIE_ControlUploadDataResult
            handleFakeLUTImport(data: data, txID: txID, conn: conn)

        case PTPOpCode.getObjectInfo.rawValue:
            // GetObjectInfo(0xFFFFC002): return ObjectInfo when live view enabled
            let handle = params.first ?? 0
            if handle == 0xFFFFC002 {
                if config.liveViewEnabled {
                    sendDataResponse(responsePayload: buildFakeLiveViewObjectInfo(),
                                     txID: txID, responseCode: PTPResponseCode.ok.rawValue, conn: conn)
                } else {
                    sendResponse(code: PTPResponseCode.parameterNotSupported.rawValue, txID: txID, on: conn)
                }
            } else {
                sendResponse(code: PTPResponseCode.parameterNotSupported.rawValue, txID: txID, on: conn)
            }

        case PTPOpCode.getObject.rawValue:
            // GetObject(0xFFFFC002): return LiveView Dataset when enabled
            let handle = params.first ?? 0
            if handle == 0xFFFFC002 {
                if config.liveViewEnabled {
                    sendDataResponse(responsePayload: buildFakeLiveViewDataset(),
                                     txID: txID, responseCode: PTPResponseCode.ok.rawValue, conn: conn)
                } else {
                    // 0x2009 = Invalid_Object_Handle when live view not enabled
                    sendResponse(code: PTPResponseCode.parameterNotSupported.rawValue, txID: txID, on: conn)
                }
            } else {
                sendResponse(code: PTPResponseCode.parameterNotSupported.rawValue, txID: txID, on: conn)
            }

        case SDIOOpCode.getDisplayStringList.rawValue:
            // Type 8: Camera.Gain.BaseISO.DisplayList, 0x01=High→ISO 12800, 0x02=Low→ISO 800. Anything else:
            // an empty list (tests that need names build their own datasets).
            if params.first == 0x00000008 {
                sendDataResponse(responsePayload: buildFakeBaseISODisplayStringList(), txID: txID,
                                 responseCode: PTPResponseCode.ok.rawValue, conn: conn)
            } else if params.first == 0x0000000B, !config.assignableNames.isEmpty {
                sendDataResponse(responsePayload: buildFakeDisplayStringList(type: 0x0B, config.assignableNames), txID: txID,
                                 responseCode: PTPResponseCode.ok.rawValue, conn: conn)
            } else if params.first == 0x00000015, !config.subjectNames.isEmpty {
                sendDataResponse(responsePayload: buildFakeDisplayStringList(type: 0x15, config.subjectNames), txID: txID,
                                 responseCode: PTPResponseCode.ok.rawValue, conn: conn)
            } else {
                var payload = Data()
                payload.appendLE(UInt32(8))   // offset to list
                payload.appendLE(UInt32(4))   // list size
                payload.appendLE(UInt16(0))   // ListTypeNum = 0
                payload.appendLE(UInt16(0))   // reserved
                sendDataResponse(responsePayload: payload, txID: txID, responseCode: PTPResponseCode.ok.rawValue, conn: conn)
            }

        default:
            sendResponse(code: PTPResponseCode.parameterNotSupported.rawValue, txID: txID, on: conn)
        }
    }

    private func handleFakeLUTImport(data: Data, txID: UInt32, conn: NWConnection) {
        // Parse BaseLookImport Dataset: Version(4) + BaseLookIndex(2)
        if data.count >= 6 {
            lastImportSlot = data.readLE(UInt16.self, at: 4)
        }
        sendResponse(code: PTPResponseCode.ok.rawValue, txID: txID, on: conn)

        // Fire SDIE_ControlUploadDataResult (0xC214) on the event channel
        let result: UInt32
        switch config.lutImportResult {
        case .ok:           result = 0x00000001
        case .ng:           result = 0x00000002
        case .ngInvalidName: result = 0x00000003
        case .ngBusy:       result = 0x00000004
        case .unknown:      return  // simulate no event (timeout test)
        }
        let event = ParsedEvent(
            eventCode: PTPEventCode.controlUploadDataResult.rawValue,
            transactionID: 0,
            params: [result, sdioControlUploadBaseLookImport]
        )
        queue.asyncAfter(deadline: .now() + config.lutImportDelay) {
            self.sendEvent(event)
        }
    }

    // MARK: - Event channel handler

    private func handleEventChannel(_ conn: NWConnection) {
        receivePacket(from: conn) { [weak self] data in
            guard let self else { return }
            guard let data else { if self.evtConnection === conn { self.evtConnection = nil }; return }
            // Init_Event_Request (type 0x3 per CIPA DC-005 §3.2.2): reply with Init_Event_Ack (type 0x4)
            if data.readLE(UInt32.self, at: 4) == PTPIPPacketType.initEventRequest.rawValue { self.ackEventChannel(on: conn) }
            // Keep reading (probes may arrive here) so a closed event channel is noticed and its slot freed.
            self.handleEventChannel(conn)
        }
    }

    private func ackEventChannel(on conn: NWConnection) {
        var ack = Data()
        ack.appendLE(UInt32(8))                               // Length = 8 (header only)
        ack.appendLE(PTPIPPacketType.initEventAck.rawValue)   // 0x00000004
        sendPacket(ack, on: conn)
    }

    // MARK: - Send helpers

    private func sendInitCommandAck(on conn: NWConnection) {
        var payload = Data()
        payload.appendLE(UInt32(1))  // ConnectionNumber
        payload.append(UUID().uuidBytes)
        payload.appendUTF16LEString("FakeCamera")
        payload.appendLE(ptpIPProtocolVersion)
        sendPacket(buildPTPIPPacket(type: .initCommandAck, payload: payload), on: conn)
    }

    private func sendInitFail(reason: InitFailReason, on conn: NWConnection) {
        var payload = Data()
        payload.appendLE(reason.rawValue)
        sendPacket(buildPTPIPPacket(type: .initFail, payload: payload), on: conn)
    }

    private func sendResponse(code: UInt16, txID: UInt32, params: [UInt32] = [], on conn: NWConnection) {
        var payload = Data()
        payload.appendLE(code)
        payload.appendLE(txID)
        for p in params { payload.appendLE(p) }
        sendPacket(buildPTPIPPacket(type: .cmdResponse, payload: payload), on: conn)
    }

    private func sendDataResponse(responsePayload: Data, txID: UInt32, responseCode: UInt16, conn: NWConnection, responseParams: [UInt32] = []) {
        // Start_Data + End_Data + Response
        sendPacket(buildStartData(transactionID: txID, totalLength: UInt64(responsePayload.count)), on: conn)
        sendPacket(buildEndData(transactionID: txID, data: responsePayload), on: conn)
        sendResponse(code: responseCode, txID: txID, params: responseParams, on: conn)
    }

    private func sendPacket(_ data: Data, on conn: NWConnection) {
        conn.send(content: data, completion: .idempotent)
    }

    func sendEvent(_ event: ParsedEvent) {
        guard let evt = evtConnection else { return }
        var payload = Data()
        payload.appendLE(event.eventCode)
        payload.appendLE(event.transactionID)
        for p in event.params { payload.appendLE(p) }
        sendPacket(buildPTPIPPacket(type: .event, payload: payload), on: evt)
    }

    // MARK: - Fake property data

    private var fakePropData: [UInt16: Data] = [:]

    private func applyFakePropWrite(code: UInt16, data: Data) {
        fakePropData[code] = data
        propWrites.append((code: code, data: data))
        // Update internal state for recording
        if code == SDIPropCode.movieRecordingState.rawValue, let v = data.first {
            config.recordingState = v
        }
        // Track Position Key Setting: 0x01 = PC Remote priority
        if code == SDIPropCode.positionKeySetting.rawValue, data.first == 0x01 {
            positionKeySetToPCRemote = true
        }
        if config.fx6Playback, data.first == 0x01 {  // a button let go
            let live = operatingMode == 0x01
            switch code {
            case SDIPropCode.moviePrevButton.rawValue where live && prevsIgnored < config.ignoredPrevs:
                prevsIgnored += 1
            case SDIPropCode.moviePrevButton.rawValue where live:
                operatingMode = 0x02; fx6Speed = 0
                if let takes = config.takes { takeNumber = max(1, (config.parkedTake ?? takes) - 1) }
            case SDIPropCode.moviePrevButton.rawValue where config.takes != nil: takeNumber = max(1, takeNumber - 1)
            case SDIPropCode.movieNextButton.rawValue where !live && config.takes != nil:
                takeNumber = min(config.takes ?? 0, takeNumber + 1)
            case SDIPropCode.moviePlayButton.rawValue where !live: fx6Speed = 1
            case SDIPropCode.moviePlayPauseButton.rawValue where !live && fx6Speed != 0: fx6Speed = 0
            case SDIPropCode.moviePlayStopButton.rawValue: operatingMode = 0x01; fx6Speed = nil; takeNumber = 0
            default: break
            }
        }
    }

    /// REC modeled on a real FX3 (fixtures/fx3-rec-hold-*.jsonl). Movie Rec Button (Hold) 0xD2C8 takes a
    /// UINT16: Down (0x0002) starts, Up (0x0001) stops, and both are absolute (no-op when already there). A control
    /// the body doesn't list (0xF001 on the FX3) or a wrongly sized data phase is answered OK and ignored. The
    /// toggle is modeled as acting on Down; no toggle-only body has been tested.
    private func handleFakeControl(code: UInt16?, data: Data, txID: UInt32, conn: NWConnection) {
        controls.append((code ?? 0, data))
        if config.streaming, code == SDIControlCode.streamButton.rawValue, data.count == 2 {
            let start = data[data.startIndex] == 0x02
            if start, config.streamSettingOn, streamStatus == 0x02 { startPublishing() }
            if !start, streamStatus == 0x03 { stopPublishing() }
            sendResponse(code: PTPResponseCode.ok.rawValue, txID: txID, on: conn)
            return
        }
        if let code, data.allSatisfy({ $0 == 0 }), let n = config.failedStops[code], n > 0 {
            config.failedStops[code] = n - 1
            sendResponse(code: PTPResponseCode.generalError.rawValue, txID: txID, on: conn)
            return
        }
        if code == SDIControlCode.cameraButtonFunction.rawValue, config.buttonPlayback, data.count == 4 {
            let value = data.readLE(UInt32.self, at: 0)
            let id = UInt16(value >> 16), on = value & 0xFFFF == 0x0002
            buttonPresses.append((id, on))
            if on {
                switch id {
                case CameraButton.playback.rawValue:
                    // A clip that's open (playing or paused) goes back to its own screen; that screen, to live.
                    if operatingMode == 0x02 && clipOpen { clipOpen = false; clipPlaying = false } else {
                        operatingMode = operatingMode == 0x02 ? 0x01 : 0x02
                        clipOpen = false
                        clipPlaying = false
                        sendEvent(ParsedEvent(eventCode: PTPEventCode.devicePropChanged.rawValue, transactionID: 0, params: []))
                    }
                case CameraButton.enter.rawValue where operatingMode == 0x02:
                    if clipOpen { clipPlaying.toggle() } else { clipOpen = true; clipPlaying = true }
                case CameraButton.left.rawValue where operatingMode == 0x02 && !clipOpen:
                    clipIndex -= 1
                case CameraButton.right.rawValue where operatingMode == 0x02 && !clipOpen:
                    clipIndex += 1
                default:
                    if operatingMode != 0x02 { shortcutPresses += 1 }
                }
            }
            sendResponse(code: PTPResponseCode.ok.rawValue, txID: txID, on: conn)
            return
        }
        if let code, config.controlCodes.contains(code), data.count == 2 {
            let value = UInt16(data[data.startIndex]) | UInt16(data[data.startIndex + 1]) << 8
            let recording = config.recordingState == 0x01
            var wants: Bool?
            if code == SDIControlCode.movieRecButtonHold.rawValue {
                if value == ButtonValue.down.rawValue { wants = true }
                if value == ButtonValue.up.rawValue { wants = false }
            } else if code == SDIControlCode.movieRecButtonToggle.rawValue, value == ButtonValue.down.rawValue {
                wants = !recording
            }
            if let wants, wants != recording {
                if !wants, config.ignoredStops > 0 { config.ignoredStops -= 1 } else { applyRec(start: wants) }
            }
        }
        sendResponse(code: PTPResponseCode.ok.rawValue, txID: txID, on: conn)
    }

    private func applyRec(start: Bool) {
        let propChanged = ParsedEvent(eventCode: PTPEventCode.devicePropChanged.rawValue, transactionID: 0, params: [])
        func result(_ ok: Bool) -> ParsedEvent {
            ParsedEvent(eventCode: PTPEventCode.movieRecOperationResults.rawValue, transactionID: 0, params: [ok ? 1 : 2])
        }
        if config.rejectRec { sendEvent(result(false)); return }
        sendEvent(result(true))
        if config.neverConfirmRec { return }  // accepted, but the state never changes: exercises the REC timeout
        if start && config.recConfirmDelay > 0 {
            config.recordingState = 0x03  // Waiting
            sendEvent(propChanged)
            queue.asyncAfter(deadline: .now() + config.recConfirmDelay) {
                self.config.recordingState = 0x01
                self.sendEvent(propChanged)
            }
        } else if !start && config.stopDelay > 0 && config.recordingStateSource == .recorderMainStatus {
            stopping = true
            sendEvent(propChanged)
            queue.asyncAfter(deadline: .now() + config.stopDelay) {
                self.stopping = false
                self.config.recordingState = 0x00
                self.sendEvent(propChanged)
            }
        } else {
            config.recordingState = start ? 0x01 : 0x00
            sendEvent(propChanged)
        }
    }

    func buildFakeDeviceInfo() -> Data {
        // Minimal PTP GetDeviceInfo response [PIMA 15740 §13.3.2]
        var d = Data()
        d.appendLE(UInt16(0x0064))   // StandardVersion = 100
        d.appendLE(UInt32(0x00000006)) // VendorExtensionID = Sony
        d.appendLE(UInt16(0x012C))   // VendorExtensionVersion = 3.00
        appendPTPStr(&d, "")         // VendorExtensionDesc
        d.appendLE(UInt16(0x0000))   // FunctionalMode
        appendPTPStrArray(&d, [UInt16]()) // OperationsSupported (empty)
        appendPTPStrArray(&d, [UInt16]()) // EventsSupported
        appendPTPStrArray(&d, [UInt16]()) // DevicePropertiesSupported
        appendPTPStrArray(&d, [UInt16]()) // CaptureFormats
        appendPTPStrArray(&d, [UInt16]()) // ImageFormats
        appendPTPStr(&d, "Sony")     // Manufacturer
        appendPTPStr(&d, config.model) // Model
        appendPTPStr(&d, "7.00")     // DeviceVersion
        appendPTPStr(&d, "0000001")  // SerialNumber
        return d
    }

    private func appendPTPStr(_ d: inout Data, _ s: String) {
        if s.isEmpty { d.append(UInt8(0)); return }
        let encoded = s.utf16.map { UInt16($0) } + [0]  // include null terminator
        d.append(UInt8(encoded.count))
        for ch in encoded { d.appendLE(ch) }
    }

    private func appendPTPStrArray(_ d: inout Data, _ arr: [UInt16]) {
        d.appendLE(UInt32(arr.count))
        for v in arr { d.appendLE(v) }
    }

    /// Camera.Gain.BaseISO.DisplayList (type 8): matches fx3-displaystringlist-baseiso.bin.
    /// 0x01 → "ISO 12800", 0x02 → "ISO 800". Datatype UINT8, two entries.
    /// PTP ObjectInfo for 0xFFFFC002 (live view handle). Minimal valid dataset.
    /// CompressedSize = estimated worst-case JPEG size.
    private func buildFakeLiveViewObjectInfo() -> Data {
        var d = Data()
        d.appendLE(UInt32(0))            // StorageID
        d.appendLE(UInt16(0x3801))       // ObjectFormat: JFIF/EXIF
        d.appendLE(UInt16(0x0000))       // ProtectionStatus
        d.appendLE(UInt32(64_000))       // ObjectCompressedSize (estimated worst-case)
        d.appendLE(UInt16(0))            // ThumbFormat
        d.appendLE(UInt32(0))            // ThumbCompressedSize
        d.appendLE(UInt32(0))            // ThumbPixWidth
        d.appendLE(UInt32(0))            // ThumbPixHeight
        d.appendLE(UInt32(0))            // ImagePixWidth
        d.appendLE(UInt32(0))            // ImagePixHeight
        d.appendLE(UInt32(0))            // ImageBitDepth
        d.appendLE(UInt32(0))            // ParentObject
        d.appendLE(UInt16(0))            // AssociationType
        d.appendLE(UInt32(0))            // AssociationDesc
        d.appendLE(UInt32(0))            // SequenceNumber
        d.append(0x00)                   // Filename: empty PTP string
        d.append(0x00)                   // DateCreated: empty
        d.append(0x00)                   // DateModified: empty
        d.append(0x00)                   // Keywords: empty
        return d
    }

    /// LiveView Dataset wrapping a minimal JPEG:
    /// Offset(4) + ImageSize(4) + FocalOffset(4) + FocalSize(4) + JPEG
    private func buildFakeLiveViewDataset() -> Data {
        let jpeg = FakePTPIPCamera.minimalJPEG
        var d = Data()
        d.appendLE(UInt32(16))                       // Offset to Live View Image
        d.appendLE(UInt32(jpeg.count))                // Live View Image Size
        d.appendLE(UInt32(UInt32(16 + jpeg.count)))   // Offset to Focal Frame Info
        d.appendLE(UInt32(0))                         // Focal Frame Info Size
        d.append(jpeg)
        return d
    }

    /// Minimal valid JPEG for dataset tests (FF D8 … FF D9).
    static let minimalJPEG: Data = {
        // Same 2×2 gray JPEG as MockCameraBackend.syntheticJPEG
        let bytes: [UInt8] = [
            0xFF,0xD8,0xFF,0xE0,0x00,0x10,0x4A,0x46,0x49,0x46,0x00,0x01,0x01,0x00,0x00,0x01,
            0x00,0x01,0x00,0x00,0xFF,0xDB,0x00,0x43,0x00,0x08,0x06,0x06,0x07,0x06,0x05,0x08,
            0x07,0x07,0x07,0x09,0x09,0x08,0x0A,0x0C,0x14,0x0D,0x0C,0x0B,0x0B,0x0C,0x19,0x12,
            0x13,0x0F,0x14,0x1D,0x1A,0x1F,0x1E,0x1D,0x1A,0x1C,0x1C,0x20,0x24,0x2E,0x27,0x20,
            0x22,0x2C,0x23,0x1C,0x1C,0x28,0x37,0x29,0x2C,0x30,0x31,0x34,0x34,0x34,0x1F,0x27,
            0x39,0x3D,0x38,0x32,0x3C,0x2E,0x33,0x34,0x32,0xFF,0xC0,0x00,0x0B,0x08,0x00,0x02,
            0x00,0x02,0x01,0x01,0x11,0x00,0xFF,0xC4,0x00,0x1F,0x00,0x00,0x01,0x05,0x01,0x01,
            0x01,0x01,0x01,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x02,0x03,0x04,
            0x05,0x06,0x07,0x08,0x09,0x0A,0x0B,0xFF,0xDA,0x00,0x08,0x01,0x01,0x00,0x00,0x3F,
            0x00,0xFB,0xD5,0xBF,0xFF,0xD9
        ]
        return Data(bytes)
    }()

    /// One display string list, UINT8 values, as `buildFakeBaseISODisplayStringList` lays out type 8.
    private func buildFakeDisplayStringList(type: UInt32, _ names: [UInt8: String]) -> Data {
        var body = Data()
        body.appendLE(UInt32(1))
        body.appendLE(type)
        body.appendLE(UInt16(0x0002))
        body.appendLE(UInt16(names.count))
        for (value, name) in names.sorted(by: { $0.key < $1.key }) {
            body.append(value)
            let s = Data((name + "\0").utf8)
            body.appendLE(UInt16(s.count))
            body.append(s)
        }
        var d = Data()
        d.appendLE(UInt32(8))
        d.appendLE(UInt32(body.count))
        d.append(body)
        return d
    }

    private func buildFakeBaseISODisplayStringList() -> Data {
        // Offset (4) + size (4) header
        let headerSize = 8
        var body = Data()
        body.appendLE(UInt32(1))           // 1 list type
        body.appendLE(UInt32(0x00000008))  // type 8 = Camera.Gain.BaseISO.DisplayList
        body.appendLE(UInt16(0x0002))      // UINT8 datatype
        body.appendLE(UInt16(2))           // 2 entries
        // Entry 1: value 0x01 = High = ISO 12800
        body.append(0x01)
        let s1 = Data("ISO 12800\0".utf8)
        body.appendLE(UInt16(s1.count))
        body.append(s1)
        // Entry 2: value 0x02 = Low = ISO 800
        body.append(0x02)
        let s2 = Data("ISO 800\0".utf8)
        body.appendLE(UInt16(s2.count))
        body.append(s2)

        var d = Data()
        d.appendLE(UInt32(headerSize))     // offset to payload
        d.appendLE(UInt32(body.count))     // size of payload
        d.append(body)
        return d
    }

    func buildFakeExtDeviceInfo() -> Data {
        var d = Data()
        d.appendLE(UInt16(0x0136))  // SDIExtensionVersion = 3.10 — FX3 v7
        // SDIDevicePropCode Array: count(4) + codes
        let propCodes: [UInt16] = [
            recordingStateCode,
            SDIPropCode.shutterAngle.rawValue,
            SDIPropCode.shutterMode.rawValue,
            SDIPropCode.shutterSpeed.rawValue,
            SDIPropCode.colorTemperature.rawValue,
            SDIPropCode.isoSensitivity.rawValue,
            SDIPropCode.gainBaseIso.rawValue,
            SDIPropCode.recordingFrameRate.rawValue,
            SDIPropCode.batteryRemaining.rawValue,
            SDIPropCode.fNumber.rawValue,
            SDIPropCode.focusMode.rawValue,
            SDIPropCode.baseLookValue.rawValue,
            SDIPropCode.monitorLUTSetting.rawValue,
            SDIPropCode.positionKeySetting.rawValue,
            SDIPropCode.uploadDatasetVersion.rawValue,
            SDIPropCode.baseLookImportCommandVersion.rawValue,
            SDIPropCode.baseLookImportOperationEnableStatus.rawValue,
            SDIPropCode.liveViewStatus.rawValue,
            SDIPropCode.liveViewImageQuality.rawValue,
        ]
        d.appendLE(UInt32(propCodes.count))
        for c in propCodes { d.appendLE(c) }
        // SDIControlCode Array
        let ctrlCodes = config.controlCodes + (config.buttonPlayback ? [SDIControlCode.cameraButtonFunction.rawValue] : [])
        d.appendLE(UInt32(ctrlCodes.count))
        for c in ctrlCodes { d.appendLE(c) }
        return d
    }

    func buildFakePropInfoArray() -> Data {
        let props = buildFakeProps()
        var d = Data()
        d.appendLE(UInt64(props.count))  // Num of Elements (UINT64)
        for prop in props { d.append(prop) }
        return d
    }

    private func buildFakeProps() -> [Data] {
        guard config.exposureIndex else { return buildBaseProps() }
        return buildBaseProps() + [
            makeProp(code: SDIPropCode.exposureIndex.rawValue, type: .uint16, getSet: .getSet, enabled: .enabled,
                     defaultVal: uint16LE(12800),
                     currentVal: fakePropData[SDIPropCode.exposureIndex.rawValue] ?? uint16LE(12800),
                     enumValues: [5000, 6400, 8000, 10000, 12800, 25600, 51200].map { uint16LE(UInt16($0)) }),
        ]
    }

    private func buildBaseProps() -> [Data] {
        // Shutter mode: 0x02 = Angle (FX3 default)
        let shutterModeVal = fakePropData[SDIPropCode.shutterMode.rawValue] ?? Data([0x02])
        let inAngleMode = shutterModeVal.first == 0x02
        return ([
            makeProp(code: recordingStateCode,
                     type: .uint8, getSet: .getOnly, enabled: .enabled,
                     defaultVal: Data([0x00]),
                     currentVal: Data([config.recordingStateSource == .movieRecordingState ? config.recordingState : recorderMainStatus])),
            makeProp(code: SDIPropCode.shutterAngle.rawValue,
                     type: .uint32, getSet: .getSet, enabled: inAngleMode ? .enabled : .dispOnly,
                     defaultVal: uint32LE(180_000), currentVal: fakePropData[SDIPropCode.shutterAngle.rawValue] ?? uint32LE(180_000),
                     enumValues: [90_000, 144_000, 172_800, 180_000, 270_000, 360_000].map { uint32LE($0) }),
            // Shutter mode: 0x01=Speed, 0x02=Angle
            makeProp(code: SDIPropCode.shutterMode.rawValue,
                     type: .uint8, getSet: .getSet, enabled: .enabled,
                     defaultVal: Data([0x02]), currentVal: shutterModeVal,
                     enumValues: [Data([0x01]), Data([0x02])]),
            // Shutter speed 0xD20D: disabled in angle mode; enumeration of UINT32 speeds
            makeProp(code: SDIPropCode.shutterSpeed.rawValue,
                     type: .uint32, getSet: .getSet, enabled: inAngleMode ? .disabled : .enabled,
                     defaultVal: uint32LE(0x00010032),  // 1/50
                     currentVal: fakePropData[SDIPropCode.shutterSpeed.rawValue] ?? uint32LE(0x00010032),
                     enumValues: [0x00010040, 0x00010032, 0x00010019, 0x00010014].map { uint32LE($0) }),  // 1/64,1/50,1/25,1/20
            makeProp(code: SDIPropCode.colorTemperature.rawValue,
                     type: .uint16, getSet: .getSet, enabled: .enabled,
                     defaultVal: uint16LE(5600), currentVal: fakePropData[SDIPropCode.colorTemperature.rawValue] ?? uint16LE(5600),
                     rangeMin: uint16LE(2500), rangeMax: uint16LE(9900), rangeStep: uint16LE(100)),
            makeProp(code: SDIPropCode.isoSensitivity.rawValue,
                     type: .uint32, getSet: .getSet, enabled: .enabled,
                     defaultVal: uint32LE(800), currentVal: fakePropData[SDIPropCode.isoSensitivity.rawValue] ?? uint32LE(800),
                     enumValues: [100, 200, 400, 800, 1600, 3200, 6400, 12800].map { uint32LE(UInt32($0)) }),
            // Gain Base ISO 0xD020: 0x01=High(12800), 0x02=Low(800)
            makeProp(code: SDIPropCode.gainBaseIso.rawValue,
                     type: .uint8, getSet: .getSet, enabled: .enabled,
                     defaultVal: Data([0x02]), currentVal: fakePropData[SDIPropCode.gainBaseIso.rawValue] ?? Data([0x02]),
                     enumValues: [Data([0x01]), Data([0x02])]),
            makeProp(code: SDIPropCode.recordingFrameRate.rawValue,
                     type: .uint8, getSet: .getSet, enabled: .enabled,
                     defaultVal: Data([FrameRateCode.fps2398.rawValue]),
                     currentVal: Data([FrameRateCode.fps2398.rawValue]),
                     enumValues: [FrameRateCode.fps2398.rawValue, FrameRateCode.fps2400.rawValue, FrameRateCode.fps25.rawValue].map { Data([$0]) }),
            makeProp(code: SDIPropCode.batteryRemaining.rawValue,
                     type: .uint8, getSet: .getOnly, enabled: .enabled,
                     defaultVal: Data([100]), currentVal: Data([85])),
            // F-Number 0x5007 (FX3 — no T-Number)
            makeProp(code: SDIPropCode.fNumber.rawValue,
                     type: .uint16, getSet: .getSet, enabled: .enabled,
                     defaultVal: uint16LE(280), currentVal: fakePropData[SDIPropCode.fNumber.rawValue] ?? uint16LE(280),
                     enumValues: [280, 320, 350, 400, 450, 500, 560, 630, 710, 800, 900, 1000, 1100].map { uint16LE(UInt16($0)) }),
            // Focus mode 0x500A: 0x8004=AF-C, 0x0001=MF
            makeProp(code: SDIPropCode.focusMode.rawValue,
                     type: .uint16, getSet: .getSet, enabled: .enabled,
                     defaultVal: uint16LE(0x8004), currentVal: fakePropData[SDIPropCode.focusMode.rawValue] ?? uint16LE(0x8004),
                     enumValues: [uint16LE(0x8004), uint16LE(0x0002), uint16LE(0x0001)]),  // AF-C, AF-S, MF
            // BaseLook 0xD03C: 3 presets + 3 user slots (mirrors FX3 fixture)
            makeProp(code: SDIPropCode.baseLookValue.rawValue,
                     type: .uint16, getSet: .getSet, enabled: .enabled,
                     defaultVal: uint16LE(0x0001), currentVal: fakePropData[SDIPropCode.baseLookValue.rawValue] ?? uint16LE(0x0001),
                     enumValues: [0x0001, 0x0002, 0x0003, 0x0101, 0x0102, 0x0103].map { uint16LE(UInt16($0)) }),
            // Monitor LUT Setting (All Line) 0xD04D: 0x01=OFF 0x02=ON
            makeProp(code: SDIPropCode.monitorLUTSetting.rawValue,
                     type: .uint8, getSet: .getSet, enabled: .enabled,
                     defaultVal: Data([0x01]), currentVal: fakePropData[SDIPropCode.monitorLUTSetting.rawValue] ?? Data([0x01]),
                     enumValues: [Data([0x01]), Data([0x02])]),
            // Position Key Setting
            makeProp(code: SDIPropCode.positionKeySetting.rawValue,
                     type: .uint8, getSet: .getSet, enabled: .enabled,
                     defaultVal: Data([0x00]), currentVal: fakePropData[SDIPropCode.positionKeySetting.rawValue] ?? Data([0x00]),
                     enumValues: [Data([0x00]), Data([0x01])]),
            // Upload Dataset Version 0xD057: UINT32 get-only
            makeProp(code: SDIPropCode.uploadDatasetVersion.rawValue,
                     type: .uint32, getSet: .getOnly, enabled: .enabled,
                     defaultVal: uint32LE(0x00000064), currentVal: uint32LE(0x00000064),  // version 100 (example from)
                     enumValues: [uint32LE(0x00000064)]),
            // BaseLookImport Command Version 0xD059: UINT32 get-only, IsEnabled=DispOnly
            makeProp(code: SDIPropCode.baseLookImportCommandVersion.rawValue,
                     type: .uint32, getSet: .getOnly, enabled: .dispOnly,
                     defaultVal: uint32LE(0x00000064), currentVal: uint32LE(0x00000064),
                     enumValues: [uint32LE(0x00000064)]),
            // BaseLookImport Operation Enable Status 0xD08B: UINT8 0x01=Enable
            makeProp(code: SDIPropCode.baseLookImportOperationEnableStatus.rawValue,
                     type: .uint8, getSet: .getOnly, enabled: .enabled,
                     defaultVal: Data([0x01]), currentVal: Data([0x01]),
                     enumValues: [Data([0x00]), Data([0x01])]),
            // Live View Status 0xD221: 0x00=Disabled 0x01=Enabled 0x02=Not Supported
            makeProp(code: SDIPropCode.liveViewStatus.rawValue,
                     type: .uint8, getSet: .getOnly, enabled: .enabled,
                     defaultVal: Data([0x00]),
                     currentVal: Data([config.liveViewEnabled ? 0x01 : 0x00]),
                     enumValues: [Data([0x00]), Data([0x01])]),
            // Live View Image Quality 0xD26A: 0x01=Low 0x02=High
            makeProp(code: SDIPropCode.liveViewImageQuality.rawValue,
                     type: .uint8, getSet: .getSet, enabled: .enabled,
                     defaultVal: Data([0x02]), currentVal: fakePropData[SDIPropCode.liveViewImageQuality.rawValue] ?? Data([0x02]),
                     enumValues: [Data([0x01]), Data([0x02])]),
        ] + extraProps() + buttonProps() + fx6PlaybackProps() + fx6LensProps() + assignableProps() + streamProps())
            .filter { prop in !config.omitPropCodes.contains(UInt16(prop[prop.startIndex]) | UInt16(prop[prop.startIndex + 1]) << 8) }
    }

    private func buttonProps() -> [Data] {
        guard config.buttonPlayback else { return [] }
        return [
            makeProp(code: SDIPropCode.cameraButtonList.rawValue, type: .uint16, getSet: .getOnly, enabled: .enabled,
                     defaultVal: uint16LE(0), currentVal: uint16LE(0),
                     enumValues: [0x01, 0x02, 0x03, 0x04, 0x05, 0x11].map { uint16LE(UInt16($0)) }),
            makeProp(code: SDIPropCode.cameraOperatingMode.rawValue, type: .uint8, getSet: .getOnly, enabled: .dispOnly,
                     defaultVal: Data([0x01]), currentVal: Data([operatingMode]), enumValues: [Data([0x01]), Data([0x02])]),
        ]
    }

    private func fx6LensProps() -> [Data] {
        guard config.fx6Lens else { return [] }
        return [
            makeProp(code: SDIPropCode.focusSpeedRange.rawValue, type: .int8, getSet: .getOnly, enabled: .enabled,
                     defaultVal: Data([0]), currentVal: Data([0]), rangeMin: Data([0xF8]), rangeMax: Data([0x08]),
                     rangeStep: Data([0x01])),
            makeProp(code: SDIPropCode.followFocusPosition.rawValue, type: .uint16, getSet: .getOnly, enabled: .dispOnly,
                     defaultVal: uint16LE(0x27E9), currentVal: uint16LE(0x27E9)),
        ]
    }

    private func assignableProps() -> [Data] {
        config.assignables.sorted { $0.key < $1.key }.flatMap { id, function -> [Data] in
            [makeProp(code: UInt16(0xE013 + id), type: .uint8, getSet: .getSet, enabled: .enabled,
                      defaultVal: Data([function]), currentVal: Data([function])),
             makeProp(code: UInt16(0xE028 + id), type: .uint16, getSet: .getSet, enabled: .enabled,
                      defaultVal: uint16LE(0x0001), currentVal: uint16LE(0x0001)),
             makeProp(code: UInt16(0xE034 + id), type: .uint8, getSet: .getOnly, enabled: .dispOnly,
                      defaultVal: Data([0x01]), currentVal: Data([0x01]))]
        }
    }

    /// An FX5's stream properties (`streaming`): what it writes is what it reads, and the
    /// bit rate's range follows the resolution (1.5–9 Mbps at 720p, 3–18 at 1080p, at 23.98).
    private func streamProps() -> [Data] {
        guard config.streaming else { return [] }
        func u16(_ v: UInt16) -> Data { var d = Data(); d.appendLE(v); return d }
        func u32(_ v: UInt32) -> Data { var d = Data(); d.appendLE(v); return d }
        func u64(_ v: UInt64) -> Data { var d = Data(); d.appendLE(v); return d }
        let resolutions: [UInt32] = [0x0F00_0870, 0x0780_0438, 0x0500_02D0]
        let resolution = fakePropData[SDIPropCode.videoStreamResolution.rawValue] ?? u32(0x0780_0438)
        let is720 = resolution == u32(0x0500_02D0)
        let streamStatus = config.streamSettingOn ? self.streamStatus : 0x01
        return [
            makeProp(code: SDIPropCode.videoStreamSelect.rawValue, type: .uint8, getSet: .getSet, enabled: .enabled,
                     defaultVal: Data([1]), currentVal: fakePropData[SDIPropCode.videoStreamSelect.rawValue] ?? Data([1]),
                     enumValues: (1 ... 6).map { Data([UInt8($0)]) }),
            makeProp(code: SDIPropCode.videoStreamCodec.rawValue, type: .uint16, getSet: .getSet, enabled: .dispOnly,
                     defaultVal: u16(3), currentVal: u16(3), enumValues: [u16(3)]),
            makeProp(code: SDIPropCode.videoStreamResolution.rawValue, type: .uint32, getSet: .getSet, enabled: .enabled,
                     defaultVal: u32(0x0780_0438), currentVal: resolution, enumValues: resolutions.map(u32)),
            makeProp(code: SDIPropCode.streamStatus.rawValue, type: .uint8, getSet: .getOnly, enabled: .dispOnly,
                     defaultVal: Data([1]), currentVal: Data([streamStatus])),
            makeProp(code: SDIPropCode.streamSettingListOperationEnableStatus.rawValue, type: .uint8, getSet: .getOnly,
                     enabled: .enabled, defaultVal: Data([1]), currentVal: Data([1]), enumValues: [Data([1]), Data([0])]),
            makeProp(code: SDIPropCode.targetStreamingDestinationSelect.rawValue, type: .uint16, getSet: .getSet,
                     enabled: .enabled, defaultVal: u16(1),
                     currentVal: fakePropData[SDIPropCode.targetStreamingDestinationSelect.rawValue] ?? u16(1),
                     enumValues: (1 ... 6).map { u16(UInt16($0)) }),
            makeProp(code: SDIPropCode.videoStreamMaxBitRate.rawValue, type: .uint64, getSet: .getSet, enabled: .enabled,
                     defaultVal: u64(6000), currentVal: fakePropData[SDIPropCode.videoStreamMaxBitRate.rawValue] ?? u64(6000),
                     rangeMin: u64(is720 ? 1500 : 3000), rangeMax: u64(is720 ? 9000 : 18000), rangeStep: u64(100)),
        ]
    }

    /// The Stream button down: Streaming, and the PYXIS's recorded stream published to the destination picked
    /// (`rtmp://<host>:<port>/<app>`, the key the stream's name), over and over until it's let go.
    private func startPublishing() {
        let target = fakePropData[SDIPropCode.targetStreamingDestinationSelect.rawValue].map { Int($0.readLE(UInt16.self, at: 0)) } ?? 1
        guard streamList.streams.indices.contains(target - 1),
              let url = URL(string: streamList.streams[target - 1].url), let port = url.port else { streamStatus = 0x04; return }
        let key = streamList.streams[target - 1].key ?? ""
        let app = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        streamStatus = 0x03
        publishing = Task.detached {
            guard let publisher = try? await RTMPTestPublisher(port: UInt16(port)) else { return }
            defer { publisher.close() }
            guard (try? await publisher.handshake()) != nil, (try? await publisher.publish(app: app, stream: key)) != nil,
                  let tags = try? FLVFixture.tags(in: FLVFixture.pyxisStream).filter({ $0.type == 9 }) else { return }
            while !Task.isCancelled {
                for tag in tags where !Task.isCancelled {
                    guard (try? await publisher.video(tag.data, timestamp: tag.timestamp)) != nil else { return }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }
    }

    private func stopPublishing() {
        publishing?.cancel()
        publishing = nil
        streamStatus = 0x02
    }

    private func fx6PlaybackProps() -> [Data] {
        guard config.fx6Playback else { return [] }
        var speed = Data()
        speed.appendLE(fx6Speed.map { UInt64(UInt32(bitPattern: $0)) << 32 | ($0 == 0 ? 0 : 1) } ?? UInt64.max)
        var takes: [Data] = []
        if let total = config.takes {
            let inPlayback = operatingMode == 0x02
            var number = Data(), count = Data(), zero = Data()
            number.appendLE(inPlayback ? takeNumber : 0); count.appendLE(inPlayback ? total : 0); zero.appendLE(UInt32(0))
            takes = [
                makeProp(code: SDIPropCode.playbackContentsNumber.rawValue, type: .uint32, getSet: .getOnly,
                         enabled: inPlayback ? .dispOnly : .disabled, defaultVal: zero, currentVal: number),
                makeProp(code: SDIPropCode.playbackContentsTotalNumber.rawValue, type: .uint32, getSet: .getOnly,
                         enabled: inPlayback ? .dispOnly : .disabled, defaultVal: zero, currentVal: count),
            ]
        }
        return [
            makeProp(code: SDIPropCode.cameraOperatingMode.rawValue, type: .uint8, getSet: .getOnly, enabled: .dispOnly,
                     defaultVal: Data([0x01]), currentVal: Data([operatingMode]), enumValues: [Data([0x01]), Data([0x02])]),
            makeProp(code: SDIPropCode.moviePlayingSpeed.rawValue, type: .uint64, getSet: .getOnly, enabled: .dispOnly,
                     defaultVal: speed, currentVal: speed),
        ] + takes
    }

    /// Any codes in fakePropData not already handled by buildFakeProps() are served as UINT16 GetSet enabled.
    /// Used by tests that inject playback button codes (0xE021–0xE028, 0xD02F, etc.).
    private func extraProps() -> [Data] {
        let knownCodes: Set<UInt16> = [
            SDIPropCode.movieRecordingState.rawValue, SDIPropCode.recorderMainStatus.rawValue, SDIPropCode.shutterAngle.rawValue,
            SDIPropCode.shutterMode.rawValue, SDIPropCode.shutterSpeed.rawValue,
            SDIPropCode.colorTemperature.rawValue, SDIPropCode.isoSensitivity.rawValue,
            SDIPropCode.gainBaseIso.rawValue, SDIPropCode.recordingFrameRate.rawValue,
            SDIPropCode.batteryRemaining.rawValue, SDIPropCode.fNumber.rawValue,
            SDIPropCode.focusMode.rawValue, SDIPropCode.baseLookValue.rawValue,
            SDIPropCode.monitorLUTSetting.rawValue, SDIPropCode.positionKeySetting.rawValue,
            SDIPropCode.uploadDatasetVersion.rawValue, SDIPropCode.baseLookImportCommandVersion.rawValue,
            SDIPropCode.baseLookImportOperationEnableStatus.rawValue,
            SDIPropCode.liveViewStatus.rawValue, SDIPropCode.liveViewImageQuality.rawValue,
            SDIPropCode.videoStreamSelect.rawValue, SDIPropCode.videoStreamResolution.rawValue,
            SDIPropCode.targetStreamingDestinationSelect.rawValue, SDIPropCode.videoStreamMaxBitRate.rawValue,
            SDIPropCode.streamDisplayName.rawValue,
        ]
        return fakePropData
            .filter { !knownCodes.contains($0.key) }
            .map { (code, value) in
                // Served GetSet enabled with the stored value: one byte as a UINT8 (an FX5's Focus Mode Setting), else UINT16
                makeProp(code: code, type: value.count == 1 ? .uint8 : .uint16, getSet: .getSet, enabled: .enabled,
                         defaultVal: value, currentVal: value,
                         enumValues: config.fakePropLists[code] ?? [value])
            }
    }

    private func makeProp(code: UInt16, type: SDIDataType, getSet: SDIGetSet, enabled: SDIIsEnabled,
                          defaultVal: Data, currentVal: Data,
                          enumValues: [Data] = [],
                          rangeMin: Data = Data(), rangeMax: Data = Data(), rangeStep: Data = Data()) -> Data {
        var d = Data()
        d.appendLE(code)
        d.appendLE(type.rawValue)
        d.append(getSet.rawValue)
        d.append(enabled.rawValue)
        d.append(defaultVal)
        d.append(currentVal)

        if !enumValues.isEmpty {
            d.append(SDIFormFlag.enumeration.rawValue)
            d.appendLE(UInt16(enumValues.count))
            for v in enumValues { d.append(v) }
            d.appendLE(UInt16(enumValues.count))
            for v in enumValues { d.append(v) }
        } else if rangeMin.count > 0 {
            d.append(SDIFormFlag.range.rawValue)
            d.append(rangeMin)
            d.append(rangeMax)
            d.append(rangeStep)
        } else {
            d.append(SDIFormFlag.none.rawValue)
        }
        return d
    }

    // MARK: - Receive loop

    private func receivePacket(from conn: NWConnection, handler: @escaping (Data?) -> Void) {
        // The connection calls back on the fake's queue, one receive at a time: the handler is never run concurrently.
        nonisolated(unsafe) let handler = handler
        conn.receive(minimumIncompleteLength: 8, maximumLength: 8) { data, _, _, error in
            guard error == nil, let header = data, header.count == 8 else { handler(nil); return }
            let length = header.readLE(UInt32.self, at: 0)
            let bodyLen = Int(length) - 8
            if bodyLen <= 0 {
                handler(header); return
            }
            conn.receive(minimumIncompleteLength: bodyLen, maximumLength: bodyLen) { body, _, _, err in
                guard err == nil, let body else { handler(nil); return }
                var full = header
                full.append(body)
                handler(full)
            }
        }
    }
}

// MARK: - Helpers

public struct FakeTransaction: Sendable {
    public let opCode: UInt16
    public let txID: UInt32
    public let params: [UInt32]
    public let data: Data
}

private func uint32LE(_ v: UInt32) -> Data {
    var d = Data(); d.appendLE(v); return d
}
private func uint16LE(_ v: UInt16) -> Data {
    var d = Data(); d.appendLE(v); return d
}

extension Data {
    mutating func append(_ byte: UInt8) {
        self.append(Data([byte]))
    }
}

extension SDIGetSet {
    var rawValue: UInt8 { self == .getSet ? 0x01 : 0x00 }
}
extension SDIIsEnabled {
    var rawValue: UInt8 {
        switch self {
        case .enabled: return 0x01
        case .disabled: return 0x00
        case .dispOnly: return 0x02
        }
    }
}
extension SDIFormFlag {
    var rawValue: UInt8 {
        switch self {
        case .none: return 0x00
        case .range: return 0x01
        case .enumeration: return 0x02
        }
    }
}

