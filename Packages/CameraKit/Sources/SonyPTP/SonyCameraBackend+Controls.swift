import Foundation
import Network
import CameraCore
import SSHTunnel

extension SonyCameraBackend {
    // MARK: - REC control [Architecture rule 6]

    func handleRec(start: Bool) async {
        // Never optimistic: set request, wait for camera to confirm [Architecture rule 6]. A stop is never dropped:
        // one asked for while a start is still being confirmed takes its place (a take started and stopped quickly,
        // or linked cameras that confirm at different speeds). A start asked for while a stop is still being
        // confirmed goes as soon as the camera has stopped: a camera closing a long take (an FX5 at Stopping for
        // seconds) would otherwise miss the next linked take. The same press again is nothing more to send.
        startAfterStop = startAfterStop && !(!start && state.recording.request == .stop)
        if let pending = state.recording.request {
            if pending == .stop, start {
                startAfterStop = true
                ActivityLog.shared.note(host, "REC start asked for while the camera was still stopping: starting once it has")
                return
            }
            guard pending == .start, !start else { return }
            recConfirmTask?.cancel()
            ActivityLog.shared.note(host, "REC stop asked for while the start was still being confirmed: stopping")
        }
        if !start { startAfterStop = false }

        state.recording.request = start ? .start : .stop
        state.recording.failure = nil
        emit()

        // `.connected` is emitted before the first property fetch lands. A REC tapped in that window waits up to
        // 2 s for the recording state instead of being dropped without a word.
        var waited = 0
        while state.recording.state == .unknown && waited < 40 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        guard state.recording.state != .unknown else {
            state.recording.request = nil
            state.recording.failure = RecordingControl.Failure.notReported
            emit()
            return
        }

        var succeeded = await sendRecCommand(start: start)
        if !succeeded, !start {
            // A stop the camera didn't take is sent once more: Movie Rec (Hold) Up is absolute, and the toggle is only
            // pressed while the camera says it's recording, so neither can start a take.
            ActivityLog.shared.note(host, "REC stop: the camera didn't take the command; sending it once more")
            try? await Task.sleep(for: .milliseconds(500))
            succeeded = await sendRecCommand(start: false)
        }
        guard succeeded else {
            state.recording.request = nil
            state.recording.failure = RecordingControl.Failure.notSent
            ActivityLog.shared.note(host, "REC \(start ? "start" : "stop"): the camera didn't take the command")
            emit()
            return
        }

        // Wait for camera to report new recording state [Architecture rule 6]
        recConfirmTask?.cancel()
        recConfirmTask = Task {
            let sent = Date()
            var deadline = sent.addingTimeInterval(config.recConfirmTimeout)
            var sentAgain = false
            while true {
                while Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    guard state.recording.request != nil else { return }  // already confirmed
                    // The recorder says the change is under way (an FX5's, FX6's or BURANO's Preparing or Stopping):
                    // closing a long take, proxy and all, can outlast the usual wait. Waited on, 30 s at most.
                    if let status = recorderStatus, (start && status == 0x02) || (!start && status == 0x05) {
                        deadline = max(deadline, min(Date().addingTimeInterval(2), sent.addingTimeInterval(30)))
                    }
                    if settleRec(start: start) { await startIfAsked(after: start); return }
                    // Trigger a diff fetch to get fresh state
                    await fetchChangedProps()
                }
                // Timeout: re-read recording state [Architecture rule 6]. What it says now counts: a confirmation
                // that came in after the last look isn't a failure.
                guard !Task.isCancelled else { return }
                await fetchAllProps()
                guard state.recording.request != nil else { return }
                if settleRec(start: start) { await startIfAsked(after: start); return }
                // A stop the camera still says it's recording through is sent once more, and waited for again: an FX5
                // has kept rolling after a linked stop until REC was pressed a second time. Up can't start a take; a
                // start is never sent again (a late start would roll a take nobody asked for at that moment).
                if !start, !sentAgain, cameraRecording == true {
                    sentAgain = true
                    ActivityLog.shared.note(host, "REC stop not confirmed in \(Int(Date().timeIntervalSince(sent).rounded())) s, "
                        + "the camera still recording (\(recordingReport)): sending it once more")
                    if await sendRecCommand(start: false) {
                        deadline = Date().addingTimeInterval(config.recConfirmTimeout)
                        continue
                    }
                }
                startAfterStop = false  // the camera is still rolling, or never said: a start would be nothing new
                state.recording.request = nil
                state.recording.failure = RecordingControl.Failure.notConfirmed(start: start)
                state.takeStartedAt = nil
                ActivityLog.shared.note(host, "REC \(start ? "start" : "stop") not confirmed in "
                    + "\(Int(Date().timeIntervalSince(sent).rounded())) s: \(recordingReport)")
                emit()
                return
            }
        }
    }

    /// A start asked for while this stop was on its way, now the camera has stopped.
    private func startIfAsked(after start: Bool) async {
        guard !start, startAfterStop else { return }
        startAfterStop = false
        await handleRec(start: true)
    }

    /// Settles a REC request the camera now reports done: true if it did.
    private func settleRec(start: Bool) -> Bool {
        if start, cameraRecording == true {
            state.recording.state = .recording
            state.recording.request = nil
            state.takeStartedAt = Date()
        } else if !start, cameraStopped {
            state.recording.state = .idle
            state.recording.request = nil
            state.takeStartedAt = nil
        } else {
            return false
        }
        emit()
        return true
    }

    /// The recorder's status (0xE010) on a body that reports REC by it (FX5, FX6, BURANO), nil on one with 0xD21D.
    var recorderStatus: UInt8? {
        guard rawProps[SDIPropCode.movieRecordingState.rawValue] == nil else { return nil }
        return rawProps[SDIPropCode.recorderMainStatus.rawValue]?.currentUInt8()
    }

    /// What the camera last said of its recording, for the Activity Log.
    var recordingReport: String {
        if let raw = rawProps[SDIPropCode.movieRecordingState.rawValue]?.currentUInt8() {
            return String(format: "Movie Recording State 0x%02X", raw)
        }
        guard let raw = recorderStatus else { return "no recording state" }
        let names = [0x00: "Idle", 0x01: "Ready", 0x02: "Preparing to Record", 0x03: "Standby", 0x04: "Recording",
                     0x05: "Stopping"]
        return "recorder \(names[Int(raw)] ?? String(format: "0x%02X", raw))"
    }

    /// Whether a take is rolling, per 0xD21D (0x01 Recording) or, on an FX6/BURANO, which don't list it, the
    /// recorder's status 0xE010 (0x04 Recording). Nil until the camera has said.
    var cameraRecording: Bool? {
        if let raw = rawProps[SDIPropCode.movieRecordingState.rawValue]?.currentUInt8() { return raw == 0x01 }
        if let raw = rawProps[SDIPropCode.recorderMainStatus.rawValue]?.currentUInt8() { return raw == 0x04 }
        return nil
    }

    /// Whether a stop has finished: 0xD21D Not Recording or Failed; 0xE010 Idle, Ready or Standby (not Stopping,
    /// which is the take still ending, and not Preparing, which is one starting).
    var cameraStopped: Bool {
        if let raw = rawProps[SDIPropCode.movieRecordingState.rawValue]?.currentUInt8() { return raw == 0x00 || raw == 0x02 }
        if let raw = rawProps[SDIPropCode.recorderMainStatus.rawValue]?.currentUInt8() { return [0x00, 0x01, 0x03].contains(raw) }
        return false
    }

    /// Send REC. Movie Rec Button (Hold) 0xD2C8 is absolute: Down starts recording, Up stops it.
    /// Verified on a real FX3 (fixtures/fx3-rec-hold-*.jsonl): Down while recording and Up while stopped
    /// are accepted and change nothing; Up stops a take another session started; a dropped session does NOT
    /// stop the take. The toggle 0xF001 is only a fallback for bodies that don't list 0xD2C8, and since it is
    /// relative it is only pressed when the camera is not already in the requested state.
    func sendRecCommand(start: Bool) async -> Bool {
        guard let transport else { return false }
        let controls = sessionInfo?.extDeviceInfo.controlCodes ?? []
        let presses: [(code: SDIControlCode, value: ButtonValue)]
        if controls.contains(SDIControlCode.movieRecButtonHold.rawValue) {
            presses = [(.movieRecButtonHold, start ? .down : .up)]
        } else if controls.contains(SDIControlCode.movieRecButtonToggle.rawValue) {
            // A toggle flips whatever the camera is doing, so it is never pressed blind.
            guard let recording = cameraRecording else { return false }
            presses = recording == start ? [] : [(.movieRecButtonToggle, .down), (.movieRecButtonToggle, .up)]
        } else {
            return false  // this body offers no REC control over the network
        }
        do {
            for press in presses {
                var data = Data()
                data.appendLE(press.value.rawValue)  // UINT16
                let (resp, _) = try await transport.execute(
                    opCode: SDIOOpCode.controlDevice.rawValue,
                    params: [UInt32(press.code.rawValue), sdioExtendedCodesFlag],
                    sendData: data
                )
                guard resp.responseCode == PTPResponseCode.ok.rawValue else { return false }
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Property set helpers

    func setProp(code: UInt16, data: Data) async {
        guard let transport else { return }
        do {
            let (resp, _) = try await transport.execute(
                opCode: SDIOOpCode.setExtDevicePropValue.rawValue,
                params: [UInt32(code), sdioExtendedCodesFlag],
                sendData: data
            )
            if resp.responseCode != PTPResponseCode.ok.rawValue {
                // Log the camera's rejection; clear any pending optimistic value.
                state.warnings.append("Set 0x\(String(code, radix:16, uppercase:true)) rejected: 0x\(String(resp.responseCode, radix:16, uppercase:true))")
                emit()
                return
            }
        } catch {
            state.warnings.append("Set 0x\(String(code, radix:16, uppercase:true)) failed: \(error)")
            emit()
            return
        }
        if Self.optionDrivers.contains(code) {
            // Give the camera a moment to switch modes, then re-read the option lists. The FX3 family carries a
            // list that changed without its value moving in a changed-only fetch (verified live on FX3: XAVC S HD
            // -> HS 4K reported 0xD286 and 0xD242), so it gets the ~0.5 KB changed-only fetch, not the ~9.5 KB full
            // read. Other bodies haven't been checked: they keep the full read.
            try? await Task.sleep(for: .milliseconds(400))
            if state.model?.contains("FX3") == true {
                await fetchChangedProps()
            } else {
                await fetchAllProps()
            }
        } else {
            await fetchChangedProps()
        }
    }

    /// Properties that change what other properties offer: the codec decides the frame rates, the frame rate the
    /// bitrates, base ISO the EI list, the WB mode whether Kelvin is settable, the shutter mode angle vs speed.
    /// After setting one, re-read everything (~9.5 KB on the FX3) rather than trust a changed-only fetch to carry
    /// option lists whose values didn't move. These are rare, deliberate changes.
    static let optionDrivers: Set<UInt16> = [
        SDIPropCode.fileFormatMovie.rawValue, SDIPropCode.recordingFrameRate.rawValue,
        SDIPropCode.recordingSettingMovie.rawValue, SDIPropCode.gainBaseIso.rawValue,
        SDIPropCode.shutterMode.rawValue, SDIPropCode.whiteBalance.rawValue, SDIPropCode.wbModeSetting.rawValue,
        // An FX6's: a shooting mode brings its own of nearly everything; ECS, auto iris and proxy recording turn
        // others display-only or show them.
        SDIPropCode.movieShootingMode.rawValue, SDIPropCode.ecsSetting.rawValue, SDIPropCode.irisModeSetting.rawValue,
        SDIPropCode.recorderControlProxy.rawValue, SDIPropCode.ndFilterModeSetting.rawValue,
        SDIPropCode.gainControlSetting.rawValue, SDIPropCode.gainBaseSensitivity.rawValue,
    ]

    func setISO(_ iso: Int) async {
        // Determine which property is active [Gotcha 10]
        let useEI = rawProps[SDIPropCode.exposureIndex.rawValue]?.isEnabled == .enabled
        if useEI {
            // EI is UINT16: a value it can't hold (ISO 102400 and up) is refused, not trapped on.
            guard let ei = UInt16(exactly: iso) else {
                state.warnings.append("ISO \(iso) can't be set while the camera uses Exposure Index")
                emit()
                return
            }
            await setProp(code: SDIPropCode.exposureIndex.rawValue, data: encodeEI(ei))
        } else {
            await setProp(code: SDIPropCode.isoSensitivity.rawValue, data: encodeISO(iso))
        }
    }

    func setBaseISO(_ iso: Int) async {
        guard let raw = baseISONames.first(where: { $0.value == iso })?.key else {
            state.warnings.append("Unknown base ISO: \(iso)")
            emit()
            return
        }
        // 1. Switch the base selector (0xD020: 0x01=High, 0x02=Low).
        await setProp(code: SDIPropCode.gainBaseIso.rawValue, data: Data([raw]))
        // 2. Set ISO/EI to the base's native value — without this the camera would show the previously
        //    selected ISO for that base rather than the base value itself.
        await setISO(iso)
    }

    func setShutterAngle(_ degrees: Double) async {
        // Only effective when shutter is in angle mode [Gotcha 9]
        await setProp(code: SDIPropCode.shutterAngle.rawValue, data: encodeShutterAngle(degrees))
    }

    func setNDPreset(_ preset: String) async {
        // A body with ND densities (the BURANO, StateMapper.nd): Clear is the ND off, and a density puts it on and
        // picks it (0xD14F, OD × 100). Both measured on a BURANO.
        if rawProps[SDIPropCode.ndOpticalDensity.rawValue] != nil, !["ON", "OFF"].contains(preset.uppercased()) {
            if preset == "Clear" {
                await setProp(code: SDIPropCode.ndFilter.rawValue, data: Data([0x01]))
                return
            }
            guard let od = Double(preset) else { return }
            if rawProps[SDIPropCode.ndFilter.rawValue]?.currentUInt8() != 0x02 {
                await setProp(code: SDIPropCode.ndFilter.rawValue, data: Data([0x02]))
            }
            var d = Data(); d.appendLE(UInt16((od * 100).rounded()))
            await setProp(code: SDIPropCode.ndOpticalDensity.rawValue, data: d)
            return
        }
        let val: UInt8 = preset.uppercased() == "ON" ? 0x02 : 0x01
        await setProp(code: SDIPropCode.ndFilter.rawValue, data: Data([val]))
    }

    func setVariableND(_ fraction: Double) async {
        await setProp(code: SDIPropCode.ndFilterValue.rawValue, data: encodeNDTransmittance(fraction))
    }

    /// "Auto" puts White Balance 0x5005 in AWB; "3200K" sets the color temperature, from AWB by way of C.Temp. first
    /// (setting the mode re-reads the properties, so Kelvin is settable by the time it's sent).
    func setWBPreset(_ preset: String) async {
        // One-push AWB: 0xD03B written Down then Up, as a press of the camera's AWB button (the BURANO).
        if preset == "AWB", rawProps[SDIPropCode.awb.rawValue] != nil {
            var down = Data(); down.appendLE(ButtonValue.down.rawValue)
            await setProp(code: SDIPropCode.awb.rawValue, data: down)
            try? await Task.sleep(for: .milliseconds(300))
            var up = Data(); up.appendLE(ButtonValue.up.rawValue)
            await setProp(code: SDIPropCode.awb.rawValue, data: up)
            return
        }
        let mode = SDIPropCode.whiteBalance.rawValue
        // An FX6 has no 0x5005: its White Balance Mode Setting (0xD00C) is Automatic or Manual.
        let setting = SDIPropCode.wbModeSetting.rawValue
        if preset == "Auto" {
            if rawProps[mode] == nil, rawProps[setting] != nil {
                await setProp(code: setting, data: Data([StateMapper.wbSettingAutomatic]))
                return
            }
            var d = Data(); d.appendLE(StateMapper.wbAuto)
            await setProp(code: mode, data: d)
            return
        }
        guard preset.hasSuffix("K"), let k = Double(preset.dropLast()) else { return }
        if rawProps[mode]?.currentUInt16() == StateMapper.wbAuto {
            var d = Data(); d.appendLE(StateMapper.wbColorTemperature)
            await setProp(code: mode, data: d)
            // A camera that refused the mode has said why; the Kelvin would only be refused too.
            guard rawProps[mode]?.currentUInt16() == StateMapper.wbColorTemperature else { return }
        }
        if rawProps[setting]?.currentUInt8() == StateMapper.wbSettingAutomatic {
            await setProp(code: setting, data: Data([StateMapper.wbSettingManual]))
            guard rawProps[setting]?.currentUInt8() == StateMapper.wbSettingManual else { return }
        }
        await setProp(code: SDIPropCode.colorTemperature.rawValue, data: encodeKelvin(k))
    }

    func setKelvin(_ kelvin: Double) async {
        await setProp(code: SDIPropCode.colorTemperature.rawValue, data: encodeKelvin(kelvin))
    }

    func setTint(_ tint: Double) async {
        // Use 0xD210 (G-M biaxial) if present on this camera, else 0xD00D (INT8)
        if rawProps[SDIPropCode.wbTintGM.rawValue] != nil {
            await setProp(code: SDIPropCode.wbTintGM.rawValue, data: encodeTintGM(tint))
        } else {
            await setProp(code: SDIPropCode.wbTint.rawValue, data: encodeTint(tint))
        }
    }

    func setIris(_ stop: Double) async {
        // F-Number on FX3 (0x5007); T-Number on BURANO/FX6 (0xD000).
        // Use whichever is present in the current prop list.
        let t = rawProps[SDIPropCode.tNumber.rawValue]
        let useF = rawProps[SDIPropCode.fNumber.rawValue] != nil && (t == nil || t?.isEnabled == .disabled)
        let code: UInt16 = useF ? SDIPropCode.fNumber.rawValue : SDIPropCode.tNumber.rawValue
        let raw = UInt16(stop * 100)
        var d = Data(); d.appendLE(raw)
        await setProp(code: code, data: d)
    }

    func setShutterSpeedCmd(_ label: String) async {
        // FX6/BURANO: 0xD016 (UINT64), sent as the camera's own value for that label, never built.
        if rawProps[SDIPropCode.shutterSpeed.rawValue] == nil,
           let prop = rawProps[SDIPropCode.shutterSpeedValue.rawValue] {
            // Speed mode: "Off" is Shutter Setting 0xD00F off, and a speed turns it on first, since 0xD016 is
            // display-only while it's off (StateMapper.cinemaShutterSpeed). An FX6 lists the speeds only in its
            // Get/Set list then.
            let setting = rawProps[SDIPropCode.shutterSetting.rawValue]
            if label == "Off" {
                if setting?.isSettable == true { await setProp(code: SDIPropCode.shutterSetting.rawValue, data: Data([0x01])) }
                return
            }
            let speeds = prop.enumCurrentUInt64().isEmpty && setting?.currentUInt8() == 0x01
                ? prop.enumAllUInt64() : prop.enumCurrentUInt64()
            guard let raw = speeds.first(where: { StateMapper.shutterSpeedLabel64($0) == label }) else {
                state.warnings.append("Unknown shutter speed: \(label)")
                emit()
                return
            }
            if let setting, setting.isSettable, setting.currentUInt8() == 0x01 {
                await setProp(code: SDIPropCode.shutterSetting.rawValue, data: Data([0x02]))
            }
            var d = Data(); d.appendLE(raw)
            await setProp(code: SDIPropCode.shutterSpeedValue.rawValue, data: d)
            return
        }
        // Reverse-lookup shutter speed label → UINT32
        guard let data = encodeShutterSpeedLabel(label) else {
            state.warnings.append("Unknown shutter speed: \(label)")
            emit()
            return
        }
        await setProp(code: SDIPropCode.shutterSpeed.rawValue, data: data)
    }

    func setShutterModeCmd(_ mode: ShutterMode) async {
        // 0xD010: 0x01=Speed, 0x02=Angle
        let val: UInt8 = mode == .speed ? 0x01 : 0x02
        await setProp(code: SDIPropCode.shutterMode.rawValue, data: Data([val]))
        // The BURANO's speed mode has its own on/off, Shutter Setting 0xD00F, settable only once in speed mode.
        // Left off, the shutter reads "Off" on the camera and no speed can be picked: what the first BURANO test hit
        // Switching to speed means wanting a speed, so it goes on.
        if mode == .speed, rawProps[SDIPropCode.shutterSetting.rawValue] != nil {
            await setProp(code: SDIPropCode.shutterSetting.rawValue, data: Data([0x02]))
        }
    }

    func setFocusModeCmd(_ label: String) async {
        // Where the AF / MF was read from (StateMapper.focusMode): an FX5's, FX6's or BURANO's Focus Mode Setting 0xD007,
        // UINT8, where there's no 0x500A.
        if rawProps[SDIPropCode.focusMode.rawValue].map({ $0.isEnabled == .disabled }) ?? true,
           rawProps[SDIPropCode.focusModeSetting.rawValue] != nil {
            guard let raw = StateMapper.focusModeSettings.first(where: { $0.value == label })?.key else {
                state.warnings.append("Unknown focus mode: \(label)")
                emit()
                return
            }
            await setProp(code: SDIPropCode.focusModeSetting.rawValue, data: Data([raw]))
            return
        }
        // Reverse-lookup focus mode label → UINT16
        guard let data = encodeFocusModeLabel(label) else {
            state.warnings.append("Unknown focus mode: \(label)")
            emit()
            return
        }
        await setProp(code: SDIPropCode.focusMode.rawValue, data: data)
    }

    /// A clip naming change. The camera answers a value it won't take with SDIE_OperationResults, not the response.
    func setClipNaming(_ code: SDIPropCode, data: Data?) async {
        guard let data else { return }
        if state.fileNaming?.failure != nil {
            state.fileNaming?.failure = nil
            emit()
        }
        await setProp(code: code.rawValue, data: data)
    }

    func setLUTCmd(_ label: String) async {
        // Reverse-lookup label → UINT16 BaseLook value using current lutNames map
        let match = lutNames.first(where: { $0.value == label })?.key
            ?? encodeLUTLabel(label)
        guard let raw = match else {
            state.warnings.append("Unknown LUT: \(label)")
            emit()
            return
        }
        var d = Data(); d.appendLE(raw)
        await setProp(code: SDIPropCode.baseLookValue.rawValue, data: d)
    }

    func setFrameRateVariable(_ on: Bool) async {
        // S&Q Mode Setting: 0x01 Off, 0x02 On (this sent 0x01 for on and 0x00, not a value, for off)
        await setProp(code: SDIPropCode.sqModeSetting.rawValue, data: Data([on ? 0x02 : 0x01]))
    }

    func setFrameRate(_ label: String) async {
        // Encode back via FrameRateCode lookup; reject unknown labels
        guard let data = encodeFrameRate(label) else {
            state.warnings.append("Unknown frame rate label: \(label)")
            emit()
            return
        }
        // Note: frame-rate changes require a camera restart; the option's restartRequired set
        // is set by StateMapper so the UI warns before calling this.
        await setProp(code: SDIPropCode.recordingFrameRate.rawValue, data: data)
    }

    func setResolution(_ label: String) async {
        // Encode "WxH" string → UINT32 (width<<16)|height
        guard let data = encodeResolution(label) else {
            state.warnings.append("Unknown resolution: \(label)")
            emit()
            return
        }
        await setProp(code: SDIPropCode.recordingResolution.rawValue, data: data)
    }

    func setFileFormat(_ label: String) async {
        guard let data = encodeFileFormat(label) else {
            state.warnings.append("Unknown file format: \(label)")
            emit()
            return
        }
        await setProp(code: SDIPropCode.fileFormatMovie.rawValue, data: data)
    }

    func setRecordingSetting(_ label: String) async {
        guard let data = encodeRecordingSetting(label) else {
            state.warnings.append("Unknown recording setting: \(label)")
            emit()
            return
        }
        await setProp(code: SDIPropCode.recordingSettingMovie.rawValue, data: data)
    }

    func setDesqueeze(_ label: String) async {
        guard let data = encodeDesqueeze(label) else {
            state.warnings.append("Unknown de-squeeze ratio: \(label)")
            emit()
            return
        }
        await setProp(code: SDIPropCode.desqueezeDisplayRatio.rawValue, data: data)
    }

    func setLook(_ on: Bool) async {
        let val: UInt8 = on ? 0x02 : 0x01
        // Prefer Monitor LUT Setting (All Line) 0xD04D; works regardless of picture profile.
        // Gamma Display Assist 0xD1FE is the fallback but is dispOnly unless S-Log/HLG is active.
        if rawProps[SDIPropCode.monitorLUTSetting.rawValue] != nil {
            await setProp(code: SDIPropCode.monitorLUTSetting.rawValue, data: Data([val]))
        } else {
            await setProp(code: SDIPropCode.gammaDisplayAssist.rawValue, data: Data([val]))
        }
    }
}

