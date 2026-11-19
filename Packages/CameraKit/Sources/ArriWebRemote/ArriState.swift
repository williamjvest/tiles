import CameraCore
import Foundation

extension ArriReading {
    /// Fills in everything the variables say. Connection, REC requests and latency are the backend's.
    public func apply(to state: inout CameraState, host: String) {
        state.make = .arri
        if let model = modelText, !model.isEmpty { state.model = model }

        // REC: a bool, or a state whose label says recording ("Recording", "REC"), never "ready" or "standby". One
        // that can't be read leaves what the backend knows from the camera accepting REC.
        if let rolling = recording() {
            state.recording.state = rolling ? .recording : .idle
        } else if state.recording.state == .unknown {
            state.recording.state = .idle
        }

        // Timecode, at the project rate (else the sensor's, rounded). An ALEXA Mini sends whole seconds only
        // (TimecodeHours / Minutes / Seconds, no frames); in free run the clock counts the frames between them.
        if let tc = timecodeParts ?? value(.timecode).flatMap(ArriFormat.timecode) {
            let rate = projectRate ?? (value(.fps)?.number ?? 24).rounded().asInt ?? 24
            let freeRun = snapshot.variables["TCIsFreeRun_Effective"]?.value.bool == true
            state.timecode = TimecodeClock(hours: tc.h, minutes: tc.m, seconds: tc.s, frames: tc.f, rate: max(rate, 1),
                                           fps: Double(max(rate, 1)), anchor: Date(),
                                           isRunning: state.recording.state == .recording || freeRun)
        }
        state.clipName = text(.clipName).flatMap { $0.isEmpty ? nil : $0 }

        // EI: the camera's own list, by its labels; else what it says it's at, read-only.
        let eiChoices = choices(.ei).compactMap { choice in ArriFormat.eiNumber(choice.label).map { (choice.index, $0) } }
        if let current = text(.ei).flatMap(ArriFormat.eiNumber), !eiChoices.isEmpty {
            let options = Array(Set(eiChoices.map(\.1) + [current])).sorted()
            state.iso = Choice(current, options: options, isWritable: isWritable(.ei))
        } else if let actual = value(.eiActual)?.number?.asInt ?? text(.ei).flatMap(ArriFormat.eiNumber) {
            state.iso = Choice(actual, options: [actual], isWritable: false)
        }
        state.nativeISOs = state.iso == nil ? [] : [800]

        // ND: the camera's filters by their labels ("ND 0.6" → 0.6, "ND  -" → Clear).
        let ndChoices = choices(.nd).map { ArriFormat.ndLabel($0.label) }
        if let current = text(.nd).map(ArriFormat.ndLabel) ?? text(.ndEffective).map(ArriFormat.ndLabel) {
            var options = ndChoices.isEmpty ? [current] : ndChoices
            if !options.contains(current) { options.append(current) }
            state.nd = NDState(preset: Choice(current, options: options, isWritable: isWritable(.nd) && !ndChoices.isEmpty))
        }

        // White balance: Kelvin and CC as levels within the camera's own range; the preset is the Kelvin's step.
        if let kelvinVariable = variable(.kelvin), let kelvin = kelvinVariable.value.number, kelvin.asInt != nil {
            let low = kelvinVariable.min ?? 2000, high = kelvinVariable.max ?? 11000
            let tintVariable = variable(.tint)
            let tint = tintVariable.flatMap { v in v.value.number.map { t in
                Level(t, range: (v.min ?? -16)...(v.max ?? 16), step: 0.1, isWritable: !v.readOnly)
            } }
            let preset = "\(Int(kelvin.rounded()))K"
            var presets = ArriTables.whiteBalancePresets.filter { label in
                Double(label.dropLast()).map { $0 >= low && $0 <= high } ?? false
            }
            if !presets.contains(preset) { presets = (presets + [preset]).sorted { (Int($0.dropLast()) ?? 0) < (Int($1.dropLast()) ?? 0) } }
            // One-push AWB, where the camera has the command (an ALEXA Mini's AutoWB, its page's AWB button): it measures
            // the light once and the Kelvin and tint become what it measured, as a Sony's "AWB" preset.
            if autoWhiteBalanceID != nil { presets.append("AWB") }
            state.whiteBalance = WhiteBalanceState(
                preset: Choice(preset, options: presets, isWritable: !kelvinVariable.readOnly),
                kelvin: Level(kelvin, range: min(low, kelvin)...max(high, kelvin), step: 10,
                              isWritable: !kelvinVariable.readOnly),
                tint: tint)
        }

        // Frame rate: the sensor's (FPSNominal), offered as the usual rates inside the range the format allows now.
        let fpsNow = value(.fps)?.number
        if let fpsVariable = variable(.fps), let fps = fpsNow {
            let low = fpsVariable.min ?? 0.75, high = fpsVariable.max ?? 200
            let label = ArriFormat.number(fps)
            // The camera's own list where it sends one (an ALEXA Mini's FPSTable), else Tiles' usual rates.
            let rates = table("FPSTable") ?? ArriTables.frameRates
            var options = rates.filter { $0 >= low - 0.0001 && $0 <= high + 0.0001 }.map(ArriFormat.number)
            if !options.contains(label) { options.append(label) }
            options.sort { (Double($0) ?? 0) < (Double($1) ?? 0) }
            state.frameRate = FrameRateState(project: Choice(label, options: options,
                                                             isWritable: !fpsVariable.readOnly && !lockedWhileRolling),
                                             variableName: "Sensor FPS")
        }

        // Shutter: the angle (ShutterNominal); the time is the same shutter at this frame rate (1/x s).
        if let angleVariable = variable(.shutterAngle), let angle = angleVariable.value.number {
            let low = angleVariable.min ?? 5, high = angleVariable.max ?? 356
            var angles = (table("ShutterTable") ?? ArriTables.shutterAngles).filter { $0 >= low && $0 <= high }
            if !angles.contains(where: { abs($0 - angle) < 0.05 }) { angles.append(angle) }
            state.shutterAngle = Choice(angle, options: angles.sorted(), isWritable: !angleVariable.readOnly && !lockedWhileRolling)
            if let fps = fpsNow, fps > 0 {
                let speed = ArriTables.speedLabel(angle: angle, fps: fps)
                var speeds = ArriTables.shutterSpeeds.filter { label in
                    ArriTables.angle(forSpeed: label, fps: fps).map { $0 >= low && $0 <= high } ?? false
                }
                if !speeds.contains(speed) { speeds.append(speed) }
                speeds.sort { (ArriTables.seconds($0) ?? 0) > (ArriTables.seconds($1) ?? 0) }
                state.shutterSpeed = Choice(speed, options: speeds, isWritable: !angleVariable.readOnly && !lockedWhileRolling)
            }
            let isAngle = value(.shutterIsAngle)?.bool ?? true
            state.shutterMode = Choice(isAngle ? .angle : .speed, options: [.angle, .speed],
                                       isWritable: isWritable(.shutterIsAngle))
        }

        // Sensor mode and codec as the resolution and format pickers, by the camera's labels. Where the camera has a
        // …Prepare twin (an ALEXA Mini's SensorFormatPrepare, RecCodecTypePrepare) a change can reload its software
        // (every one tried did), so each other choice asks first, as a VENICE's do; the backend changes them as the
        // camera's page does.
        if let mode = text(.sensorMode) {
            let options = choices(.sensorMode).map(\.label)
            state.resolution = Choice(mode, options: options.isEmpty ? [mode] : options,
                                      isWritable: isWritable(.sensorMode) && !options.isEmpty,
                                      restartRequired: hasPrepare(.sensorMode) ? Set(options.filter { $0 != mode }) : [])
        }
        if let codec = text(.codec) {
            let options = choices(.codec).map(\.label)
            state.fileFormat = Choice(codec, options: options.isEmpty ? [codec] : options,
                                      isWritable: isWritable(.codec) && !options.isEmpty,
                                      restartRequired: hasPrepare(.codec) ? Set(options.filter { family($0) != family(codec) }) : [])
        }
        state.recordingFormat = [text(.sensorMode), text(.codec)].compactMap { $0 }.joined(separator: " · ")
            .nilIfEmpty

        // The look: which one (a list of the camera's looks when it's an enum, else its name, read-only). An ARRI has
        // its own false color, and its look reaches every output (and a ProRes recording it's burned into), so the
        // LUT tile's FC swap is off.
        if let look = activeLookName ?? text(.look), !look.isEmpty {
            let options = choices(.look).map(\.label)
            state.lut = Choice(look, options: options.isEmpty ? [look] : options,
                               isWritable: isWritable(.look) && !options.isEmpty)
        }
        state.offersFalseColorLUTSwap = false

        // De-squeeze for the camera's displays.
        if let ratio = text(.desqueeze) {
            let options = choices(.desqueeze).map(\.label)
            state.desqueeze = Choice(ratio, options: options.isEmpty ? [ratio] : options,
                                     isWritable: isWritable(.desqueeze) && (!options.isEmpty || variable(.desqueeze)?.isBool == true))
        }
        if let bars = switchState(.colorBars, onWords: ["bar", "on", "enabled"]) {
            // Standby only: REC turns the bars off, and they can't come on while rolling (ALEXA Mini manual p. 93).
            state.colorBars = Choice(bars.on, options: [false, true], isWritable: bars.writable && recording() != true)
        }
        if let sw = switchBinding(.imageFlip, onWords: Self.flipWords), let variable = variable(.imageFlip) {
            // Any flip reads as on: an ALEXA Mini's SensorImageFlip is Off, V, H or V+H, and on writes V+H, the camera
            // upside down. It flips the recording, not only the outputs (manual p. 101).
            // Not while rolling: half a take upside down is worse than a grayed tile.
            state.imageFlip = Choice(variable.value != sw.off, options: [false, true],
                                     isWritable: !variable.readOnly && recording() != true)
        }

        // Lens data from LDS / LBUS: the iris, read-only (the Web Remote doesn't drive the lens). An ALEXA Mini gives
        // it as its display does, a full stop ("T 2.8") and tenths, thirds or quarters past it.
        if let t = ldsIris ?? value(.lensIris)?.number.flatMap(ArriFormat.tStop) {
            state.iris = Choice(t, options: [t], isWritable: false)
        }

        // Power and media. The Mini's battery percentage counts only when the battery reports its capacity.
        if let percent = value(.batteryPercent)?.number, percent >= 0, percent <= 100, batteryCapacityKnown {
            state.batteryPercent = percent.rounded().asInt
        }
        // Volts, as the camera's own display shows them, whatever the percentage: a battery that doesn't report one
        // would otherwise leave the tile grayed.
        state.batteryVolts = displayedVolts
        if let seconds = cardSecondsLeft {
            state.mediaRemainingMinutes = (seconds / 60).rounded(.down).asInt
        } else if let left = value(.mediaRemaining)?.number {
            state.mediaRemainingMinutes = ArriFormat.minutes(left)
        }

        // Clip naming: the camera letter and reel, where the camera lets them be set.
        var naming = FileNaming()
        if let index = variable(.cameraIndex), let letter = ArriFormat.letter(index.value, label: text(.cameraIndex)) {
            naming.cameraID = Choice(letter, options: (65...90).map { String(UnicodeScalar(UInt8($0))) },
                                     isWritable: !index.readOnly)
        }
        // Reel: prefer the card in use (ReelCountCardA/B) like cardSecondsLeft picks the card. Fall back to the
        // generic reel variable (ClipNameReelCount) for cameras that don't split by card.
        let reelVariable = reelField.flatMap(variable)
        if let reel = reelVariable, let number = reel.value.number, number.asInt != nil {
            naming.reel = Level(number, range: (reel.min ?? 1)...max(reel.max ?? 999, number), step: 1,
                                isWritable: !reel.readOnly)
        }
        state.fileNaming = naming.cameraID == nil && naming.reel == nil ? nil : naming

        // Outputs: the look, frame lines, false color, zebra, peaking and overlays, output by output.
        let sdi2IsClone = snapshot.variables["SDI2IsSDI1Clone"]
        var monitorOutputs: [MonitorOutput] = outputs.compactMap { output in
            var overlays: [MonitorOverlay: Choice<Bool>] = [:]
            for (overlay, sw) in output.switches {
                guard let variable = snapshot.variables[sw.variable], let on = sw.isOn(variable.value) else { continue }
                overlays[overlay] = Choice(on, options: [false, true],
                                           isWritable: !variable.readOnly && sw.canSwitch(variable))
            }
            return overlays.isEmpty ? nil : MonitorOutput(id: output.id, name: output.name, overlays: overlays)
        }
        // SDI 2 clone: when SDI2IsSDI1Clone is on, SDI 2 inherits SDI 1's settings and can't be set independently.
        // The sameAsSwitch is always present when the variable exists, so the user can turn the clone off.
        if let cloneVar = sdi2IsClone, let cloneOn = cloneVar.value.bool ?? cloneVar.value.number.map({ $0 != 0 }),
           let sdi2Index = monitorOutputs.firstIndex(where: { $0.id == "Sdi2" }),
           let sdi1 = monitorOutputs.first(where: { $0.id == "Sdi1" }) {
            let sameAsSwitch = Choice(cloneOn, options: [false, true], isWritable: !cloneVar.readOnly)
            monitorOutputs[sdi2Index].sameAsSwitch = sameAsSwitch
            if cloneOn {
                monitorOutputs[sdi2Index].follows = "Sdi1"
                // SDI 2's overlays show SDI 1's values and can't be changed while cloning.
                for overlay in monitorOutputs[sdi2Index].overlays.keys {
                    // Keep SDI 2's own LUT entry if SDI 1 has none.
                    if overlay == .lut, sdi1.overlays[.lut] == nil { continue }
                    var shown = sdi1.overlays[overlay] ?? monitorOutputs[sdi2Index].overlays[overlay]!
                    shown.isWritable = false
                    monitorOutputs[sdi2Index].overlays[overlay] = shown
                }
            }
        }
        state.monitoring = monitorOutputs.isEmpty ? nil : MonitoringState(outputs: monitorOutputs)
        state.look = state.monitoring?.onEverywhere(.lut)
        state.falseColor = state.monitoring?.onEverywhere(.falseColor)

        // The camera's own Web Remote, a tap away.
        state.webRemoteURL = URL(string: "http://\(host)/")

        // Playback: in it while a clip is cued (PlaybackClipIndex ≥ 0) or the camera says it's in playback, and while
        // its own screen is still on its playback page with nothing cued (an ALEXA Mini after a bare PlayBackEnd: Live
        // then clears it); playing at any speed but pause.
        if variable(.playbackSpeed) != nil || variable(.playbackClipIndex) != nil {
            let index = value(.playbackClipIndex)?.number?.asInt
            // Not while rolling: REC takes the screen off its playback page, and Live there would go to a rolling camera.
            let inPlayback = stateIsPlayback || (screenInPlayback && recording() != true)
            let speed = playbackSpeedToken
            let count = [value(.clipCountA)?.number, value(.clipCountB)?.number].compactMap { $0 }.reduce(0, +)
            state.playback = PlaybackState(
                isPlaying: speed.map { $0 != "PAUSE" && !$0.isEmpty },
                inReview: inPlayback ? true : index.map { $0 >= 0 },
                clipName: state.clipName,
                clipNumber: index.flatMap { $0 >= 0 ? $0 + 1 : nil },
                clipCount: count > 0 ? count.asInt : nil,
                capabilities: PlaybackCapabilities(playPause: true, stop: true, nextPrevious: true, seek: false,
                                                   fastForwardRewind: variable(.playbackSpeed) != nil, recReview: false,
                                                   live: true, review: true,
                                                   // The Clips window: skipped to a clip at a time by its index.
                                                   goToClip: variable(.playbackClipIndex) != nil))
        }
    }

    /// The AWB command to run: the page's own AWB button's (captured 2026-10-29) where the camera lists it, else any
    /// AutoWB or AutoWhiteBalance command the camera names. nil: the camera has none.
    var autoWhiteBalanceID: String? {
        let ids = snapshot.commandIDs(named: "AutoWB") + snapshot.commandIDs(named: "AutoWhiteBalance")
        return ids.contains(Self.pageAutoWhiteBalanceID) ? Self.pageAutoWhiteBalanceID : ids.first
    }
    static let pageAutoWhiteBalanceID = "_4da_Ua3pEeSjhp9JjGKhGQ"

    /// The project rate's number ("25", "23.976" → 24), when the camera has one.
    var projectRate: Int? {
        guard let text = text(.projectRate), let n = Double(text.filter { $0.isNumber || $0 == "." }) else { return nil }
        return n > 0 ? n.rounded().asInt : nil
    }

    /// The model as text, or named from the number an ALEXA Mini sends (SystemCameraType 2).
    public var modelText: String? {
        if let n = value(.model)?.number?.asInt, let name = ArriTables.modelName(cameraType: n) { return name }
        return text(.model)
    }

    /// The firmware as text, or "SUP 6.1.2" from an ALEXA Mini's SystemSWMajor / Minor / Patch.
    public var firmwareText: String? {
        if let text = text(.firmware), !text.isEmpty { return text }
        let parts = ["SystemSWMajor", "SystemSWMinor", "SystemSWPatch"].map { snapshot.variables[$0]?.value.number?.asInt }
        guard let major = parts[0], let minor = parts[1] else { return nil }
        return "SUP \(major).\(minor)" + (parts[2].map { ".\($0)" } ?? "")
    }

    /// An ALEXA Mini's timecode: TimecodeHours, TimecodeMinutes, TimecodeSeconds (frames aren't sent).
    var timecodeParts: (h: Int, m: Int, s: Int, f: Int)? {
        func n(_ name: String) -> Int? { snapshot.variables[name]?.value.number?.asInt }
        guard let h = n("TimecodeHours"), let m = n("TimecodeMinutes"), let s = n("TimecodeSeconds"),
              (0..<24).contains(h), (0..<60).contains(m), (0..<60).contains(s) else { return nil }
        return (h, m, s, n("TimecodeFrames") ?? 0)
    }

    /// The look in use on an ALEXA Mini: slot LookActiveSlot (0–2) of Look1_Filename… Look3_Filename, without its
    /// extension.
    var activeLookName: String? {
        guard let slot = snapshot.variables["LookActiveSlot"]?.value.number?.asInt,
              let name = snapshot.variables["Look\(slot + 1)_Filename"]?.value.string?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["aml", "alf", "alf4", "cube", "xml"].contains(ext) ? (name as NSString).deletingPathExtension : name
    }

    /// An LDS lens's iris as the Mini shows it: LDSIrisFullStops ("T 2.8") plus LDSIrisSubStops in tenths, thirds
    /// or quarters (LDSIrisSubStopsScaleInt) of a stop past it. Nil without lens data ("-", near close, closed).
    var ldsIris: Double? {
        guard let full = snapshot.variables["LDSIrisFullStops"], let index = full.value.number?.asInt,
              let label = catalog.label(variable: "LDSIrisFullStops", index: index),
              let base = ArriEnumCatalog.firstGroup(#"T\s*(\d+(?:\.\d+)?)"#, in: label).flatMap(Double.init), base > 0
        else { return nil }
        let sub = snapshot.variables["LDSIrisSubStops"]?.value.number ?? 0
        let scale = snapshot.variables["LDSIrisSubStopsScaleInt"]?.value.number ?? 10
        let stops = scale > 0 ? sub / scale : 0
        return (base * pow(2, stops / 2) * 10).rounded() / 10
    }

    /// The supply voltage as the camera's display shows it. An ALEXA Mini shows Bat2 (its supply, 14.8 V on the bench)
    /// unless Bat1 is at least 1 V higher (its page script: `_Bat1_2BDisplayed = Bat1LevelVolt - 1 >= Bat2LevelVolt`);
    /// another body, its one battery voltage. Nil at 0 V: nothing there.
    var displayedVolts: Double? {
        let bat1 = snapshot.variables["Bat1LevelVolt"]?.value.number
        let shown: Double?
        if let bat2 = snapshot.variables["Bat2LevelVolt"]?.value.number {
            shown = bat1.map { $0 - 1 >= bat2 } == true ? bat1 : bat2
        } else {
            shown = value(.batteryVoltage)?.number
        }
        return shown.flatMap { $0 > 0.5 && $0.isFinite ? $0 : nil }
    }

    /// Whether the battery percentage means anything: an ALEXA Mini says so with Bat1CapacityState (CapacityValid,
    /// the third choice); other cameras are taken at their word.
    var batteryCapacityKnown: Bool {
        guard let state = snapshot.variables["Bat1CapacityState"], let index = state.value.number?.asInt else { return true }
        return catalog.token(variable: "Bat1CapacityState", index: index).map { $0 == "CapacityValid" } ?? (index == 2)
    }

    /// The reel's variable: the card in use's (ReelCountCardA/B), as `cardSecondsLeft` picks the card, else the generic
    /// one (ClipNameReelCount) for a camera that doesn't split it by card. Read and written there both: the write went
    /// to the generic one, which a Mini doesn't have (its per-card reel read-only there, so never offered; the sweep).
    var reelField: ArriField? {
        func present(_ card: String) -> Bool { (snapshot.variables["Card\(card)Status"]?.value.number ?? 0) != 0 }
        let a = present("A"), b = present("B")
        let order: [ArriField]
        if a || b {
            let useB = a && b ? (snapshot.variables["CardBIsSelected"]?.value.bool == true) : b
            order = [useB ? .reelCardB : .reelCardA, .reel]
        } else {
            order = [.reelCardB, .reelCardA, .reel]
        }
        return order.first { variable($0) != nil }
    }

    /// Seconds of recording left on the card in use, from an ALEXA Mini's CardA… / CardB… variables: the card that's
    /// there (Card…Status not 0), or the selected one when both are. Nil with no card.
    var cardSecondsLeft: Double? {
        func present(_ card: String) -> Bool { (snapshot.variables["Card\(card)Status"]?.value.number ?? 0) != 0 }
        let a = present("A"), b = present("B")
        guard a || b else { return nil }
        let card = a && b ? (snapshot.variables["CardBIsSelected"]?.value.bool == true ? "B" : "A") : (a ? "A" : "B")
        return snapshot.variables["Card\(card)CapacityRemain_Raw"]?.value.number.flatMap { $0 >= 0 ? $0 : nil }
    }

    /// A list the camera keeps for its own screens (an ALEXA Mini's FPSTable, ShutterTable): rows of [flags, value],
    /// flags 0 for an unused slot (7 selectable, 5 there but beyond the format's range). Sorted, no repeats.
    func table(_ name: String) -> [Double]? {
        guard case .other(let text)? = snapshot.variables[name]?.value,
              let rows = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[Any]] else { return nil }
        let values = rows.compactMap { row -> Double? in
            guard row.count >= 2, let flags = (row[0] as? NSNumber)?.intValue, flags != 0 else { return nil }
            return (row[1] as? NSNumber)?.doubleValue
        }
        return values.isEmpty ? nil : Array(Set(values)).sorted()
    }

    /// While rolling, an ALEXA Mini takes a sensor-rate or shutter write (`{"result": 1}`) and ignores it, without
    /// marking either read-only: its own screen locks FPS, shutter, timecode and look for the take (manual p. 37).
    var lockedWhileRolling: Bool {
        recording() == true && snapshot.variables["MajorState"] != nil
    }

    /// A codec's family: changing within one (ProRes 4444 XQ to 422 HQ) doesn't reload an ALEXA Mini's software;
    /// changing between them (ProRes to ARRIRAW) does.
    func family(_ codec: String) -> String {
        let c = codec.uppercased()
        return c.contains("ARRIRAW") ? "ARRIRAW" : c.contains("MPEG") ? "MPEG" : "PRORES"
    }

    /// Whether the camera changes this field through a "…Prepare" twin and a command rather than by writing it.
    func hasPrepare(_ field: ArriField) -> Bool {
        fields[field].map { snapshot.variables["\($0)Prepare"] != nil } ?? false
    }

    /// The page script's token for an enum variable's current value ("PLAYBACK"), by the variable's name.
    func token(of name: String) -> String? {
        guard let index = snapshot.variables[name]?.value.number?.asInt else { return nil }
        return catalog.token(variable: name, index: index)
    }

    /// The camera's state is playback: an ALEXA Mini's MajorState PLAYBACK (its label is "PLAY").
    var stateIsPlayback: Bool {
        fields[.recState].flatMap { token(of: $0) } == "PLAYBACK"
    }

    /// The camera's own screen is on its playback page: an ALEXA Mini's GuiMode PLAYBACK. Its page puts it back to
    /// NORMAL when it leaves playback; PlayBackEnd on its own doesn't, and the screen then says "No clip selected" until
    /// PLAY is held on the camera or REC is pressed (`ArriCameraBackend.endPlayback`).
    var screenInPlayback: Bool { token(of: "GuiMode") == "PLAYBACK" }

    /// The words that name an image flip's "on", most telling first (`switchBinding` takes the first word any label
    /// has): "V+H" is an ALEXA Mini's both ways, upside down, so a body with "Flip H" or "Horizontal" among its
    /// choices still turns on upside down rather than mirrored.
    public static let flipWords = ["v+h", "180", "upside", "rotat", "flip", "on"]

    /// The playback speed's token ("PAUSE", "FWD_1", "REV_2"), from the page script or the camera's label.
    var playbackSpeedToken: String? {
        guard let name = fields[.playbackSpeed], let index = value(.playbackSpeed)?.number?.asInt else { return nil }
        return catalog.token(variable: name, index: index) ?? text(.playbackSpeed)?.uppercased()
    }

    /// A switch-like field (color bars, flip): a bool, or an enum with off and a word that means on.
    func switchState(_ field: ArriField, onWords: [String]) -> (on: Bool, writable: Bool)? {
        guard let variable = variable(field), let sw = switchBinding(field, onWords: onWords),
              let on = sw.isOn(variable.value) else { return nil }
        return (on, !variable.readOnly)
    }

    /// The values that turn a switch-like field on and off.
    public func switchBinding(_ field: ArriField, onWords: [String]) -> ArriSwitch? {
        guard let name = fields[field], let variable = snapshot.variables[name] else { return nil }
        if variable.isBool || { if case .bool = variable.value { return true }; return false }() {
            return ArriSwitch(variable: name, on: .bool(true), off: .bool(false))
        }
        if variable.isEnum {
            let labels = variable.enumIndexes.map { ($0, catalog.label(variable: name, index: $0)?.lowercased() ?? "") }
            guard let off = labels.first(where: { $0.1 == "off" || $0.1 == "none" || $0.1.hasPrefix("off")
                                                   || $0.1 == "normal" || $0.1 == "0°" || $0.1 == "0" })?.0,
                  // The first of `onWords` that any choice has, in the words' order: "v+h" before "on", which
                  // "Horizontal" also has.
                  let on = onWords.lazy.compactMap({ word in labels.first { $0.0 != off && $0.1.contains(word) }?.0 }).first
            else { return nil }
            return ArriSwitch(variable: name, on: .number(Double(on)), off: .number(Double(off)))
        }
        if variable.min == 0, variable.max == 1 { return ArriSwitch(variable: name, on: .number(1), off: .number(0)) }
        return nil
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
