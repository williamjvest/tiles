// PTP-IP packet encode/decode — CIPA DC-005-2005 framing
// All multi-byte fields are little-endian.

import Foundation

// MARK: - PTP-IP Packet Types (CIPA DC-005-2005)

/// PTP-IP PacketType codes: the standard values from CIPA DC-005 (the same as libgphoto2's ptpip.c), checked against
/// an FX3.
public enum PTPIPPacketType: UInt32 {
    case initCommandRequest  = 1  // I→R: GUID + FriendlyName + ProtocolVersion
    case initCommandAck      = 2  // R→I: ConnectionNumber + GUID + FriendlyName + ProtocolVersion
    case initEventRequest    = 3  // I→R: ConnectionNumber
    case initEventAck        = 4  // R→I: no payload
    case initFail            = 5  // R→I: Reason
    case cmdRequest          = 6  // I→R: DataPhaseInfo + OpCode + TransactionID + Params
    case cmdResponse         = 7  // R→I: ResponseCode + TransactionID + Params
    case event               = 8  // R→I: EventCode + TransactionID + Params
    case startData           = 9  // I↔R: TransactionID + TotalDataLength(8)
    case data                = 10 // I↔R: TransactionID + Payload
    case cancelTransaction   = 11 // I↔R: TransactionID
    case endData             = 12 // I↔R: TransactionID + Payload
    case probeRequest        = 13 // I↔R: keepalive, no payload
    case probeResponse       = 14 // I↔R: reply to probe
}

/// Init_Fail reason codes — standard PTP-IP
public enum InitFailReason: UInt32 {
    case rejected    = 0x00000001
    case busy        = 0x00000002
    case unspecified = 0x00000003
}

/// PTP-IP ProtocolVersion: major=1, minor=0 per CIPA DC-005
public let ptpIPProtocolVersion: UInt32 = 0x00010000

// MARK: - PTP Operation / Response Codes

/// Standard PTP operation codes
public enum PTPOpCode: UInt16 {
    case getDeviceInfo    = 0x1001
    case openSession      = 0x1002
    case closeSession     = 0x1003
    case getObjectInfo    = 0x1008
    case getObject        = 0x1009
}

/// Sony SDIO vendor operation codes
public enum SDIOOpCode: UInt16 {
    case connect                 = 0x9201
    case getExtDeviceInfo        = 0x9202
    case setExtDevicePropValue   = 0x9205
    case controlDevice           = 0x9207
    case getAllExtDevicePropInfo  = 0x9209
    case openSession             = 0x9210
    case getDisplayStringList    = 0x9215 // SDIO_GetDisplayStringList
    case uploadData              = 0x921A // SDIO_UploadData — send file to camera temp storage
    case controlUploadData       = 0x921B // SDIO_ControlUploadData — commit/import the upload
    case getOSDImage             = 0x9238 // PNG of the camera's on-screen display
    case getDeviceDescriptionFile = 0x923A
    case getStreamSettingList    = 0x9241 // SDIO_GetStreamSettingList: every stream destination (StreamSettingList)
    case setStreamSettingList    = 0x9242 // SDIO_SetStreamSettingList, param 1 the Video Stream number
}

/// PTP/SDIO response codes
public enum PTPResponseCode: UInt16 {
    case ok                        = 0x2001
    case generalError              = 0x2002
    case operationNotSupported     = 0x2005
    case deviceBusy                = 0x2006
    case parameterNotSupported     = 0x2009 // also used as Invalid_Object_Handle for GetObject
    case accessDenied              = 0x200F // GetObject on live view when frame not ready yet
    case sessionNotOpen            = 0x201D
    case sessionAlreadyOpen        = 0x201E // SDIO_OpenSession when session already active — treat as OK [FX3]
    case authenticationFailed      = 0xA101
}

/// PTP event codes used by Sony cameras
public enum PTPEventCode: UInt16 {
    case devicePropChanged          = 0xC203
    case operationResults           = 0xC222
    case movieRecOperationResults   = 0xC224
    case cautionDisplayEvent        = 0xC228
    case controlUploadDataResult    = 0xC214 // SDIE_ControlUploadDataResult: param1=result, param2=ControlType
}

// MARK: - DataPhaseInfo for Cmd_Request

/// DataPhaseInfo: 1=no data, 2=data I→R, 3=data R→I [CIPA DC-005-2005]
public enum DataPhaseInfo: UInt32 {
    case noDataOrUnknown = 0x00000001
    case dataToResponder = 0x00000002
    case dataToInitiator = 0x00000003
}

// MARK: - Raw packet builders

/// Builds a PTP-IP wire packet: [Length(4)][PacketType(4)][payload]
public func buildPTPIPPacket(type: PTPIPPacketType, payload: Data) -> Data {
    var out = Data(capacity: 8 + payload.count)
    let length = UInt32(8 + payload.count)
    out.appendLE(length)
    out.appendLE(type.rawValue)
    out.append(payload)
    return out
}

// MARK: - Init packets

/// Init_Command_Request: GUID(16) + FriendlyName(UTF-16LE null-term) + ProtocolVersion(4)
public func buildInitCommandRequest(guid: UUID, friendlyName: String) -> Data {
    var payload = Data()
    payload.append(guid.uuidBytes)
    payload.appendUTF16LEString(friendlyName)
    payload.appendLE(ptpIPProtocolVersion)
    return buildPTPIPPacket(type: .initCommandRequest, payload: payload)
}

/// Init_Event_Request: ConnectionNumber(4), sent on the event connection.
public func buildInitEventRequestPacket(connectionNumber: UInt32) -> Data {
    var payload = Data()
    payload.appendLE(connectionNumber)
    return buildPTPIPPacket(type: .initEventRequest, payload: payload)
}

// MARK: - Cmd_Request

public struct PTPTransaction {
    public let opCode: UInt16
    public let transactionID: UInt32
    public let params: [UInt32]
    public let dataPhase: DataPhaseInfo

    public init(opCode: UInt16, transactionID: UInt32, params: [UInt32] = [], dataPhase: DataPhaseInfo = .noDataOrUnknown) {
        self.opCode = opCode
        self.transactionID = transactionID
        self.params = params
        self.dataPhase = dataPhase
    }
}

/// Cmd_Request packet: DataPhaseInfo(4) + OpCode(2) + TransactionID(4) + Params(4×N)
public func buildCmdRequest(_ tx: PTPTransaction) -> Data {
    var payload = Data()
    payload.appendLE(tx.dataPhase.rawValue)
    payload.appendLE(tx.opCode)
    payload.appendLE(tx.transactionID)
    for p in tx.params { payload.appendLE(p) }
    return buildPTPIPPacket(type: .cmdRequest, payload: payload)
}

/// Start_Data_Packet: TransactionID(4) + TotalDataLength(8)
public func buildStartData(transactionID: UInt32, totalLength: UInt64) -> Data {
    var payload = Data()
    payload.appendLE(transactionID)
    payload.appendLE(totalLength)
    return buildPTPIPPacket(type: .startData, payload: payload)
}

/// End_Data_Packet: TransactionID(4) + Payload
public func buildEndData(transactionID: UInt32, data: Data) -> Data {
    var payload = Data()
    payload.appendLE(transactionID)
    payload.append(data)
    return buildPTPIPPacket(type: .endData, payload: payload)
}

/// Probe_Request: keepalive.
public func buildProbeRequest() -> Data {
    return buildPTPIPPacket(type: .probeRequest, payload: Data())
}

/// Probe_Response: answer to a camera's Probe_Request.
public func buildProbeResponse() -> Data {
    return buildPTPIPPacket(type: .probeResponse, payload: Data())
}

// MARK: - Parsed incoming packets

public struct ParsedInitCommandAck: Sendable {
    public let connectionNumber: UInt32
}

public struct ParsedCmdResponse: Sendable {
    public let responseCode: UInt16
    public let transactionID: UInt32
    public let params: [UInt32] // up to 5
}

public struct ParsedEvent: Sendable {
    public let eventCode: UInt16
    public let transactionID: UInt32
    public let params: [UInt32]
}

/// Parsed incoming PTP-IP packet
public enum IncomingPacket {
    case initCommandAck(ParsedInitCommandAck)
    case initEventAck
    case initFail(InitFailReason)
    case cmdResponse(ParsedCmdResponse)
    case event(ParsedEvent)
    case startData(transactionID: UInt32, totalLength: UInt64)
    case dataChunk(transactionID: UInt32, payload: Data)
    case endData(transactionID: UInt32, payload: Data)
    case probeRequest
    case probeResponse
    case unknown(type: UInt32)
}

/// Parse a single PTP-IP packet from its full wire bytes (including Length+PacketType header).
public func parsePTPIPPacket(_ bytes: Data) -> IncomingPacket {
    guard bytes.count >= 8 else { return .unknown(type: 0) }
    let packetType = bytes.readLE(UInt32.self, at: 4)
    let payload = bytes.dropFirst(8)

    switch packetType {
    case PTPIPPacketType.initCommandAck.rawValue:
        guard payload.count >= 4 else { return .unknown(type: packetType) }
        let connNum = payload.readLE(UInt32.self, at: 0)
        return .initCommandAck(ParsedInitCommandAck(connectionNumber: connNum))

    case PTPIPPacketType.initEventAck.rawValue:
        return .initEventAck

    case PTPIPPacketType.initFail.rawValue:
        let reason = payload.count >= 4 ? payload.readLE(UInt32.self, at: 0) : 0
        return .initFail(InitFailReason(rawValue: reason) ?? .unspecified)

    case PTPIPPacketType.cmdResponse.rawValue:
        guard payload.count >= 6 else { return .unknown(type: packetType) }
        let code = payload.readLE(UInt16.self, at: 0)
        let txID = payload.readLE(UInt32.self, at: 2)
        var params: [UInt32] = []
        var off = 6
        while off + 4 <= payload.count {
            params.append(payload.readLE(UInt32.self, at: off))
            off += 4
        }
        return .cmdResponse(ParsedCmdResponse(responseCode: code, transactionID: txID, params: params))

    case PTPIPPacketType.event.rawValue:
        guard payload.count >= 6 else { return .unknown(type: packetType) }
        let code = payload.readLE(UInt16.self, at: 0)
        let txID = payload.readLE(UInt32.self, at: 2)
        var params: [UInt32] = []
        var off = 6
        while off + 4 <= payload.count {
            params.append(payload.readLE(UInt32.self, at: off))
            off += 4
        }
        return .event(ParsedEvent(eventCode: code, transactionID: txID, params: params))

    case PTPIPPacketType.startData.rawValue:
        guard payload.count >= 12 else { return .unknown(type: packetType) }
        let txID = payload.readLE(UInt32.self, at: 0)
        let total = payload.readLE(UInt64.self, at: 4)
        return .startData(transactionID: txID, totalLength: total)

    case PTPIPPacketType.data.rawValue:
        guard payload.count >= 4 else { return .unknown(type: packetType) }
        let txID = payload.readLE(UInt32.self, at: 0)
        return .dataChunk(transactionID: txID, payload: Data(payload.dropFirst(4)))

    case PTPIPPacketType.endData.rawValue:
        guard payload.count >= 4 else { return .unknown(type: packetType) }
        let txID = payload.readLE(UInt32.self, at: 0)
        return .endData(transactionID: txID, payload: Data(payload.dropFirst(4)))

    case PTPIPPacketType.probeResponse.rawValue:
        return .probeResponse

    case PTPIPPacketType.probeRequest.rawValue:
        return .probeRequest

    default:
        return .unknown(type: packetType)
    }
}

// MARK: - Data encoding helpers

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }

    /// UTF-16LE null-terminated string
    mutating func appendUTF16LEString(_ s: String) {
        for unit in s.utf16 {
            appendLE(unit)
        }
        // null terminator
        appendLE(UInt16(0))
    }

    func readLE<T: FixedWidthInteger>(_ type: T.Type, at byteOffset: Int) -> T {
        let sz = MemoryLayout<T>.size
        let absOffset = startIndex + byteOffset
        guard absOffset + sz <= endIndex else { return 0 }
        var value: T = 0
        for i in 0..<sz { value |= T(self[absOffset + i]) << (i * 8) }
        return value
    }
}

/// Parse a UTF-16LE null-terminated string from Data (PTP-IP FriendlyName, Init_Command_Ack).
public func parseUTF16LEString(_ data: Data) -> String? {
    var units: [UInt16] = []
    var i = data.startIndex
    while i + 1 < data.endIndex {
        let unit = data.readLE(UInt16.self, at: i - data.startIndex)
        if unit == 0 { break }
        units.append(unit)
        i += 2
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(units.count * 2)
    for u in units { bytes.append(UInt8(u & 0xFF)); bytes.append(UInt8(u >> 8)) }
    return String(bytes: bytes, encoding: .utf16LittleEndian) ?? ""
}

// MARK: - UUID bytes helper

extension UUID {
    /// 16-byte big-endian UUID representation
    var uuidBytes: Data {
        var data = Data(count: 16)
        let (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p) = self.uuid
        data[0]=a; data[1]=b; data[2]=c; data[3]=d
        data[4]=e; data[5]=f; data[6]=g; data[7]=h
        data[8]=i; data[9]=j; data[10]=k; data[11]=l
        data[12]=m; data[13]=n; data[14]=o; data[15]=p
        return data
    }

    init(bytes: Data) {
        precondition(bytes.count == 16)
        self.init(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],
                         bytes[4],bytes[5],bytes[6],bytes[7],
                         bytes[8],bytes[9],bytes[10],bytes[11],
                         bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}

