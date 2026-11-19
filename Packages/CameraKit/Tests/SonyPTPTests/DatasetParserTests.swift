// DatasetParserTests — regression tests against real FX3 fixture data.
// Fixture: fixtures/fx3-propinfo-full.bin  (9511 bytes, 409 properties)
//          fixtures/fx3-propinfo-changed.bin (439 bytes, 11 properties, diff payload)

import Testing
import Foundation
import CameraCore
@testable import SonyPTP

// MARK: - Helpers

private func fixtureURL(_ name: String) -> URL {
    // Fixtures live at repo-root/fixtures/
    // #filePath = .../vvcc-s/Packages/CameraKit/Tests/SonyPTPTests/DatasetParserTests.swift
    // 5 × deletingLastPathComponent: file → SonyPTPTests → Tests → CameraKit → Packages → vvcc-s
    let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // → SonyPTPTests/
        .deletingLastPathComponent()  // → Tests/
        .deletingLastPathComponent()  // → CameraKit/
        .deletingLastPathComponent()  // → Packages/
        .deletingLastPathComponent()  // → repo-root/
        .appendingPathComponent("fixtures/\(name)")
    return file
}

// MARK: - Full dump regression (real FX3)

@Suite("SDIODataset Parser — Real FX3 Fixture")
struct DatasetParserTests {

    // Load once for the full suite
    let props: [SDIDevicePropInfo]

    init() throws {
        let url = fixtureURL("fx3-propinfo-full.bin")
        let data = try Data(contentsOf: url)
        props = try parseSDIDevicePropInfoArray(data)
    }

    @Test("Full payload: parses all 409 properties without error")
    func propertyCount() throws {
        #expect(props.count == 409)
    }

    @Test("Model string: 0xD278 (liveview URL) is a non-empty STR")
    func liveviewURL() throws {
        let prop = try #require(props.first(where: { $0.code == 0xD278 }))
        #expect(prop.dataType == .str)
        #expect(!prop.stringValue.isEmpty)
        #expect(prop.stringValue.hasPrefix("http"))
    }

    @Test("Frame rate: 0xD286 decodes to 59.94 fps (FPS code 0x0A)")
    func frameRate() throws {
        let prop = try #require(props.first(where: { $0.code == SDIPropCode.recordingFrameRate.rawValue }))
        let raw = try #require(prop.currentUInt8())
        let fps = FrameRateCode(rawValue: raw)?.rate
        // FX3 was in 4K 59.94 mode; code 0x0A = fps5994
        #expect(raw == 0x0A)
        #expect(fps == 59.94)
    }

    @Test("ISO/EI: 0xD022 (Exposure Index) decodes to 800")
    func exposureIndex() throws {
        let prop = try #require(props.first(where: { $0.code == SDIPropCode.exposureIndex.rawValue }))
        let raw = try #require(prop.currentUInt16())
        #expect(raw == 800)
    }

    @Test("White balance: 0xD20F (colorTemperature) decodes to 5600 K")
    func colorTemperature() throws {
        let prop = try #require(props.first(where: { $0.code == SDIPropCode.colorTemperature.rawValue }))
        let raw = try #require(prop.currentUInt16())
        #expect(raw == 5600)
    }

    @Test("Recording state: 0xD21D decodes to not-recording (0x00)")
    func recordingState() throws {
        let prop = try #require(props.first(where: { $0.code == SDIPropCode.movieRecordingState.rawValue }))
        let raw = try #require(prop.currentUInt8())
        #expect(raw == 0x00)
    }

    @Test("Shutter angle: 0xD00E decodes to 180.0 degrees")
    func shutterAngle() throws {
        let prop = try #require(props.first(where: { $0.code == SDIPropCode.shutterAngle.rawValue }))
        let raw = try #require(prop.currentUInt32())
        let degrees = Double(raw) / 1000.0
        #expect(degrees == 180.0)
    }

    @Test("Timecode: 0xD0D3 raw value encodes hours=23 in bits 31-24")
    func timecodePreset() throws {
        let prop = try #require(props.first(where: { $0.code == SDIPropCode.timeCodePreset.rawValue }))
        let raw = try #require(prop.currentUInt32())
        // UINT32 layout: bits 31-24=H, 23-16=M, 15-8=S, 7-0=Frame
        let hours  = Int((raw >> 24) & 0xFF)
        let mins   = Int((raw >> 16) & 0xFF)
        let secs   = Int((raw >> 8) & 0xFF)
        let frames = Int(raw & 0xFF)
        // Fixture was captured at 23:xx:xx local time; camera was idle so frames=0
        #expect(hours == 23)
        #expect(mins < 60)
        #expect(secs < 60)
        #expect(frames < 60)  // frames ≤ 59 at any frame rate
    }

    @Test("File format: 0xD241 decodes to XAVC S-I 4K (0x0E)")
    func fileFormat() throws {
        let prop = try #require(props.first(where: { $0.code == SDIPropCode.fileFormatMovie.rawValue }))
        let raw = try #require(prop.currentUInt8())
        #expect(raw == 0x0E)  // XAVC S-I 4K
    }

    @Test("Tint: 0xD210 (G-M biaxial) decodes to 0xC0 = 0.0 tint")
    func tintGM() throws {
        let prop = try #require(props.first(where: { $0.code == SDIPropCode.wbTintGM.rawValue }))
        let raw = try #require(prop.currentUInt8())
        #expect(raw == 0xC0)  // center = tint 0
        let tintVal = (Double(raw) - 192.0) * 0.25
        #expect(tintVal == 0.0)
    }

    @Test("Iris: 0x5007 (F-Number) decodes to f/2.8 (0x0118 = 280)")
    func fNumber() throws {
        let prop = try #require(props.first(where: { $0.code == SDIPropCode.fNumber.rawValue }))
        let raw = try #require(prop.currentUInt16())
        #expect(raw == 280)
        let fstop = Double(raw) / 100.0
        #expect(fstop == 2.8)
    }

    @Test("Gamma Display Assist: 0xD1FE is dispOnly with value OFF (0x01)")
    func gammaDisplayAssist() throws {
        let prop = try #require(props.first(where: { $0.code == SDIPropCode.gammaDisplayAssist.rawValue }))
        #expect(prop.isEnabled == .dispOnly)
        let raw = try #require(prop.currentUInt8())
        #expect(raw == 0x01)  // OFF
    }

    @Test("Resolution: 0xD024 is absent on FX3")
    func resolutionAbsent() throws {
        let prop = props.first(where: { $0.code == SDIPropCode.recordingResolution.rawValue })
        #expect(prop == nil)
    }

    @Test("De-squeeze: 0xE0A4 is absent on FX3")
    func desqueezeAbsent() throws {
        let prop = props.first(where: { $0.code == SDIPropCode.desqueezeDisplayRatio.rawValue })
        #expect(prop == nil)
    }

    @Test("StateMapper: fileFormat, iris, tint all decode from fixture")
    func stateMapperNewFields() throws {
        let mapper = StateMapper(props: props)

        // File format: XAVC S-I 4K
        let ff = try #require(mapper.fileFormat())
        #expect(ff.value == "XAVC S-I 4K")
        #expect(ff.options.contains("XAVC S-I 4K"))

        // Iris: f/2.8 via 0x5007
        let iris = try #require(mapper.iris())
        #expect(iris.value == 2.8)

        // Tint: 0.0 via 0xD210
        let wb = try #require(mapper.whiteBalance())
        let tint = try #require(wb.tint)
        #expect(tint.value == 0.0)

        // Look: from 0xD04D (Monitor LUT, ON=true, writable) — takes priority over 0xD1FE (dispOnly)
        let look = try #require(mapper.look())
        #expect(look.value == true)   // fixture 0xD04D = 0x02 = ON
        #expect(look.isWritable == true)

        // Resolution: nil (absent on FX3)
        #expect(mapper.resolution() == nil)

        // De-squeeze: nil (absent on FX3)
        #expect(mapper.desqueeze() == nil)
    }

    @Test("StateMapper: shutter mode Angle (0x02), shutter speed nil in angle mode")
    func shutterModeAndSpeed() throws {
        let mapper = StateMapper(props: props)
        // FX3 fixture: 0xD010 = 0x02 (Angle mode)
        let mode = try #require(mapper.shutterMode())
        #expect(mode.value == .angle)
        // 0xD20D is present but disabled when in angle mode
        #expect(mapper.shutterSpeed() == nil)
    }

    @Test("StateMapper: focus mode AF-C (0x8004) from fixture 0x500A")
    func focusMode() throws {
        let mapper = StateMapper(props: props)
        let fm = try #require(mapper.focusMode())
        #expect(fm.value == "AF-C")
        #expect(fm.options.contains("MF"))
    }

    @Test("StateMapper: iris from 0x5007 (F-Number) — f/2.8, has discrete options")
    func irisFromFNumber() throws {
        let mapper = StateMapper(props: props)
        // FX3 fixture: 0x5007 current = 0x0118 = 280 → f/2.8
        let iris = try #require(mapper.iris())
        #expect(iris.value == 2.8)
        #expect(iris.options.count > 1)
    }

    @Test("StateMapper: LUT from 0xD03C — current 0x0103 = User 3")
    func lut() throws {
        let mapper = StateMapper(props: props)
        // Fixture: 0xD03C current = 0x0103 (little-endian) → hi=0x01 (user), lo=0x03 (index 3)
        let lut = try #require(mapper.lut())
        #expect(lut.value == "User 3")
        #expect(lut.options.contains("Preset 1"))
    }

    @Test("StateMapper: HDMI info display 0xD079 and grid lines 0xD1DE, as the FX3 reported them (off, writable)")
    func hdmiInfoAndGridLines() throws {
        let mapper = StateMapper(props: props)
        let hdmi = try #require(mapper.onOff(.monitoringOutputDisplayHDMI))
        #expect(hdmi.value == false && hdmi.isWritable)
        let grid = try #require(mapper.onOff(.gridLineDisplay))
        #expect(grid.value == false && grid.isWritable)
        var state = CameraState()
        mapper.map(into: &state)
        #expect(state.offers(.hdmiInfo) && state.offers(.gridLines))
    }

    @Test("StateMapper: look from 0xD04D (Monitor LUT) — ON (0x02), writable")
    func lookFromMonitorLUT() throws {
        let mapper = StateMapper(props: props)
        // Fixture: 0xD04D current = 0x02 = ON; getset = r/w
        let look = try #require(mapper.look())
        #expect(look.value == true)
        #expect(look.isWritable == true)
    }

    @Test("STR lens name: 0xD07B decodes to non-empty lens string")
    func lensName() throws {
        let prop = try #require(props.first(where: { $0.code == 0xD07B }))
        #expect(prop.dataType == .str)
        #expect(prop.stringValue.contains("24-70"))
    }

    @Test("STR firmware version: 0xD040 decodes to '7.00'")
    func firmwareVersion() throws {
        let prop = try #require(props.first(where: { $0.code == 0xD040 }))
        #expect(prop.dataType == .str)
        #expect(prop.stringValue == "7.00")
    }

    // MARK: - StateMapper integration

    @Test("StateMapper: ISO, shutter, WB, recording, TC all decode to plausible values")
    func stateMapper() throws {
        let mapper = StateMapper(props: props)

        // ISO: EI prop enabled → 800
        let iso = try #require(mapper.iso())
        #expect(iso.value == 800)

        // Shutter: 0xD00E is enabled, 180000 → 180.0°
        let shutter = try #require(mapper.shutterAngle())
        #expect(shutter.value == 180.0)

        // WB: 5600 K
        let wb = try #require(mapper.whiteBalance())
        #expect(wb.kelvin.value == 5600.0)

        // Recording: idle
        let rec = mapper.recordingState()
        #expect(rec.state == .idle)

        // No timecode: 0xD0D3 is only the preset (the tile shows REC time instead).
        var state = CameraState()
        mapper.map(into: &state)
        #expect(state.timecode == nil)
        #expect(state.offers(.timecode))
    }
}

// MARK: - Changed-only payload

@Suite("SDIODataset Parser — Changed-only payload")
struct DatasetChangedTests {

    @Test("Changed-only payload: parses without error, count ≤ full count")
    func changedPayload() throws {
        let url = fixtureURL("fx3-propinfo-changed.bin")
        let data = try Data(contentsOf: url)
        let props = try parseSDIDevicePropInfoArray(data)
        #expect(!props.isEmpty)
        #expect(props.count <= 409)
    }
}

@Suite("FX3 BaseLook names (SDIO_GetDisplayStringList type 3)")
struct DisplayStringListTests {
    @Test("Real FX3 capture parses to presets and imported LUT names")
    func fx3BaseLookNames() throws {
        let data = try Data(contentsOf: fixtureURL("fx3-displaystringlist-baselook-2026-10-09.bin"))
        let names = parseDisplayStringList(data, type: 0x00000003)
        #expect(names.count == 19)  // 3 presets + 16 user slots
        #expect(names[0x0001] == "S-Log3")
        #expect(names[0x0003] == "709(800%)")
        #expect(names[0x0103] == "User3:1 ARRI Neutral G10 Slog3.cube")
        #expect(names[0x0104] == "User4:(No Import)")
        #expect(parseDisplayStringList(data, type: 0x00000004).isEmpty)

        let labels = lutDisplayNames(names)
        #expect(labels[0x0103] == "1 ARRI Neutral G10 Slog3")
        #expect(labels[0x0101] == "sLogto709-1_33")
        #expect(labels[0x0002] == "s709")
        #expect(labels[0x0104] == nil)  // empty slot
        #expect(labels.count == 7)
    }

    @Test("Two slots with the same file keep their full camera names")
    func duplicateNames() {
        let labels = lutDisplayNames([0x0101: "User1:Show.cube", 0x0102: "User2:Show.cube", 0x0001: "S-Log3"])
        #expect(labels[0x0101] == "User1:Show.cube")
        #expect(labels[0x0102] == "User2:Show.cube")
        #expect(labels[0x0001] == "S-Log3")
    }

    @Test("Truncated or empty data yields no names")
    func malformed() {
        #expect(parseDisplayStringList(Data(), type: 3).isEmpty)
        #expect(parseDisplayStringList(Data([8, 0, 0, 0, 0xFF, 0, 0, 0]), type: 3).isEmpty)
    }

    @Test("Real FX3 base ISO list: High is ISO 12800, Low is ISO 800")
    func fx3BaseISONames() throws {
        let data = try Data(contentsOf: fixtureURL("fx3-displaystringlist-baseiso-2026-10-09.bin"))
        let names = parseDisplayStringList(data, type: 0x00000008)
        #expect(names[0x01] == "ISO 12800")
        #expect(names[0x02] == "ISO 800")
        #expect(names.values.compactMap(parseISOLabel).sorted() == [800, 12800])
    }
}

// MARK: - StateMapper unit tests (synthetic props, no fixture dependency)

@Suite("StateMapper — battery and timecode mapping")
struct StateMappingUnitTests {

    /// Build a minimal SDIDevicePropInfo for a scalar property.
    private static func makeProp(code: UInt16, type: SDIDataType, value: Data,
                                 enabled: SDIIsEnabled = .enabled, getSet: SDIGetSet = .getOnly) -> SDIDevicePropInfo {
        SDIDevicePropInfo(
            code: code, dataType: type, getSet: getSet, isEnabled: enabled,
            defaultValue: value, currentValue: value,
            defaultStringValue: "", stringValue: "",
            defaultArrayValues: [], arrayValues: [],
            formFlag: .none, rangeMin: Data(), rangeMax: Data(), rangeStep: Data(),
            enumValues: [], enumValuesAll: []
        )
    }

    // MARK: Iris

    @Test("iris: a lens that reports no stop (0xFFFF) is no iris, not f/655")
    func irisNothingToDisplay() {
        for raw: UInt16 in [0xFFFD, 0xFFFE, 0xFFFF] {
            let prop = Self.makeProp(code: SDIPropCode.fNumber.rawValue, type: .uint16,
                                     value: Data([UInt8(raw & 0xFF), UInt8(raw >> 8)]))
            #expect(StateMapper(props: [prop]).iris() == nil, "0x\(String(raw, radix: 16))")
        }
        let f45 = Self.makeProp(code: SDIPropCode.fNumber.rawValue, type: .uint16, value: Data([0xC2, 0x01]))
        #expect(StateMapper(props: [f45]).iris()?.value == 4.5)
    }

    @Test("iris: BURANO's T-Number when it has one; the F-Number when the camera switches it off")
    func irisTNumberFallsBack() {
        let t28 = Self.makeProp(code: SDIPropCode.tNumber.rawValue, type: .uint16, value: Data([0x18, 0x01]))  // 2.8
        let f40 = Self.makeProp(code: SDIPropCode.fNumber.rawValue, type: .uint16, value: Data([0x90, 0x01]))  // 4.0
        #expect(StateMapper(props: [t28, f40]).iris()?.value == 2.8)
        let off = Self.makeProp(code: SDIPropCode.tNumber.rawValue, type: .uint16, value: Data([0x18, 0x01]), enabled: .disabled)
        #expect(StateMapper(props: [off, f40]).iris()?.value == 4.0)
    }

    // MARK: FX6 / BURANO (shapes as those cameras send them)

    @Test("Shutter speed on an FX6/BURANO comes from 0xD016 (UINT64 numerator:denominator), labeled like the FX3's")
    func cinemaShutterSpeed() {
        func v(_ num: UInt64, _ den: UInt64) -> Data { var d = Data(); d.appendLE(num << 32 | den); return d }
        let prop = SDIDevicePropInfo(
            code: SDIPropCode.shutterSpeedValue.rawValue, dataType: .uint64, getSet: .getSet, isEnabled: .enabled,
            defaultValue: v(1, 50), currentValue: v(1, 50), defaultStringValue: "", stringValue: "",
            defaultArrayValues: [], arrayValues: [], formFlag: .enumeration, rangeMin: Data(), rangeMax: Data(), rangeStep: Data(),
            enumValues: [v(1, 24), v(1, 48), v(1, 50), v(1, 100), v(3, 2), v(2, 1)], enumValuesAll: [])
        let speed = StateMapper(props: [prop]).shutterSpeed()
        #expect(speed?.value == "1/50")
        #expect(speed?.options == ["1/24", "1/48", "1/50", "1/100", "1.5\"", "2\""])
        #expect(speed?.isWritable == true)
    }

    @Test("FX6/BURANO frame rate is the recording's 0xD286, never the proxy's 0xD028; S&Q 0x01 is Off, 0x02 On")
    func cinemaFrameRateAndSQ() {
        let rec = Self.makeProp(code: SDIPropCode.recordingFrameRate.rawValue, type: .uint8, value: Data([0x08]))  // 23.98p
        let proxy = Self.makeProp(code: SDIPropCode.recordingFrameRateProxy.rawValue, type: .uint8, value: Data([0x07]))  // 24p
        let off = Self.makeProp(code: SDIPropCode.sqModeSetting.rawValue, type: .uint8, value: Data([0x01]))
        let fr = StateMapper(props: [rec, proxy, off]).frameRate()
        #expect(fr?.project.value == FrameRateCode.fps2398.label)
        #expect(fr?.variable?.value == false)
        let on = Self.makeProp(code: SDIPropCode.sqModeSetting.rawValue, type: .uint8, value: Data([0x02]))
        #expect(StateMapper(props: [rec, on]).frameRate()?.variable?.value == true)
        #expect(StateMapper(props: [proxy]).frameRate() == nil)  // a proxy rate alone is not the camera's frame rate
    }

    @Test("REC state on an FX6/BURANO is the recorder's status 0xE010: only Recording is a take")
    func recorderMainStatus() {
        let expected: [UInt8: RecordingState] = [0x00: .idle, 0x01: .idle, 0x02: .idle, 0x03: .idle, 0x04: .recording, 0x05: .idle]
        for (raw, state) in expected {
            let prop = Self.makeProp(code: SDIPropCode.recorderMainStatus.rawValue, type: .uint8, value: Data([raw]))
            #expect(StateMapper(props: [prop]).recordingState().state == state, "0x0\(raw)")
        }
        #expect(StateMapper(props: []).recordingState().state == .unknown)
    }

    // MARK: Battery

    @Test("batteryPercent: INT8 29 (0x1D) is read correctly via currentInt8()")
    func batteryINT8Live() {
        // Live FX3 returned [1d] with datatype INT8 (0x0001). Old code used currentUInt8() which
        // checks dataType == .uint8 and returns nil — the bug.
        let prop = Self.makeProp(code: 0xD218, type: .int8, value: Data([0x1d]))
        let mapper = StateMapper(props: [prop])
        #expect(mapper.batteryPercent() == 29)
    }

    @Test("batteryPercent: 0xFF (−1 as INT8) means untaken — returns nil")
    func batteryUntaken() {
        let prop = Self.makeProp(code: 0xD218, type: .int8, value: Data([0xFF]))
        let mapper = StateMapper(props: [prop])
        #expect(mapper.batteryPercent() == nil)
    }

    @Test("batteryPercent: 100 (0x64) is the maximum")
    func batteryFull() {
        let prop = Self.makeProp(code: 0xD218, type: .int8, value: Data([0x64]))
        let mapper = StateMapper(props: [prop])
        #expect(mapper.batteryPercent() == 100)
    }
}

@Suite("FX3 capabilities, from a real dump")
struct FX3CapabilityTests {
    /// What the tiles get from the FX3's own property table (fixtures/fx3-propinfo-full.bin, Cine EI, XAVC S-I 4K,
    /// 59.94). Guards the rule that every control on a Sony page is something the camera actually offers.
    @Test("The FX3 offers exactly its own controls, with its own option lists")
    func fx3() throws {
        let data = try Data(contentsOf: fixtureURL("fx3-propinfo-full.bin"))
        var state = CameraState()
        StateMapper(props: try parseSDIDevicePropInfoArray(data)).map(into: &state)
        state.recording = RecordingControl(state: .idle)  // as after the first read

        let lacking: [WidgetKind] = [.desqueeze, .resolution, .ndPreset, .ndMinus, .ndPlus, .colorBars, .falseColor,
                                     .sensorFlip, .webGUI]
        for kind in lacking {
            #expect(!state.offers(kind), "the FX3 doesn't offer \(kind)")
        }
        let offered: [WidgetKind] = [.iso, .shutterDial, .shutterValue, .frameRate, .wbPreset, .wbSliders, .iris,
                                     .focusMode, .codec, .bitrate, .lut, .clipName, .afSettings]
        for kind in offered {
            #expect(state.offers(kind), "the FX3 offers \(kind)")
        }
        #expect(state.frameRate?.variable == nil)                              // no S&Q switch
        // Its autofocus settings: Face/Eye Priority on or off, seven areas.
        #expect(state.subjectRecognition?.options == ["Face/Eye Priority AF", "Off"])
        #expect(state.focusArea?.options.count == 7 && state.afSubjectShift?.value == 1)
        #expect(state.frameRate?.project.options == ["59.94", "29.97", "23.98"])  // no 120 at XAVC S-I 4K
        #expect(state.recordingSetting?.isWritable == false)                   // bitrate is display-only under S-I
        #expect(state.shutterSpeed == nil)                                     // off in angle mode
        #expect(state.whiteBalance?.preset.isWritable == true)                 // C.Temp. mode: Kelvin presets
        #expect(state.whiteBalance?.preset.options == ["2800K", "3200K", "4300K", "5000K", "5600K", "6500K"])
        #expect(state.fileFormat?.options.count == 5)
        #expect(state.iris?.options.first == 2.8 && state.iris?.options.last == 22)
        // Clip naming, as this FX3 was set: title "mm", camera ID M, reel 1; the next clip's name, not the stills prefix.
        #expect(state.clipName == "mm0556")
        #expect(state.fileNaming?.title?.value == "mm" && state.fileNaming?.title?.isWritable == true)
        #expect(state.fileNaming?.cameraID?.value == "M" && state.fileNaming?.cameraID?.options.count == 26)
        #expect(state.fileNaming?.reel?.value == 1 && state.fileNaming?.reel?.range == 1...999)
    }

    /// Auto only where the camera takes AWB. The FX3 in Cine EI doesn't (this dump's 0x5005 offers Daylight, Shade,
    /// Cloudy, Incandescent, four Fluorescents, C.Temp. and Custom 1–3), hence the four presets above; a body that
    /// lists AWB gets Auto, and in AWB the tile says Auto and the presets take it back to C.Temp.
    @Test("White balance: Auto where the camera takes AWB")
    func whiteBalanceAuto() throws {
        let props = try parseSDIDevicePropInfoArray(try Data(contentsOf: fixtureURL("fx3-propinfo-full.bin")))
        func uint16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
        func with(_ prop: SDIDevicePropInfo, current: UInt16? = nil, addingEnum: UInt16? = nil,
                  getSet: SDIGetSet? = nil) -> SDIDevicePropInfo {
            SDIDevicePropInfo(code: prop.code, dataType: prop.dataType, getSet: getSet ?? prop.getSet,
                              isEnabled: prop.isEnabled, defaultValue: prop.defaultValue,
                              currentValue: current.map(uint16) ?? prop.currentValue,
                              defaultStringValue: prop.defaultStringValue, stringValue: prop.stringValue,
                              defaultArrayValues: prop.defaultArrayValues, arrayValues: prop.arrayValues,
                              formFlag: prop.formFlag, rangeMin: prop.rangeMin, rangeMax: prop.rangeMax,
                              rangeStep: prop.rangeStep, enumValues: prop.enumValues + (addingEnum.map { [uint16($0)] } ?? []),
                              enumValuesAll: prop.enumValuesAll)
        }
        let mode = SDIPropCode.whiteBalance.rawValue, kelvin = SDIPropCode.colorTemperature.rawValue

        // C.Temp. with AWB on offer: the Kelvin, and Auto after the presets.
        let offering = props.map { $0.code == mode ? with($0, addingEnum: StateMapper.wbAuto) : $0 }
        let cTemp = try #require(StateMapper(props: offering).whiteBalance())
        #expect(cTemp.preset.options == ["2800K", "3200K", "4300K", "5000K", "5600K", "6500K", "Auto"])
        #expect(cTemp.preset.value == "\(Int(cTemp.kelvin.value))K")

        // In AWB (Kelvin not settable): "Auto", and the presets to go back.
        let inAuto = offering.map {
            $0.code == mode ? with($0, current: StateMapper.wbAuto) : $0.code == kelvin ? with($0, getSet: .getOnly) : $0
        }
        let auto = try #require(StateMapper(props: inAuto).whiteBalance())
        #expect(auto.preset.value == "Auto" && auto.preset.isWritable)
        #expect(auto.preset.options == ["2800K", "3200K", "4300K", "5000K", "5600K", "6500K", "Auto"])
        #expect(!auto.kelvin.isWritable)
    }

    /// The encoding the FX3 takes for a title (verified live on FX3): count with the null, UTF-16LE, null.
    @Test("A title goes out as a PTP string")
    func ptpString() {
        #expect(encodePTPString("mm") == Data([0x03, 0x6D, 0x00, 0x6D, 0x00, 0x00, 0x00]))
        #expect(encodePTPString(String(repeating: "a", count: 255)) == nil)
        #expect(FileNaming.isValidTitle("TW_A-1") && FileNaming.isValidTitle(String(repeating: "a", count: 37)))
        #expect(!FileNaming.isValidTitle("") && !FileNaming.isValidTitle(String(repeating: "a", count: 38)))
        #expect(!FileNaming.isValidTitle("a/b") && !FileNaming.isValidTitle("a b") && !FileNaming.isValidTitle("café"))
    }
}


