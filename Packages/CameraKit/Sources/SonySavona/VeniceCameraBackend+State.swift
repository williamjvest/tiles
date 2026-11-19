import CameraCore
import Foundation
import os

extension VeniceCameraBackend {
    // MARK: - State building

    func rebuild() {
        func value(_ field: Field) -> MPValue? {
            guard let name = property[field] else { return nil }
            return livePending(name) ?? stored(name)
        }
        func plain(_ field: Field) -> MPValue? {
            guard let name = property[field] else { return nil }
            return stored(name)
        }
        /// Whether the camera lets a field change now: neither the property nor its menu item is locked.
        func open(_ field: Field) -> Bool { property[field].map(unlocked) ?? false }
        /// The imager mode and the recording format by name. VENICE 2 reads both as menu values ("17" is 8.6K 3:2, "3"
        /// X-OCN LT), named from the menu's own tables. Sony's tables go by name too: given "17", Select FPS found no
        /// row for it and offered up to 60, 48 in open gate included, which the camera can't take.
        func imagerName() -> String? {
            guard let raw = value(.imager)?.string ?? value(.imager)?.unwrapped.string else { return nil }
            guard property[.imager]?.hasSuffix("System.Menu.CamImagermode") == true else { return raw }
            return VeniceMenu.label(VeniceMenu.imagerModes, value: .string(raw)) ?? raw
        }
        func codecName() -> String? {
            guard let raw = value(.codec)?.string ?? value(.codec)?.unwrapped.string else { return nil }
            guard property[.codec]?.hasSuffix("System.Menu.AxsRecformatSelect") == true else { return raw }
            return VeniceMenu.label(VeniceMenu.recordingFormats, value: .string(raw)) ?? raw
        }

        // VENICE 2's Savona calls itself "PXW-X180" (savona-2.9.4): keep "VENICE" unless the camera names a VENICE.
        if let model = plain(.model)?.string, model.uppercased().contains("VENICE") || model.uppercased().contains("MPC-") {
            state.model = model
        } else if (state.model == "VENICE" || state.model == "MPC-3628"),
                  let allowed = options[VeniceMenu.imagerModeAllowed]?.compactMap({ $0.number.map { Int($0) } }),
                  !allowed.isEmpty {
            // The imager modes it offers say which sensor: the 8.6K modes (menu items 13–23) are a VENICE 2's MPC-3628.
            state.model = allowed.contains { $0 >= 13 } ? "MPC-3628" : "VENICE"
        }

        // REC
        if plain(.recorder) != nil {
            // A take ending stops a rec-run timecode at once; a free-running one shows it's running again within a report.
            if state.recording.state == .recording, !recorderIsRecording { timecodeAdvancing = false }
            state.recording.state = recorderIsRecording ? .recording : .idle
            // The camera's own report settles a pending REC at once (VENICE 2 takes ~2 s to close a clip); the wait
            // in record() is only for a camera that never says.
            if let request = state.recording.request, (request == .start) == (state.recording.state == .recording) {
                state.recording.request = nil
                state.recording.failure = nil
            }
        } else {
            state.recording.state = .idle
        }

        // Timecode: "01:02:03:04", counted at the project rate. The camera sends it ~10 times a second while it runs
        // (free run, or REC in rec run): the clock runs here between reports, and a report it agrees with (to a
        // quarter of a second, the link's jitter over HaLow) changes nothing, so the page isn't redrawn ten times a
        // second for it.
        if let text = plain(.timecode)?.string ?? plain(.timecode)?.unwrapped.string,
           let tc = Self.parseTimecode(text) {
            let now = Date()
            timecodeHighestFrame = max(timecodeHighestFrame, tc.f)
            let projectLabel = VeniceMenu.label(VeniceMenu.projectRates, value: values[VeniceMenu.projectRateProperty])
                ?? plain(.fps)?.string ?? plain(.fps).flatMap { $0.number.map { Self.fpsLabel($0) } }
            let (rate, fps) = Self.timecodeRates(project: projectLabel, highestFrame: timecodeHighestFrame)
            let total = ((tc.h * 60 + tc.m) * 60 + tc.s) * rate + tc.f
            if timecodeSeen?.text != text {
                timecodeAdvancing = timecodeSeen.map { now.timeIntervalSince($0.at) < 1 && total > $0.frames } ?? false
                timecodeSeen = (text, total, now)
            } else if let seen = timecodeSeen, now.timeIntervalSince(seen.at) > 1 {
                timecodeAdvancing = false  // it stopped (rec run, between takes)
            }
            let running = state.recording.state == .recording || timecodeAdvancing
            let seen = timecodeSeen ?? (text, total, now)
            let reported = TimecodeClock(frames: seen.frames, anchor: seen.at, rate: rate, fps: fps, isRunning: running)
            if running, let shown = state.timecode, shown.isRunning, shown.rate == rate,
               abs(shown.frames(at: seen.at) - seen.frames) <= max(2, rate / 4) {
                // The clock here already shows it.
            } else {
                state.timecode = reported
            }
        }

        state.clipName = plain(.clipName)?.string ?? plain(.clipName)?.unwrapped.string  // VENICE 2: {"main": "B020C005"}

        // EI: an int over an int property, "1250EI" over a string one; options from the camera when it has them.
        if let ei = value(.ei) {
            let number = ei.number.map(Int.init)
            let list = options[property[.ei] ?? ""]?.compactMap { $0.number.map { Int($0) } }
            let pair = Self.baseISOPair(model: state.model, reading: value(.baseISO))
            let base = Self.baseIsHigh(value(.baseISO), pair: pair) ? pair.1 : pair.0
            state.iso = Choice(number ?? base, options: (list?.isEmpty == false ? list! : VeniceTables.eiOptions(base: base)).sorted(),
                               isWritable: open(.ei), pending: nil)
        }
        if let base = value(.baseISO), base.number != nil || base.string != nil {
            let pair = Self.baseISOPair(model: state.model, reading: base)
            let shown = Self.baseIsHigh(base, pair: pair) ? pair.1 : pair.0  // 0 / 1, or VENICE 2's "ISO 3200"
            state.baseISO = Choice(shown, options: [pair.0, pair.1], isWritable: open(.baseISO))
        }

        // Shutter: Angle / Speed, whichever the camera says it's in; the other still shows if it's there.
        let modeString = plain(.shutterMode)?.string ?? plain(.shutterMode)?.unwrapped.string
        let mode: ShutterMode = (modeString?.lowercased().contains("speed") ?? false) ? .speed : .angle
        if plain(.shutterMode) != nil {
            state.shutterMode = Choice(mode, options: [.angle, .speed], isWritable: open(.shutterMode))
        }
        if let angle = value(.shutterAngle)?.number {
            let list = options[property[.shutterAngle] ?? ""]?.compactMap { $0.number }.sorted()
            state.shutterAngle = Choice(angle, options: list?.isEmpty == false ? list! : VeniceTables.shutterAngles,
                                        isWritable: open(.shutterAngle))
        }
        if let rawSpeed = value(.shutterSpeed)?.string ?? value(.shutterSpeed)?.unwrapped.string {
            let speed = Self.speedLabel(rawSpeed)
            let list = options[property[.shutterSpeed] ?? ""]?.compactMap(\.string).map(Self.speedLabel)
            let project = plain(.fps)?.string ?? plain(.fps)?.unwrapped.string
            var steps = VeniceTables.shutterSpeeds(projectRate: project)
            if !steps.contains(speed) { steps.append(speed) }  // a continuous value stays in the list
            state.shutterSpeed = Choice(speed, options: list?.isEmpty == false ? list! : steps, isWritable: open(.shutterSpeed))
        }

        // ND: an int, or {"cam": int}, or "0.6" — the label either way.
        if let nd = value(.nd) {
            let label = Self.ndLabel(for: nd)
            let clear = property[.ndMode].flatMap { (livePending($0) ?? values[$0])?.unwrapped.string } == "PresetClear"
                || (nd.unwrapped.number ?? 0) > 1000  // the page reads anything over 1000 as Clear
            state.nd = NDState(preset: Choice(clear || values["Camera.NDFilter.Enabled"]?.unwrapped.bool == false ? "Clear" : label,
                                                 options: Self.ndLabels, isWritable: open(.nd)))
        }

        // White balance: kelvin and tint as levels; the presets are Tiles' (`WhiteBalancePresets`), then the camera's own
        // steps (VENICE's factory set when it lists none); the current one is what the kelvin and tint match.
        var kelvin: Double?
        if let k = value(.kelvin)?.number { kelvin = k }
        var tint: Double?
        if let t = value(.tint)?.number { tint = t }
        if kelvin != nil {
            let steps = wbSteps
            let own = steps.isEmpty ? Self.wbPresets : steps.map(\.label)
            let standard = WhiteBalancePresets.labels(within: 2000...15000)
            let presets = standard + own.filter { !standard.contains($0) }
            let current = Self.wbLabel(kelvin: Int(kelvin!.rounded()), tint: Int((tint ?? 0).rounded()))
            let wbOpen = open(.kelvin) && (property[.tint].map(unlocked) ?? true)
            state.whiteBalance = WhiteBalanceState(
                preset: Choice(current, options: presets, isWritable: wbOpen),
                kelvin: Level(kelvin!, range: 2000...15000, step: 10, isWritable: wbOpen),
                tint: tint.map { Level($0, range: -99...99, step: 1, isWritable: wbOpen) })
        }

        // S&Q and project fps.
        if plain(.fps) != nil || plain(.sqRate) != nil || plain(.sqEnabled) != nil {
            let projectMenu = livePending(VeniceMenu.projectRateProperty) ?? values[VeniceMenu.projectRateProperty]
            let project = VeniceMenu.label(VeniceMenu.projectRates, value: projectMenu)
                ?? plain(.fps)?.string ?? plain(.fps).flatMap { $0.number.map { Self.fpsLabel($0) } } ?? "24"
            let imagerNow = imagerName() ?? state.resolution?.value ?? ""
            let listedProject = values[VeniceMenu.projectRateProperty] != nil
                ? VeniceMenu.labels(VeniceMenu.projectRates, allowed: options[VeniceMenu.projectRateAllowed])
                : (options[property[.fps] ?? ""]?.compactMap(\.string) ?? [])
            let projectList = listedProject.isEmpty ? VeniceTables.projectFrameRates(imager: imagerNow, model: state.model)
                : listedProject
            // The camera's Select FPS list when it gives one; otherwise Sony's range for the imager mode, the format
            // and the base ISO.
            let current = value(.sqRate)?.number
            let codecNow = codecName()
            let highBase = Self.baseIsHigh(value(.baseISO), pair: Self.baseISOPair(model: state.model, reading: value(.baseISO)))
            var rates = (options[property[.sqRate] ?? ""] ?? []).compactMap { $0.number }.sorted()
            if rates.isEmpty, current != nil {
                rates = Array(Set(VeniceTables.selectFPS(imager: imagerNow, model: state.model, codec: codecNow,
                                                         highBase: highBase, projectRate: project) + [current!])).sorted()
            }
            let menuRate = values[VeniceMenu.projectRateProperty] != nil
            state.frameRate = FrameRateState(
                // VENICE 2's project rate is the menu's own setting; its mediabox's reading
                // (P.Clip.Mediabox.Video.Format.FrameRate) doesn't take a write, so without the menu it's shown only.
                project: Choice(project, options: projectList.isEmpty ? [project] : projectList,
                                isWritable: menuRate ? unlocked(VeniceMenu.projectRateProperty)
                                    : property[.fps]?.hasPrefix("P.Clip.Mediabox") != true,
                                restartRequired: Set(projectList.filter { $0 != project })),
                variable: value(.sqEnabled).map { Choice($0.bool ?? false, options: [false, true], isWritable: open(.sqEnabled)) },
                variableRate: rates.isEmpty ? nil : Choice(current ?? rates.last ?? 24, options: rates,
                                                           isWritable: open(.sqRate)),
                variableName: "Select FPS")
        }

        // Lens
        if let iris = value(.irisF)?.number, iris >= 0.5, iris <= 22 {
            state.iris = Choice(iris, options: [iris], isWritable: open(.irisF))
        }

        // Power and media
        // VENICE 2 reads -1 here while its battery display is in volts: no percentage then, rather than 0 %.
        state.batteryPercent = plain(.battery)?.number.flatMap { $0 < 0 ? nil : Int(min($0, 100)) }
        state.batteryVolts = values[Self.batteryVolts]?.unwrapped.number.flatMap { $0 > 0 ? ($0 * 10).rounded() / 10 : nil }
        // One entry per slot on VENICE 2 ({"media.5": 2770, the empty ones 0}): the slot that has time left.
        let mediaValue = plain(.mediaTime)
        if let media = mediaValue?.number ?? mediaValue?.map?.values.compactMap(\.number).max() {
            // Storage.Media.AvailableTime is seconds: the VENICE 2's 2770 was a part-used AXS card's 46 minutes (2770
            // minutes would be 46 hours). It was read as minutes under 1000, so a card's last 16 minutes showed as up to
            // 1000 minutes, just when the low-media warning matters (the 11/14 sweep).
            state.mediaRemainingMinutes = Int(media / 60)
        }

        // Identity
        // Clip naming: VENICE 2's menu (camera ID as an ASCII code, reel, position), else the camera's letter.
        let letters = (65...90).map { String(UnicodeScalar(UInt8($0))) }
        func menu(_ name: String) -> MPValue? { (livePending(name) ?? values[name])?.unwrapped }
        let menuLetter = menu(Self.clipCameraID)?.number.flatMap { UnicodeScalar(UInt32($0)) }.map(String.init)
        if let letter = menuLetter ?? plain(.cameraID)?.string ?? plain(.cameraID)?.unwrapped.string, !letter.isEmpty {
            let reel = menu(Self.clipReel)?.number.map {
                Level($0, range: 1...999, step: 1, isWritable: unlocked(Self.clipReel))
            }
            let position = menu(Self.clipPosition)?.number.flatMap { n -> Choice<String>? in
                let all = ["C", "L", "R"]
                return all.indices.contains(Int(n))
                    ? Choice(all[Int(n)], options: all, isWritable: unlocked(Self.clipPosition)) : nil
            }
            let idOpen = menuLetter != nil ? unlocked(Self.clipCameraID) : open(.cameraID)
            var naming = FileNaming(cameraID: Choice(letter, options: letters, isWritable: idOpen), reel: reel)
            naming.position = position
            state.fileNaming = naming
        }
        if let display = menu(Self.timeDataDisplay)?.string {
            state.timecodeShowsDuration = Choice(display == "2", options: [false, true], isWritable: true)
        }
        // Color bars: the camera's own reading (Camera.ColorBar.Enabled), else the menu's; a change asked for shows until
        // the camera confirms it. Changed whichever way is open now (`.setColorBars`).
        let barsMenu = menu(VeniceMenu.colorBarProperty)?.bool
        let barsCamera = value(.colorBars)?.unwrapped.bool
        let barsKey = assignment("ColorBar")
        let barsAsked = livePending(VeniceMenu.colorBarProperty) != nil ? barsMenu
            : barsKey.flatMap { pendingKeys[$0.slot] != nil ? $0.on : nil }
        if let bars = barsAsked ?? barsCamera ?? barsMenu ?? barsKey?.on {
            let open = (barsMenu != nil && statuses[VeniceMenu.colorBarLock] != "Locked")
                || (property[.colorBars].map { statuses[$0] != "Locked" } ?? false)
                || barsKey != nil
            state.colorBars = Choice(bars, options: [false, true], isWritable: open)
        }
        // Imager mode as the resolution picker; codec; de-squeeze. Options from the camera when it lists them.
        // Sony's lists stand in only where the camera's own value is one of their names, so the picker never mixes
        // the camera's spelling with the manual's.
        if let imager = imagerName() {
            let fromMenu = property[.imager]?.hasSuffix("System.Menu.CamImagermode") == true
            let list = fromMenu ? VeniceMenu.labels(VeniceMenu.imagerModes, allowed: options[VeniceMenu.imagerModeAllowed])
                : (options[property[.imager] ?? ""]?.compactMap { $0.string } ?? [])
            let sony = VeniceTables.imagerModes(model: state.model)
            let fallback = sony.contains { VeniceTables.normalised($0) == VeniceTables.normalised(imager) } ? sony : [imager]
            let modes = list.isEmpty ? fallback : list
            // Changing the imager mode, format or project rate restarts a VENICE's image (X-OCN → ProRes rebooted
            // it, VENICE 2): the tile asks first.
            state.resolution = Choice(imager, options: modes, isWritable: open(.imager),
                                      restartRequired: Set(modes.filter { $0 != imager }))
            state.recordingFormat = imager
        }
        if let codec = codecName() {
            let fromMenu = property[.codec]?.hasSuffix("System.Menu.AxsRecformatSelect") == true
            let list = fromMenu
                ? VeniceMenu.labels(VeniceMenu.recordingFormats, allowed: options[VeniceMenu.recordingFormatAllowed])
                : (options[property[.codec] ?? ""]?.compactMap { $0.string } ?? [])
            let project = plain(.fps)?.string ?? plain(.fps)?.unwrapped.string
            var sony = VeniceTables.recordingFormats(imager: state.resolution?.value ?? "", model: state.model,
                                                     projectRate: project)
            if !sony.contains(codec) { sony = VeniceTables.recordingFormats.contains(codec) ? sony + [codec] : [codec] }
            // Not "Rec Off" (AXS recording off): the camera's menu has it beside the codecs, but from Tiles' codec picker
            // it would stop REC recording, behind only a restart prompt. The camera's own menu turns it off.
            let formats = (list.isEmpty ? sony : list).filter { $0 != "Rec Off" || $0 == codec }
            state.fileFormat = Choice(codec, options: formats, isWritable: open(.codec),
                                      restartRequired: Set(formats.filter { $0 != codec }))
        }
        if property[.desqueeze] == VeniceMenu.desqueezeProperty {
            // VENICE 2: Project > Anamo. De-Squeeze, while the menu shows it (it needs the Anamorphic license). The
            // ratios it highlights now; it restarts the image, so the tile asks first.
            if menu(VeniceMenu.desqueezeVisible)?.string != "0",
               let ratio = VeniceMenu.label(VeniceMenu.desqueeze, value: value(.desqueeze)) {
                var list = VeniceMenu.labels(VeniceMenu.desqueeze, allowed: options[VeniceMenu.desqueezeAllowed])
                if !list.contains(ratio) { list.append(ratio) }
                state.desqueeze = Choice(ratio, options: list, isWritable: open(.desqueeze),
                                         restartRequired: Set(list.filter { $0 != ratio }))
            } else {
                state.desqueeze = nil
            }
        } else if let raw = value(.desqueeze)?.string ?? value(.desqueeze)?.unwrapped.string {
            // The camera's list when it gives one; otherwise Sony's table for the current imager mode. VENICE 1's page
            // reads the ratio as an index ("0"), so a digit is shown as the ratio at that place in the full list.
            let listed = options[property[.desqueeze] ?? ""]?.compactMap { $0.string } ?? []
            let list = listed.isEmpty
                ? VeniceDesqueeze.options(forImager: state.resolution?.value ?? "", model: state.model,
                                          codec: state.fileFormat?.value)
                : listed
            let shown = Int(raw).flatMap { VeniceDesqueeze.all.indices.contains($0) ? VeniceDesqueeze.all[$0] : nil } ?? raw
            state.desqueeze = Choice(shown, options: list, isWritable: open(.desqueeze))
        }

        // Outputs: the LUT, frame lines (markers) and status info on each; false color on the Monitor out and the
        // viewfinder, from the button it's assigned to (VENICE 2) or VENICE 1's menu switch.
        var outputs: [MonitorOutput] = []
        for output in Self.outputs {
            var overlays: [MonitorOverlay: Choice<Bool>] = [:]
            for (overlay, field) in output.fields {
                guard let raw = value(field), let name = property[field] else { continue }
                let on: Bool? = overlay == .lut ? Self.lutIsOn(raw) : raw.bool
                let writable = overlay == .lut ? !outputLocked(name) : true
                if let on { overlays[overlay] = Choice(on, options: [false, true], isWritable: writable) }
            }
            if let function = Self.falseColorFunctions.first(where: { $0.output == output.id })?.function,
               let assigned = assignment(function) {
                overlays[.falseColor] = Choice(assigned.on, options: [false, true])
            }
            // VENICE 2: the audio meters of the info set the output's overlay shows (none on the REC indicator alone),
            // and which frame line set it shows.
            if let select = Self.infoSetSelect[output.id], let set = menu(select)?.string,
               let meter = Self.audioMeterInInfoSet[set], let raw = menu(meter)?.string {
                overlays[.audioMeters] = Choice(raw == "1", options: [false, true])
            }
            let frameLines = Self.frameLineSelect[output.id].flatMap { menu($0)?.string }
                .map { Choice<FrameLineSet>($0 == "1" ? .b : .a, options: [.a, .b]) }
            if !overlays.isEmpty {
                outputs.append(MonitorOutput(id: output.id, name: output.name, overlays: overlays, frameLines: frameLines))
            }
        }
        // An output the camera links to another (SDI 3/4 or HDMI "Same as Monitor") shows that one's overlays and
        // can't set its own. The LUT is linked separately (the joint maps), so it stays the output's own.
        let follows: [String: String?] = [
            "Sdi34": VeniceMenu.followed(menu(VeniceMenu.followsSdi34)?.string),
            "Monitor": menu(VeniceMenu.monitorOutSource)?.string == "1" ? "Vf"
                : VeniceMenu.followed(menu(VeniceMenu.followsMonitor)?.string),
            "Hdmi": VeniceMenu.followed(menu(VeniceMenu.followsHdmi)?.string),
        ]
        // A chain (SDI 3/4 Same as Monitor, the Monitor showing the VF) ends at the output with settings of its own.
        let own = outputs
        func source(of id: String) -> MonitorOutput? {
            var at = id
            for _ in 0..<own.count {
                guard let next = follows[at] ?? nil, next != at, own.contains(where: { $0.id == next }) else { break }
                at = next
            }
            return at == id ? nil : own.first { $0.id == at }
        }
        for index in outputs.indices {
            guard let leader = follows[outputs[index].id] ?? nil, let source = source(of: outputs[index].id) else { continue }
            outputs[index].follows = leader
            for (overlay, mine) in outputs[index].overlays where overlay != .lut {
                var shown = source.overlays[overlay] ?? mine
                shown.isWritable = false
                outputs[index].overlays[overlay] = shown
            }
            if var lines = source.frameLines ?? outputs[index].frameLines {
                lines.isWritable = false
                outputs[index].frameLines = lines
            }
        }
        followers = Set(outputs.filter { $0.follows != nil }.map(\.id))
        state.monitoring = outputs.isEmpty ? nil : MonitoringState(outputs: outputs)
        state.look = state.monitoring?.onEverywhere(.lut)
        // The LUT picker: what the Monitor out (else the viewfinder) shows, or would show when its LUT is turned on.
        // VENICE 2 lists every look it has (presets, user 3D LUTs, ART files); picking one loads it and puts every
        // output showing a LUT on it (`setLUT`).
        if let monitorProperty = property[.lutMonitor] ?? property[.lutVf] {
            let showing = (livePending(monitorProperty) ?? stored(monitorProperty))?.string
            let shown = outputLUTLabel(showing) ?? outputLUTLabel(lastLUT[monitorProperty] ?? "Look") ?? "Look"
            var list = looks.map(\.label)
            if list.isEmpty {
                let listed = options[monitorProperty]?.compactMap { $0.string }.filter { !VeniceTables.isLog($0) }
                list = (listed?.isEmpty == false ? listed! : VeniceTables.monitorLUTs).map(Self.presetLabel)
            }
            if !list.contains(shown) { list.append(shown) }
            state.lut = Choice(shown, options: list, isWritable: statuses[Self.lutLock] != "Locked")
        }
        state.offersFalseColorLUTSwap = false
        state.falseColor = state.monitoring?.onEverywhere(.falseColor)

        // User buttons: whatever function sits on an assignable slot, and whether the camera says it's on.
        if let flip = menu(Self.flipImage)?.string {
            state.imageFlip = Choice(flip != "0", options: [false, true], isWritable: unlocked(Self.flipImage))
        } else if let flip = assignedSlotState(matching: ["flip", "inversion", "invert"]) {
            state.imageFlip = Choice(flip, options: [false, true], isWritable: true)
        }
        if state.colorBars == nil, let bars = assignedSlotState(matching: ["color bar", "colour bar", "bars"]) {
            state.colorBars = Choice(bars, options: [false, true], isWritable: true)
        }

        // The camera's own Web Remote, one tap away.
        state.webRemoteURL = URL(string: "http://\(host)/rm.html")

        // Playback (VENICE 2): InsideClips puts the camera in playback, where the mediabox reads
        // "Playing" (its speed 0 until Play: 1, FF 4, REW -4); Home takes it back to "Standby".
        let status = (values[Self.mediaboxStatus]?.unwrapped.string ?? "").lowercased()
        let speed = values[Self.mediaboxSpeed]?.unwrapped.number
        let reviewing = status.isEmpty ? nil : (status == "playing")
        state.playback = PlaybackState(
            isPlaying: reviewing == true ? (speed.map { $0 != 0 } ?? false) : (reviewing == nil ? nil : false),
            inReview: reviewing,
            clipName: state.clipName,
            // A VENICE 2 nests both under "main" ({"main": 6}) and reads -1 on the live picture (the 10/23 capture): a
            // plain number read nothing, so its Playback tile never said which clip.
            clipNumber: plain(.clipPosition)?.unwrapped.number.flatMap { $0 >= 1 ? Int($0) : nil },
            clipCount: plain(.clipTotal)?.unwrapped.number.flatMap { $0 >= 1 ? Int($0) : nil },
            capabilities: PlaybackCapabilities(playPause: true, stop: true, nextPrevious: true, seek: false,
                                               fastForwardRewind: true, recReview: false,
                                               live: values[Self.mediaboxStatus] == nil,  // the Live/Review switch is it
                                               review: values[Self.mediaboxStatus] != nil,
                                               scanSpeed: 4,  // Forward and Rewind: 4×, as a VENICE 2 scanned
                                               // The Clips window: stepped to with Next and Prev, by the clip's position.
                                               goToClip: values[Self.mediaboxStatus] != nil && property[.clipPosition] != nil))
        state.latencyMilliseconds = latencyMilliseconds

        // Camera Menu: the keys Sony's own page and SkaarHoj's VENICE 2 core send, less any this camera didn't answer.
        state.cameraButtons = CameraBodyButton.allCases.filter {
            Self.menuKeys[$0].map { !unansweredKeys.contains($0) } ?? false
        }
        // What frame line sets A and B show of the user frame lines: two menu switches each, "0" / "1".
        state.userFrameLinesA = userFrameLines(Self.userFrameA)
        state.userFrameLinesB = userFrameLines(Self.userFrameB)
        applyMeters()
    }

    /// One frame line set's user frame lines, from its two switches; Off / On where the camera has only the first.
    func userFrameLines(_ names: (first: String, second: String)) -> Choice<String>? {
        func menu(_ name: String) -> String? { (livePending(name) ?? values[name])?.unwrapped.string }
        guard let first = menu(names.first) else { return nil }
        let second = menu(names.second)
        let label = UserFrameLines.label(first: first == "1", second: second.map { $0 == "1" })
        return Choice(label, options: second == nil ? UserFrameLines.single : UserFrameLines.options,
                      isWritable: unlocked(names.first) && (second == nil || unlocked(names.second)))
    }

    /// The audio meters from `Output.Audio.dBLevel` ({"ch.1": 0–24, …}), as fractions of the meter; grayed while S&Q
    /// records no sound (its page's test: S&Q on, and not at 1×, `SandQPseudoFixed`).
    func applyMeters() {
        guard let channels = values[Self.audioMeters]?.map, !channels.isEmpty else {
            state.audioMeterCount = 0
            state.audioMeters = nil
            return
        }
        let keys = channels.keys.sorted { (Int($0.dropFirst(3)) ?? 0) < (Int($1.dropFirst(3)) ?? 0) }
        state.audioMeterCount = keys.count
        state.audioMeters = keys.map { min(max((channels[$0]?.number ?? 0) / 24, 0), 1) }
        let slowAndQuick = values["Camera.SlowAndQuickMotion.Enabled"]?.unwrapped.bool == true
        let atOneTimes = values[Self.slowAndQuickAtOneTimes]?.unwrapped.string == "1"
            || values[Self.slowAndQuickAtOneTimes]?.unwrapped.bool == true
        state.audioMetersMuted = slowAndQuick && !atOneTimes
    }

    /// The menu properties behind an overlay on one output, or on every output that has it; never on an output showing
    /// another's (the camera ignores its own setting while it does), but for its LUT, which stays its own.
    func overlayProperties(_ overlay: MonitorOverlay, output: String?) -> [String] {
        Self.outputs.filter { (output == nil || $0.id == output) && (overlay == .lut || !followers.contains($0.id)) }
            .compactMap { $0.fields.first { $0.0 == overlay }?.1 }
            .compactMap { property[$0] }
    }

    /// Whether the camera lets a property change now: neither it nor the menu item behind it is locked.
    func unlocked(_ name: String) -> Bool {
        let base = Self.slot(name)?.base ?? name
        if statuses[base] == "Locked" { return false }
        if let item = VeniceMenu.menuLocks[base], statuses[item] == "Locked" { return false }
        return true
    }

    /// VENICE 2's outputs and the property behind each overlay on them (manual: frame lines and info overlay on every
    /// output, false color on the Monitor output and the viewfinder, a LUT choice on each).
    static let outputs: [(id: String, name: String, fields: [(MonitorOverlay, Field)])] = [
        ("Sdi12", "SDI 1/2", [(.lut, .lutSdi12), (.frameGuides, .markerSdi), (.statusText, .osdSdi12)]),
        ("Sdi34", "SDI 3/4", [(.lut, .lutSdi34), (.frameGuides, .markerSdi34), (.statusText, .osdSdi34)]),
        ("Monitor", "Monitor", [(.lut, .lutMonitor), (.frameGuides, .markerMonitor), (.statusText, .osdMonitor),
                                (.falseColor, .falseColor), (.focusAssist, .peaking)]),
        ("Vf", "VF", [(.lut, .lutVf), (.frameGuides, .markerVf), (.statusText, .osdVf), (.falseColor, .vfFalseColor),
                      (.zebra, .zebraVf), (.focusAssist, .peaking)]),
        // HDMI's LUT is VENICE 2's "hdmi" entry (Log, s709, R709_800%, Look, HLG); on a body without one it takes the
        // LUT of the output it follows (manual p. 51).
        ("Hdmi", "HDMI", [(.lut, .lutHdmi), (.frameGuides, .markerHdmi), (.statusText, .osdHdmi)]),
    ]

    /// A LUT is on unless the output shows Log (or FW 3.0's Log(Legal), S-Log3 in legal range).
    static func lutIsOn(_ value: MPValue) -> Bool? {
        guard let text = value.string ?? value.unwrapped.string else { return value.bool }
        return !VeniceTables.isLog(text)
    }

    /// The LUT to put back on an output: the one it showed last (s709, R709(800%), Look), or Look.
    func lutValue(_ on: Bool, for name: String) -> MPValue {
        guard on else { return .string("Log") }
        if let last = lastLUT[name] { return .string(last) }
        return .string("Look")
    }

    /// `Button.Assign`: {"Assignable.N": [function, "On"/"Off"]}. The slot whose function matches, as its key.
    func assignedSlot(matching words: [String]) -> String? {
        guard let name = property[.assign], let slots = values[name]?.map else { return nil }
        return slots.keys.sorted().filter { $0 != "Assignable.0" }.first { key in
            let function = (slots[key]?[0]?.string ?? "").lowercased()
            return words.contains { function.contains($0) }
        }
    }

    func assignedSlotState(matching words: [String]) -> Bool? {
        guard let key = assignedSlot(matching: words), let name = property[.assign] else { return nil }
        return values[name]?.map?[key]?[1]?.bool
    }

    /// Playback as VENICE 2's page does it: the camera's own keys (KeyConverter.js, savona-2.9.4: Play is play/pause,
    /// Stop, Forward, Rewind, Next, Prev, InsideClips opens the clip list, Home goes back to live). The PXW's
    /// Clip.Player.* calls get no answer on a VENICE 2.
    func play(_ command: PlaybackCommand) async {
        switch command {
        case .play, .togglePlay, .pause: await sendKey("Play")
        case .stop: await sendKey("Stop")
        case .live: await sendKey("Home")
        case .review:
            // Into the last take, playing: the camera opens it paused, its picture black until Play, and takes Play
            // only once it says the clip can play (on a VENICE 2, about 5 s after InsideClips).
            values[Self.playbackEnabled] = nil
            await sendKey("InsideClips")
            if await readyToPlay() { await sendKey("Play") }
        case .fastForward, .scan(forward: true): await sendKey("Forward")   // 4×, until Play or Stop
        case .rewind, .scan(forward: false): await sendKey("Rewind")        // −4×
        case .endScan:
            // A held ▶▶ / ◀◀ let go: on at normal speed. Play during a scan pauses (speed 4 to 0 on the camera), so a
            // second Play once it has; a scan that already ran to the clip's end takes the one.
            let scanning = (values[Self.mediaboxSpeed]?.unwrapped.number ?? 0) != 0
            await sendKey("Play")
            if scanning, await speedSettles(at: 0) { await sendKey("Play") }
        case .next: await sendKey("Next")
        case .previous: await sendKey("Prev")
        case .goToClip(let index): await goToClip(index + 1)
        case .skip, .recReview: break          // not offered: no seek, no Rec Review
        }
        await refresh([.recorder, .clipName, .clipPosition, .clipTotal])
    }

    /// The clip the Clips window picked (`number`, from 1), playing. Into playback first where it isn't (InsideClips,
    /// the last take, as Review), then Next or Prev a clip at a time by where the camera says it is
    /// (`Clip.Mediabox.AllClipPosition` of `AllTotalClips`), then Play once the clip can play, if it's paused. A pick
    /// while another still steps changes where that one goes. Not during a take. What a VENICE 2 did on 10/23, its own
    /// page driving it: InsideClips opened 6 of 6 in 3.5 s, Prev went to 5 of 6 in 0.4 s, paused, and Next back; each
    /// said the clip could play again. Never run from Tiles (docs/feature-gaps.md).
    func goToClip(_ number: Int) async {
        var idle: Bool { state.recording.state == .idle }
        guard number >= 1, idle else { return }
        clipTarget = number
        guard !steppingToClip else { return }
        steppingToClip = true
        defer { steppingToClip = false; clipTarget = nil }
        if state.playback?.inReview != true {
            values[Self.playbackEnabled] = nil
            await sendKey("InsideClips")
            guard await readyToPlay("Clips") || state.playback?.inReview == true else { return }
        }
        func wanted(_ total: Int) -> Int { min(clipTarget ?? number, total) }
        // Again if a pick lands meanwhile, even while Play goes: the last tap wins (five at most).
        for _ in 0..<5 {
            let target = clipTarget
            let end = await ClipStepper.step(
                to: wanted,
                read: {
                    await self.refresh([.clipPosition, .clipTotal])
                    guard self.state.playback?.inReview == true, let n = self.state.playback?.clipNumber,
                          let t = self.state.playback?.clipCount else { return nil }
                    return (n, t)
                },
                press: { forward in await self.sendKey(forward ? "Next" : "Prev") },
                keepGoing: { idle })
            guard let end else { return }
            if end.number != wanted(end.total) {
                ActivityLog.shared.note(host, "Clips: clip \(end.number) of \(end.total) is open, not clip \(wanted(end.total))")
            }
            guard idle else { return }
            guard clipTarget == target else { continue }
            // Play only takes once the camera says the clip can play, and it's a toggle: only on a paused clip.
            if await readyToPlay("Clips") { await sendKey("Play") }
            if clipTarget == target { return }
        }
    }

    /// After InsideClips: whether the camera is in playback (its mediabox "Playing"), says the clip can play
    /// (`Clip.Mediabox.PlaybackEnabled`, reported again after InsideClips) and has it paused (speed 0), waited for up
    /// to 8 s. A clip already moving isn't touched: Play would pause it.
    func readyToPlay(_ what: String = "Review") async -> Bool {
        for _ in 0..<32 {
            let inPlayback = (values[Self.mediaboxStatus]?.unwrapped.string ?? "").lowercased() == "playing"
            if inPlayback, values[Self.playbackEnabled]?.map?["selectClip"]?.bool == true {
                return (values[Self.mediaboxSpeed]?.unwrapped.number ?? 0) == 0
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        log.notice("\(what, privacy: .public): the clip wasn't ready to play within 8 s; left paused")
        return false
    }

    /// Whether the mediabox's speed reads `speed` within 2 s.
    func speedSettles(at speed: Double) async -> Bool {
        for _ in 0..<8 {
            if (values[Self.mediaboxSpeed]?.unwrapped.number ?? speed) == speed { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    var latencyMilliseconds: Int? {
        guard !recentLatencies.isEmpty else { return nil }
        return Int(recentLatencies.suffix(4).reduce(0, +) / Double(min(recentLatencies.count, 4)) * 1000)
    }

    /// What the backend reads only goes out when it changed: the camera's audio meters notify ten times a second.
    func yield() {
        guard state != lastYielded else { return }
        lastYielded = state
        continuation.yield(state)
    }
}
