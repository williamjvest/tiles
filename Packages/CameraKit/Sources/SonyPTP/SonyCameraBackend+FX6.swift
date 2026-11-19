import CameraCore
import Foundation

// The FX6's own controls (docs/fx6-controls.md): each measured on one, set through this path and read back.
extension SonyCameraBackend {
    func sendFX6(_ command: CameraCommand) async {
        guard isProBody else { return }
        let idle = state.recording.state == .idle && state.recording.request == nil
        switch command {
        case .setShootingMode(let label):
            // Each mode brings its own white balance, look and exposure: never mid-take.
            guard idle, let raw = StateMapper.shootingModes.first(where: { $0.value == label })?.key else { return }
            var data = Data(); data.appendLE(raw)
            await setProp(code: SDIPropCode.movieShootingMode.rawValue, data: data)
        case .setGain(let db):
            await setProp(code: SDIPropCode.gainDbValue.rawValue, data: Data([UInt8(bitPattern: Int8(clamping: db))]))
        case .setBaseSensitivity(let label):
            guard let raw = StateMapper.baseSensitivities.first(where: { $0.value == label })?.key else { return }
            await setProp(code: SDIPropCode.gainBaseSensitivity.rawValue, data: Data([raw]))
        case .setRecordedLUT(let on):
            // Where each setting goes can be changed on the camera, and a changed-only read may not carry it: read it
            // all again first, so the setting written is the one that reaches the recording now.
            guard idle, await requestFetch(.full) == nil,
                  let code = StateMapper.recordedLUTSetting(rawProps[SDIPropCode.monitorLUTOutputs.rawValue])
            else { return }
            await setProp(code: code.rawValue, data: Data([on ? 0x02 : 0x01]))
        case .setProxyRecording(let on):
            guard idle else { return }
            await setProp(code: SDIPropCode.recorderControlProxy.rawValue, data: Data([on ? 0x01 : 0x00]))
        case .setECS(let on):
            await setProp(code: SDIPropCode.ecsSetting.rawValue, data: Data([on ? 0x02 : 0x01]))
        case .stepECS(let by):
            guard state.ecs?.canStep == true, by != 0 else { return }
            _ = await stepControl(.shutterECSStep, by: by)
            await fetchChangedProps()
        case .setIrisAuto(let on):
            await setProp(code: SDIPropCode.irisModeSetting.rawValue, data: Data([on ? 0x01 : 0x02]))
        case .setNDAuto(let on):
            await setProp(code: SDIPropCode.ndFilterModeSetting.rawValue, data: Data([on ? 0x01 : 0x02]))
        case .setISOAuto(let on):
            await setProp(code: SDIPropCode.gainControlSetting.rawValue, data: Data([on ? 0x01 : 0x02]))
        case .driveFocus(let speed):
            await drive(.focusOperation, speed: speed, fastest: state.focusDrive?.maxSpeed ?? 0)
        case .driveZoom(let speed):
            await drive(.zoomOperation, speed: speed, fastest: state.zoomDrive?.maxSpeed ?? 0)
        case .pressAssignable(let id):
            await pressAssignable(id)
        default:
            break
        }
    }

    /// The LUT on monitoring outputs (`StateMapper.lutOutputs`): one, by its id, or with nil every one of them. Never the
    /// setting that reaches the recording, whatever the id says.
    func setLUTOutputs(_ on: Bool, output: String?) async {
        // Where each setting goes, read again first (as `setRecordedLUT`): one reassigned on the camera to the
        // recording since the last full read must not be taken for a monitoring output.
        guard await requestFetch(.full) == nil, let dest = rawProps[SDIPropCode.monitorLUTOutputs.rawValue] else { return }
        let recorded = StateMapper.recordedLUTSetting(dest)
        let outputs = StateMapper(props: Array(rawProps.values)).lutOutputs() ?? []
        let ids = output.map { [$0] } ?? outputs.map(\.id)
        for id in ids where outputs.contains(where: { $0.id == id }) {
            guard let n = Int(id.dropFirst(3)), id.hasPrefix("LUT"), (1...3).contains(n) else { continue }
            let code = StateMapper.lutSettings[n - 1]
            guard code != recorded else { continue }
            await setProp(code: code.rawValue, data: Data([on ? 0x02 : 0x01]))
        }
    }

    // MARK: Focus and zoom

    /// Push Auto Focus (0xD05E): autofocus while it's held, so it's held long enough for the lens to settle, then let
    /// go, as an assignable button is (an Up the camera doesn't answer is sent again, and on the next session: a lens
    /// left autofocusing mid-take is the thing to avoid). During a take too: a push mid-take is what it's for. Only in
    /// manual focus (`CameraState.canPushAutoFocus`): with AF on, the same press is Push MF, stopping autofocus.
    func pushAutoFocus() async {
        guard state.canPushAutoFocus else { return warn("Autofocus is on, so there's nothing to push: switch to MF first") }
        let code = SDIPropCode.pushAutoFocus.rawValue
        guard await writeButton(code, .down) == PTPResponseCode.ok.rawValue else {
            return warn("The camera didn't take the push autofocus")
        }
        try? await Task.sleep(for: .milliseconds(1200))
        if await !releaseButton(code) {
            buttonsToRelease.insert(code)
            warn("Push autofocus may still be held on the camera: Tiles will let it go when it can")
        }
        await fetchChangedProps()
    }

    /// Starts, changes or stops a lens motor. The camera drives until it's told 0 (an FX6 ran its focus for 6 s on one
    /// +1), so a held control renews the speed about every 200 ms, which sends the camera nothing new, and a watchdog
    /// sends the 0 when nothing has renewed it for 600 ms.
    func drive(_ control: SDIControlCode, speed: Int, fastest: Int) async {
        let speed = min(max(speed, -fastest), fastest)
        guard speed != 0 else {
            lensDrives[control] = nil
            await stopMotor(control)
            return
        }
        let was = lensDrives[control]?.speed
        lensDrives[control] = (speed, .now)
        startLensWatchdog()
        if was != speed, await stepControl(control, by: speed) != PTPResponseCode.ok.rawValue {
            lensDrives[control] = nil
            await stopMotor(control)
        }
    }

    /// Tells a motor 0. One the camera didn't answer OK is kept in `drivesToStop` and told again as soon as there's a
    /// session: a stop that times out on a wedged link must not be forgotten while the lens runs on.
    func stopMotor(_ control: SDIControlCode) async {
        if await stepControl(control, by: 0) == PTPResponseCode.ok.rawValue {
            drivesToStop.remove(control)
        } else {
            drivesToStop.insert(control)
        }
    }

    private func startLensWatchdog() {
        guard lensWatchdog == nil else { return }
        lensWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, await self.stopUnrenewedDrives() else { return }
            }
        }
    }

    /// Stops each motor nothing renewed for 600 ms. False once none is driving.
    private func stopUnrenewedDrives() async -> Bool {
        let now = ContinuousClock.now
        for (control, drive) in lensDrives where now - drive.renewed > .milliseconds(600) {
            lensDrives[control] = nil
            await stopMotor(control)
        }
        guard lensDrives.isEmpty else { return true }
        lensWatchdog = nil
        return false
    }

    /// Every motor told 0: those driving, and any whose 0 hasn't landed yet. One that still doesn't is told again on
    /// the next session.
    func stopLensDrives() async {
        drivesToStop.formUnion(lensDrives.keys)
        lensDrives = [:]
        lensWatchdog?.cancel()
        lensWatchdog = nil
        for control in drivesToStop { await stopMotor(control) }
    }

    // MARK: Assignable buttons

    /// Presses an assignable button, Down then Up, if what it's set to do is a function Tiles presses
    /// (`StateMapper.pressableFunctions`). The assignment is read again just before, so a button reassigned on the camera
    /// since the last read isn't pressed on an old one; `expecting` a function by name (False Color's), a button set to
    /// anything else by then isn't pressed at all. An Up that fails is sent again: a button is never left held.
    func pressAssignable(_ id: Int, expecting: String? = nil) async {
        guard let button = StateMapper.assignables.first(where: { $0.id == id }) else { return }
        if assignableNames.isEmpty, let transport,
           let names = await fetchDisplayStrings(transport: transport, type: SDIODisplayStringListType.buttonAssignShort) {
            assignableNames = names
        }
        guard await readNow() else { return warn("Button \(button.id) not pressed: the camera didn't answer a read first") }
        guard let function = rawProps[button.assignment]?.currentUInt8(),
              StateMapper.isPressable(function: function, name: assignableNames[UInt16(function)]) else { return }
        if let expecting, assignableNames[UInt16(function)] != expecting {
            return warn("Button \(button.id) not pressed: it's set to \(assignableNames[UInt16(function)] ?? "something else") now, not \(expecting)")
        }
        guard await writeButton(button.press, .down) == PTPResponseCode.ok.rawValue else { return }
        try? await Task.sleep(for: .milliseconds(100))
        if await !releaseButton(button.press) {
            // Down landed and Up didn't: it's let go as soon as there's a session again.
            buttonsToRelease.insert(button.press)
            warn("Button \(button.id) may still be held on the camera: Tiles will let it go when it can")
        }
        await fetchChangedProps()
    }

    /// Up, a few times if the camera doesn't answer OK. True once it has.
    func releaseButton(_ code: UInt16) async -> Bool {
        for attempt in 0..<4 {
            if await writeButton(code, .up) == PTPResponseCode.ok.rawValue { return true }
            try? await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
        }
        return false
    }

    /// On the camera's tile until the next read, and in the Activity Log.
    private func warn(_ message: String) {
        ActivityLog.shared.note(host, message)
        state.warnings.append(message)
        emit()
    }

    /// A button property written straight to the camera: the tools' raw write refuses these codes.
    private func writeButton(_ code: UInt16, _ value: ButtonValue) async -> UInt16 {
        guard let transport else { return PTPResponseCode.sessionNotOpen.rawValue }
        var data = Data(); data.appendLE(value.rawValue)
        do {
            let (resp, _) = try await transport.execute(opCode: SDIOOpCode.setExtDevicePropValue.rawValue,
                                                        params: [UInt32(code), sdioExtendedCodesFlag], sendData: data)
            return resp.responseCode
        } catch {
            return PTPResponseCode.generalError.rawValue
        }
    }
}
