import CameraCore
import Foundation
import os

extension VeniceCameraBackend {
    // MARK: - The look (VENICE 2)

    /// One of the looks the camera can load: a preset, a user 3D LUT or an ART file, by the name Tiles shows.
    struct Look: Equatable {
        var label: String
        var mode: String
        var preset: String?
        var fileID: Int?
    }

    /// Every look the camera has now, in its own order: the presets, then the user 3D LUTs and ART files loaded into its
    /// sixteen slots ("User 5: show.cube"; slots still holding the factory s709 are left out, unless one is in use).
    /// Empty on a camera without the look properties (VENICE 1's page), which keeps its output LUT names.
    var looks: [Look] {
        guard values[Self.lookMode] != nil else { return [] }
        let modes = options[Self.lookMode]?.compactMap(\.string) ?? []
        let now = currentLookChoice
        var out: [Look] = []
        if modes.isEmpty || modes.contains("PresetLook") {
            for preset in options[Self.lookPreset]?.compactMap(\.string) ?? [] {
                out.append(Look(label: Self.presetLabel(preset), mode: "PresetLook", preset: preset))
            }
        }
        for (mode, list, prefix) in [("User3D", Self.userLUTList, "User"), ("ART", Self.artList, "ART")]
        where modes.contains(mode) || now.mode == mode {
            for (index, name) in (options[list]?.map { $0.string ?? "" } ?? []).enumerated() {
                let id = index + 1
                let inUse = now.mode == mode && now.fileID == id
                guard !Self.isEmptySlot(name) || inUse else { continue }
                out.append(Look(label: "\(prefix) \(id): \(name)", mode: mode, fileID: id))
            }
        }
        if let label = currentLookLabel, !out.contains(where: { $0.label == label }) {
            out.append(Look(label: label, mode: now.mode ?? "", preset: now.preset, fileID: now.fileID))
        }
        return out
    }

    /// The look the camera is on (or has been asked for).
    var currentLookChoice: (mode: String?, preset: String?, fileID: Int?) {
        func read(_ name: String) -> MPValue? { (livePending(name) ?? values[name])?.unwrapped }
        let mode = read(Self.lookMode)?.string
        // 1-based slots; anything else names no slot.
        let fileID = (mode == "ART" ? read(Self.lookARTFileID) : read(Self.lookUserFileID))?.number
            .map { Int($0) }.flatMap { (1...16).contains($0) ? $0 : nil }
        return (mode, read(Self.lookPreset)?.string, fileID)
    }

    /// Its name as `looks` gives it.
    var currentLookLabel: String? {
        let now = currentLookChoice
        switch now.mode {
        case "PresetLook":
            return now.preset.map(Self.presetLabel)
        case "User3D", "ART":
            guard let id = now.fileID else { return nil }
            let list = options[now.mode == "ART" ? Self.artList : Self.userLUTList]?.map { $0.string ?? "" } ?? []
            let name = list.indices.contains(id - 1) ? list[id - 1]
                : values[now.mode == "ART" ? Self.lookARTFileName : Self.lookUserFileName]?.unwrapped.string ?? ""
            return "\(now.mode == "ART" ? "ART" : "User") \(id): \(name)"
        case let mode?:
            // The ACES looks (ACEScct input): the file it names, else the mode.
            return values[Self.lookUserFileName]?.unwrapped.string.flatMap { $0.isEmpty ? nil : $0 } ?? mode
        case nil:
            return nil
        }
    }

    /// What an output shows, by the name the LUT picker uses: "Look" is the look's own name, s709 and R709(800%)
    /// themselves; nil for Log, which is the LUT off.
    func outputLUTLabel(_ raw: String?) -> String? {
        guard let raw, !VeniceTables.isLog(raw) else { return nil }
        if raw == "Look" { return currentLookLabel ?? "Look" }
        return Self.presetLabel(raw)
    }

    /// Picking a LUT. VENICE 2: load that look (its mode and selection together when the mode changes, as proven on the
    /// camera; the selection alone otherwise, as the page sends it), then every output showing a LUT shows the look.
    /// A camera without the look properties sets the Monitor out and viewfinder to the name, as before.
    func setLUT(_ label: String) async {
        let lutFields: [Field] = [.lutSdi12, .lutSdi34, .lutMonitor, .lutVf, .lutHdmi]
        if let look = looks.first(where: { $0.label == label }) {
            let now = currentLookChoice
            var props: [String: MPValue] = [:]
            if now.mode != look.mode { props[Self.lookMode] = .map(["cam": .string(look.mode)]) }
            if let preset = look.preset { props[Self.lookPreset] = .map(["cam": .string(preset)]) }
            if let id = look.fileID {
                props[look.mode == "ART" ? Self.lookARTFileID : Self.lookUserFileID] = .map(["cam": .int(Int64(id))])
            }
            // The whole change is decided before anything is sent: the actor takes other commands while it waits.
            var toLook: [String] = []
            for field in lutFields {
                guard let prop = property[field] else { continue }
                lastLUT[prop] = "Look"
                let shows = (livePending(prop) ?? stored(prop))?.string
                if let shows, !VeniceTables.isLog(shows), shows != "Look", !outputLocked(prop) { toLook.append(prop) }
            }
            if !props.isEmpty { await writeAll(props) }
            for prop in toLook where (livePending(prop) ?? stored(prop))?.string != "Look" {
                await write(.string("Look"), for: prop)
            }
        } else {
            let raw = Self.presetValue(label)
            // The Monitor out, the viewfinder and the HDMI take s709 and R709(800%) themselves; the SDIs only Look.
            for field in [Field.lutMonitor, .lutVf, .lutHdmi] {
                guard let prop = property[field] else { continue }
                lastLUT[prop] = raw
                if Self.lutIsOn(stored(prop) ?? .string("Log")) == true, outputLocked(prop) == false {
                    await write(.string(raw), for: prop)
                }
            }
            if raw == "Look" {
                for field in [Field.lutSdi12, .lutSdi34] {
                    if let prop = property[field], Self.lutIsOn(stored(prop) ?? .string("Log")) == true {
                        await write(.string("Look"), for: prop)
                    }
                }
            }
        }
        rebuild()
    }

    /// Whether an output's LUT is locked now (VENICE 2's per-output LockStatus maps).
    func outputLocked(_ prop: String) -> Bool {
        guard let slot = Self.slot(prop) else { return statuses[prop] == "Locked" }
        return values[slot.base + ".LockStatus"]?.map?[slot.key]?.string == "Locked"
    }

    // MARK: - Assignable functions (VENICE 2)

    /// The camera's false color (Exposure Assist) on each output that has it: a function of the assignable buttons,
    /// switched by pressing the button it's on (VENICE 2: Assignable.2 turns the Monitor on and off, and
    /// `Button.Assign` said so).
    static let falseColorFunctions: [(output: String, function: String)] = [("Monitor", "FalseColorMonitor"),
                                                                            ("Vf", "FalseColorVF")]

    /// The button a function is on, and whether the camera says it's on. Assignable.0 is no button (the page lists
    /// 1–7 and A–C).
    func assignment(_ function: String) -> (slot: String, on: Bool)? {
        guard let name = property[.assign], let slots = values[name]?.map else { return nil }
        for key in slots.keys.sorted() where key != "Assignable.0" {
            guard let entry = slots[key]?.array, entry.first?.string == function else { continue }
            if let pressed = pendingKeys[key], Date().timeIntervalSince(pressed.since) < 4 { return (key, pressed.on) }
            return (key, entry.count > 1 && entry[1].string == "On")
        }
        return nil
    }

    func setFalseColor(_ on: Bool, output: String?) async {
        for (id, function) in Self.falseColorFunctions where (output == nil || output == id) && !followers.contains(id) {
            if assignment(function) != nil {
                await pressAssigned(function, toBe: on)
            } else {
                // VENICE 1's menu switch, where it has one by its exact name.
                for name in overlayProperties(.falseColor, output: id) { await write(.bool(on), for: name) }
            }
        }
    }

    /// Presses the button a function is on when the camera says it's in the other state (the press toggles), and
    /// shows the change as asked for until `Button.Assign` reports it.
    func pressAssigned(_ function: String, toBe on: Bool) async {
        guard let current = assignment(function), current.on != on else { return }
        pendingKeys[current.slot] = (on, Date())
        rebuild()
        yield()
        do {
            try await client.sendKey(current.slot, timeout: 3)
        } catch {
            pendingKeys[current.slot] = nil
            log.error("key \(current.slot, privacy: .public) for \(function, privacy: .public) failed")
        }
        settleLater([property[.assign] ?? "Button.Assign"])
    }

    // MARK: - Commands it can't take

    /// Why this camera can't take `command` now, or nil. A command from another camera on a linked page, or from the
    /// Control API, can ask for what this one's own tiles never would: a setting it has locked (most of them while it
    /// rolls) or read-only, or a value it doesn't list (another make's frame rate or shutter angle). Sent anyway, it
    /// does nothing at best; a write the camera doesn't answer holds its one queue for up to 3 s, and a linked STOP
    /// behind it waits. The lists are the camera's own where it gives one: the
    /// project rates its menu allows, Select FPS, shutter angles and speeds.
    func refusal(_ command: CameraCommand) -> String? {
        func listed(_ field: Field) -> [MPValue]? {
            property[field].flatMap { options[$0] }.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch command {
        case .setShutterAngle(let angle):
            guard let shutter = state.shutterAngle else { return nil }
            if !shutter.isWritable { return "the shutter is locked" }
            if let list = listed(.shutterAngle)?.compactMap(\.number), !list.contains(where: { abs($0 - angle) < 0.05 }) {
                return "an angle the camera doesn't list"
            }
        case .setShutterSpeed(let speed):
            guard let shutter = state.shutterSpeed else { return nil }
            if !shutter.isWritable { return "the shutter is locked" }
            if let list = listed(.shutterSpeed)?.compactMap(\.string).map(Self.speedLabel),
               !list.contains(Self.speedLabel(speed)) {
                return "a speed the camera doesn't list"
            }
        case .setShutterMode:
            if state.shutterMode?.isWritable == false { return "the shutter mode is locked" }
        case .setFrameRate(let rate):
            guard let project = state.frameRate?.project else { return nil }
            if !project.isWritable { return "the project rate is locked" }
            // VENICE 2 sets it in its menu, from the rates the menu allows now; its mediabox's reading takes no write.
            if values[VeniceMenu.projectRateProperty] != nil, !project.options.contains(rate) {
                return "a project rate the camera doesn't allow now"
            }
        case .setFrameRateVariable:
            if state.frameRate?.variable?.isWritable == false { return "S&Q is locked" }
        case .setFrameRateVariableRate(let rate):
            guard let select = state.frameRate?.variableRate else { return nil }
            if !select.isWritable { return "Select FPS is locked" }
            if let list = listed(.sqRate)?.compactMap(\.number), !list.contains(rate) {
                return "a Select FPS the camera doesn't list"
            }
            // No list from the camera: the one Tiles offers, Sony's for the mode. A linked 48 from another camera
            // mustn't reach a VENICE in 8.6K 3:2.
            if listed(.sqRate) == nil, !select.options.contains(rate) { return "a Select FPS this imager mode doesn't have" }
        case .setKelvin(let kelvin):
            guard let wb = state.whiteBalance else { return nil }
            if !wb.kelvin.isWritable { return "white balance is locked" }
            if !wb.kelvin.range.contains(kelvin) { return "a Kelvin out of the camera's range" }
        case .setTint(let tint):
            guard let level = state.whiteBalance?.tint else { return nil }
            if !level.isWritable { return "white balance is locked" }
            if !level.range.contains(tint) { return "a tint out of the camera's range" }
        case .setWhiteBalancePreset:
            if state.whiteBalance?.preset.isWritable == false { return "white balance is locked" }
        default:
            return nil
        }
        return nil
    }

    // MARK: - REC

    /// Never optimistic, and absolute: only a camera in the other state is asked. The captured VENICE frames send REC
    /// as a key press; a PXW takes `Clip.Recorder.Start` / `.Stop`, so a body whose recorder property is absent gets
    /// those instead.
    func record(_ start: Bool) async {
        let isRecording = recorderIsRecording
        guard isRecording != start else { return }
        state.recording.request = start ? .start : .stop
        yield()
        do {
            if property[.recorder] != nil {
                try await client.sendKey("Rec")
            } else {
                _ = try await client.request(start ? "Clip.Recorder.Start" : "Clip.Recorder.Stop", .array([]))
            }
        } catch {
            state.recording.request = nil
            state.recording.failure = RecordingControl.Failure.notSent
            log.error("rec: \(String(describing: error).prefix(160), privacy: .public)")
            ActivityLog.shared.note(host, "REC \(start ? "start" : "stop") didn't reach the camera: \(String(describing: error).prefix(160))")
            yield()
            return
        }
        // The camera reports the new state by notification. If it doesn't in time, re-read and say what happened.
        try? await Task.sleep(for: .seconds(recConfirmTimeout))
        if state.recording.request != nil {
            state.recording.request = nil
            await refresh([.recorder])
            if recorderIsRecording != start {
                state.recording.failure = RecordingControl.Failure.notConfirmed(start: start)
            }
            yield()
        }
    }

    var recorderIsRecording: Bool {
        guard let name = property[.recorder], let value = values[name] else { return false }
        if let bool = value.bool { return bool }
        func recording(_ text: String) -> Bool {
            let t = text.lowercased()
            return t.contains("rec") && !t.contains("paus") && !t.hasPrefix("not") && !t.contains("standby")
        }
        // VENICE 2: one entry per media slot, {"media.5": "Recording", "media.1": "NotRecording", …}.
        if let map = value.map, value.unwrapped == value { return map.values.contains { recording($0.string ?? "") } }
        return recording(value.string ?? value.unwrapped.string ?? "")
    }
}
