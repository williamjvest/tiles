// Maps Sony SDIDevicePropInfo arrays → CameraState.
// nil fields mean "camera didn't report it". [Architecture rule 7]

import Foundation
import CameraCore

// MARK: - State Mapper

public struct StateMapper {

    let propsByCode: [UInt16: SDIDevicePropInfo]

    /// The control codes the camera declared (SDIO_GetExtDeviceInfo). Only playback by buttons needs them.
    let controls: [UInt16]

    public init(props: [SDIDevicePropInfo], controls: [UInt16] = []) {
        self.propsByCode = Dictionary(props.map { ($0.code, $0) }, uniquingKeysWith: { _, last in last })
        self.controls = controls
    }

    // MARK: - Build CameraState fields

    /// Every control field, from the camera's own properties. nil = this camera doesn't offer it (or it's switched
    /// off in the current mode), which is what decides whether a tile shows. Recording, timecode and latency are
    /// handled by the backend. Public so captured dumps can be checked offline (`camctl decode`, tests).
    public func map(into state: inout CameraState, lutNames: [UInt16: String] = [:], baseISONames: [UInt8: Int] = [:],
                    assignableNames: [UInt16: String] = [:], subjectNames: [UInt16: String] = [:]) {
        state.make          = .sony
        state.shutterAngle  = shutterAngle()
        state.shutterSpeed  = shutterSpeed()
        state.shutterMode   = shutterMode()
        state.focusMode     = focusMode()
        state.focusIsAuto   = focusIsAuto(state.focusMode)
        state.subjectRecognition = subjectRecognition(names: subjectNames)
        state.focusArea     = focusArea()
        state.afTransitionSpeed = steps(.afTransitionSpeed)
        state.afSubjectShift = steps(.afSubjectShiftSens)
        state.afAssist      = onOff(.afAssist)
        state.frameRate     = frameRate()
        state.iso           = iso()
        state.baseISO       = baseISO(names: baseISONames)
        state.whiteBalance  = whiteBalance()
        state.iris          = iris()
        state.nd            = nd()
        state.resolution    = resolution()
        state.fileFormat    = fileFormat()
        state.recordingSetting = recordingSetting() ?? fx5BitRate(model: state.model)
        state.desqueeze     = desqueeze()
        state.lut           = lut(lutNames: lutNames)
        state.look          = look()
        state.hdmiInfo      = onOff(.monitoringOutputDisplayHDMI)
        state.gridLines     = onOff(.gridLineDisplay)
        state.batteryPercent        = batteryPercent()
        state.batteryVolts          = batteryVolts()
        state.batteryMinutes        = batteryMinutes()
        state.powerSource           = powerSource()
        state.mediaRemainingMinutes = mediaRemainingMinutes()
        state.warnings      = warnings()
        state.alerts        = alerts()
        // Not in Sony's PTP 3 for these bodies (docs/protocol.md §6.9, §6.10; docs/fx3-controls.md).
        state.colorBars = nil
        state.ndMode = ndMode()
        state.tally = tally()
        state.call = onOff(.callSetting)
        state.colorGamut = colorGamut()
        state.cameraButtons = cameraButtons()
        state.falseColor = nil
        state.clipFlag = nil
        state.imageFlip = nil
        state.clipName = recorderClipName()
        state.fileNaming = fileNaming(failure: state.fileNaming?.failure)
        // 0xD221 Live View Status: 0x01 = Enabled = can GetObject(0xFFFFC002)
        // Live View Status, or the camera's stream (an FX5: `SonyCameraBackend.streamsLiveView`).
        state.hasLiveView = liveViewEnabled() || Self.streamsLiveView(props: propsByCode, controls: controls)
        state.playback = playback()
        if SonyProBody.has(state.model) { mapFX6(into: &state, assignableNames: assignableNames) }
        if let format = state.fileFormat?.value, let resolution = state.resolution?.value {
            state.recordingFormat = "\(resolution) · \(format)"
        } else {
            state.recordingFormat = state.fileFormat?.value
        }
    }

    public func recordingState() -> RecordingControl {
        guard let prop = propsByCode[SDIPropCode.movieRecordingState.rawValue],
              let raw = prop.currentUInt8() else {
            // FX6/BURANO: no 0xD21D; the recorder's status says it. Only Recording is a take: Preparing,
            // like 0xD21D's Waiting, isn't one yet, and Stopping is the take ending.
            if let status = propsByCode[SDIPropCode.recorderMainStatus.rawValue]?.currentUInt8() {
                return RecordingControl(state: status == 0x04 ? .recording : .idle)
            }
            return RecordingControl(state: .unknown)
        }
        // 0x00=Not Recording, 0x01=Recording, 0x02=Failed, 0x03=Waiting
        let state: RecordingState
        switch raw {
        case 0x01: state = .recording
        case 0x02, 0x03: state = .idle  // failed/waiting → treat as idle; surface via warnings
        default: state = .idle
        }
        return RecordingControl(state: state)
    }

    /// Shutter angle: UINT32 × 1000 → degrees
    public func shutterAngle() -> Choice<Double>? {
        guard let prop = propsByCode[SDIPropCode.shutterAngle.rawValue],
              prop.isEnabled != .disabled else { return nil }
        guard let raw = prop.currentUInt32() else { return nil }
        let degrees = Double(raw) / 1000.0
        let options: [Double] = prop.enumCurrentUInt32().map { Double($0) / 1000.0 }
        let writable = prop.isSettable
        return choice(degrees, opts: options, isWritable: writable)
    }

    /// Frame rate from 0xD286 Recording Frame Rate Setting (Movie), which the FX3, FX6 and BURANO all have.
    /// Not 0xD028: that's the PROXY's frame rate. Reading it on an FX6/BURANO while the setter writes
    /// 0xD286 would leave the display out of sync with the camera.
    public func frameRate() -> FrameRateState? {
        guard let prop = propsByCode[SDIPropCode.recordingFrameRate.rawValue], prop.isEnabled != .disabled,
              let raw = prop.currentUInt8() else { return nil }

        let current = FrameRateCode(rawValue: raw)?.label ?? "\(raw)"
        let opts: [String] = prop.enumCurrentUInt8().map { FrameRateCode(rawValue: $0)?.label ?? "\($0)" }

        // S&Q Mode Setting 0xD051: 0x01 Off, 0x02 On. Only the FX6 and BURANO have it; the FX3's own list hasn't
        // (fixtures/fx3-propinfo-full.bin). Reading any non-zero value as on would show Off (0x01) as on.
        let sqProp = propsByCode[SDIPropCode.sqModeSetting.rawValue]
        var sqChoice: Choice<Bool>? = nil
        if let sq = sqProp, sq.isEnabled != .disabled, let val = sq.currentUInt8() {
            sqChoice = Choice(val == 0x02, options: [false, true], isWritable: sq.isSettable)
        }

        // S&Q Frame Rate 0xD052: UINT16 fps, 0x0000 invalid; 1–60 then 100/120/150/180/200/240. The BURANO's
        // project rate is one fixed value (23.98p, the only entry in 0xD286's list on a BURANO), so off-speed is its
        // only other frame rate, and the FPS tile had nothing to offer without this.
        var sqRate: Choice<Double>? = nil
        if let rateProp = propsByCode[SDIPropCode.sqFrameRate.rawValue], rateProp.isEnabled != .disabled,
           let fps = rateProp.currentUInt16(), fps != 0 {
            let rates = rateProp.enumCurrentUInt16().filter { $0 != 0 }.map(Double.init)
            sqRate = Choice(Double(fps), options: rates.isEmpty ? [Double(fps)] : rates, isWritable: rateProp.isSettable)
        }

        return FrameRateState(
            project: choice(current, opts: opts, isWritable: prop.isSettable),
            variable: sqChoice,
            variableRate: sqRate
        )
    }

    /// ISO: use Exposure Index (0xD022) in EI mode, ISO Sensitivity (0xD21E) otherwise.
    /// Check IsEnabled to decide which is active [Gotcha 10, §6.6]
    public func iso() -> Choice<Int>? {
        // EI
        if let eiProp = propsByCode[SDIPropCode.exposureIndex.rawValue],
           eiProp.isEnabled == .enabled,
           let raw = eiProp.currentUInt16() {
            let opts: [Int] = eiProp.enumCurrentUInt16().map { Int($0) }
            return choice(Int(raw), opts: opts, isWritable: eiProp.isSettable)
        }
        // ISO
        if let isoProp = propsByCode[SDIPropCode.isoSensitivity.rawValue],
           isoProp.isEnabled == .enabled,
           let raw = isoProp.currentUInt32() {
            let opts: [Int] = isoProp.enumCurrentUInt32().map { Int($0) }
            return choice(Int(raw), opts: opts, isWritable: isoProp.isSettable)
        }
        return nil
    }

    /// Base ISO: 0xD020 Gain Base ISO Sensitivity, 0x01=High, 0x02=Low
    /// Base ISO as a number. 0xD020 only says High (0x01) or Low (0x02); `names` turns those into
    /// ISOs (from the camera's display strings). Without names there's no honest number to show, so nil.
    public func baseISO(names: [UInt8: Int] = [:]) -> Choice<Int>? {
        guard let prop = propsByCode[SDIPropCode.gainBaseIso.rawValue],
              prop.isEnabled != .disabled,
              let raw = prop.currentUInt8(), let current = names[raw] else { return nil }
        let opts = prop.enumCurrentUInt8().compactMap { names[$0] }.sorted()
        return choice(current, opts: opts, isWritable: prop.isSettable)
    }

    /// White balance [§6.7]
    public func whiteBalance() -> WhiteBalanceState? {
        guard let ktProp = propsByCode[SDIPropCode.colorTemperature.rawValue] else { return nil }
        let kelvin: Double
        if let raw = ktProp.currentUInt16(), raw > 0 && raw < 0xFFFF {
            kelvin = Double(raw)
        } else {
            kelvin = 3200
        }
        let ktRange: ClosedRange<Double>
        if let minRaw = ktProp.rangeMin.count >= 2 ? ktProp.rangeMin.readLE(UInt16.self, at: 0) : nil,
           let maxRaw = ktProp.rangeMax.count >= 2 ? ktProp.rangeMax.readLE(UInt16.self, at: 0) : nil,
           minRaw > 0, maxRaw > minRaw {
            ktRange = Double(minRaw)...Double(maxRaw)
        } else {
            ktRange = 2500...9900  // the camera gave no range
        }
        let ktWritable = ktProp.isSettable
        let kelvinLevel = Level(kelvin, range: ktRange, step: 100, isWritable: ktWritable)

        // WB tint, in the app's convention: negative = green, positive = magenta (as Lightroom and Resolve show it;
        // the slider runs green → magenta). FX3: 0xD210 G-M biaxial fine-tuning, UINT8, 0xC0 = 0, 0.25 steps, where
        // Sony's min 0x9C is M9.00 and max 0xE4 is G9.00 — raw above center is GREEN, so it's negated here.
        // BURANO and FX6: 0xD00D, INT8 −99…+99. Sony doesn't say which sign is which, and neither body shows
        // its picture over the network to look; taken as + = magenta.
        var tintLevel: Level? = nil
        if let tintProp = propsByCode[SDIPropCode.wbTintGM.rawValue],
           tintProp.isEnabled != .disabled,
           let rawUint8 = tintProp.currentUInt8() {
            func tint(_ raw: UInt8) -> Double { (192.0 - Double(raw)) * 0.25 }
            var minV = -9.0, maxV = 9.0
            if let rawMax = tintProp.rangeMax.first { minV = tint(rawMax) }  // G9.00
            if let rawMin = tintProp.rangeMin.first { maxV = tint(rawMin) }  // M9.00
            tintLevel = Level(tint(rawUint8), range: min(minV, maxV)...max(minV, maxV), step: 0.25,
                              isWritable: tintProp.isSettable)
        } else if let tintProp = propsByCode[SDIPropCode.wbTint.rawValue],
                  tintProp.isEnabled != .disabled,
                  let rawTint = tintProp.currentInt8() {
            tintLevel = Level(Double(rawTint), range: -99...99, step: 1, isWritable: tintProp.isSettable)
        }

        // The preset tile: quick Kelvin presets, and Auto (AWB) where the camera takes it, i.e. White Balance 0x5005
        // is settable with AWB among its values. In C.Temp. mode (Kelvin settable) the value is the Kelvin; in AWB it's
        // "Auto", and a Kelvin preset takes the camera back to C.Temp. Any other mode shows as itself, read-only: it
        // claiming it's settable with nothing to pick would leave the preset tile permanently empty.
        let modeProp = propsByCode[SDIPropCode.whiteBalance.rawValue]
        let modes = modeProp?.isSettable == true ? Set(modeProp?.enumCurrentUInt16() ?? []) : []
        // An FX6 has no 0x5005, but White Balance Mode Setting 0xD00C: Automatic, or Manual (Kelvin settable). Set both
        // ways on one over the network. A BURANO lists it display-only.
        let settingProp = propsByCode[SDIPropCode.wbModeSetting.rawValue]
        let settings = settingProp?.isSettable == true ? Set(settingProp?.enumCurrentUInt8() ?? []) : []
        let settingAuto = settings.isSuperset(of: [Self.wbSettingAutomatic, Self.wbSettingManual])
        let auto: [String] = modes.contains(Self.wbAuto) || settingAuto ? ["Auto"] : []
        // One-push AWB (0xD03B, written Down then Up as a button press): picking it measures the light once and the
        // value becomes the measured Kelvin (BURANO: 5600 K → 3276 K under room light).
        let onePush: [String] = propsByCode[SDIPropCode.awb.rawValue]?.isSettable == true ? ["AWB"] : []
        let presets = WhiteBalancePresets.labels(within: ktRange)
        let wbPreset: Choice<String>
        if ktWritable {
            wbPreset = Choice("\(Int(kelvin))K", options: presets + auto + onePush, isWritable: true)
        } else if modeProp?.currentUInt16() == Self.wbAuto, modes.contains(Self.wbColorTemperature) {
            wbPreset = Choice("Auto", options: presets + auto, isWritable: true)
        } else if settingProp?.currentUInt8() == Self.wbSettingAutomatic {
            wbPreset = settingAuto ? Choice("Auto", options: presets + auto, isWritable: true)
                                   : Choice("Auto", options: ["Auto"], isWritable: false)
        } else {
            // Without 0x5005 (an FX6 in playback, say) the Kelvin it reads is the label, not "WB".
            let label = modeProp == nil ? "\(Int(kelvin))K" : wbPresetLabel()
            wbPreset = Choice(label, options: [label], isWritable: false)
        }

        return WhiteBalanceState(preset: wbPreset, kelvin: kelvinLevel, tint: tintLevel)
    }

    /// White Balance 0x5005: AWB, and C.Temp. (the mode in which Kelvin is settable).
    public static let wbAuto: UInt16 = 0x0002
    public static let wbColorTemperature: UInt16 = 0x8012
    /// White Balance Mode Setting 0xD00C.
    public static let wbSettingAutomatic: UInt8 = 0x01
    public static let wbSettingManual: UInt8 = 0x02

    /// White Balance 0x5005 as the camera names its modes.
    private func wbPresetLabel() -> String {
        guard let raw = propsByCode[SDIPropCode.whiteBalance.rawValue]?.currentUInt16() else { return "WB" }
        switch raw {
        case 0x0001: return "Manual"
        case 0x0002: return "AWB"
        case 0x0003: return "One-push"
        case 0x0004: return "Daylight"
        case 0x0005, 0x8001, 0x8002, 0x8003, 0x8004: return "Fluor."
        case 0x0006: return "Tungsten"
        case 0x0007: return "Flash"
        case 0x8010: return "Cloudy"
        case 0x8011: return "Shade"
        case 0x8012: return "C.Temp."
        case 0x8020: return "Custom 1"
        case 0x8021: return "Custom 2"
        case 0x8022: return "Custom 3"
        case 0x8023: return "Custom"
        case 0x8030: return "Underwater"
        default: return "WB"
        }
    }

    /// Iris: F-Number 0x5007 on FX3 (T-Number 0xD000 absent on FX3). UINT16 × 100.
    /// T-Number takes priority when present (BURANO, FX6). Enum of camera-offered stops.
    /// No stop to show (a lens that doesn't report one, iris closed) is no iris, not "f/655".
    public func iris() -> Choice<Double>? {
        // A T-Number the camera has switched off (a lens without one) falls back to the F-Number. BURANO has
        // 0xD000; the FX6 has 0x5007 instead.
        let t = propsByCode[SDIPropCode.tNumber.rawValue]
        let prop = (t != nil && t?.isEnabled != .disabled) ? t : propsByCode[SDIPropCode.fNumber.rawValue]
        guard let prop, prop.isEnabled != .disabled,
              let raw = prop.currentUInt16(), let val = Self.stop(raw) else { return nil }
        let options: [Double] = prop.enumCurrentUInt16().compactMap(Self.stop)
        return choice(val, opts: options, isWritable: prop.isSettable)
    }

    /// An F-Number value as a stop: 0xFFFD is iris close, 0xFFFE is "--" and 0xFFFF is nothing to display;
    /// anything else is the stop × 100.
    static func stop(_ raw: UInt16) -> Double? {
        raw >= 0xFFFD ? nil : Double(raw) / 100.0
    }

    /// Shutter speed from 0xD20D: UINT32. Upper 2B=numerator, lower 2B=denominator.
    /// Disabled (IsEnabled=.disabled) in angle mode. nil in that case.
    public func shutterSpeed() -> Choice<String>? {
        guard let prop = propsByCode[SDIPropCode.shutterSpeed.rawValue],
              prop.isEnabled != .disabled,
              let raw = prop.currentUInt32() else { return cinemaShutterSpeed() }
        let current = shutterSpeedLabel(raw)
        let opts: [String] = prop.enumCurrentUInt32().map { shutterSpeedLabel($0) }
        return choice(current, opts: opts, isWritable: prop.isSettable)
    }

    /// FX6/BURANO have no 0xD20D: Shutter Speed Value 0xD016, UINT64, upper four bytes numerator,
    /// lower four denominator, an enumeration.
    private func cinemaShutterSpeed() -> Choice<String>? {
        guard let prop = propsByCode[SDIPropCode.shutterSpeedValue.rawValue], prop.isEnabled != .disabled,
              let raw = prop.currentUInt64() else { return nil }
        let opts = prop.enumCurrentUInt64().map(Self.shutterSpeedLabel64)
        // Speed mode has its own on/off, Shutter Setting 0xD00F (0x01 OFF, 0x02 ON). It's settable only in
        // speed mode, and while it's off 0xD016 is display-only and the camera shows "Off", exposing for 1/24 at
        // 23.98. So Off is offered with the speeds, and picking one turns it on. A BURANO keeps its Set list of speeds
        // while it's off; an FX6 empties it, and the Get/Set list has them.
        if let setting = propsByCode[SDIPropCode.shutterSetting.rawValue], setting.isEnabled == .enabled,
           let on = setting.currentUInt8() {
            let current = on == 0x01 ? "Off" : Self.shutterSpeedLabel64(raw)
            let speeds = opts.isEmpty && on == 0x01 ? prop.enumAllUInt64().map(Self.shutterSpeedLabel64) : opts
            return Choice(current, options: ["Off"] + speeds, isWritable: setting.isSettable)
        }
        return choice(Self.shutterSpeedLabel64(raw), opts: opts, isWritable: prop.isSettable)
    }

    /// An optical density (OD × 100) as the camera shows it: "0.6", "1.2", and two places where it needs them, "0.65".
    static func ndDensityLabel(_ od: UInt16) -> String {
        String(format: od % 10 == 0 ? "%.1f" : "%.2f", Double(od) / 100)
    }

    /// A 0xD016 value as the FX3's labels read: "1/50", or seconds as 1.5".
    static func shutterSpeedLabel64(_ raw: UInt64) -> String {
        let num = Int(raw >> 32), den = Int(raw & 0xFFFF_FFFF)
        guard den > 0, num > 0 else { return "—" }
        if num == 1 { return "1/\(den)" }
        if num % den == 0 { return "\(num / den)\"" }
        let secs = Double(num) / Double(den)
        return secs >= 1 ? String(format: "%.1f\"", secs) : "\(num)/\(den)"
    }

    /// Shutter mode from 0xD010: UINT8. 0x01=Speed, 0x02=Angle.
    public func shutterMode() -> Choice<ShutterMode>? {
        guard let prop = propsByCode[SDIPropCode.shutterMode.rawValue],
              prop.isEnabled != .disabled,
              let raw = prop.currentUInt8() else { return nil }
        let current: ShutterMode = raw == 0x01 ? .speed : .angle
        let opts: [ShutterMode] = prop.enumCurrentUInt8().compactMap { v in
            switch v { case 0x01: .speed; case 0x02: .angle; default: nil }
        }
        return Choice(current, options: opts.isEmpty ? [.angle, .speed] : opts,
                      isWritable: prop.isSettable)
    }

    /// The name the next recording gets, 0xE00B Recorder Clip Name. (0xD1CA "Recording Setting File Name"
    /// is the stills prefix: "DSC" on the FX3.)
    public func recorderClipName() -> String? {
        guard let prop = propsByCode[SDIPropCode.recorderClipName.rawValue], prop.isEnabled != .disabled,
              let name = prop.currentString(), !name.isEmpty else { return nil }
        return name
    }

    /// File Settings: title name 0xD1DC (STR), camera ID 0xD1D0 (UINT8, 0x01–0x1A = A–Z), reel
    /// number 0xD1D1 (UINT16 range). `failure` carries over the camera's last refusal until a change lands.
    public func fileNaming(failure: String? = nil) -> FileNaming? {
        func usable(_ code: SDIPropCode) -> SDIDevicePropInfo? {
            guard let prop = propsByCode[code.rawValue], prop.isEnabled != .disabled else { return nil }
            return prop
        }
        var naming = FileNaming(failure: failure)
        if let prop = usable(.fileTitleName), let title = prop.currentString() {
            naming.title = Choice(title, isWritable: prop.isSettable)
        }
        if let prop = usable(.fileCameraID), let raw = prop.currentUInt8(), let letter = cameraIDLetter(raw) {
            naming.cameraID = choice(letter, opts: prop.enumCurrentUInt8().compactMap(cameraIDLetter), isWritable: prop.isSettable)
        }
        if let prop = usable(.fileReelNumber), let raw = prop.currentUInt16() {
            let low = prop.rangeMin.count >= 2 ? Double(prop.rangeMin.readLE(UInt16.self, at: 0)) : 1
            let high = prop.rangeMax.count >= 2 ? Double(prop.rangeMax.readLE(UInt16.self, at: 0)) : 999
            naming.reel = Level(Double(raw), range: low...max(high, low), step: 1, isWritable: prop.isSettable)
        }
        guard naming.title != nil || naming.cameraID != nil || naming.reel != nil else { return nil }
        return naming
    }

    private func cameraIDLetter(_ raw: UInt8) -> String? {
        (1...26).contains(raw) ? String(UnicodeScalar(UInt8(64) + raw)) : nil
    }

    /// Focus mode from 0x500A: UINT16 enum. A cinema body without it (an FX5, FX6 or BURANO) has its AF / MF as Focus
    /// Mode Setting 0xD007, "AF" | "MF" (`focusModeSettings`), set from here on an FX5. Display-only where the lens
    /// decides, as an FX6's and a BURANO's were as found (2026-10): both still shown, grayed, so it reads which it is.
    public func focusMode() -> Choice<String>? {
        if let prop = propsByCode[SDIPropCode.focusMode.rawValue], prop.isEnabled != .disabled,
           let raw = prop.currentUInt16() {
            let current = focusModeLabel(raw)
            let opts: [String] = prop.enumCurrentUInt16().map { focusModeLabel($0) }
            return choice(current, opts: opts, isWritable: prop.isSettable)
        }
        guard let prop = propsByCode[SDIPropCode.focusModeSetting.rawValue], prop.isEnabled != .disabled,
              let raw = prop.currentUInt8(), let current = Self.focusModeSettings[raw] else { return nil }
        // Display-only, the Set list is empty: everything it can be, to show.
        let listed = Set((prop.enumCurrentUInt8().isEmpty ? prop.enumAllUInt8() : prop.enumCurrentUInt8())
            .compactMap { Self.focusModeSettings[$0] })
        let opts = ["AF", "MF"].filter(listed.contains)
        return Choice(current, options: opts.contains(current) ? opts : [current],
                      isWritable: prop.isSettable && opts.count > 1)
    }

    /// Focus Mode Setting 0xD007, a cinema body's AF / MF.
    static let focusModeSettings: [UInt8: String] = [0x01: "AF", 0x02: "MF"]

    // MARK: Autofocus settings

    /// Subject Recognition AF 0xD060. Sony's reference names 0x01 Off, 0x02 Only AF and 0x03 Priority AF, which an FX6
    /// calls Face/Eye Only AF and Face/Eye Priority AF (an FX3 lists Off and Priority). An FX5 lists three more and calls
    /// its subjects Human, Animal and Bird; its menu: Human Only AF, Human Priority AF, Animal/Bird Prio. AF, Animal
    /// Priority AF, Bird Priority AF, Off (help guide, focus_detect.html), 0x02–0x06 in that order: its own list of names
    /// (display list 0x15) said so on 2026-11-14. Those names, `names`, come first where the camera gives them.
    static func subjectRecognitionLabel(_ raw: UInt8, humans: Bool, names: [UInt16: String] = [:]) -> String? {
        if let name = names[UInt16(raw)], !name.isEmpty { return name }
        return switch raw {
        case 0x01: "Off"
        case 0x02: humans ? "Human Only AF" : "Face/Eye Only AF"
        case 0x03: humans ? "Human Priority AF" : "Face/Eye Priority AF"
        case 0x04: "Animal/Bird Prio. AF"
        case 0x05: "Animal Priority AF"
        case 0x06: "Bird Priority AF"
        default: nil
        }
    }

    /// The values the camera lists (all it can be, where it's display-only), in its menu's order with Off last, each
    /// with its name; Human where it lists more than the reference's three.
    static func subjectRecognitionValues(_ prop: SDIDevicePropInfo, names: [UInt16: String] = [:])
        -> (humans: Bool, options: [(raw: UInt8, label: String)]) {
        let listed = prop.enumCurrentUInt8().isEmpty ? prop.enumAllUInt8() : prop.enumCurrentUInt8()
        let humans = listed.contains { $0 > 0x03 }
        let ordered = listed.sorted { ($0 == 0x01 ? 0xFF : $0) < ($1 == 0x01 ? 0xFF : $1) }
        return (humans, ordered.compactMap { raw in subjectRecognitionLabel(raw, humans: humans, names: names).map { (raw, $0) } })
    }

    func subjectRecognition(names: [UInt16: String] = [:]) -> Choice<String>? {
        guard let prop = enabledProperty(.subjectRecognitionAF), let raw = prop.currentUInt8() else { return nil }
        let (humans, options) = Self.subjectRecognitionValues(prop, names: names)
        guard let current = Self.subjectRecognitionLabel(raw, humans: humans, names: names) else { return nil }
        let labels = options.map(\.label)
        return choice(current, opts: labels.contains(current) ? labels : [current] + labels, isWritable: prop.isSettable)
    }

    /// Focus Area 0xD22C as the menus name it (its "Lock on AF" areas are Tracking on current
    /// bodies). An FX5 and FX6 offer Wide, Zone and Flexible Spot; an FX3 seven.
    static let focusAreaNames: [UInt16: String] = [
        0x0001: "Wide", 0x0002: "Zone", 0x0003: "Center", 0x0101: "Flexible Spot S", 0x0102: "Flexible Spot M",
        0x0103: "Flexible Spot L", 0x0104: "Expand Flexible Spot", 0x0105: "Flexible Spot", 0x0106: "Flexible Spot XS",
        0x0107: "Flexible Spot XL", 0x1101: "Free Size 1", 0x1102: "Free Size 2", 0x1103: "Free Size 3",
        0x0201: "Tracking: Wide", 0x0202: "Tracking: Zone", 0x0203: "Tracking: Center",
        0x0204: "Tracking: Flexible Spot S", 0x0205: "Tracking: Flexible Spot M", 0x0206: "Tracking: Flexible Spot L",
        0x0207: "Tracking: Expand Flexible Spot", 0x0208: "Tracking: Flexible Spot", 0x0209: "Tracking: Flexible Spot XS",
        0x020A: "Tracking: Flexible Spot XL", 0x1201: "Tracking: Free Size 1", 0x1202: "Tracking: Free Size 2",
        0x1203: "Tracking: Free Size 3",
    ]

    func focusArea() -> Choice<String>? {
        guard let prop = enabledProperty(.focusArea), let raw = prop.currentUInt16(),
              let current = Self.focusAreaNames[raw] else { return nil }
        let labels = (prop.enumCurrentUInt16().isEmpty ? prop.enumAllUInt16() : prop.enumCurrentUInt16())
            .compactMap { Self.focusAreaNames[$0] }
        return choice(current, opts: labels.contains(current) ? labels : [current] + labels, isWritable: prop.isSettable)
    }

    /// A UINT8 setting the camera gives as a range: AF Transition Speed 0xD061 (1 slow to 7 fast) and AF Subj. Shift
    /// Sens. 0xD062 (1 locked on to 5 responsive) on an FX3, FX5, FX6 and BURANO.
    func steps(_ code: SDIPropCode) -> Choice<Int>? {
        guard let prop = enabledProperty(code), let raw = prop.currentUInt8(),
              let low = prop.rangeMin.first, let high = prop.rangeMax.first, low <= high else { return nil }
        let step = max(1, Int(prop.rangeStep.first ?? 1))
        return Choice(Int(raw), options: Array(stride(from: Int(low), through: Int(high), by: step)),
                      isWritable: prop.isSettable)
    }

    /// Whether the camera's focusing by itself. Focus Mode status 0xE044 where it reports it (an FX5: Focus Hold, MF or
    /// AF Operation), as a lens's own AF/MF switch at MF keeps focus manual whatever the setting says; otherwise the
    /// AF / MF read (`CameraState.isAutofocusMode`).
    func focusIsAuto(_ mode: Choice<String>?) -> Bool {
        if let raw = propsByCode[SDIPropCode.focusModeStatus.rawValue].flatMap({ $0.isEnabled == .disabled ? nil : $0.currentUInt8() }),
           (0x01...0x03).contains(raw) {
            return raw != 0x02
        }
        return mode.map { CameraState.isAutofocusMode($0.value) } ?? false
    }

    /// BaseLook Value 0xD03C: UINT16. Upper byte: 0x00=preset, 0x01=user LUT slot.
    /// Display names from SDIO_GetDisplayStringList type 0x00000003 (BaseLook.Name.DisplayList).
    /// `lutNames` maps raw UINT16 value → display string. Without the map, synthesises labels.
    public func lut(lutNames: [UInt16: String] = [:]) -> Choice<String>? {
        guard let prop = propsByCode[SDIPropCode.baseLookValue.rawValue],
              prop.isEnabled != .disabled,
              let raw = prop.currentUInt16() else { return nil }
        let current = lutLabel(raw, names: lutNames)
        // With the camera's names, offer presets and imported LUTs only. An empty user slot has no name on the FX3 and
        // is called "(No LUT)" on the BURANO (16 of its 23 slots); either way the picker leaves it out,
        // unless it's what's on. Importing a LUT lists the slots itself (`camctl lut list`, the LUT import sheet).
        func isEmptySlot(_ v: UInt16) -> Bool {
            guard let name = lutNames[v] else { return true }
            return name.isEmpty || name == "(No LUT)"
        }
        let values = prop.enumCurrentUInt16().filter { lutNames.isEmpty || !isEmptySlot($0) || $0 == raw }
        let opts: [String] = values.map { lutLabel($0, names: lutNames) }
        return choice(current, opts: opts, isWritable: prop.isSettable)
    }

    /// ND filter state (FX6/BURANO) [§6.3]
    public func nd() -> NDState? {
        guard let ndProp = propsByCode[SDIPropCode.ndFilter.rawValue] else { return nil }

        // ND on/off: 0x01=OFF, 0x02=ON
        let isOn = ndProp.currentUInt8() == 0x02

        // A body that lists ND Filter Optical Density Value (0xD14F, OD × 100) gets Clear plus every density it offers
        // in its current mode (ND Filter Switching Setting 0xD073): on the BURANO, 0.6–2.1 in whole stops in STEP and
        // every 0.05 in VARIABLE; on the FX6, Clear and every 0.05 from 0.6 to 2.1 in VARIABLE, read-only in PRESET.
        // The BURANO never enables its transmittance (0xD01B); without 0xD14F it shows only On/Off. Both bodies' own
        // displays read optical density (ND Filter Unit Setting 0xD14E).
        if let odProp = propsByCode[SDIPropCode.ndOpticalDensity.rawValue], odProp.isEnabled != .disabled,
           let od = odProp.currentUInt16(), od != 0xFFFF {
            let labels = ["Clear"] + odProp.enumCurrentUInt16().filter { $0 != 0xFFFF }.map(Self.ndDensityLabel)
            let current = isOn ? Self.ndDensityLabel(od) : "Clear"
            return NDState(preset: Choice(current, options: labels.contains(current) ? labels : labels + [current],
                                          isWritable: odProp.isSettable && ndProp.isSettable))
        }

        var variableLevel: Level? = nil
        if let valProp = propsByCode[SDIPropCode.ndFilterValue.rawValue],
           valProp.isEnabled == .enabled,
           let raw64 = valProp.currentUInt64() {
            if raw64 != 0xFFFF_FFFF_FFFF_FFFF {
                let num = Double(raw64 >> 32)
                let den = Double(raw64 & 0xFFFF_FFFF)
                let transmittance = den > 0 ? num / den : 0
                variableLevel = Level(transmittance, range: 0...1, step: 0.01,
                                      isWritable: valProp.isSettable)
            }
        }

        let preset = Choice<String>(isOn ? "ON" : "OFF", options: ["OFF", "ON"])
        return NDState(preset: preset, variable: variableLevel)
    }

    /// ND Filter Switching Setting 0xD073: 0x01 PRESET, 0x02 VARIABLE, 0x03 STEP. The BURANO takes VARIABLE and
    /// STEP over the network whatever its body switch says.
    public func ndMode() -> Choice<String>? {
        guard let prop = propsByCode[SDIPropCode.ndFilterSwitching.rawValue], prop.isEnabled != .disabled,
              let raw = prop.currentUInt8() else { return nil }
        func label(_ v: UInt8) -> String? { [0x01: "Preset", 0x02: "Variable", 0x03: "Step"][v] }
        guard let current = label(raw) else { return nil }
        return choice(current, opts: prop.enumCurrentUInt8().compactMap(label), isWritable: prop.isSettable)
    }

    /// The tally lamps, red 0xE0D2 and green 0xE0D3 (0x01 OFF, 0x02 ON), as one choice: Off, Green or Red.
    /// Both set and read back on a BURANO.
    public func tally() -> Choice<String>? {
        guard let red = propsByCode[SDIPropCode.redTallyLamp.rawValue], red.isEnabled != .disabled,
              let green = propsByCode[SDIPropCode.greenTallyLamp.rawValue], green.isEnabled != .disabled else { return nil }
        let current = red.currentUInt8() == 0x02 ? "Red" : green.currentUInt8() == 0x02 ? "Green" : "Off"
        return Choice(current, options: ["Off", "Green", "Red"], isWritable: red.isSettable && green.isSettable)
    }

    /// Movie Shooting Mode Color Gamut 0xE001: 0x01 S-Gamut3.Cine, 0x02 S-Gamut3. Set both ways on a BURANO.
    public func colorGamut() -> Choice<String>? {
        guard let prop = propsByCode[SDIPropCode.colorGamut.rawValue], prop.isEnabled != .disabled,
              let raw = prop.currentUInt8() else { return nil }
        func label(_ v: UInt8) -> String? { [0x01: "S-Gamut3.Cine", 0x02: "S-Gamut3"][v] }
        guard let current = label(raw) else { return nil }
        return choice(current, opts: prop.enumCurrentUInt8().compactMap(label), isWritable: prop.isSettable)
    }

    /// The body buttons the app can press: Camera Button Function (0xD309) over the 0xD208 list, and MENU through the
    /// Multi version (0xD30A, 0xD209 list). Offered only on a body that lets Home be pressed (the BURANO): its screen
    /// is optional, and Home is what puts its menu on the HDMI output. On the FX3 the arrows are shooting shortcuts.
    public func cameraButtons() -> [CameraBodyButton] {
        let single = controls.contains(SDIControlCode.cameraButtonFunction.rawValue)
            ? Set(propsByCode[SDIPropCode.cameraButtonList.rawValue]?.enumAllUInt16() ?? []) : []
        let multi = controls.contains(SDIControlCode.cameraButtonFunctionMulti.rawValue)
            ? Set(propsByCode[SDIPropCode.cameraButtonListMulti.rawValue]?.enumAllUInt16() ?? []) : []
        guard single.contains(CameraButton.home.rawValue) else { return [] }
        var buttons: [CameraBodyButton] = []
        if multi.contains(CameraButton.menu.rawValue) || single.contains(CameraButton.menu.rawValue) { buttons.append(.menu) }
        let pairs: [(CameraButton, CameraBodyButton)] = [(.home, .home), (.back, .back), (.display, .display), (.clips, .clips),
                                                         (.msUp, .up), (.msDown, .down), (.msLeft, .left), (.msRight, .right)]
        buttons += pairs.filter { single.contains($0.0.rawValue) }.map(\.1)
        if single.contains(CameraButton.msEnter.rawValue) || single.contains(CameraButton.enter.rawValue) { buttons.append(.enter) }
        return buttons
    }

    /// Resolution from 0xD024: UINT32 packed as (width << 16) | height.
    public func resolution() -> Choice<String>? {
        guard let prop = propsByCode[SDIPropCode.recordingResolution.rawValue],
              prop.isEnabled != .disabled,
              let raw = prop.currentUInt32() else { return nil }
        let current = resolutionLabel(raw)
        let opts = prop.enumCurrentUInt32().map { resolutionLabel($0) }
        return choice(current, opts: opts, isWritable: prop.isSettable)
    }

    /// File format (Movie) 0xD241: UINT8 codec family enum.
    public func fileFormat() -> Choice<String>? {
        guard let prop = propsByCode[SDIPropCode.fileFormatMovie.rawValue],
              prop.isEnabled != .disabled,
              let raw = prop.currentUInt8() else { return nil }
        let current = fileFormatLabel(raw)
        let opts = prop.enumCurrentUInt8().map { fileFormatLabel($0) }
        return choice(current, opts: opts, isWritable: prop.isSettable)
    }

    /// Recording Setting (Movie) 0xD242: UINT16 bitrate/sampling enum.
    public func recordingSetting() -> Choice<String>? {
        guard let prop = propsByCode[SDIPropCode.recordingSettingMovie.rawValue],
              prop.isEnabled != .disabled,
              let raw = prop.currentUInt16() else { return nil }
        let current = recordingSettingLabel(raw)
        let opts = prop.enumCurrentUInt16().map { recordingSettingLabel($0) }
        return choice(current, opts: opts, isWritable: prop.isSettable)
    }

    /// An FX5's bit rate, which it shows but doesn't report: from its project rate, codec and video format
    /// (`FX5BitRate`), to read only.
    func fx5BitRate(model: String?) -> Choice<String>? {
        guard model?.contains("FX5") == true,
              let code = propsByCode[SDIPropCode.recordingFrameRate.rawValue]?.currentUInt8(),
              let fps = FrameRateCode(rawValue: code)?.rate,
              let codec = fileFormat()?.value, let format = resolution()?.value,
              let label = FX5BitRate.label(fps: fps, codec: codec, format: format) else { return nil }
        return Choice(label, options: [label], isWritable: false)
    }

    /// De-squeeze Display Ratio 0xE0A4: UINT16, value = ratio × 1000.
    public func desqueeze() -> Choice<String>? {
        guard let prop = propsByCode[SDIPropCode.desqueezeDisplayRatio.rawValue],
              prop.isEnabled != .disabled,
              let raw = prop.currentUInt16() else { return nil }
        let current = desqueezeLabel(raw)
        let opts = prop.enumCurrentUInt16().map { desqueezeLabel($0) }
        return choice(current, opts: opts, isWritable: prop.isSettable)
    }

    /// Monitor LUT Setting (All Line) 0xD04D: UINT8 0x01=OFF 0x02=ON.
    /// Maps to the `look` (view-LUT on/off) field. Works regardless of picture profile.
    /// Falls back to Gamma Display Assist 0xD1FE if 0xD04D is absent (unlikely on FX3,
    /// but 0xD1FE is dispOnly when no S-Log/HLG profile is active so its isWritable will be false).
    public func look() -> Choice<Bool>? {
        if let prop = propsByCode[SDIPropCode.monitorLUTSetting.rawValue],
           prop.isEnabled != .disabled, let raw = prop.currentUInt8() {
            let on = raw == 0x02
            return Choice(on, options: [false, true], isWritable: prop.isSettable)
        }
        guard let prop = propsByCode[SDIPropCode.gammaDisplayAssist.rawValue],
              prop.isEnabled != .disabled, let raw = prop.currentUInt8() else { return nil }
        let on = raw == 0x02
        return Choice(on, options: [false, true], isWritable: prop.isSettable)
    }

    /// A UINT8 switch, 0x01 off and 0x02 on: HDMI info display 0xD079, grid lines 0xD1DE. Both set on a
    /// real FX3 (its property list: both Get/Set, enabled, off).
    public func onOff(_ code: SDIPropCode) -> Choice<Bool>? {
        guard let prop = propsByCode[code.rawValue], prop.isEnabled != .disabled, let raw = prop.currentUInt8() else { return nil }
        return Choice(raw == 0x02, options: [false, true], isWritable: prop.isSettable)
    }

    // No timecode here: Sony PTP 3 has no running-timecode property. 0xD0D3 is the TC *preset* and never
    // moves (live FX3, Free Run: same value before, during and after a take), so a clock built on it
    // was fiction. The timecode tile shows the take's REC time instead (CameraState.takeStartedAt).

    /// Battery % from 0xD218.
    ///
    /// It's INT8 (datatype 0x0001), not UINT8.
    /// On the FX3: raw [1d] = 29, [1c] = 28 — confirmed live to be plausible % values
    /// [fixtures/fx3-tc-battery-2026-10-09.txt]. 0xFF (-1 as INT8) = "untaken" (no battery).
    /// 0xD204/D037/D038/D039 are all absent on the FX3.
    /// The FX3 declares 0xD218 INT8 (0x1D = 29%), so reading it only as UINT8 showed no battery
    /// at all; 0xFF / -1 means no reading. Accepts UINT8 too, for bodies that declare it so.
    public func batteryPercent() -> Int? {
        guard let prop = propsByCode[SDIPropCode.batteryRemaining.rawValue] else { return nil }
        let percent: Int? = prop.currentInt8().map(Int.init) ?? prop.currentUInt8().map(Int.init)
        guard let percent, (0...100).contains(percent) else { return nil }
        return percent
    }

    /// Volts, for a body whose display reads volts rather than a percentage: Battery Remaining in Voltage (0xD039),
    /// else DC Voltage (0xD03E), both volts × 1000 with 0xFFFFFFFF untaken. The battery tile shows it when there's no
    /// percentage. BURANO: Battery Remain Display Unit 0xD037 = voltage, 0xD218 = 0xFF and
    /// 0xD039 = 14200, so the tile read "—" where the camera showed 14.2 V. Absent on the FX3.
    public func batteryVolts() -> Double? {
        for code in [SDIPropCode.batteryRemainingVoltage, .dcVoltage] {
            guard let prop = propsByCode[code.rawValue], prop.isEnabled != .disabled,
                  let raw = prop.currentUInt32(), raw != 0, raw != 0xFFFF_FFFF else { continue }
            return Double(raw) / 1000
        }
        return nil
    }

    /// Minutes left, where the camera shows its battery in minutes (Battery Remain Display Unit 0xD037 = 0x01): Battery
    /// Remaining in Minutes 0xD038, 0xFFFFFFFF untaken. A BURANO and an FX6 list it, disabled at their other units; an
    /// FX5 doesn't list it. Set to minutes, the tile read nothing (the 11/14 sweep).
    func batteryMinutes() -> Int? {
        guard propsByCode[SDIPropCode.batteryRemainDisplayUnit.rawValue]?.currentUInt8() == 0x01,
              let prop = propsByCode[SDIPropCode.batteryRemainingMinutes.rawValue], prop.isEnabled != .disabled,
              let raw = prop.currentUInt32(), raw != 0xFFFF_FFFF else { return nil }
        return Int(raw)
    }

    /// What's powering the camera where it isn't simply its battery (`CameraState.powerSource`): Battery Level
    /// Indicator 0xD20E says USB power alongside the battery's level (0x0B–0x0F) or alone (0x10), and Fake Battery (0x01)
    /// for one it can't read, a dummy battery on external power; Power Source 0xD03A says DC (0x01) or PoE (0x03). An
    /// FX5 on USB-C with a flat battery read 0% and "Pre-End Battery with USB Bus Power Supply" (2026-11-14); an FX6 on
    /// DC, Power Source DC.
    func powerSource() -> String? {
        if let level = propsByCode[SDIPropCode.batteryLevelIndicator.rawValue].flatMap({ $0.isEnabled == .disabled ? nil : $0.currentUInt8() }) {
            if (0x0B...0x10).contains(level) { return "USB" }
            if level == 0x01 { return "Ext" }
        }
        switch propsByCode[SDIPropCode.powerSource.rawValue].flatMap({ $0.isEnabled == .disabled ? nil : $0.currentUInt8() }) {
        case 0x01: return "DC"
        case 0x03: return "PoE"
        default: return nil
        }
    }

    /// Media remaining (minutes): the first slot with a card that's OK (Media Slot Status 0xD248 / 0xD256: 0x01 OK) and
    /// time left, A then B, so a camera recording to its B slot alone shows it (it showed nothing); a card that's OK and
    /// full reads 0. A camera that doesn't give a slot's status: slot 1's time, as before.
    public func mediaRemainingMinutes() -> Int? {
        let slots: [(status: SDIPropCode, remaining: SDIPropCode)] = [(.mediaSlot1Status, .mediaSlot1Remaining),
                                                                      (.mediaSlot2Status, .mediaSlot2Remaining)]
        var full = false
        for (i, slot) in slots.enumerated() {
            let status = propsByCode[slot.status.rawValue]?.currentUInt8()
            guard status == 0x01 || (status == nil && i == 0),
                  let prop = propsByCode[slot.remaining.rawValue], prop.isEnabled != .disabled,
                  let raw = prop.currentUInt32() else { continue }
            if raw > 0 { return max(1, Int(raw) / 60) }
            full = true
        }
        return full ? 0 : nil
    }

    /// What the camera warns of on its own screen (`CameraState.alerts`): Device Overheating State 0xD251 (0 normal, 1
    /// rising, 2 overheating; an FX3 and FX5 give it), then any card in trouble.
    func alerts() -> [String] {
        let heat: String? = switch propsByCode[SDIPropCode.overheatingState.rawValue]?.currentUInt8() {
        case 0x01: "Getting hot"
        case 0x02: "Overheating"
        default: nil
        }
        return (heat.map { [$0] } ?? []) + cardWarnings()
    }

    /// A card in trouble, by slot (Media Slot Status 0xD248 / 0xD256), as the camera's own screen would warn: an error,
    /// a database error or one that needs formatting, read-only media. Not 0x04 or 0x06, recognizing (an FX3's empty
    /// second slot read 0x04 for good).
    func cardWarnings() -> [String] {
        [(SDIPropCode.mediaSlot1Status, "A"), (.mediaSlot2Status, "B")].compactMap { code, slot in
            switch propsByCode[code.rawValue]?.currentUInt8() {
            case 0x03: "Card \(slot): error"
            case 0x05, 0x07: "Card \(slot): database error"
            case 0x08: "Card \(slot): needs formatting"
            case 0x09: "Card \(slot): read-only"
            default: nil
            }
        }
    }

    /// Warnings from caution/error properties [§6.12]
    public func warnings() -> [String] {
        var result: [String] = []
        if let oh = propsByCode[SDIPropCode.overheatingState.rawValue],
           let raw = oh.currentUInt8(), raw != 0 {
            result.append("Overheat")
        }
        return result
    }

    // MARK: - Live view [§6.11]

    /// Whether Live View Status (0xD221) == 0x01 (Enabled).
    public func liveViewEnabled() -> Bool {
        propsByCode[SDIPropCode.liveViewStatus.rawValue]?.currentUInt8() == 0x01
    }

    // MARK: - Raw snapshot for debugging [Architecture rule 7]
    public var rawProperties: [UInt16: SDIDevicePropInfo] { propsByCode }

    // MARK: - Playback

    /// Playback state, or nil when this camera can't be played back over the network.
    ///
    /// Offered when Play Pause (0xE022) or Play (0xE021) is present and not IsEnabled=disabled. Bodies without those
    /// (the FX3) can still be played through their own buttons: see `buttonPlayback()`.
    public func playback() -> PlaybackState? {
        let hasPP = propsByCode[SDIPropCode.moviePlayPauseButton.rawValue]
        let hasP  = propsByCode[SDIPropCode.moviePlayButton.rawValue]
        guard let anchor = hasPP ?? hasP, anchor.isEnabled != .disabled else { return buttonPlayback() }

        // A button the camera doesn't list is a button it doesn't have: absent means false, not "not disabled".
        func has(_ code: SDIPropCode) -> Bool { propsByCode[code.rawValue].map { $0.isEnabled != .disabled } ?? false }
        func reading(_ code: SDIPropCode) -> UInt8? {
            propsByCode[code.rawValue].flatMap { $0.isEnabled != .disabled ? $0.currentUInt8() : nil }
        }
        // Live | Review, the switch every camera's Playback tile has: consistent across cameras. In review while
        // Camera Operating Mode (0xD0BC) says Playback (0x02),
        // else while Movie Playing State (0xD02F) says it's in movie playback; Review is Play from the live picture and
        // Live is Stop (SonyCameraBackend). A BURANO reads Record 0x01 / Not Playing live, and Playback 0x02 / Playing
        // both playing and paused (BURANO fixtures). Only on a body with Stop that says which it's in.
        let inReview: Bool? = reading(.cameraOperatingMode).map { $0 == 0x02 } ?? reading(.moviePlayingState).map { $0 == 0x01 }
        let review = has(.moviePlayStopButton) && inReview != nil
        let nextPrevious = has(.movieNextButton) && has(.moviePrevButton)
        // The Clips window: a body that numbers its takes in Playback (0xD09E/0xD09F, listed but disabled on the live
        // picture: an FX5's) is stepped to one with Prev and Next (SonyCameraBackend `goToTake`).
        let numbersTakes = propsByCode[SDIPropCode.playbackContentsNumber.rawValue] != nil
            && propsByCode[SDIPropCode.playbackContentsTotalNumber.rawValue] != nil
        let caps = PlaybackCapabilities(
            playPause: true,
            stop: has(.moviePlayStopButton),
            nextPrevious: nextPrevious,
            seek: false,  // Sony has no seek-by-seconds; FF/REW buttons are the mechanism
            fastForwardRewind: has(.movieForwardButton) && has(.movieRewindButton),
            recReview: has(.movieRecReviewButton),
            live: false,  // Stop is Sony's way back to the live picture: the switch's Live
            review: review,
            goToClip: review && nextPrevious && has(.moviePlayButton) && numbersTakes
        )

        // Playing state. Movie Playing Speed 0xD030 (int32 numerator / uint32 denominator) is 0 when paused, 1/1 at
        // speed and ±n scanning; Movie Playing State 0xD02F (0x00 Not Playing, 0x01 Playing) only says the
        // camera is in movie playback. A BURANO kept 0xD02F at 0x01 through a pause while 0xD030 went 1/1 → 0 → 1/1
        // (BURANO), so the play/pause button stuck on pause. The speed decides where the body has it.
        let isPlaying: Bool?
        if let speed = propsByCode[SDIPropCode.moviePlayingSpeed.rawValue], speed.isEnabled != .disabled,
           let raw = speed.currentUInt64(), raw != 0xFFFF_FFFF_FFFF_FFFF {
            isPlaying = Int32(bitPattern: UInt32(truncatingIfNeeded: raw >> 32)) != 0
        } else if let ps = propsByCode[SDIPropCode.moviePlayingState.rawValue],
           let raw = ps.currentUInt8() {
            isPlaying = raw == 0x01
        } else {
            isPlaying = nil
        }

        // Clip name from 0xD09D (STR), its number 0xD09E and the total 0xD09F (UINT32): an FX5's, only while the camera
        // has them enabled. On the live picture it has all three disabled, an empty name and 0 of 0
        // (fixtures/fx5-propinfo-2026-11-14.bin), which the Playback tile showed as " · 0 of 0".
        let clipName = enabledProperty(.playbackContentsName)?.currentString().flatMap { $0.isEmpty ? nil : $0 }
        let clipNumber = enabledProperty(.playbackContentsNumber)?.currentUInt32().map { Int($0) }
        let clipCount = enabledProperty(.playbackContentsTotalNumber)?.currentUInt32().map { Int($0) }

        // Out of playback nothing plays: after a Rec Review a BURANO was back on the live picture (Record) with its playing
        // speed still at 1/1 (BURANO: back on Record with playing speed at 1/1).
        return PlaybackState(
            isPlaying: review && inReview == false ? false : isPlaying,
            inReview: review ? inReview : nil,
            clipName: clipName,
            clipNumber: clipNumber,
            clipCount: clipCount,
            position: nil,   // Sony has no position property
            duration: nil,
            capabilities: caps
        )
    }

    /// Playback through the camera's own buttons (Camera Button Function 0xD309), for bodies without Sony's Movie Play
    /// buttons: the FX3, which has none of 0xE021–E028. It needs Playback, ENTER, Left and Right in its button list
    /// (0xD208) and Camera Operating Mode (0xD0BC), which is all it says back: whether it's showing clips. Nothing
    /// reports playing or paused, or which clip. See docs/fx3-controls.md.
    func buttonPlayback() -> PlaybackState? {
        guard controls.contains(SDIControlCode.cameraButtonFunction.rawValue),
              let mode = propsByCode[SDIPropCode.cameraOperatingMode.rawValue]?.currentUInt8(),
              let list = propsByCode[SDIPropCode.cameraButtonList.rawValue]?.enumAllUInt16(),
              Set(list).isSuperset(of: [CameraButton.playback, .enter, .left, .right].map(\.rawValue))
        else { return nil }
        return PlaybackState(
            isPlaying: nil,
            inReview: mode == 0x02,
            capabilities: PlaybackCapabilities(playPause: true, stop: false, nextPrevious: true, seek: false,
                                               fastForwardRewind: true, recReview: false, live: false, review: true)
        )
    }

    // MARK: - Helpers

    /// Build a Choice ensuring at least one option (the current value itself when the camera returns none).
    /// A list of one is the camera saying there's nothing else to pick, so it isn't offered as a choice: the BURANO's
    /// codec (X-OCN LT) and project frame rate (23.98p) each came as a picker of one (BURANO).
    private func choice<V: Sendable & Hashable>(_ value: V, opts: [V], isWritable: Bool) -> Choice<V> {
        Choice(value, options: opts.isEmpty ? [value] : opts, isWritable: isWritable && !(opts.count == 1 && opts[0] == value))
    }

    private func resolutionLabel(_ raw: UInt32) -> String {
        // upper 16 bits = width, lower 16 bits = height
        let w = Int((raw >> 16) & 0xFFFF)
        let h = Int(raw & 0xFFFF)
        guard w > 0, h > 0 else { return "0x\(String(raw, radix: 16, uppercase: true))" }
        return "\(w)x\(h)"
    }

    private func fileFormatLabel(_ raw: UInt8) -> String {
        fileFormatNames[raw] ?? "0x\(String(raw, radix: 16, uppercase: true))"
    }

    private func recordingSettingLabel(_ raw: UInt16) -> String {
        recordingSettingNames[raw] ?? "0x\(String(raw, radix: 16, uppercase: true))"
    }

    private func desqueezeLabel(_ raw: UInt16) -> String {
        if let name = desqueezeNames[raw] { return name }
        return String(format: "%.2fx", Double(raw) / 1000.0)
    }

    /// Shutter speed from UINT32 (upper 2B=num, lower 2B=denom) → human label.
    /// Special: 0x00000000=BULB, 0xFFFFFFFF=nothing.
    private func shutterSpeedLabel(_ raw: UInt32) -> String {
        if raw == 0x00000000 { return "BULB" }
        if raw == 0xFFFFFFFF { return "—" }
        let num = Int((raw >> 16) & 0xFFFF)
        let den = Int(raw & 0xFFFF)
        guard den > 0 else { return "—" }
        // Denominator = 0x000A (10) → real-number display (e.g. "1.5\"")
        if den == 10 {
            let secs = Double(num) / 10.0
            if secs == secs.rounded() { return "\(Int(secs))\"" }
            return String(format: "%.1f\"", secs)
        }
        // Numerator = 1 → fraction (e.g. "1/50")
        if num == 1 { return "1/\(den)" }
        return "\(num)/\(den)"
    }

    private func focusModeLabel(_ raw: UInt16) -> String {
        focusModeNames[raw] ?? "0x\(String(raw, radix: 16, uppercase: true))"
    }

    /// BaseLook UINT16 → display label. Upper byte: 0x00=preset, 0x01=user.
    /// `names` overrides with camera-reported display strings from GetDisplayStringList.
    private func lutLabel(_ raw: UInt16, names: [UInt16: String]) -> String {
        if let name = names[raw] { return name }
        let hi = UInt8((raw >> 8) & 0xFF)
        let lo = Int(raw & 0xFF)
        return hi == 0x01 ? "User \(lo)" : "Preset \(lo)"
    }
}

// MARK: - Value encoding helpers for writes

/// Encode shutter angle for SDIO_SetExtDevicePropValue: UINT32 = angle × 1000
public func encodeShutterAngle(_ degrees: Double) -> Data {
    let raw = UInt32(degrees * 1000)
    var d = Data(); d.appendLE(raw); return d
}

/// Encode ISO sensitivity: UINT32 direct value
public func encodeISO(_ iso: Int) -> Data {
    var d = Data(); d.appendLE(UInt32(iso)); return d
}

/// Encode Exposure Index: UINT16 direct value
public func encodeEI(_ ei: UInt16) -> Data {
    var d = Data(); d.appendLE(ei); return d
}

/// Encode color temperature: UINT16 direct Kelvin
public func encodeKelvin(_ kelvin: Double) -> Data {
    var d = Data(); d.appendLE(UInt16(kelvin)); return d
}

/// Encode WB tint: INT8
public func encodeTint(_ tint: Double) -> Data {
    let clamped = Int8(min(max(tint, -99), 99))
    return Data([UInt8(bitPattern: clamped)])
}

/// Encode WB tint (negative = green, positive = magenta) for FX3 0xD210 (G-M biaxial): UINT8 = 0xC0 - value/0.25,
/// so M9.00 is 0x9C and G9.00 is 0xE4.
public func encodeTintGM(_ tint: Double) -> Data {
    let clamped = min(max(tint, -9.0), 9.0)
    return Data([UInt8(192.0 - (clamped / 0.25).rounded())])
}

/// Encode frame rate by camera label: UINT8
public func encodeFrameRate(_ label: String) -> Data? {
    let codes = FrameRateCode.allCases
    guard let code = codes.first(where: { $0.label == label }) else { return nil }
    return Data([code.rawValue])
}

/// Encode ND variable value: UINT64, upper 4B=numerator, lower 4B=denominator
public func encodeNDTransmittance(_ fraction: Double) -> Data {
    let clamped = min(max(fraction, 0), 1)
    let scale: UInt32 = 10_000
    let num = UInt32(clamped * Double(scale))
    let den = scale
    let raw: UInt64 = (UInt64(num) << 32) | UInt64(den)
    var d = Data(); d.appendLE(raw); return d
}

/// Encode resolution "WxH" → UINT32 (width<<16)|height
public func encodeResolution(_ label: String) -> Data? {
    let parts = label.split(separator: "x")
    guard parts.count == 2, let w = UInt32(parts[0]), let h = UInt32(parts[1]) else { return nil }
    let raw = (w << 16) | (h & 0xFFFF)
    var d = Data(); d.appendLE(raw); return d
}

/// File format (Movie) 0xD241 codec family codes → display names.
/// Every File Format (Movie) value Sony's cameras use. The BURANO reports X-OCN LT as 0x1A, which showed as "0x1A"
/// while the table stopped at 0x14 (BURANO, MPC-2610).
public let fileFormatNames: [UInt8: String] = [
    0x01: "DVD", 0x02: "M2PS", 0x03: "AVCHD",
    0x04: "MP4", 0x05: "DV", 0x06: "XAVC", 0x07: "MXF", 0x08: "XAVC S 4K", 0x09: "XAVC S HD",
    0x0A: "XAVC HS 8K", 0x0B: "XAVC HS 4K", 0x0C: "XAVC S-L 4K",
    0x0D: "XAVC S-L HD", 0x0E: "XAVC S-I 4K", 0x0F: "XAVC S-I HD",
    0x10: "XAVC I", 0x11: "XAVC L", 0x12: "XAVC Proxy", 0x13: "XAVC HS HD", 0x14: "XAVC S-I DCI 4K",
    0x15: "XAVC H-I HQ", 0x16: "XAVC H-I SQ", 0x17: "XAVC H-L",
    0x18: "X-OCN XT", 0x19: "X-OCN ST", 0x1A: "X-OCN LT",
    0x1B: "XAVC HS-L 422", 0x1C: "XAVC HS-L 420", 0x1D: "XAVC S-L 422", 0x1E: "XAVC S-L 420",
    0x1F: "XAVC S-I 422", 0x20: "MPEG HD 422",
]

/// Encode file format label → UINT8
public func encodeFileFormat(_ label: String) -> Data? {
    guard let raw = fileFormatNames.first(where: { $0.value == label })?.key else { return nil }
    return Data([raw])
}

/// Reverse-lookup recording-setting label → UINT16
/// Recording Setting (Movie) 0xD242 values as Sony names them. The camera's own list says which apply
/// to the current codec and frame rate; on the FX3 it's display-only under XAVC S-I.
public let recordingSettingNames: [UInt16: String] = [
    0x0001: "60p 50M / XAVC S",
    0x0002: "30p 50M / XAVC S",
    0x0003: "24p 50M / XAVC S",
    0x0004: "50p 50M / XAVC S",
    0x0005: "25p 50M / XAVC S",
    0x0006: "60i 24M(FX) / AVCHD",
    0x0007: "50i 24M(FX) / AVCHD",
    0x0008: "60i 17M(FH) / AVCHD",
    0x0009: "50i 17M(FH) / AVCHD",
    0x000A: "60p 28M(PS) / AVCHD",
    0x000B: "50p 28M(PS) / AVCHD",
    0x000C: "24p 24M(FX) / AVCHD",
    0x000D: "25p 24M(FX) / AVCHD",
    0x000E: "24p 17M(FH) / AVCHD",
    0x000F: "25p 17M(FH) / AVCHD",
    0x0010: "120p 50M (1280x720) / XAVC S",
    0x0011: "100p 50M (1280x720) / XAVC S",
    0x0012: "1920x1080 30p 16M / MP4",
    0x0013: "1920x1080 25p 16M / MP4",
    0x0014: "1280x720 30p 6M / MP4",
    0x0015: "1280x720 25p 6M / MP4",
    0x0016: "1920x1080 60p 28M / MP4",
    0x0017: "1920x1080 50p 28M / MP4",
    0x0018: "60p 25M / XAVC S HD",
    0x0019: "50p 25M / XAVC S HD",
    0x001A: "30p 16M / XAVC S HD",
    0x001B: "25p 16M / XAVC S HD",
    0x001C: "120p 100M (1920x1080) / XAVC S HD",
    0x001D: "100p 100M (1920x1080) / XAVC S HD",
    0x001E: "120p 60M (1920x1080) / XAVC S HD",
    0x001F: "100p 60M (1920x1080) / XAVC S HD",
    0x0020: "30p 100M / XAVC S 4K",
    0x0021: "25p 100M / XAVC S 4K",
    0x0022: "24p 100M / XAVC S 4K",
    0x0023: "30p 60M / XAVC S 4K",
    0x0024: "25p 60M / XAVC S 4K",
    0x0025: "24p 60M / XAVC S 4K",
    0x0026: "600M 422 10bit",
    0x0027: "500M 422 10bit",
    0x0028: "400M 420 10bit",
    0x0029: "300M 422 10bit",
    0x002A: "280M 422 10bit",
    0x002B: "250M 422 10bit",
    0x002C: "240M 422 10bit",
    0x002D: "222M 422 10bit",
    0x002E: "200M 422 10bit",
    0x002F: "200M 420 10bit",
    0x0030: "200M 420 8bit",
    0x0031: "185M 422 10bit",
    0x0032: "150M 420 10bit",
    0x0033: "150M 420 8bit",
    0x0034: "140M 422 10bit",
    0x0035: "111M 422 10bit",
    0x0036: "100M 422 10bit",
    0x0037: "100M 420 10bit",
    0x0038: "100M 420 8bit",
    0x0039: "93M 422 10bit",
    0x003A: "89M 422 10bit",
    0x003B: "75M 420 10bit",
    0x003C: "60M 420 8bit",
    0x003D: "50M 422 10bit",
    0x003E: "50M 420 10bit",
    0x003F: "50M 420 8bit",
    0x0040: "45M 420 10bit",
    0x0041: "30M 420 10bit",
    0x0042: "25M 420 8bit",
    0x0043: "16M 420 8bit",
    0x0044: "520M 422 10bit",
    0x0045: "260M 422 10bit",
]

/// Encode a recording setting (bitrate) by its label: UINT16.
public func encodeRecordingSetting(_ label: String) -> Data? {
    guard let raw = recordingSettingNames.first(where: { $0.value == label })?.key else { return nil }
    var d = Data(); d.appendLE(raw); return d
}

/// De-squeeze display ratio 0xE0A4 named values → label.
public let desqueezeNames: [UInt16: String] = [
    0x03E8: "Off", 0x0514: "1.3x", 0x05DC: "1.5x", 0x07D0: "2.0x",
]

/// Encode de-squeeze label → UINT16 ratio×1000
public func encodeDesqueeze(_ label: String) -> Data? {
    guard let raw = desqueezeNames.first(where: { $0.value == label })?.key else { return nil }
    var d = Data(); d.appendLE(raw); return d
}

