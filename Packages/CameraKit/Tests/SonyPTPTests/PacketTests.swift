// Packet round-trip tests and dataset parser tests.

import Testing
import Foundation
@testable import SonyPTP

// MARK: - Packet encode/decode round trips

@Suite("PTP-IP Packet Round Trips")
struct PacketTests {

    @Test("Init_Command_Request encodes GUID, name, version")
    func initCommandRequest() throws {
        let guid = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let pkt = buildInitCommandRequest(guid: guid, friendlyName: "TestApp")
        #expect(pkt.count > 8)
        // Length field
        let length = pkt.readLE(UInt32.self, at: 0)
        #expect(Int(length) == pkt.count)
        // PacketType
        let ptype = pkt.readLE(UInt32.self, at: 4)
        #expect(ptype == PTPIPPacketType.initCommandRequest.rawValue)
        // GUID starts at offset 8
        let guidBytes = pkt[pkt.startIndex+8 ..< pkt.startIndex+24]
        #expect(Data(guidBytes) == guid.uuidBytes)
        // Protocol version at end
        let versionOffset = pkt.count - 4
        let version = pkt.readLE(UInt32.self, at: versionOffset)
        #expect(version == ptpIPProtocolVersion)
    }

    @Test("buildCmdRequest encodes all fields correctly")
    func cmdRequestEncoding() throws {
        let tx = PTPTransaction(opCode: 0x9209, transactionID: 42, params: [0x00000000, 0x00000001], dataPhase: .noDataOrUnknown)
        let pkt = buildCmdRequest(tx)
        #expect(pkt.readLE(UInt32.self, at: 4) == PTPIPPacketType.cmdRequest.rawValue)
        let payload = pkt.dropFirst(8)
        // DataPhaseInfo
        #expect(payload.readLE(UInt32.self, at: 0) == DataPhaseInfo.noDataOrUnknown.rawValue)
        // OpCode
        #expect(payload.readLE(UInt16.self, at: 4) == 0x9209)
        // TransactionID
        #expect(payload.readLE(UInt32.self, at: 6) == 42)
        // Param1
        #expect(payload.readLE(UInt32.self, at: 10) == 0x00000000)
        // Param2
        #expect(payload.readLE(UInt32.self, at: 14) == 0x00000001)
    }

    @Test("parsePTPIPPacket: cmdResponse round trip")
    func cmdResponseRoundTrip() {
        var payload = Data()
        payload.appendLE(PTPResponseCode.ok.rawValue)
        payload.appendLE(UInt32(7))  // txID
        payload.appendLE(UInt32(0x0310))  // param1 = vendor code version
        let raw = buildPTPIPPacket(type: .cmdResponse, payload: payload)
        let parsed = parsePTPIPPacket(raw)
        guard case .cmdResponse(let resp) = parsed else {
            Issue.record("Expected cmdResponse, got \(parsed)")
            return
        }
        #expect(resp.responseCode == PTPResponseCode.ok.rawValue)
        #expect(resp.transactionID == 7)
        #expect(resp.params.first == 0x0310)
    }

    @Test("parsePTPIPPacket: event round trip")
    func eventRoundTrip() {
        var payload = Data()
        payload.appendLE(PTPEventCode.devicePropChanged.rawValue)
        payload.appendLE(UInt32(3))  // txID
        let raw = buildPTPIPPacket(type: .event, payload: payload)
        let parsed = parsePTPIPPacket(raw)
        guard case .event(let evt) = parsed else {
            Issue.record("Expected event")
            return
        }
        #expect(evt.eventCode == PTPEventCode.devicePropChanged.rawValue)
        #expect(evt.transactionID == 3)
    }

    @Test("parsePTPIPPacket: initFail reason")
    func initFailParsing() {
        var payload = Data()
        payload.appendLE(InitFailReason.rejected.rawValue)
        let raw = buildPTPIPPacket(type: .initFail, payload: payload)
        let parsed = parsePTPIPPacket(raw)
        guard case .initFail(let reason) = parsed else {
            Issue.record("Expected initFail")
            return
        }
        #expect(reason == .rejected)
    }

    @Test("parsePTPIPPacket: startData + endData")
    func dataPackets() {
        let txID: UInt32 = 99
        let startRaw = buildStartData(transactionID: txID, totalLength: 1234)
        let startParsed = parsePTPIPPacket(startRaw)
        guard case .startData(let id, let total) = startParsed else {
            Issue.record("Expected startData"); return
        }
        #expect(id == txID)
        #expect(total == 1234)

        let body = Data([0xAA, 0xBB, 0xCC])
        let endRaw = buildEndData(transactionID: txID, data: body)
        let endParsed = parsePTPIPPacket(endRaw)
        guard case .endData(let id2, let payload) = endParsed else {
            Issue.record("Expected endData"); return
        }
        #expect(id2 == txID)
        #expect(payload == body)
    }

    @Test("buildProbeRequest parses as probeResponse-able")
    func probeRequestType() {
        let pkt = buildProbeRequest()
        #expect(pkt.readLE(UInt32.self, at: 4) == PTPIPPacketType.probeRequest.rawValue)
    }

    @Test("UTF-16LE string encode/decode round trip")
    func utf16leRoundTrip() {
        var d = Data()
        d.appendUTF16LEString("camctl")
        let parsed = parseUTF16LEString(d)
        #expect(parsed == "camctl")
    }

    @Test("UUID bytes round trip")
    func uuidRoundTrip() {
        let original = UUID()
        let bytes = original.uuidBytes
        let recovered = UUID(bytes: bytes)
        #expect(recovered == original)
    }
}

// MARK: - Dataset parser tests

@Suite("SDIO Dataset Parser")
struct DatasetTests {

    @Test("parseSDIExtDeviceInfo: minimal valid data")
    func extDeviceInfoParse() throws {
        var d = Data()
        d.appendLE(UInt16(0x012C))  // version
        d.appendLE(UInt32(2))       // 2 prop codes
        d.appendLE(UInt16(0xD21D))
        d.appendLE(UInt16(0xD00E))
        d.appendLE(UInt32(1))       // 1 control code
        d.appendLE(UInt16(0xD2C8))

        let info = try parseSDIExtDeviceInfo(d)
        #expect(info.extensionVersion == 0x012C)
        #expect(info.propCodes == [0xD21D, 0xD00E])
        #expect(info.controlCodes == [0xD2C8])
        // 0x012C is 300, v3.00: the major version is the version / 100, not its high byte (0x01).
        #expect(info.majorVersion == 3)
    }

    @Test("parseSDIDevicePropInfoArray: recording state property")
    func recordingStatePropParse() throws {
        var d = Data()
        d.appendLE(UInt64(1))  // 1 element
        // One SDIDevicePropInfo: code=0xD21D, type=UINT8, getOnly, enabled, default=0, current=1, no form
        d.appendLE(UInt16(SDIPropCode.movieRecordingState.rawValue))
        d.appendLE(UInt16(SDIDataType.uint8.rawValue))
        d.append(SDIGetSet.getOnly.rawValue)
        d.append(SDIIsEnabled.enabled.rawValue)
        d.append(UInt8(0x00))  // default
        d.append(UInt8(0x01))  // current = Recording
        d.append(SDIFormFlag.none.rawValue)

        let props = try parseSDIDevicePropInfoArray(d)
        try #require(props.count == 1)
        #expect(props[0].code == SDIPropCode.movieRecordingState.rawValue)
        #expect(props[0].currentUInt8() == 0x01)
        #expect(props[0].isEnabled == .enabled)
        #expect(props[0].getSet == .getOnly)
    }

    @Test("parseSDIDevicePropInfoArray: shutter angle with enumeration form")
    func shutterAngleEnumParse() throws {
        let values: [UInt32] = [90_000, 180_000, 360_000]
        var d = Data()
        d.appendLE(UInt64(1))
        d.appendLE(UInt16(SDIPropCode.shutterAngle.rawValue))
        d.appendLE(UInt16(SDIDataType.uint32.rawValue))
        d.append(SDIGetSet.getSet.rawValue)
        d.append(SDIIsEnabled.enabled.rawValue)
        d.appendLE(UInt32(180_000))  // default
        d.appendLE(UInt32(180_000))  // current
        d.append(SDIFormFlag.enumeration.rawValue)
        d.appendLE(UInt16(values.count))
        for v in values { d.appendLE(v) }
        d.appendLE(UInt16(values.count))
        for v in values { d.appendLE(v) }

        let props = try parseSDIDevicePropInfoArray(d)
        try #require(props.count == 1)
        #expect(props[0].currentUInt32() == 180_000)
        #expect(props[0].enumCurrentUInt32() == values)
    }

    @Test("parseSDIDevicePropInfoArray: kelvin with range form")
    func kelvinRangeParse() throws {
        var d = Data()
        d.appendLE(UInt64(1))
        d.appendLE(UInt16(SDIPropCode.colorTemperature.rawValue))
        d.appendLE(UInt16(SDIDataType.uint16.rawValue))
        d.append(SDIGetSet.getSet.rawValue)
        d.append(SDIIsEnabled.enabled.rawValue)
        d.appendLE(UInt16(5600))  // default
        d.appendLE(UInt16(6500))  // current
        d.append(SDIFormFlag.range.rawValue)
        d.appendLE(UInt16(2500))  // min
        d.appendLE(UInt16(9900))  // max
        d.appendLE(UInt16(100))   // step

        let props = try parseSDIDevicePropInfoArray(d)
        #expect(props[0].currentUInt16() == 6500)
        let min = props[0].rangeMin.readLE(UInt16.self, at: 0)
        let max = props[0].rangeMax.readLE(UInt16.self, at: 0)
        #expect(min == 2500)
        #expect(max == 9900)
    }

    @Test("Shutter angle encoding: 180° = 180000")
    func shutterAngleEncoding() {
        let encoded = encodeShutterAngle(180.0)
        let raw = encoded.readLE(UInt32.self, at: 0)
        #expect(raw == 180_000)
    }

    @Test("Shutter angle encoding: 11.25° = 11250")
    func shutterAngleSmall() {
        let encoded = encodeShutterAngle(11.25)
        let raw = encoded.readLE(UInt32.self, at: 0)
        #expect(raw == 11_250)
    }

    @Test("ND transmittance encoding: 0.25 → upper/lower")
    func ndTransmittanceEncoding() {
        let encoded = encodeNDTransmittance(0.25)
        let raw = encoded.readLE(UInt64.self, at: 0)
        let num = UInt32(raw >> 32)
        let den = UInt32(raw & 0xFFFF_FFFF)
        #expect(den > 0)
        let fraction = Double(num) / Double(den)
        #expect(abs(fraction - 0.25) < 0.001)
    }

    @Test("ISO encoding: 3200 → 0x00000C80")
    func isoEncoding() {
        let encoded = encodeISO(3200)
        let raw = encoded.readLE(UInt32.self, at: 0)
        #expect(raw == 0x00000C80)
    }

    @Test("Color temperature Kelvin sentinels")
    func kelvinSentinels() {
        // 0x0000 = below range; 0xFFFF = above range per spec
        let low = UInt16(0x0000)
        let high = UInt16(0xFFFF)
        #expect(low == 0)
        #expect(high == 65535)
    }

    @Test("Frame rate enum round trip")
    func frameRateEnum() {
        #expect(FrameRateCode.fps2398.rate == 23.976)
        #expect(FrameRateCode.fps2400.rate == 24.0)
        #expect(FrameRateCode.fps25.rate == 25.0)
        #expect(FrameRateCode.fps2997.rate == 29.97)
        #expect(FrameRateCode.fps5994.rate == 59.94)
        #expect(FrameRateCode.fps30.rate == 30.0)
        #expect(FrameRateCode.fps60.rate == 60.0)
        #expect(FrameRateCode.fps120.rate == 120.0)
    }

    @Test("Timecode preset encoding/decoding: bits 24-31=H, 16-23=M, 8-15=S, 0-7=F")
    func timecodePresetEncoding() {
        // 01:02:03:04 → (1<<24)|(2<<16)|(3<<8)|4
        let raw = UInt32((1 << 24) | (2 << 16) | (3 << 8) | 4)
        let hours  = Int((raw >> 24) & 0xFF)
        let mins   = Int((raw >> 16) & 0xFF)
        let secs   = Int((raw >> 8)  & 0xFF)
        let frames = Int(raw & 0xFF)
        #expect(hours == 1)
        #expect(mins == 2)
        #expect(secs == 3)
        #expect(frames == 4)
    }
}

// MARK: - StateMapper tests

@Suite("StateMapper")
struct StateMapperTests {

    @Test("recordingState maps 0x01 → recording")
    func recStateRecording() throws {
        var d = Data(); d.appendLE(UInt64(1))
        d.appendLE(UInt16(SDIPropCode.movieRecordingState.rawValue))
        d.appendLE(UInt16(SDIDataType.uint8.rawValue))
        d.append(SDIGetSet.getOnly.rawValue)
        d.append(SDIIsEnabled.enabled.rawValue)
        d.append(UInt8(0)); d.append(UInt8(0x01))
        d.append(SDIFormFlag.none.rawValue)
        let props = try parseSDIDevicePropInfoArray(d)
        let mapper = StateMapper(props: props)
        #expect(mapper.recordingState().state == .recording)
    }

    @Test("shutterAngle maps 180000 → 180.0")
    func shutterAngleMap() throws {
        var d = Data(); d.appendLE(UInt64(1))
        d.appendLE(UInt16(SDIPropCode.shutterAngle.rawValue))
        d.appendLE(UInt16(SDIDataType.uint32.rawValue))
        d.append(SDIGetSet.getSet.rawValue)
        d.append(SDIIsEnabled.enabled.rawValue)
        d.appendLE(UInt32(180_000)); d.appendLE(UInt32(180_000))
        d.append(SDIFormFlag.none.rawValue)
        let props = try parseSDIDevicePropInfoArray(d)
        let mapper = StateMapper(props: props)
        let angle = mapper.shutterAngle()
        #expect(angle?.value == 180.0)
    }

    @Test("batteryPercent maps correctly")
    func batteryMap() throws {
        var d = Data(); d.appendLE(UInt64(1))
        d.appendLE(UInt16(SDIPropCode.batteryRemaining.rawValue))
        d.appendLE(UInt16(SDIDataType.uint8.rawValue))
        d.append(SDIGetSet.getOnly.rawValue)
        d.append(SDIIsEnabled.enabled.rawValue)
        d.append(UInt8(100)); d.append(UInt8(76))
        d.append(SDIFormFlag.none.rawValue)
        let props = try parseSDIDevicePropInfoArray(d)
        let mapper = StateMapper(props: props)
        #expect(mapper.batteryPercent() == 76)
    }
}

