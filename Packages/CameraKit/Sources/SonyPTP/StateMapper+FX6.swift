import CameraCore
import Foundation

// The FX6's own controls, as measured on one (docs/fx6-controls.md), and an FX5's, which lists the same codes and was
// checked with them (docs/fx5-controls.md, 2026-11-14): `SonyProBody`. Not a BURANO's: it lists several and hasn't
// been checked.
extension StateMapper {
    func mapFX6(into state: inout CameraState, assignableNames: [UInt16: String]) {
        state.steadyShot = steadyShot()
        state.imagerMode = imagerMode()
        state.canAutoFocus = enabledProperty(.pushAutoFocus)?.isSettable == true
        state.shootingMode = shootingMode()
        state.gain = gain()
        state.baseSensitivity = baseSensitivity()
        // The LUT on SDI/HDMI and on the viewfinder are monitoring outputs, so the LUT tile switches both and the
        // Monitoring tile each; the one baked into the recording is its own tile and no switch reaches it.
        if let outputs = lutOutputs() {
            state.monitoring = MonitoringState(outputs: outputs)
            state.look = state.monitoring?.onEverywhere(.lut)
        } else {
            state.monitoring = nil
        }
        state.recordedLUT = recordedLUT(rolling: state.recording.state == .recording)
        state.proxyRecording = proxyRecording()
        state.proxyStatus = state.proxyRecording?.value == true ? proxyStatus() : nil
        state.ecs = ecs()
        state.irisAuto = irisAuto()
        state.ndAuto = automatic(.ndFilterModeSetting)
        state.isoAuto = automatic(.gainControlSetting)
        if state.isoAuto?.value == true { showPickedByAGC(in: &state) }
        state.focalLength = focalLength()
        state.focusDrive = lensDrive(control: .focusOperation, speeds: .focusSpeedRange, enabled: nil)
        state.zoomDrive = lensDrive(control: .zoomOperation, speeds: .zoomSpeedRange, enabled: .zoomOperationEnable)
        state.assignableButtons = assignableButtons(names: assignableNames)
        // False Color where a button is set to it (an FX5's 4, as found): its light says whether it's on, and only a
        // button with a light can be pressed for it, as a press toggles it. A camera that has the function with no
        // button set to it gets the tile grayed, saying that it needs a button.
        state.falseColor = state.assignableButtons.first(where: Self.isFalseColor).map {
            Choice($0.isOn ?? false, options: [false, true], isWritable: $0.isOn != nil)
        }
        state.falseColorHint = nil
        if state.falseColor == nil, Self.hasFalseColor(names: assignableNames) {
            state.falseColor = Choice(false, options: [false, true], isWritable: false)
            state.falseColorHint = "Assign a button"
        }
        state.playback?.speed = playingSpeed()
    }

    /// Movie Playing Speed 0xD030: int32 numerator over uint32 denominator, all ones on the live picture. An FX6 scans
    /// at ±4, ±15 and ±24.
    func playingSpeed() -> Double? {
        guard let raw = propsByCode[SDIPropCode.moviePlayingSpeed.rawValue]?.currentUInt64(), raw != .max else { return nil }
        let numerator = Double(Int32(bitPattern: UInt32(truncatingIfNeeded: raw >> 32)))
        let denominator = Double(UInt32(truncatingIfNeeded: raw))
        return denominator > 0 ? numerator / denominator : 0
    }

    // MARK: Shooting mode, gain

    /// Movie Shooting Mode 0xE000, UINT16.
    static let shootingModes: [UInt16: String] = [0x0401: "Custom", 0x0301: "Cine EI", 0x0302: "Cine EI Quick",
                                                  0x0501: "Flexible ISO", 0x0101: "SDR", 0x0201: "HDR"]

    func shootingMode() -> Choice<String>? {
        guard let prop = enabledProperty(.movieShootingMode),
              let raw = prop.currentUInt16(), let current = Self.shootingModes[raw] else { return nil }
        let options = prop.enumCurrentUInt16().compactMap { Self.shootingModes[$0] }
        return Choice(current, options: options.contains(current) ? options : [current] + options, isWritable: prop.isSettable)
    }

    /// SteadyShot (Movie) 0xD0DA. The guide calls 0x04 Hybrid; an FX5's menu has Dynamic Active there (Sony's FX5
    /// pages: "Dynamic active Mode … Active Mode").
    static let steadyShotModes: [UInt8: String] = [0x01: "Off", 0x02: "Standard", 0x03: "Active", 0x04: "Dynamic Active"]

    func steadyShot() -> Choice<String>? {
        guard let prop = enabledProperty(.steadyShotMovie), let raw = prop.currentUInt8(),
              let current = Self.steadyShotModes[raw] else { return nil }
        let offered = Set(prop.enumCurrentUInt8().compactMap { Self.steadyShotModes[$0] })
        let options = ["Off", "Standard", "Active", "Dynamic Active"].filter(offered.contains)
        return Choice(current, options: options.isEmpty ? [current] : options, isWritable: prop.isSettable)
    }

    /// Imager Mode 0xE131 as the camera's menu writes it: "FF 5K 16:9", "FFc 4.5K 17:9", "S35 3.2K 16:9". Size in bits
    /// 0–7, resolution ×100 in 8–23, aspect in 24–31 (0x05 is 17:9 on an FX5 and later bodies).
    static func imagerModeLabel(_ value: UInt64) -> String? {
        let sizes: [UInt64: String] = [0x01: "FF", 0x02: "FFc", 0x03: "S35", 0x04: "S35c"]
        let aspects: [UInt64: String] = [0x01: "3:2", 0x02: "4:3", 0x03: "6:5", 0x04: "16:9", 0x05: "17:9"]
        guard let size = sizes[value & 0xFF], let aspect = aspects[(value >> 24) & 0xFF] else { return nil }
        let resolution = Double((value >> 8) & 0xFFFF) / 100
        let k = resolution == resolution.rounded() ? String(Int(resolution)) : String(format: "%g", resolution)
        return "\(size) \(k)K \(aspect)"
    }

    func imagerMode() -> Choice<String>? {
        guard let prop = enabledProperty(.imagerMode), let raw = prop.currentUInt64(),
              let current = Self.imagerModeLabel(raw) else { return nil }
        let options = prop.enumCurrentUInt64().compactMap(Self.imagerModeLabel)
        return Choice(current, options: options.contains(current) ? options : [current] + options,
                      isWritable: prop.isSettable && options.count > 1)
    }

    /// Gain Base Sensitivity 0xD021: 0x01 High, 0x02 Low, and on an FX5 0x03 Mid, as its menu has them (ISO 5000, 320
    /// and 1600 in Custom, docs/fx5-controls.md).
    static let baseSensitivities: [UInt8: String] = [0x02: "Low", 0x03: "Mid", 0x01: "High"]

    /// The base in dB, enabled where the gain is (an FX6 in Custom; Gain Base ISO Sensitivity 0xD020 is the base
    /// in ISO modes). Low before High.
    func baseSensitivity() -> Choice<String>? {
        guard let prop = enabledProperty(.gainBaseSensitivity),
              let raw = prop.currentUInt8(), let current = Self.baseSensitivities[raw] else { return nil }
        let offered = Set(prop.enumCurrentUInt8().compactMap { Self.baseSensitivities[$0] })
        let options = ["Low", "Mid", "High"].filter(offered.contains)
        return Choice(current, options: options.isEmpty ? [current] : options, isWritable: prop.isSettable)
    }

    /// Gain dB Value 0xD01E, INT8, enabled while the camera works in dB (Gain Unit 0xD01D): an FX6 in Custom, −3 to
    /// 30 dB.
    func gain() -> Choice<Int>? {
        guard let prop = enabledProperty(.gainDbValue),
              let current = prop.currentInt8() else { return nil }
        var options: [Int] = []
        if let low = prop.rangeMin.first.map({ Int(Int8(bitPattern: $0)) }),
           let high = prop.rangeMax.first.map({ Int(Int8(bitPattern: $0)) }), low < high {
            let step = max(Int(prop.rangeStep.first ?? 1), 1)
            options = Array(stride(from: low, through: high, by: step))
        }
        return Choice(Int(current), options: options.isEmpty ? [Int(current)] : options, isWritable: prop.isSettable)
    }

    // MARK: LUT outputs

    /// Monitor LUT Setting Output Dest Assign 0xD2A9: which outputs each of the three Monitor LUT settings
    /// (0xD2AA–0xD2AC) carries, as setting number (bits 0–7) and output bits. Bits 8 on: all, live view, proxy, HDMI,
    /// SDI, VF, LCD, internal rec, SDI2, stream.
    static func lutDestinations(_ value: UInt32) -> (setting: Int, outputs: [String], recording: Bool) {
        // SDI before HDMI and the LCD before the VF, as the cameras name their settings "SDI/HDMI" (an FX6) and
        // "LCD Monitor/VF" (an FX5).
        let names = [(9, "LiveView"), (10, "Proxy"), (12, "SDI"), (11, "HDMI"), (14, "LCD"), (13, "VF"), (16, "SDI2"),
                     (17, "Stream")]
        let shown = names.filter { value & (1 << $0.0) != 0 }.map(\.1)
        return (Int(value & 0xFF), shown, value & (1 << 15) != 0)
    }

    static let lutSettings: [SDIPropCode] = [.monitorLUT1, .monitorLUT2, .monitorLUT3]

    /// Monitor LUT Setting `n` (1 to 3), or nil for a number the camera has no setting for.
    static func lutSetting(_ n: Int) -> SDIPropCode? {
        (1...3).contains(n) ? lutSettings[n - 1] : nil
    }

    /// The settings that go to outputs, as monitoring outputs: "SDI/HDMI" (setting 1 on an FX6) and "VF" (2); "HDMI",
    /// "Proxy/Live View" and "LCD/VF" on an FX5 (its menu: HDMI, Proxy/Remote Live View, LCD Monitor/VF). A setting
    /// that also reaches the recording isn't one of them (`recordedLUT`); an FX5 has none.
    func lutOutputs() -> [MonitorOutput]? {
        guard let dest = propsByCode[SDIPropCode.monitorLUTOutputs.rawValue] else { return nil }
        var outputs: [MonitorOutput] = []
        for value in dest.enumAllUInt32() {
            let (setting, shown, recording) = Self.lutDestinations(value)
            guard !recording, !shown.isEmpty, let code = Self.lutSetting(setting),
                  let prop = enabledProperty(code),
                  let raw = prop.currentUInt8() else { continue }
            // Named by what's watched: an FX6's viewfinder setting also feeds the proxy and the network's live view
            // ("VF"); an FX5 has one that feeds only those two (fixtures/fx5-propinfo-flexible-iso-2026-11-14.bin).
            let watched = shown.filter { $0 != "LiveView" && $0 != "Proxy" }
            let name = watched.isEmpty ? "Proxy/Live View" : watched.joined(separator: "/")
            outputs.append(MonitorOutput(id: "LUT\(setting)", name: name,
                                         overlays: [.lut: Choice(raw == 0x02, options: [false, true], isWritable: prop.isSettable)]))
        }
        return outputs.isEmpty ? nil : outputs
    }

    /// The Monitor LUT setting whose outputs include Internal Rec: the LUT baked into what's recorded. Not settable
    /// during a take, whatever the camera says.
    func recordedLUT(rolling: Bool) -> Choice<Bool>? {
        guard let code = Self.recordedLUTSetting(propsByCode[SDIPropCode.monitorLUTOutputs.rawValue]),
              let prop = enabledProperty(code),
              let raw = prop.currentUInt8() else { return nil }
        return Choice(raw == 0x02, options: [false, true], isWritable: prop.isSettable && !rolling)
    }

    /// Which Monitor LUT setting carries the recording, so the backend writes that one.
    static func recordedLUTSetting(_ dest: SDIDevicePropInfo?) -> SDIPropCode? {
        guard let value = dest?.enumAllUInt32().first(where: { lutDestinations($0).recording }) else { return nil }
        return lutSetting(lutDestinations(value).setting)
    }

    // MARK: Proxy, ECS, iris, lens

    /// Recorder Control Proxy Setting 0xE00D: 0x00 Rec Disable, 0x01 Rec Enable.
    func proxyRecording() -> Choice<Bool>? {
        guard let prop = enabledProperty(.recorderControlProxy),
              let raw = prop.currentUInt8() else { return nil }
        return Choice(raw == 0x01, options: [false, true], isWritable: prop.isSettable)
    }

    /// Recorder Proxy Status 0xE011, as Recorder Main Status (0xE010) is read.
    func proxyStatus() -> String? {
        guard let raw = propsByCode[SDIPropCode.recorderProxyStatus.rawValue]?.currentUInt8() else { return nil }
        return [0x01: "Ready", 0x02: "Preparing", 0x03: "Standby", 0x04: "Recording", 0x05: "Stopping"][raw]
    }

    /// Shutter ECS Setting 0xE006 (0x01 OFF, 0x02 ON); its frequency 0xE008, UINT32 in thousandths of a hertz (23.99 to
    /// 6000 Hz on an FX6), steps by Shutter ECS Number Step (0xF000) while it's on.
    func ecs() -> ECSState? {
        guard let prop = enabledProperty(.ecsSetting),
              let raw = prop.currentUInt8() else { return nil }
        let on = raw == 0x02
        let frequency = on ? propsByCode[SDIPropCode.ecsFrequency.rawValue]?.currentUInt32().map { Double($0) / 1000 } : nil
        return ECSState(on: Choice(on, options: [false, true], isWritable: prop.isSettable), frequency: frequency,
                        canStep: on && controls.contains(SDIControlCode.shutterECSStep.rawValue))
    }

    /// With AGC on, what the camera has picked, read-only: in dB (Custom) Gain dB Current Value 0xD01F, as Gain dB
    /// Value 0xD01E keeps the manual setting; otherwise ISO Current Sensitivity 0xD023, which in Custom is disabled and
    /// carries the dB.
    func showPickedByAGC(in state: inout CameraState) {
        if state.gain != nil {
            if let prop = enabledProperty(.gainDbCurrent),
               let now = prop.currentInt8() {
                state.gain = Choice(Int(now), options: [Int(now)], isWritable: false)
            }
        } else if state.iso?.isWritable != true, let now = enabledProperty(.isoCurrentSensitivity)?.currentUInt32(),
                  now > 0 {
            state.iso = Choice(Int(now), options: [Int(now)], isWritable: false)
        }
    }

    /// A property the camera hasn't disabled, or nil.
    func enabledProperty(_ code: SDIPropCode) -> SDIDevicePropInfo? {
        guard let prop = propsByCode[code.rawValue], prop.isEnabled != .disabled else { return nil }
        return prop
    }

    /// An Automatic (0x01) / Manual (0x02) setting: ND Filter Mode Setting 0xD01A (Auto ND), Gain Control Setting
    /// 0xD01C (AGC). Both set and read back on an FX6, where Auto makes the density or the ISO
    /// display-only.
    func automatic(_ code: SDIPropCode) -> Choice<Bool>? {
        guard let prop = enabledProperty(code), let raw = prop.currentUInt8() else { return nil }
        return Choice(raw == 0x01, options: [false, true], isWritable: prop.isSettable)
    }

    /// Iris Mode Setting 0xD001: 0x01 Automatic, 0x02 Manual. Only with a lens that sets its iris.
    func irisAuto() -> Choice<Bool>? {
        guard propsByCode[SDIPropCode.fNumber.rawValue]?.isEnabled != .disabled else { return nil }
        return automatic(.irisModeSetting)
    }

    /// Zoom Distance 0xD00B, the focal length in thousandths of a millimetre (24000 for 24 mm).
    func focalLength() -> Double? {
        guard let prop = enabledProperty(.zoomDistance),
              let raw = prop.currentUInt32(), raw > 0, raw != .max else { return nil }
        return Double(raw) / 1000
    }

    /// A motor the camera drives (Focus Operation 0xD2EF, Zoom Operation 0xD2DD, INT8, 0 stops), offered when the
    /// camera lists the control and its speed range. On an FX6 a positive speed focuses farther, and Follow Focus
    /// Position Current Value 0xE089 (0–65535) falls as it does, so the position is turned round: 0 near, 1 far. The
    /// distance is Focal Distance in Meter 0xD004, in thousandths of a meter once the lens has said.
    func lensDrive(control: SDIControlCode, speeds: SDIPropCode, enabled: SDIPropCode?) -> LensDrive? {
        guard controls.contains(control.rawValue), let range = enabledProperty(speeds),
              let high = range.rangeMax.first.map({ Int(Int8(bitPattern: $0)) }), high > 0 else { return nil }
        if let enabled { guard propsByCode[enabled.rawValue]?.currentUInt8() == 0x01 else { return nil } }
        // The camera drives it only while its speed range is enabled, not just shown: an FX5 on AF with AF Assist off
        // has Focus Speed Range display-only and ignores a drive (2026-11-14), as an FX6 without an autofocus lens did.
        let live = range.isEnabled == .enabled
        guard control == .focusOperation else { return LensDrive(maxSpeed: high, isWritable: live) }
        // Where it is and how far, only while the lens says: as found, before it did, both were disabled and 0.
        let position = enabledProperty(.followFocusPosition)?.currentUInt16().map { 1 - Double($0) / 65535 }
        let distance = enabledProperty(.focalDistanceMeters)?.currentUInt32().flatMap { $0 == .max ? nil : Double($0) / 1000 }
        return LensDrive(maxSpeed: high, position: position, distance: distance, isWritable: live)
    }

    // MARK: Assignable buttons

    /// The functions Tiles presses a button for, by the camera's index for it and its English short name: both, so a
    /// camera in another language or a firmware that numbers them differently gets nothing pressable. Each was pressed
    /// on an FX6 and what it changed read back; False Color on an FX5 (2026-11-14: its light on, the LUT outputs held while
    /// it's on, and off again). Last Clip Del. (0x43) deletes a take and is never here.
    static let pressableFunctions: [UInt8: String] = [0x31: "S&Q Motion", 0x03: "Base ISO/Sens.", 0x42: "Rec Review",
                                                      0x6B: "False Colo"]

    /// A button set to False Color, which on these bodies is only a button function: the False Color tile presses it.
    static func isFalseColor(_ button: AssignableButton) -> Bool { button.isPressable && button.function.hasPrefix("False Colo") }

    /// The camera has False Color among its button functions (its display list 0x0B), at a number Tiles presses.
    static func hasFalseColor(names: [UInt16: String]) -> Bool {
        names.contains { key, name in
            key <= 0xFF && name.hasPrefix("False Colo") && isPressable(function: UInt8(key), name: name)
        }
    }

    /// An assignable button's codes: Button Assignment Assignable 1–9 (0xE014–0xE01C) and the lens's (0xE01E), its
    /// press (0xE029–0xE031, 0xE033: UINT16 Down then Up) and its Assignable Button Indicator (0xE035–0xE03D, 0xE03F;
    /// 0x01 off, 0x02 on).
    struct AssignableCodes: Sendable {
        let id: Int
        let assignment: UInt16
        let press: UInt16
        let indicator: UInt16
    }

    static let assignables: [AssignableCodes] = {
        var all: [AssignableCodes] = []
        for id in 1...9 {
            all.append(AssignableCodes(id: id, assignment: UInt16(0xE013 + id), press: UInt16(0xE028 + id),
                                       indicator: UInt16(0xE034 + id)))
        }
        all.append(AssignableCodes(id: AssignableButton.lensID, assignment: 0xE01E, press: 0xE033, indicator: 0xE03F))
        return all
    }()

    func assignableButtons(names: [UInt16: String]) -> [AssignableButton] {
        Self.assignables.compactMap { button in
            guard let assignment = propsByCode[button.assignment], assignment.isEnabled != .disabled,
                  let function = assignment.currentUInt8(), propsByCode[button.press] != nil else { return nil }
            let name = names[UInt16(function)] ?? String(format: "Function %02X", function)
            let indicator = propsByCode[button.indicator]?.currentUInt8()
            return AssignableButton(id: button.id, function: name, isOn: indicator.map { $0 == 0x02 },
                                    isPressable: Self.isPressable(function: function, name: names[UInt16(function)]))
        }
    }

    /// Whether Tiles presses a button set to `function`: one of `functions` (by default the checked ones) under its
    /// name, and never Last Clip Del., whatever the list says, as a press deletes the last take: 0x43 on an FX6, 0x50
    /// on an FX5, whose function codes are numbered differently (its display list 0x0B, docs/fx5-controls.md), so
    /// it's refused by name too.
    static func isPressable(function: UInt8, name: String?, functions: [UInt8: String] = pressableFunctions) -> Bool {
        function != 0x43 && name != nil && name?.hasPrefix("Last Clip") != true && functions[function] == name
    }
}

