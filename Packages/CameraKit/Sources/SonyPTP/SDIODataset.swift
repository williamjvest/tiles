// Sony SDIO dataset encodings and property/control codes.
// Every constant has a [Lnnnn] citation into the vendor reference text.

import Foundation

// MARK: - SDIExtDeviceInfo Dataset

/// SDIExtDeviceInfo returned by SDIO_GetExtDeviceInfo (0x9202)
/// Layout: SDIExtensionVersion(2) + SDIDevicePropCode Array (UINT16[]) + SDIControlCode Array (UINT16[])
public struct SDIExtDeviceInfo: Sendable {
    public let extensionVersion: UInt16    // major=0x03 required
    public let propCodes: [UInt16]
    public let controlCodes: [UInt16]

    /// Initiator version to send: 0x012C = v3.00
    public static let initiatorVersion: UInt32 = 0x012C

    /// Major version: 0x012C = 300 decimal = v3.00, so major = extensionVersion / 100
    public var majorVersion: UInt8 { UInt8(extensionVersion / 100) }
}

/// Parse SDIExtDeviceInfo from raw response data
public func parseSDIExtDeviceInfo(_ data: Data) throws -> SDIExtDeviceInfo {
    var cursor = 0

    guard data.count >= 2 else { throw PTPError.malformedData("SDIExtDeviceInfo too short") }
    let version = data.readLE(UInt16.self, at: cursor); cursor += 2

    // SDIDevicePropCode Array: UINT32 count + UINT16[] entries
    guard cursor + 4 <= data.count else { throw PTPError.malformedData("Missing prop count") }
    let propCount = Int(data.readLE(UInt32.self, at: cursor)); cursor += 4
    guard cursor + propCount * 2 <= data.count else { throw PTPError.malformedData("Prop array overrun") }
    let props = (0..<propCount).map { i -> UInt16 in
        data.readLE(UInt16.self, at: cursor + i * 2)
    }
    cursor += propCount * 2

    // SDIControlCode Array: UINT32 count + UINT16[] entries
    guard cursor + 4 <= data.count else {
        // Older firmware may omit controls section; tolerate
        return SDIExtDeviceInfo(extensionVersion: version, propCodes: props, controlCodes: [])
    }
    let ctrlCount = Int(data.readLE(UInt32.self, at: cursor)); cursor += 4
    guard cursor + ctrlCount * 2 <= data.count else { throw PTPError.malformedData("Control array overrun") }
    let ctrls = (0..<ctrlCount).map { data.readLE(UInt16.self, at: cursor + $0 * 2) }

    return SDIExtDeviceInfo(extensionVersion: version, propCodes: props, controlCodes: ctrls)
}

// MARK: - SDIDevicePropInfo Dataset

/// DataType codes
/// Scalar types 0x0001–0x0008, array types 0x4001–0x4008 (UINT32-prefixed element arrays),
/// STR 0xFFFF (PTP string: 1-byte char-count + UTF-16LE chars including null terminator).
public enum SDIDataType: UInt16, Sendable {
    case int8    = 0x0001 // [L table §4.2]
    case uint8   = 0x0002
    case int16   = 0x0003
    case uint16  = 0x0004
    case int32   = 0x0005
    case uint32  = 0x0006
    case int64   = 0x0007
    case uint64  = 0x0008
    // Array variants: element type = rawValue & 0x00FF
    case aint8   = 0x4001
    case auint8  = 0x4002
    case aint16  = 0x4003
    case auint16 = 0x4004
    case aint32  = 0x4005
    case auint32 = 0x4006
    case aint64  = 0x4007
    case auint64 = 0x4008
    case str     = 0xFFFF // PTP string [parser.cpp DataTypeSTR]
    case unknown = 0xFFFE // sentinel for unrecognised codes

    /// Byte size of one scalar element; 0 for array and STR types.
    public var byteSize: Int {
        switch self {
        case .int8,  .uint8:  return 1
        case .int16, .uint16: return 2
        case .int32, .uint32: return 4
        case .int64, .uint64: return 8
        default: return 0
        }
    }

    /// Whether this is an array type (0x4001–0x4008). [parser.cpp DataTypeArray]
    public var isArray: Bool { rawValue >= 0x4001 && rawValue <= 0x4008 }

    /// Scalar element type for array variants (e.g. .auint32 → .uint32).
    public var elementType: SDIDataType? {
        guard isArray else { return nil }
        return SDIDataType(rawValue: rawValue & 0x00FF)
    }
}

/// FormFlag values
public enum SDIFormFlag: UInt8, Sendable {
    case none        = 0x00
    case range       = 0x01
    case enumeration = 0x02
}

/// GetSet flag
public enum SDIGetSet: UInt8, Sendable {
    case getOnly = 0x00
    case getSet  = 0x01
}

/// IsEnabled flag
public enum SDIIsEnabled: UInt8, Sendable {
    case disabled = 0x00
    case enabled  = 0x01
    case dispOnly = 0x02
}

/// Parsed property from SDIDevicePropInfo Dataset
///
/// For scalar types (int8..uint64): `currentValue` / `defaultValue` hold the raw LE bytes.
/// For STR (0xFFFF): `stringValue` / `defaultStringValue` hold the decoded string.
/// For array types (0x4001–0x4008): `arrayValues` / `defaultArrayValues` hold element bytes.
/// Enum lists follow the same convention as the scalar currentValue.
public struct SDIDevicePropInfo: Sendable {
    public let code: UInt16
    public let dataType: SDIDataType
    public let getSet: SDIGetSet
    public let isEnabled: SDIIsEnabled
    // Scalar
    public let defaultValue: Data
    public let currentValue: Data
    // STR
    public let defaultStringValue: String
    public let stringValue: String
    // Array (each element is one element's raw LE bytes, sized per elementType)
    public let defaultArrayValues: [Data]
    public let arrayValues: [Data]
    // Form
    public let formFlag: SDIFormFlag
    public let rangeMin: Data
    public let rangeMax: Data
    public let rangeStep: Data
    public let enumValues: [Data]    // settable list (Enumeration-Form set list)
    public let enumValuesAll: [Data] // get+set list
}

/// SDIDevicePropInfo Dataset Array
/// Layout: Num of Elements(8=UINT64) + SDIDevicePropInfo[0..N-1]
public func parseSDIDevicePropInfoArray(_ data: Data) throws -> [SDIDevicePropInfo] {
    guard data.count >= 8 else { throw PTPError.malformedData("PropInfo array too short") }
    let count = Int(data.readLE(UInt64.self, at: 0))
    var cursor = 8
    var result: [SDIDevicePropInfo] = []
    result.reserveCapacity(count)

    for _ in 0..<count {
        let (prop, consumed) = try parseSDIDevicePropInfo(data, at: cursor)
        result.append(prop)
        cursor += consumed
    }
    return result
}

/// Parse one SDIDevicePropInfo Dataset starting at `offset` in `data`.
/// Returns (parsed, bytesConsumed).
///
/// Three layouts depending on DataType [parser.cpp SDIDevicePropInfoDataset::create]:
///   Scalar (0x0001–0x0008): default(sz) + current(sz) + FormFlag + form-data
///   Array  (0x4001–0x4008): UINT32-count+elems (default) + UINT32-count+elems (current) + FormFlag(must be 0)
///   STR    (0xFFFF):         PTP-str(default) + PTP-str(current) + FormFlag(must be 0)
public func parseSDIDevicePropInfo(_ data: Data, at offset: Int) throws -> (SDIDevicePropInfo, Int) {
    var cursor = offset

    func need(_ n: Int) throws {
        guard cursor + n <= data.count else {
            throw PTPError.malformedData("PropInfo truncated at byte \(cursor) (need \(n) more)")
        }
    }

    try need(2); let code = data.readLE(UInt16.self, at: cursor); cursor += 2
    try need(2); let rawType = data.readLE(UInt16.self, at: cursor); cursor += 2
    let dataType = SDIDataType(rawValue: rawType) ?? .unknown

    try need(1); let rawGetSet = data[data.startIndex + cursor]; cursor += 1
    let getSet = SDIGetSet(rawValue: rawGetSet) ?? .getOnly

    try need(1); let rawEnabled = data[data.startIndex + cursor]; cursor += 1
    let isEnabled = SDIIsEnabled(rawValue: rawEnabled) ?? .disabled

    // — Values (layout depends on DataType) —
    var scalarDefault = Data(), scalarCurrent = Data()
    var strDefault = "", strCurrent = ""
    var arrayDefaults: [Data] = [], arrayCurrents: [Data] = []

    if dataType.isArray, let elemType = dataType.elementType {
        // Array: UINT32 count + elem[0..n-1], twice (default then current) [parser.cpp DataTypeArray::parseValues]
        let esz = elemType.byteSize
        try need(4)
        let nd = Int(data.readLE(UInt32.self, at: cursor)); cursor += 4
        try need(nd * esz)
        for _ in 0..<nd {
            arrayDefaults.append(Data(data[data.startIndex + cursor ..< data.startIndex + cursor + esz]))
            cursor += esz
        }
        try need(4)
        let nc = Int(data.readLE(UInt32.self, at: cursor)); cursor += 4
        try need(nc * esz)
        for _ in 0..<nc {
            arrayCurrents.append(Data(data[data.startIndex + cursor ..< data.startIndex + cursor + esz]))
            cursor += esz
        }
    } else if dataType == .str {
        // PTP string: 1-byte char-count (incl. null), then count × 2 bytes UTF-16LE [parser.cpp DataTypeSTR::parseValues]
        func parsePTPString() throws -> String {
            try need(1)
            let length = Int(data[data.startIndex + cursor]); cursor += 1
            if length == 0 { return "" }
            try need(length * 2)
            let chars = Data(data[data.startIndex + cursor ..< data.startIndex + cursor + length * 2])
            cursor += length * 2
            return String(bytes: chars, encoding: .utf16LittleEndian)?
                .trimmingCharacters(in: CharacterSet(["\0"])) ?? ""
        }
        strDefault = try parsePTPString()
        strCurrent = try parsePTPString()
    } else if dataType != .unknown {
        // Scalar
        let sz = dataType.byteSize
        try need(sz); scalarDefault = Data(data[data.startIndex + cursor ..< data.startIndex + cursor + sz]); cursor += sz
        try need(sz); scalarCurrent = Data(data[data.startIndex + cursor ..< data.startIndex + cursor + sz]); cursor += sz
    } else {
        throw PTPError.malformedData("Prop 0x\(String(code, radix:16, uppercase:true)): unrecognised DataType 0x\(String(rawType, radix:16, uppercase:true)) at byte \(offset)")
    }

    // — Form flag —
    try need(1); let rawForm = data[data.startIndex + cursor]; cursor += 1
    let formFlag = SDIFormFlag(rawValue: rawForm) ?? .none

    var rangeMin = Data(), rangeMax = Data(), rangeStep = Data()
    var enumValues: [Data] = [], enumValuesAll: [Data] = []

    // Array and STR props always have FormFlag=0 [parser.cpp DataTypeArray::parseForm / DataTypeSTR::parseForm]
    if !dataType.isArray && dataType != .str && dataType != .unknown {
        let sz = dataType.byteSize
        if formFlag == .range {
            // min, max, step each = sz bytes
            try need(sz * 3)
            rangeMin  = Data(data[data.startIndex + cursor ..< data.startIndex + cursor + sz]); cursor += sz
            rangeMax  = Data(data[data.startIndex + cursor ..< data.startIndex + cursor + sz]); cursor += sz
            rangeStep = Data(data[data.startIndex + cursor ..< data.startIndex + cursor + sz]); cursor += sz
        } else if formFlag == .enumeration {
            // Set list: Num(UINT16) + values
            try need(2)
            let setCount = Int(data.readLE(UInt16.self, at: cursor)); cursor += 2
            try need(setCount * sz)
            for _ in 0..<setCount {
                enumValues.append(Data(data[data.startIndex + cursor ..< data.startIndex + cursor + sz]))
                cursor += sz
            }
            // Get+set list: Num(UINT16) + values (parser.cpp ver300 addition)
            try need(2)
            let allCount = Int(data.readLE(UInt16.self, at: cursor)); cursor += 2
            try need(allCount * sz)
            for _ in 0..<allCount {
                enumValuesAll.append(Data(data[data.startIndex + cursor ..< data.startIndex + cursor + sz]))
                cursor += sz
            }
        }
    }

    let prop = SDIDevicePropInfo(
        code: code, dataType: dataType, getSet: getSet, isEnabled: isEnabled,
        defaultValue: scalarDefault, currentValue: scalarCurrent,
        defaultStringValue: strDefault, stringValue: strCurrent,
        defaultArrayValues: arrayDefaults, arrayValues: arrayCurrents,
        formFlag: formFlag, rangeMin: rangeMin, rangeMax: rangeMax, rangeStep: rangeStep,
        enumValues: enumValues, enumValuesAll: enumValuesAll
    )
    return (prop, cursor - offset)
}

/// A PTP string [PIMA 15740 §5.3, as `parseSDIDevicePropInfo` reads it]: UINT8 character count including the
/// terminating null, then UTF-16LE characters and the null. Nil when it's too long to count in a byte.
public func encodePTPString(_ string: String) -> Data? {
    let units = Array(string.utf16)
    guard units.count < 255 else { return nil }
    var data = Data([UInt8(units.count + 1)])
    for unit in units + [0] { data.appendLE(unit) }
    return data
}

// MARK: - Typed value readers

extension SDIDevicePropInfo {
    public func currentUInt8() -> UInt8? {
        guard dataType == .uint8, currentValue.count >= 1 else { return nil }
        return currentValue[currentValue.startIndex]
    }
    public func currentUInt16() -> UInt16? {
        guard dataType == .uint16, currentValue.count >= 2 else { return nil }
        return currentValue.readLE(UInt16.self, at: 0)
    }
    public func currentUInt32() -> UInt32? {
        guard dataType == .uint32, currentValue.count >= 4 else { return nil }
        return currentValue.readLE(UInt32.self, at: 0)
    }
    public func currentInt8() -> Int8? {
        guard dataType == .int8, currentValue.count >= 1 else { return nil }
        return Int8(bitPattern: currentValue[currentValue.startIndex])
    }
    public func currentInt16() -> Int16? {
        guard dataType == .int16, currentValue.count >= 2 else { return nil }
        return Int16(bitPattern: currentValue.readLE(UInt16.self, at: 0))
    }
    public func currentUInt64() -> UInt64? {
        guard dataType == .uint64, currentValue.count >= 8 else { return nil }
        return currentValue.readLE(UInt64.self, at: 0)
    }
    /// Current string value for STR-typed properties.
    public func currentString() -> String? {
        guard dataType == .str else { return nil }
        return stringValue
    }
    /// The camera can be set to this property right now: Get/Set and IsEnabled = True. DispOnly means
    /// show it but don't let it be changed; False means it's off in the current mode (grayed out).
    public var isSettable: Bool { getSet == .getSet && isEnabled == .enabled }

    // Picker options are the "Enum value (Set)" list: what the camera will take in its current mode. The
    // Get/Set list can hold values that aren't valid now (an ISO list while in Cine EI, say), and is empty-ish
    // when a property is display-only. (On the FX3 the two are equal whenever a property is enabled.)
    public func enumCurrentUInt8() -> [UInt8] {
        enumValues.compactMap { $0.count >= 1 ? $0[$0.startIndex] : nil }
    }
    public func enumCurrentUInt16() -> [UInt16] {
        enumValues.compactMap { $0.count >= 2 ? $0.readLE(UInt16.self, at: 0) : nil }
    }
    /// The Get/Set enum list, or the Set list when that's all the camera sent; for read-only capability lists.
    public func enumAllUInt8() -> [UInt8] {
        (enumValuesAll.isEmpty ? enumValues : enumValuesAll).compactMap { $0.count >= 1 ? $0[$0.startIndex] : nil }
    }
    public func enumAllUInt16() -> [UInt16] {
        (enumValuesAll.isEmpty ? enumValues : enumValuesAll).compactMap { $0.count >= 2 ? $0.readLE(UInt16.self, at: 0) : nil }
    }
    public func enumCurrentUInt32() -> [UInt32] {
        enumValues.compactMap { $0.count >= 4 ? $0.readLE(UInt32.self, at: 0) : nil }
    }
    public func enumCurrentUInt64() -> [UInt64] {
        enumValues.compactMap { $0.count >= 8 ? $0.readLE(UInt64.self, at: 0) : nil }
    }
    public func enumAllUInt32() -> [UInt32] {
        (enumValuesAll.isEmpty ? enumValues : enumValuesAll).compactMap { $0.count >= 4 ? $0.readLE(UInt32.self, at: 0) : nil }
    }
    public func enumAllUInt64() -> [UInt64] {
        (enumValuesAll.isEmpty ? enumValues : enumValuesAll).compactMap { $0.count >= 8 ? $0.readLE(UInt64.self, at: 0) : nil }
    }
}

// MARK: - Known Sony Device Property Codes [§6 dashboard mapping]

public enum SDIPropCode: UInt16, Sendable {
    // §6.8 Iris
    case tNumber              = 0xD000 // T-Number (cinema iris)
    case irisModeSetting      = 0xD001
    case fNumber              = 0x5007 // F-Number (PTP standard)

    // §6.4 Shutter
    case shutterSetting       = 0xD00F
    case shutterAngle         = 0xD00E
    case shutterMode          = 0xD010
    case shutterModeStatus    = 0xD011
    case shutterModeSetting   = 0xD013 // — misprint; actual shutter on/off setting
    case shutterSpeedValue    = 0xD016 // UINT64: upper 4B=num, lower 4B=denom (not on FX3)
    case shutterSpeedCurrent  = 0xD017 // UINT64 read-only (not on FX3)
    /// Shutter Speed (main): UINT32, upper 2B=numerator, lower 2B=denominator.
    /// Present on FX3 (0xD20D in props list). Enumeration of camera-offered speeds.
    /// Read-only in angle mode (IsEnabled=disabled); writable only in speed mode.
    case shutterSpeed         = 0xD20D

    // §6.7 White Balance
    case wbModeSetting        = 0xD00C
    case wbTint               = 0xD00D // — absent on FX3; FX3 uses wbTintGM (0xD210)
    case wbTintGM             = 0xD210 // Biaxial Fine-Tuning G-M Direction: UINT8 range 0x9C–0xE4 step=0.25, mid=0xC0=0
    case whiteBalance         = 0x5005 // PTP standard WB
    case colorTemperature     = 0xD20F
    case wbPresetColorTemp    = 0xD086
    case wbSwitch             = 0xD085
    case wbRGain              = 0xD087
    case wbBGain              = 0xD088

    // §6.3 ND Filter (FX6/BURANO only)
    case ndFilter             = 0xD018
    case ndFilterMode         = 0xD019
    case ndFilterModeSetting  = 0xD01A
    case ndFilterValue        = 0xD01B // UINT64 transmittance numerator/denominator
    case ndFilterSwitching    = 0xD073 // UINT8 0x01 PRESET, 0x02 VARIABLE, 0x03 STEP
    case ndFilterUnit         = 0xD14E // UINT8 0x01 optical density, 0x02 transmittance
    case ndOpticalDensity     = 0xD14F // UINT16 OD × 100, 0xFFFF nothing to display
    case ndFilterPosition     = 0xE0E5 // UINT16, transmittance = 2^((value − 0x7FFF) / 0x1000)

    // §6.6 ISO/Gain
    case gainControlSetting   = 0xD01C
    case gainUnitSetting      = 0xD01D
    case gainDbValue          = 0xD01E // INT8
    case gainDbCurrent        = 0xD01F // INT8 read-only
    case gainBaseIso          = 0xD020
    case gainBaseSensitivity  = 0xD021
    case exposureIndex        = 0xD022 // UINT16
    case isoCurrentSensitivity = 0xD023 // UINT32 read-only
    case baseIsoSwitchEI      = 0xD0CB

    // §6.5 Frame Rate
    case recordingFrameRateProxy = 0xD028 // the PROXY recording frame rate (FX6/BURANO), not a project rate
    case sqModeSetting        = 0xD051
    case sqFrameRate          = 0xD052
    case sqRecFrameRate       = 0xD0D0

    // §6.1 Timecode
    case timeCodePreset       = 0xD0D3
    case timeCodeFormat       = 0xD0D5
    case timeCodeRun          = 0xD0D6
    case timeCodeMake         = 0xD0D7
    case recordingDuration    = 0xD120 // FX6/BURANO elapsed recording time

    // §6.2 Recording
    case positionKeySetting   = 0xD25A // UINT8 0x00=camera priority 0x01=PC Remote priority; resets on session close
    case movieRecordingState  = 0xD21D // UINT8
    /// FX6 and BURANO don't have 0xD21D: their REC state is the recorder's status instead.
    /// UINT8, get: 0x00 Idle, 0x01 Ready, 0x02 PreparingToRecord, 0x03 Standby, 0x04 Recording, 0x05 Stopping.
    case recorderMainStatus   = 0xE010 // FX6/BURANO
    /// UINT8, get: 0x00 Rec Start Disable, 0x01 Rec Start Enable ("the recordable status"). FX6/BURANO.
    case recorderStartMain    = 0xE00E
    case isoSensitivity       = 0xD21E // UINT32

    // §6.5 Frame Rate (cont)
    case recordingFrameRate   = 0xD286 // UINT8
    case pushAutoFocus        = 0xD05E // UINT16 0x0002 Down (AF held), 0x0001 Up
    case focusModeSetting     = 0xD007 // UINT8 0x01 Automatic, 0x02 Manual: a cinema body's AF / MF (no 0x500A)
    case focusModeStatus      = 0xE044 // UINT8 0x01 Focus Hold, 0x02 MF Operation, 0x03 AF Operation (read-only)
    case subjectRecognitionAF = 0xD060 // UINT8 0x01 Off, 0x02 Only AF, 0x03 Priority AF (an FX5: 0x04–0x06 too)
    case afTransitionSpeed    = 0xD061 // UINT8 range, 1 slow … 7 fast
    case afSubjectShiftSens   = 0xD062 // UINT8 range, 1 locked on … 5 responsive
    case afAssist             = 0xE084 // UINT8 0x01 Off, 0x02 On
    case focusArea            = 0xD22C // UINT16 enum (StateMapper.focusAreaNames)
    case steadyShotMovie      = 0xD0DA // UINT8 0x01 Off, 0x02 Standard, 0x03 Active, 0x04 Hybrid (an FX5's Dynamic Active)
    case imagerMode           = 0xE131 // UINT64: image size bits 0–7, resolution ×100 bits 8–23, aspect bits 24–31

    // §6.1 Timecode (cont)
    case tcUbDisplaySetting   = 0xD1FD

    // Monitoring display
    /// Monitoring Output Display HDMI: the camera's info on its HDMI output. UINT8 0x01=Off 0x02=On.
    case monitoringOutputDisplayHDMI = 0xD079
    /// Grid Line Display: UINT8 0x01=OFF 0x02=ON.
    case gridLineDisplay      = 0xD1DE

    // View assist / gamma display
    case gammaDisplayAssist   = 0xD1FE // UINT8 0x01=OFF 0x02=ON
    case gammaDisplayAssistType = 0xD1FF // UINT16

    // §6.9 BaseLook / LUT
    /// BaseLook Value: UINT16. Upper byte: 0x00=preset, 0x01=user. Lower byte: 1-based index.
    /// Enum values from camera (set+getset list). Display names from SDIO_GetDisplayStringList
    /// type 0x00000003 (BaseLook.Name.DisplayList).
    case baseLookValue        = 0xD03C
    /// Monitor LUT Setting (All Line): UINT8 0x01=OFF 0x02=ON
    case monitorLUTSetting    = 0xD04D
    /// Upload Dataset Version: UINT32 get-only; set as Version in SDIUploadDataset
    case uploadDatasetVersion = 0xD057
    /// BaseLookImport Command Version: UINT32 get-only; IsEnabled=0x02 means CubeFile import is available;
    /// set as Version in BaseLookImport Dataset
    case baseLookImportCommandVersion = 0xD059
    /// BaseLookImport Operation Enable Status: UINT8 0x01=Enable
    case baseLookImportOperationEnableStatus = 0xD08B
    /// Maximum number of bytes for data payload per packet: UINT32
    case maxUploadBytes       = 0xD0C1

    // Codec / format / resolution
    case recordingResolution  = 0xD024 // UINT32 (width<<16)|height
    case fileFormatMovie      = 0xD241 // UINT8 codec family
    case recordingSettingMovie = 0xD242 // UINT16 bitrate/sampling

    // De-squeeze
    case desqueezeDisplayRatio = 0xE0A4 // UINT16 ratio×1000

    // §6.12 Battery/Media/Status
    case batteryRemaining     = 0xD218 // INT8 (datatype 0x0001) 0–100%; 0xFF(−1) = untaken
    case batteryLevelIndicator = 0xD20E // UINT8 enum, levels 1/4..4/4; 0x01 Fake Battery, 0x0B–0x10 USB power, 0xFF none
    case powerSource          = 0xD03A // UINT8 0x01 DC, 0x02 Battery, 0x03 PoE
    case batteryRemainingMinutes = 0xD038
    case batteryRemainDisplayUnit = 0xD037 // UINT8 0x01 minute, 0x02 percent, 0x03 voltage
    case batteryRemainingVoltage = 0xD039 // UINT32 volts × 1000, 0xFFFFFFFF untaken
    case dcVoltage            = 0xD03E // UINT32 volts × 1000, 0xFFFFFFFF untaken
    case mediaSlot1Status     = 0xD248 // UINT8
    case mediaSlot1Remaining  = 0xD24A
    case mediaSlot2Status     = 0xD256 // UINT8
    case mediaSlot2Remaining  = 0xD258
    case overheatingState     = 0xD251 // UINT8
    case cameraSystemErrorInfo = 0xD07A
    case cameraErrorCaution   = 0xD1BB
    case systemErrorCaution   = 0xD1BC

    // §6.2 Tally (FX6/BURANO extended props)
    case redTallyLamp         = 0xE0D2
    case callSetting          = 0xE0E1 // UINT8 0x01 OFF, 0x02 ON: CALL on the camera's display
    case colorGamut           = 0xE001 // UINT8 0x01 S-Gamut3.Cine, 0x02 S-Gamut3 (Movie Shooting Mode Color Gamut)
    case awb                  = 0xD03B // UINT16 0x0001 Up, 0x0002 Down: one-push AWB, pressed like a button
    case cameraButtonListMulti = 0xD209 // UINT16 enum: the button ids 0xD30A can press (MENU on the BURANO)
    case greenTallyLamp       = 0xE0D3

    // The FX6's own (docs/fx6-controls.md)
    case movieShootingMode    = 0xE000 // UINT16 0x0401 Custom, 0x0301 Cine EI, 0x0302 Cine EI Quick, 0x0501 Flexible ISO
    case recorderControlProxy = 0xE00D // UINT8 0x00 Rec Disable, 0x01 Rec Enable
    case recorderProxyStatus  = 0xE011 // UINT8, the values of Recorder Main Status 0xE010
    case ecsSetting           = 0xE006 // UINT8 0x01 OFF, 0x02 ON
    case ecsFrequency         = 0xE008 // UINT32, thousandths of a hertz
    case monitorLUTOutputs    = 0xD2A9 // UINT32 enum: each Monitor LUT setting's outputs
    case monitorLUT1          = 0xD2AA // UINT8 0x01 OFF, 0x02 ON
    case monitorLUT2          = 0xD2AB
    case monitorLUT3          = 0xD2AC
    case followFocusPosition  = 0xE089 // UINT16 0–65535, read-only (Follow Focus Position Current Value)
    case focusSpeedRange      = 0xD008 // INT8 range: Focus Operation's speeds
    case focalDistanceMeters  = 0xD004 // UINT32, thousandths of a meter; 0xFFFFFFFF until the lens says
    case zoomDistance         = 0xD00B // UINT32, the focal length in thousandths of a millimetre
    case zoomOperationEnable  = 0xD25B // UINT8 0x00 Disable, 0x01 Enable
    case zoomSpeedRange       = 0xD25E // INT8 range: Zoom Operation's speeds
    case yellowTallyLamp      = 0xE0D4

    // §6.11 Live view (PTP GetObject path)
    /// Live View Status: UINT8, read-only. 0x00=Disabled, 0x01=Enabled, 0x02=Not Supported.
    /// When 0x01, call GetObject(0xFFFFC002) to fetch a frame. All cameras support this.
    case liveViewStatus       = 0xD221
    // Streaming (an FX5's: Network → Stream; docs/fx5-controls.md, Live view through its stream)
    case videoStreamSelect    = 0xD0AC // UINT8 1–6: which destination the per-stream settings below are for
    case videoStreamCodec     = 0xD0AD // UINT16 0x0003 H.264, 0x0004 H.265
    case videoStreamResolution = 0xD0AE // UINT32 width << 16 | height
    case streamStatus         = 0xD119 // UINT8 0x01 Inactive (Setting off), 0x02 Idle, 0x03 Streaming, 0x04 Error
    case streamSettingListOperationEnableStatus = 0xD1CC // UINT8 0x01: Get/SetStreamSettingList allowed
    case targetStreamingDestinationSelect = 0xD2BE // UINT16 1–6: the destination the Stream button streams to
    case streamDisplayName    = 0xD2BF // STR, the destination's name in the camera's menu
    case videoStreamMaxBitRate = 0xD2C0 // UINT64 kbps; its range follows the resolution and project rate
    case osdImageMode         = 0xD207 // UINT8 0x00 OFF, 0x01 ON; ON before SDIO_GetOSDImage
    case cameraButtonList     = 0xD208 // UINT16 enum: the button ids 0xD309 can press
    case cameraDialList       = 0xD20A // UINT16 enum: the dial ids 0xD30B can turn
    case cameraButtonStatus   = 0xD20C // 0x0001 idle, 0x0002 a key is held
    /// Live View Image Quality: UINT8, r/w. 0x01=Low, 0x02=High.
    /// FX3 default is High (0x02). Set to Low before streaming; restore on stop.
    case liveViewImageQuality = 0xD26A
    /// LiveViewURL: STR (0xFFFF), read-only. Pan/tilt cameras only (BRC-AM7, ILME-FR7).
    /// Present on FX3 but the HTTP endpoint returns 503 — not used for live view on cinema bodies.
    case liveViewURL          = 0xD278

    // §Playback state and contents
    /// Movie Playing State: UINT8 read-only. 0x00=Not Playing, 0x01=Playing.
    case moviePlayingState    = 0xD02F
    case moviePlayingSpeed    = 0xD030 // UINT64: int32 numerator, uint32 denominator; 0 paused, 1/1 playing
    case cameraOperatingMode  = 0xD0BC // UINT8 0x01 Record, 0x02 Playback
    /// Playback Contents Name: STR read-only.
    case playbackContentsName = 0xD09D
    case fileCameraID         = 0xD1D0 // UINT8 enum, 0x01–0x1A = A–Z
    case fileReelNumber       = 0xD1D1 // UINT16 range
    case fileTitleName        = 0xD1DC // STR
    case recorderClipName     = 0xE00B // STR, Get only: the name the next recording gets
    /// Playback Contents Number: UINT32 read-only.
    case playbackContentsNumber = 0xD09E
    /// Playback Contents Total Number: UINT32 read-only.
    case playbackContentsTotalNumber = 0xD09F
    /// Movie Play Button: UINT16 Get/Set, Up=0x0001 Down=0x0002.
    case moviePlayButton      = 0xE021
    /// Movie Play Pause Button: UINT16 Get/Set.
    case moviePlayPauseButton = 0xE022
    /// Movie Play Stop Button: UINT16 Get/Set.
    case moviePlayStopButton  = 0xE023
    /// Movie Forward Button: UINT16 Get/Set.
    case movieForwardButton   = 0xE024
    /// Movie Rewind Button: UINT16 Get/Set.
    case movieRewindButton    = 0xE025
    /// Movie Next Button: UINT16 Get/Set.
    case movieNextButton      = 0xE026
    /// Movie Prev Button: UINT16 Get/Set.
    case moviePrevButton      = 0xE027
    /// Movie RecReview Button: UINT16 Get/Set.
    case movieRecReviewButton = 0xE028
    /// Playback Media (FX3): UINT8 read-only. Present on FX3 but no playback buttons —
    /// used only to confirm the FX3 has no playback tile. 0xD042.
    case playbackMedia        = 0xD042 // FX3 playback media selector, no playback controls

    // §6.8 Focus mode
    case focusMode            = 0x500A // UINT16 enum

    // §6.8 Focus/Zoom extended
    case focusPositionSetting = 0xE042
    case focusPositionCurrent = 0xE043

    // §6.8 Zoom
    case zoomPositionSetting  = 0xE040

    // WB step controls (FX6/BURANO)
    case colorTemperatureStep = 0xD2EC
    case wbTintStep           = 0xD2ED
}

// MARK: - Known Sony Control Codes [§5.2]

public enum SDIControlCode: UInt16, Sendable {
    // §6.2 REC
    // REC. Pick by the camera's own SDIControlCode list (SDIO_GetExtDeviceInfo), never by vendor version:
    // the FX3 reports vendor code 3.10 but does not list 0xF001, answers it 0x2001 and ignores it
    // (model table agrees). Verified on a real FX3.
    case movieRecButtonToggle = 0xF001 // UINT16 press = Down then Up; relative (toggles)
    case movieRecButtonHold   = 0xD2C8 // UINT16 Down 0x0002 = start, Up 0x0001 = stop; absolute
    case streamButton         = 0xD307 // UINT16 Down 0x0002 = start streaming, Up 0x0001 = stop; absolute

    // §6.8 Focus/Zoom
    case nearFar              = 0xD2D1
    case focusOperation       = 0xD2EF
    case focusWithInt16       = 0xF004 // extended
    case zoomOperation        = 0xD2DD
    case zoomWithInt16        = 0xF003 // extended

    // ECS step (extended)
    case shutterECSStep       = 0xF000 // extended

    // WB step controls (FX6/BURANO)
    case colorTempStep        = 0xD2EC
    case wbTintStep           = 0xD2ED

    // The camera's own buttons and dials, pressed over the network
    case cameraButtonFunction = 0xD309 // UINT32 id << 16 | 0x0002 ON / 0x0001 OFF; ids from 0xD208
    case cameraDialFunction   = 0xD30B // INT32 id << 16 | notches (plus is clockwise); ids from 0xD20A
    case cameraButtonFunctionMulti = 0xD30A // UINT32 id << 16 | 0x0002 ON / 0x0001 OFF; ids from 0xD209 (MENU on the
                                            // BURANO); unlike 0xD309 it can be held together with other buttons
}

/// Buttons Camera Button Function 0xD309 can press, by their 0xD208 ids. Only the ones Tiles uses.
public enum CameraButton: UInt16, Sendable {
    case left     = 0x03
    case right    = 0x04
    case enter    = 0x05
    case menu     = 0x06 // in 0xD209, pressed with 0xD30A
    case msUp     = 0x07
    case msDown   = 0x08
    case msLeft   = 0x09
    case msRight  = 0x0A
    case msEnter  = 0x0B
    case playback = 0x11
    case home     = 0x1D
    case clips    = 0x1E
    case display  = 0x20
    case back     = 0x22
}

// MARK: - Button value semantics
/// Button controls are UINT16. A 4-byte data phase is answered 0x2001 and ignored.
public enum ButtonValue: UInt16 {
    case up   = 0x0001
    case down = 0x0002
}

// MARK: - SDIO_Connect PhaseType values
public enum SDIOConnectPhase: UInt32 {
    case phase1 = 0x01
    case phase2 = 0x02
    case phase3 = 0x03
}

// MARK: - SDIO_OpenSession FunctionMode
public enum SDIOFunctionMode: UInt32, Sendable {
    case remoteControl           = 0x00000000
    case contentTransfer         = 0x00000001
    case remoteControlWithTransfer = 0x00000002
}

// MARK: - Flag of Device Property Option
/// Set to 0x00000001 in SDIO_SetExtDevicePropValue, SDIO_ControlDevice, SDIO_GetAllExtDevicePropInfo
/// to enable extended property / control codes (0xE000–0xEFFF, 0xF000–0xFFFF)
public let sdioExtendedCodesFlag: UInt32 = 0x00000001

// MARK: - SDIO_GetDisplayStringList type constants
public enum SDIODisplayStringListType {
    /// BaseLook.Name.DisplayList: BaseLook value → display string
    public static let baseLookName: UInt32 = 0x00000003
    /// Camera.Gain.BaseISO.DisplayList: Base ISO value → "ISO N" label
    public static let baseISO: UInt32 = 0x00000008
    /// Button.Assign.ShortDisplayList: an assignable button function's index → its short name ("S&Q Motion")
    public static let buttonAssignShort: UInt32 = 0x0000000B
    /// Subject Recognition AF DisplayList: a Subject Recognition AF value → its name ("Human Priority AF")
    public static let subjectRecognitionAF: UInt32 = 0x00000015
}

// MARK: - SDIO_GetAllExtDevicePropInfo Param1
public enum GetAllPropParam1: UInt32 {
    case allData     = 0x00000000 // full dump
    case changedOnly = 0x00000001 // diff since last call
}

// MARK: - Frame rate enum values
/// Recording Frame Rate Setting (Movie) 0xD286 values. The camera's own list says which are valid
/// for the current format; this only names them. 0x01 "120p" etc. may really be 119.88 (Sony's note *1–*4), so
/// the NTSC fractional codes are what NTSC bodies actually report.
public enum FrameRateCode: UInt8, CaseIterable {
    case fps120 = 0x01, fps100 = 0x02, fps60 = 0x03, fps50 = 0x04, fps30 = 0x05, fps25 = 0x06, fps24 = 0x07
    case fps2398 = 0x08, fps2997 = 0x09, fps5994 = 0x0A, fps1998 = 0x0B, fps1499 = 0x0C, fps1250 = 0x0D
    case fps1200 = 0x0E, fps1199 = 0x0F, fps1000 = 0x10, fps999 = 0x11, fps600 = 0x12, fps599 = 0x13
    case fps500 = 0x14, fps4995 = 0x15, fps2400 = 0x16, fps11988 = 0x17

    public var rate: Double {
        switch self {
        case .fps120: 120
        case .fps100: 100
        case .fps60: 60
        case .fps50: 50
        case .fps30: 30
        case .fps25: 25
        case .fps24, .fps2400: 24
        case .fps2398: 23.976
        case .fps2997: 29.97
        case .fps5994: 59.94
        case .fps1998: 19.98
        case .fps1499: 14.99
        case .fps1250: 12.5
        case .fps1200: 12
        case .fps1199: 11.99
        case .fps1000: 10
        case .fps999: 9.99
        case .fps600: 6
        case .fps599: 5.99
        case .fps500: 5
        case .fps4995: 4.995
        case .fps11988: 119.88
        }
    }

    /// The label the camera menu uses.
    public var label: String {
        switch self {
        case .fps120: "120"
        case .fps100: "100"
        case .fps60: "60"
        case .fps50: "50"
        case .fps30: "30"
        case .fps25: "25"
        case .fps24: "24"
        case .fps2398: "23.98"
        case .fps2997: "29.97"
        case .fps5994: "59.94"
        case .fps1998: "19.98"
        case .fps1499: "14.99"
        case .fps1250: "12.50"
        case .fps1200: "12.00"
        case .fps1199: "11.99"
        case .fps1000: "10.00"
        case .fps999: "9.99"
        case .fps600: "6.00"
        case .fps599: "5.99"
        case .fps500: "5.00"
        case .fps4995: "4.995"
        case .fps2400: "24.00"
        case .fps11988: "119.88"
        }
    }

    /// Reverse-lookup: parse a human label back to a Double fps, for TC computation.
    public static func rate(fromLabel label: String) -> Double? {
        allCases.first { $0.label == label }?.rate ?? Double(label)
    }
}

/// Encode shutter speed label (e.g. "1/50", "1.5\"", "BULB") → UINT32.
/// Returns nil for unrecognised labels; caller should surface a warning.
public func encodeShutterSpeedLabel(_ label: String) -> Data? {
    if label == "BULB" {
        var d = Data(); d.appendLE(UInt32(0x00000000)); return d
    }
    // Fraction form "1/N"
    if label.hasPrefix("1/"), let den = Int(label.dropFirst(2)), den > 0 {
        let raw: UInt32 = (UInt32(1) << 16) | UInt32(den)
        var d = Data(); d.appendLE(raw); return d
    }
    // Seconds with quote suffix, e.g. "1.5\"" or "2\""
    let stripped = label.hasSuffix("\"") ? String(label.dropLast()) : label
    if let secs = Double(stripped), secs > 0 {
        // Camera uses denominator 0x000A for real-number display
        let num = UInt32(secs * 10)
        let raw: UInt32 = (num << 16) | 0x000A
        var d = Data(); d.appendLE(raw); return d
    }
    return nil
}

/// Focus mode UINT16 → camera-menu label.
public let focusModeNames: [UInt16: String] = [
    0x0001: "MF", 0x0002: "AF-S", 0x0003: "AF-Macro",
    0x8004: "AF-C", 0x8005: "AF-A", 0x8006: "DMF",
    0x8007: "MF-R", 0x8008: "AF-D", 0x8009: "PF",
]

/// Encode focus mode label → UINT16.
public func encodeFocusModeLabel(_ label: String) -> Data? {
    guard let raw = focusModeNames.first(where: { $0.value == label })?.key else { return nil }
    var d = Data(); d.appendLE(raw); return d
}

/// Parse an SDIDisplayStringList dataset into value → string for one list type.
/// The dataset starts with Offset-to-DisplayStringList (UINT32) and DisplayStringList Size (UINT32); the list
/// itself is ListTypeNum(2) + reserved(2), then per list ListType(4), DataType(2), DisplayStringNum(2), and
/// per string Value(DataType), StringSize(2, includes the NUL), UTF-8. Reading from byte 0 instead of the
/// Offset field only works on the FX3 by accident (its 8-byte header decodes as one empty list).
public func parseDisplayStringList(_ data: Data, type requestedType: UInt32) -> [UInt16: String] {
    guard data.count >= 8 else { return [:] }
    let offset = Int(data.readLE(UInt32.self, at: 0))
    let size = Int(data.readLE(UInt32.self, at: 4))
    guard offset >= 8, size >= 4, offset + size <= data.count else { return [:] }
    let end = offset + size
    var cursor = offset
    func readU16() -> UInt16? {
        guard cursor + 2 <= end else { return nil }
        defer { cursor += 2 }
        return data.readLE(UInt16.self, at: cursor)
    }
    func readU32() -> UInt32? {
        guard cursor + 4 <= end else { return nil }
        defer { cursor += 4 }
        return data.readLE(UInt32.self, at: cursor)
    }
    guard let listTypeNum = readU16(), readU16() != nil else { return [:] }
    var result: [UInt16: String] = [:]
    for _ in 0..<Int(listTypeNum) {
        guard let listType = readU32(), let dataType = readU16(), let count = readU16() else { break }
        let width = dataType == 0x0002 ? 1 : dataType == 0x0006 ? 4 : 2
        for _ in 0..<Int(count) {
            guard cursor + width <= end else { return result }
            let value: UInt16
            switch width {
            case 1: value = UInt16(data[data.startIndex + cursor])
            case 4: value = UInt16(truncatingIfNeeded: data.readLE(UInt32.self, at: cursor))
            default: value = data.readLE(UInt16.self, at: cursor)
            }
            cursor += width
            guard let length = readU16(), cursor + Int(length) <= end else { return result }
            let bytes = data[(data.startIndex + cursor)..<(data.startIndex + cursor + Int(length))]
            cursor += Int(length)
            let string = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: CharacterSet(["\0"]))
            if listType == requestedType, !string.isEmpty { result[value] = string }
        }
    }
    return result
}

/// "ISO 12800" → 12800: the number in a Camera.Gain.BaseISO display string.
public func parseISOLabel(_ label: String) -> Int? {
    Int(label.filter(\.isNumber))
}

/// Camera BaseLook names → picker labels. "User3:1 ARRI Neutral G10 Slog3.cube" → "1 ARRI Neutral G10 Slog3";
/// presets ("S-Log3", "s709", "709(800%)") unchanged; empty user slots ("User4:(No Import)") dropped. Two slots
/// holding the same file keep their full camera name, so every label maps back to exactly one value.
public func lutDisplayNames(_ names: [UInt16: String]) -> [UInt16: String] {
    var labels: [UInt16: String] = [:]
    for (value, name) in names {
        var label = name
        if name.hasPrefix("User"), let colon = name.firstIndex(of: ":") {
            label = String(name[name.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        if label == "(No Import)" { continue }
        if label.lowercased().hasSuffix(".cube") { label = String(label.dropLast(5)) }
        labels[value] = label.isEmpty ? name : label
    }
    let uses = Dictionary(grouping: labels.values, by: { $0 }).mapValues(\.count)
    for (value, label) in labels where uses[label, default: 0] > 1 { labels[value] = names[value] }
    return labels
}

/// Encode BaseLook label synthesised by StateMapper (fallback, no display strings) → UINT16.
/// Handles "Preset N" (upper byte 0x00) and "User N" (upper byte 0x01).
public func encodeLUTLabel(_ label: String) -> UInt16? {
    if label.hasPrefix("User "), let n = Int(label.dropFirst(5)), n > 0 {
        return (0x01 << 8) | UInt16(n)
    }
    if label.hasPrefix("Preset "), let n = Int(label.dropFirst(7)), n > 0 {
        return UInt16(n)
    }
    return nil
}

// MARK: - LUT import datasets

// SDIO_UploadData type-of-data values
public let sdioUploadDataTypeCubefile: UInt32  = 0x00020001

// SDIO_ControlUploadData ControlType values
public let sdioControlUploadBaseLookImport: UInt32 = 0x00020000

/// Build the SDIUploadDataset for a Cube file.
///
/// Layout (all LE):
///   Version          UINT32  — value of 0xD057 Upload Dataset Version
///   OffsetToHeader   UINT32  — byte offset from start of dataset to HeaderInfo
///   HeaderInfoSize   UINT32  — byte count of HeaderInfo section
///   OffsetToFile     UINT32  — byte offset from start of dataset to file bytes
///   FileBinarySize   UINT32  — byte count of file bytes
///   (no reserved gap on the FX3; offset/size fields are consistent with adjacent placement)
///   HeaderInfo       UINT8[] — FileName as null-terminated UTF-8 bytes
///   FileBinary       UINT8[] — raw .cube file bytes
///
/// Note: the size fields at positions 3–5 are 4-byte UINT32 fields, like every other Sony size field (and the
/// Version field equals 0xD057's value, also a UINT32); read as UINT8 they misparse the rest.
public func buildSDIUploadDataset(uploadVersion: UInt32, fileName: String, fileData: Data) -> Data {
    // HeaderInfo = null-terminated UTF-8 file name
    var headerBytes = Data(fileName.utf8)
    headerBytes.append(0x00)  // null terminator

    // Fixed header is 5 × UINT32 = 20 bytes
    let fixedHeaderSize: UInt32 = 20
    let offsetToHeader: UInt32 = fixedHeaderSize
    let headerInfoSize: UInt32 = UInt32(headerBytes.count)
    let offsetToFile: UInt32   = fixedHeaderSize + headerInfoSize
    let fileBinarySize: UInt32 = UInt32(fileData.count)

    var d = Data()
    d.appendLE(uploadVersion)
    d.appendLE(offsetToHeader)
    d.appendLE(headerInfoSize)
    d.appendLE(offsetToFile)
    d.appendLE(fileBinarySize)
    d.append(headerBytes)
    d.append(fileData)
    return d
}

/// Build the BaseLookImport Dataset for SDIO_ControlUploadData.
///
/// Layout:
///   Version       UINT32 — value of 0xD059 BaseLookImport Command Version
///   BaseLookIndex UINT16 — 0x0001..0x0010 = User1..User16
public func buildBaseLookImportDataset(commandVersion: UInt32, slotIndex: UInt16) -> Data {
    var d = Data()
    d.appendLE(commandVersion)
    d.appendLE(slotIndex)
    return d
}

/// Result codes from SDIE_ControlUploadDataResult (0xC214) param1, when ControlType is BaseLookImport.
public enum LUTImportResult: UInt32, Sendable {
    case ok              = 0x00000001
    case ng              = 0x00000002
    case ngInvalidName   = 0x00000003
    case ngBusy          = 0x00000004
    case unknown         = 0x00000000
}

// MARK: - PTP errors

public enum PTPError: Error {
    case malformedData(String)
    case responseCode(UInt16)
    case timeout
    case disconnected
    case unexpectedPacket(String)
    case authenticationFailed
    case versionMismatch(got: UInt8, need: UInt8)
    case lutImportFailed(LUTImportResult, detail: String)
    case lutImportPrecondition(String)
}

/// What a failed connection says, in the Label tile's ⓘ and the connection menu: without it the user read
/// "authenticationFailed" or "The operation couldn't be completed. (SonyPTP.PTPError error 2.)".
extension PTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedData(let what): "The camera sent something Tiles couldn't read (\(what))."
        case .responseCode(let code): String(format: "The camera answered with error 0x%04X.", code)
        case .timeout: "No answer from the camera."
        case .disconnected: "The camera closed the connection."
        case .unexpectedPacket(let what): "The camera answered out of turn (\(what))."
        case .authenticationFailed:
            "The camera turned the connection down: check the user name and password (Access Authentication), "
                + "or approve Tiles on the camera."
        case .versionMismatch(let got, let need):
            "The camera speaks an older Camera Remote Control (\(got); Tiles needs \(need)). Update its firmware."
        case .lutImportFailed(_, let detail): "Loading the LUT failed: \(detail)"
        case .lutImportPrecondition(let why): why
        }
    }
}

