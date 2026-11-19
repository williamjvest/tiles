import Foundation
import Network
import CameraCore
import SSHTunnel

extension SonyCameraBackend {
    // MARK: - The camera's own buttons and dials

    // Camera Button Function 0xD309 presses a physical button; Camera Dial Function 0xD30B turns a dial. The camera
    // lists which ones in 0xD208 and 0xD20A. The FX3 has none of the Movie Play buttons (0xE021–E028), so this is
    // its only way into playback: it lists Playback, the arrows, ENTER and three dials.

    /// The buttons the camera lets the network press (0xD208 ids: 0x11 Playback, 0x03 Left…), or [] if none.
    public var emulatableButtons: [UInt16] {
        guard (sessionInfo?.extDeviceInfo.controlCodes ?? []).contains(SDIControlCode.cameraButtonFunction.rawValue)
        else { return [] }
        return rawProps[SDIPropCode.cameraButtonList.rawValue]?.enumAllUInt16() ?? []
    }

    /// The dials the camera lets the network turn (0xD20A ids: 0x4001 control wheel…), or [] if none.
    public var emulatableDials: [UInt16] {
        guard (sessionInfo?.extDeviceInfo.controlCodes ?? []).contains(SDIControlCode.cameraDialFunction.rawValue)
        else { return [] }
        return rawProps[SDIPropCode.cameraDialList.rawValue]?.enumAllUInt16() ?? []
    }

    /// Press and release one of the camera's buttons: id << 16 | ON, a short hold, then id << 16 | OFF.
    /// Returns the camera's response (0x2001 accepted); a press it refuses is not released.
    @discardableResult
    public func pressCameraButton(_ id: UInt16, holdFor seconds: Double = 0.1) async -> UInt16 {
        let on = await controlDevice(.cameraButtonFunction, UInt32(id) << 16 | 0x0002)
        guard on == PTPResponseCode.ok.rawValue else { return on }
        try? await Task.sleep(for: .seconds(max(0, seconds)))
        return await controlDevice(.cameraButtonFunction, UInt32(id) << 16 | 0x0001)
    }

    /// Press a button from Camera Button Function Multi's list (0xD209; MENU on the BURANO), held for `seconds`.
    public func pressCameraButtonMulti(_ id: UInt16, holdFor seconds: Double = 0.1) async -> UInt16 {
        let on = await controlDevice(.cameraButtonFunctionMulti, UInt32(id) << 16 | 0x0002)
        guard on == PTPResponseCode.ok.rawValue else { return on }
        try? await Task.sleep(for: .seconds(max(0, seconds)))
        return await controlDevice(.cameraButtonFunctionMulti, UInt32(id) << 16 | 0x0001)
    }

    /// Properties a raw write never reaches, though a camera lists them settable: Delete UserBaseLook (0xD0C7) takes a
    /// LUT away; the assignable buttons' assignments (0xE014–0xE01E, 0xE08D) and presses (0xE029–0xE033, 0xE08E), since
    /// one can be assigned Last Clip Del. and then pressed; and the scene file command and transfers (0xE0E6,
    /// 0xE101, 0xE102), which load or replace the camera's whole setup.
    static func rawWriteRefused(_ code: UInt16) -> Bool {
        code == 0xD0C7 || (0xE014...0xE01E).contains(code) || code == 0xE08D || (0xE029...0xE033).contains(code)
            || code == 0xE08E || code == 0xE0E6 || code == 0xE101 || code == 0xE102
    }

    /// Debug tools: write a property's raw little-endian bytes and return the camera's response code, without the
    /// app's command path or its optimistic state.
    public func setRawProperty(_ code: UInt16, data: Data) async -> UInt16 {
        guard let transport else { return PTPResponseCode.sessionNotOpen.rawValue }
        // Only a property the camera listed as one: every control, the card-wiping one (0xD2E2) among them, is out
        // of reach. Nor the ones in `rawWriteRefused`.
        guard rawProps[code] != nil, !Self.rawWriteRefused(code) else { return PTPResponseCode.accessDenied.rawValue }
        do {
            let (resp, _) = try await transport.execute(opCode: SDIOOpCode.setExtDevicePropValue.rawValue,
                                                        params: [UInt32(code), sdioExtendedCodesFlag], sendData: data)
            return resp.responseCode
        } catch {
            return PTPResponseCode.generalError.rawValue
        }
    }

    /// One of `CameraState.cameraButtons` (StateMapper.cameraButtons). MENU is held: a short press shows the status
    /// screen, a held one the full menu, and a press with the menu up closes it (BURANO manual p.33).
    func pressBodyButton(_ button: CameraBodyButton) async {
        let single = Set(rawProps[SDIPropCode.cameraButtonList.rawValue]?.enumAllUInt16() ?? [])
        let multi = Set(rawProps[SDIPropCode.cameraButtonListMulti.rawValue]?.enumAllUInt16() ?? [])
        let ids: [CameraBodyButton: CameraButton] = [.home: .home, .back: .back, .display: .display, .clips: .clips,
                                                     .up: .msUp, .down: .msDown, .left: .msLeft, .right: .msRight]
        switch button {
        case .menu:
            if multi.contains(CameraButton.menu.rawValue) {
                _ = await pressCameraButtonMulti(CameraButton.menu.rawValue, holdFor: 1.5)
            } else if single.contains(CameraButton.menu.rawValue) {
                _ = await pressCameraButton(CameraButton.menu.rawValue, holdFor: 1.5)
            }
        case .enter:
            let id: CameraButton = single.contains(CameraButton.msEnter.rawValue) ? .msEnter : .enter
            if single.contains(id.rawValue) { _ = await pressCameraButton(id.rawValue) }
        default:
            if let id = ids[button], single.contains(id.rawValue) { _ = await pressCameraButton(id.rawValue) }
        }
    }

    /// Turn one of the camera's dials by `notches`, plus clockwise: id << 16 | notches.
    @discardableResult
    public func turnCameraDial(_ id: UInt16, notches: Int16) async -> UInt16 {
        await controlDevice(.cameraDialFunction, UInt32(id) << 16 | UInt32(UInt16(bitPattern: notches)))
    }

    /// One of the step controls (focus, zoom, color temperature, tint, ECS), at its own size, if the camera listed it.
    /// Nothing else goes through here.
    public func stepControl(_ code: SDIControlCode, by steps: Int) async -> UInt16 {
        guard let transport else { return PTPResponseCode.sessionNotOpen.rawValue }
        guard (sessionInfo?.extDeviceInfo.controlCodes ?? []).contains(code.rawValue) else {
            return PTPResponseCode.accessDenied.rawValue
        }
        var data = Data()
        switch code {
        case .focusOperation, .zoomOperation: data.append(UInt8(bitPattern: Int8(clamping: steps)))      // INT8
        case .colorTempStep, .wbTintStep, .shutterECSStep: data.appendLE(UInt16(bitPattern: Int16(clamping: steps)))  // INT16
        default: return PTPResponseCode.accessDenied.rawValue
        }
        do {
            let (resp, _) = try await transport.execute(opCode: SDIOOpCode.controlDevice.rawValue,
                                                        params: [UInt32(code.rawValue), sdioExtendedCodesFlag], sendData: data)
            return resp.responseCode
        } catch {
            return PTPResponseCode.generalError.rawValue
        }
    }

    func controlDevice(_ code: SDIControlCode, _ value: UInt32) async -> UInt16 {
        guard let transport else { return PTPResponseCode.sessionNotOpen.rawValue }
        var data = Data(); data.appendLE(value)
        do {
            let (resp, _) = try await transport.execute(opCode: SDIOOpCode.controlDevice.rawValue,
                                                        params: [UInt32(code.rawValue), sdioExtendedCodesFlag], sendData: data)
            return resp.responseCode
        } catch {
            return PTPResponseCode.generalError.rawValue
        }
    }

    public struct OSDImageError: Error, CustomStringConvertible {
        public let responseCode: UInt16
        public var description: String { String(format: "camera answered 0x%04X", responseCode) }
    }


    /// What the camera's own screen shows over the picture, as a PNG (SDIO_GetOSDImage). Turns OSD Image
    /// Mode 0xD207 on first, which the camera needs before it will send one.
    public func osdImage() async throws -> Data {
        guard let transport else { throw OSDImageError(responseCode: PTPResponseCode.sessionNotOpen.rawValue) }
        // Only a camera that lists OSD Image Mode (0xD207) has an OSD image. The BURANO doesn't list it, yet took the
        // mode write, then never answered SDIO_GetOSDImage: the session died and the camera refused new ones for
        // minutes after; never answered SDIO_GetOSDImage.
        guard rawProps[SDIPropCode.osdImageMode.rawValue] != nil
        else { throw OSDImageError(responseCode: PTPResponseCode.operationNotSupported.rawValue) }
        if !osdModeOn, rawProps[SDIPropCode.osdImageMode.rawValue]?.currentUInt8() != 0x01 {
            await setProp(code: SDIPropCode.osdImageMode.rawValue, data: Data([0x01]))
            try? await Task.sleep(for: .milliseconds(300))
        }
        osdModeOn = true
        let (resp, data) = try await transport.execute(opCode: SDIOOpCode.getOSDImage.rawValue)
        guard resp.responseCode == PTPResponseCode.ok.rawValue else { throw OSDImageError(responseCode: resp.responseCode) }
        // OSD Image Dataset: offset to the PNG, its size, offset to the meta info, its size
        guard data.count >= 16 else { throw OSDImageError(responseCode: PTPResponseCode.generalError.rawValue) }
        let offset = Int(data.readLE(UInt32.self, at: 0)), size = Int(data.readLE(UInt32.self, at: 4))
        guard offset >= 16, size > 0, offset + size <= data.count
        else { throw OSDImageError(responseCode: PTPResponseCode.generalError.rawValue) }
        return Data(data[data.startIndex + offset ..< data.startIndex + offset + size])
    }

    /// Turn OSD Image Mode back off if osdImage() turned it on.
    public func stopOSDImage() async {
        guard osdModeOn else { return }
        await setProp(code: SDIPropCode.osdImageMode.rawValue, data: Data([0x00]))
        osdModeOn = false
    }

    /// Read every property now rather than waiting for the camera's change events (debug tools).
    public func refreshProperties() async { await fetchAllProps() }

    // MARK: - Playback control

    /// Press a playback button property: SetExtDevicePropValue Down then Up.
    /// Mirrors how REC uses SDIO_ControlDevice: same data-phase pattern but via SetExtDevicePropValue.
    func pressButton(code: SDIPropCode) async {
        guard let transport else { return }
        for value: UInt16 in [ButtonValue.down.rawValue, ButtonValue.up.rawValue] {
            var d = Data(); d.appendLE(value)
            do {
                let (resp, _) = try await transport.execute(
                    opCode: SDIOOpCode.setExtDevicePropValue.rawValue,
                    params: [UInt32(code.rawValue), sdioExtendedCodesFlag],
                    sendData: d
                )
                guard resp.responseCode == PTPResponseCode.ok.rawValue else { return }
            } catch { return }
        }
        // After a button press the camera will push a prop-changed event; let the event loop handle it.
    }

    func hasProp(_ code: SDIPropCode) -> Bool { rawProps[code.rawValue] != nil }

    /// An FX6 or an FX5: the bodies whose own controls (shooting mode, gain, proxy, AGC, assignable buttons…) Tiles
    /// reads (`StateMapper.mapFX6`), each checked on one. They take different playback buttons from a BURANO's, with the
    /// same list (docs/fx6-controls.md, docs/fx5-controls.md).
    var isProBody: Bool { SonyProBody.has(state.model) }

    /// No Movie Play buttons (0xE021/0xE022), or the camera has them disabled: it plays back through its own buttons
    /// (`StateMapper.buttonPlayback`, the FX3).
    var playsThroughButtons: Bool {
        guard let anchor = rawProps[SDIPropCode.moviePlayPauseButton.rawValue] ?? rawProps[SDIPropCode.moviePlayButton.rawValue]
        else { return true }
        return anchor.isEnabled == .disabled
    }

    func sendPlaybackCommand(_ cmd: PlaybackCommand) async {
        guard state.connection.isControllable else { return }
        let pb = state.playback
        if pb?.capabilities.review == true, playsThroughButtons { await sendButtonPlayback(cmd); return }
        switch cmd {
        case .play:
            if hasProp(.moviePlayButton) { await pressButton(code: .moviePlayButton) }
            else if pb?.isPlaying != true { await pressButton(code: .moviePlayPauseButton) }
        case .pause:
            // Play Pause toggles: only press it when the camera says it's playing.
            if pb?.isPlaying == true { await pressButton(code: .moviePlayPauseButton) }
        case .togglePlay:
            // Play Pause where the camera has it, else Play. An FX6's Play Pause only pauses: a paused clip there
            // resumes with Play.
            guard pb?.capabilities.playPause == true else { return }
            let resumeWithPlay = isProBody && pb?.isPlaying != true && hasProp(.moviePlayButton)
            await pressButton(code: hasProp(.moviePlayPauseButton) && !resumeWithPlay ? .moviePlayPauseButton : .moviePlayButton)
        case .stop:
            await pressButton(code: .moviePlayStopButton)
        case .live:
            // Sony has no explicit "return to live" button property; Stop takes a BURANO back to the live picture.
            await pressButton(code: .moviePlayStopButton)
        case .review:
            // The Live | Review switch's Review. Not during a take, and not again once it's there (Play Pause would
            // pause it). Play Pause on the live picture puts a BURANO in playback, playing. An FX6 or FX5 ignores it
            // there, and its Play only sometimes picks up where playback last stopped: Prev opens a take paused at its
            // start (an FX6's last; on an FX5 one back from where Playback was, so Next steps on to the last, by the
            // take number it gives), and Play plays it.
            guard recordingIdle, pb?.inReview != true else { return }
            if isProBody, hasProp(.moviePrevButton), hasProp(.moviePlayButton) {
                guard !reviewing else { return }
                reviewing = true
                defer { reviewing = false; clipTarget = nil }
                // On the live picture now, by a fresh read, or Prev would step back a take.
                guard await operatingModeNow() == 0x01, await openLastTake() else { return }
                await goToTakeAndPlay()
                return
            }
            await pressButton(code: hasProp(.moviePlayPauseButton) ? .moviePlayPauseButton : .moviePlayButton)
        case .next:
            await pressButton(code: .movieNextButton)
        case .previous:
            await pressButton(code: .moviePrevButton)
        case .fastForward, .scan(forward: true):
            // A held ▶▶ (scan) is a press of the camera's own, which scans until Play.
            await pressButton(code: .movieForwardButton)
        case .rewind, .scan(forward: false):
            await pressButton(code: .movieRewindButton)
        case .endScan:
            // Let go of a held ▶▶ / ◀◀: on at speed from there, as the FX3's does.
            if hasProp(.moviePlayButton) { await pressButton(code: .moviePlayButton) }
        case .recReview:
            await pressButton(code: .movieRecReviewButton)
        case .goToClip(let index):
            // The take the Clips window picked, playing: an FX5's, which numbers its takes in Playback. Review's way in
            // from the live picture (Prev opens a take), then Next or Prev a take at a time to it, then Play. A pick
            // while Review or another pick still steps changes where that one goes.
            guard recordingIdle, index >= 0, takesNumbered else { return }
            clipTarget = UInt32(index + 1)
            guard !reviewing else { return }
            reviewing = true
            defer { reviewing = false; clipTarget = nil }
            switch await operatingModeNow() {
            case 0x01: guard await openLastTake() else { return }
            case 0x02: break
            default: return
            }
            await goToTakeAndPlay()
        case .skip:
            break  // Sony can't seek by seconds; FF/REW are its own buttons.
        }
    }

    /// Whether the Clips window can go to a take: a pro body that numbers its takes in Playback (Playback Contents
    /// Number and Total 0xD09E/0xD09F: an FX5) and has Prev, Next and Play.
    var takesNumbered: Bool {
        isProBody && hasProp(.playbackContentsNumber) && hasProp(.playbackContentsTotalNumber)
            && hasProp(.moviePrevButton) && hasProp(.movieNextButton) && hasProp(.moviePlayButton)
    }


    /// Prev on the live picture, until the camera says Playback, paused at a take's start (an FX6 or FX5). Just after a
    /// cut an FX5 ignored it once, 4 s after stopping (still writing the take?); a press a few seconds later opened it
    /// (docs/fx5-controls.md). So where the camera numbers its takes (an FX5) it's pressed again, twice at most, and only
    /// after 3 s of the camera saying it's still on the live picture: Prev in Playback steps to the take before, which
    /// `goToTake` puts right there and nothing could on an FX6, which gets one press. A read that fails ends it.
    /// False if it never opened, or a take started meanwhile.
    func openLastTake() async -> Bool {
        for _ in 0..<(hasProp(.playbackContentsNumber) ? 3 : 1) {
            await pressButton(code: .moviePrevButton)
            let began = ContinuousClock.now
            var mode = await operatingModeNow()
            while mode != 0x02, ContinuousClock.now - began < .seconds(3) {
                try? await Task.sleep(for: .milliseconds(200))
                mode = await operatingModeNow()
            }
            guard recordingIdle else { return false }
            if mode == 0x02 { return true }
            guard mode == 0x01 else { return false }
        }
        return false
    }

    /// The take Playback has open, and how many the card has: Playback Contents Number 0xD09E and Total 0xD09F, an
    /// FX5's, enabled in Playback. nil where the camera hasn't them (an FX6), or no fresh read came.
    func takeNumberNow() async -> (number: UInt32, total: UInt32)? {
        guard await readNow(),
              let number = rawProps[SDIPropCode.playbackContentsNumber.rawValue], number.isEnabled != .disabled,
              let total = rawProps[SDIPropCode.playbackContentsTotalNumber.rawValue], total.isEnabled != .disabled,
              let n = number.currentUInt32(), let t = total.currentUInt32() else { return nil }
        return (n, t)
    }

    /// `goToTake`, then Play: once the camera is still in Playback and not rolling (Live tapped meanwhile took it back,
    /// and Play there could open it again). A pick that lands meanwhile, even while Play is pressed, is stepped to and
    /// played in turn, so the last tap wins (five at most).
    func goToTakeAndPlay() async {
        for _ in 0..<5 {
            let target = clipTarget
            await goToTake()
            guard recordingIdle, await operatingModeNow() == 0x02 else { return }
            guard clipTarget == target else { continue }
            await pressButton(code: .moviePlayButton)
            if clipTarget == target { return }
        }
    }

    /// On from the take Playback has open to the one the Clips window picked (`clipTarget`), else the last. An FX5's
    /// Prev on the live picture opens the take before the newest after a cut, or one back from where Playback was left
    /// (docs/fx5-controls.md), which can be far back. One Next or Prev at a time, each once the camera has said which
    /// take it's on, so never past the total it gives (`ClipStepper`: 30 s, and a second a take further). It stops if the
    /// camera leaves Playback or stops answering, or two presses in a row don't move it; short of the take, it says so
    /// in the Activity Log. An FX6 has no take number: nothing.
    func goToTake() async {
        func wanted(_ total: Int) -> Int { clipTarget.map { min(Int($0), total) } ?? total }
        guard let end = await ClipStepper.step(
            to: wanted,
            read: { await self.takeNumberNow().map { (Int($0.number), Int($0.total)) } },
            press: { forward in await self.pressButton(code: forward ? .movieNextButton : .moviePrevButton) },
            keepGoing: { self.recordingIdle }
        ), end.number != wanted(end.total) else { return }
        ActivityLog.shared.note(host, clipTarget == nil
            ? "Review: take \(end.number) of \(end.total) is open, not the last"
            : "Clips: take \(end.number) of \(end.total) is open, not take \(wanted(end.total))")
    }

    func sendButtonPlayback(_ cmd: PlaybackCommand) async {
        let previous = buttonQueue
        let task = Task { await previous?.value; await self.runButtonPlayback(cmd) }
        buttonQueue = task
        await task.value
    }

    var recordingIdle: Bool { state.recording.state == .idle && state.recording.request == nil }

    /// Playback on a body played through its own buttons (the FX3). The arrows and ENTER are pressed only while the
    /// camera says, when asked just then, that it's in Playback: in Record mode they're its shooting shortcuts, and on
    /// the FX3 Right toggles peaking and Left zebras.
    ///
    /// What the FX3 does in Playback (measured on a clip with exposure stepped every 3 s): ENTER plays and pauses; an
    /// arrow while playing scans at roughly 2–5× until the end of the clip, and ENTER during a scan plays on from
    /// there; with the clip stopped the arrows change clip. Tiles gives each its own button: ⏮ ⏭ change clip (and keep
    /// playing if a clip was), and ◀◀ ▶▶ only scan (a clip that isn't playing is started first). The camera reports none
    /// of this, so whether a clip is playing is tracked from the presses made here (`reviewPhase`).
    func runButtonPlayback(_ cmd: PlaybackCommand) async {
        switch cmd {
        case .review:
            guard recordingIdle, await operatingModeNow() == 0x01, recordingIdle else { return }
            guard await press(.playback) else { return }
            reviewPhase = .stopped
            try? await Task.sleep(for: modeFlip)   // so a queued tap sees Playback
            // The clip Playback opens on (the last take), playing.
            if await press(.enter) { reviewPhase = .playing }
        case .live:
            // Playback steps back one level per press: an open clip (playing or paused) to the clip, the clip to the
            // live picture. Each press waits for a read that says the camera is still in Playback, and the loop ends
            // on a fresh read, so a transport tap after it never trusts a stale mode.
            var mode: UInt8? = await inPlayback() ? 0x02 : nil
            for _ in 0..<3 where mode == 0x02 {
                guard await press(.playback) else { break }
                try? await Task.sleep(for: modeFlip)
                mode = await operatingModeNow()
            }
            reviewPhase = .unknown
        case .togglePlay:
            guard await inPlayback(), await press(.enter) else { return }
            reviewPhase = reviewPhase.toggled
        case .rewind, .fastForward:
            // Within the clip: a short scan, then play on, a few seconds along. Clips change with ⏮ ⏭ only.
            guard await inPlayback(), await playing(), await press(cmd == .fastForward ? .right : .left) else { return }
            try? await Task.sleep(for: .seconds(config.skipScanTime))
            await press(.enter)
        case .scan(let forward):
            guard await inPlayback(), await playing(), await press(forward ? .right : .left) else { return }
            scanning = true
        case .endScan:
            guard scanning else { return }
            scanning = false
            await press(.enter)
        case .next, .previous:
            // From a playing or paused clip, Playback goes back to the clip (one level); there an arrow changes clip.
            // A clip that was playing carries on in its neighbor, as a player's ⏮ ⏭ do.
            guard await inPlayback() else { return }
            let wasPlaying = reviewPhase == .playing
            if reviewPhase == .playing || reviewPhase == .paused {
                guard await press(.playback) else { return }
                try? await Task.sleep(for: modeFlip)
                if await operatingModeNow() != 0x02 {
                    // The clip had already ended, so that press left Playback: straight back in, to the same clip.
                    guard recordingIdle, await press(.playback) else { reviewPhase = .unknown; return }
                    try? await Task.sleep(for: modeFlip)
                    guard await operatingModeNow() == 0x02 else { reviewPhase = .unknown; return }
                }
                reviewPhase = .stopped
            }
            guard await press(cmd == .next ? .right : .left) else { return }
            if wasPlaying, await press(.enter) { reviewPhase = .playing }
        case .play, .pause, .stop, .skip, .recReview, .goToClip:
            break  // nothing says playing or paused, so only the toggle; no seek; no clip numbers
        }
    }

    /// Plays the clip shown unless the presses made here say it's playing: on a stopped clip an arrow changes clip,
    /// and the scan arrows only ever move within one.
    func playing() async -> Bool {
        guard reviewPhase != .playing else { return true }
        guard await press(.enter) else { return false }
        reviewPhase = .playing
        try? await Task.sleep(for: .milliseconds(300))
        return true
    }

    /// Where a clip shown in Playback is, as far as the presses made here say.
    enum ReviewPhase {
        case unknown, stopped, playing, paused
        var toggled: ReviewPhase {
            switch self {
            case .stopped, .paused: .playing
            case .playing: .paused
            case .unknown: .unknown
            }
        }
    }

    @discardableResult
    func press(_ button: CameraButton) async -> Bool {
        let code = await pressCameraButton(button.rawValue)
        guard code != PTPResponseCode.ok.rawValue else { return true }
        state.warnings.append("The camera didn't take its \(button) button (0x\(String(code, radix: 16, uppercase: true)))")
        emit()
        return false
    }


    /// Whether the camera is showing clips, for a transport press. The last read answers at once when it says
    /// Playback: the camera sends an event on every mode change, and Live ends on a fresh read. Otherwise a fresh
    /// read decides. In Record mode these buttons are shooting shortcuts, so nothing is pressed on a guess. A fresh
    /// read before every tap cost 0.3-0.6 s each, and timed out (so nothing happened) while a clip played.
    func inPlayback() async -> Bool {
        if rawProps[SDIPropCode.cameraOperatingMode.rawValue]?.currentUInt8() == 0x02 { return true }
        return await operatingModeNow() == 0x02
    }

    /// Camera Operating Mode (0xD0BC: 0x01 Record, 0x02 Playback) from a property read that finished after this was
    /// called, never the last one heard. nil if no read finishes within 3 s.
    func operatingModeNow() async -> UInt8? {
        // No fresh answer → nil, and nothing is pressed on a guess (in Record mode the arrows toggle peaking/zebras).
        guard await readNow() else { return nil }
        return rawProps[SDIPropCode.cameraOperatingMode.rawValue]?.currentUInt8()
    }

    /// Waits for a property read that started after the call: a fetch already running may have read before the last
    /// press. False if none came in 3 s.
    func readNow() async -> Bool {
        let target = fetchGeneration + (fetchInFlight ? 2 : 1)
        _ = await requestFetch(.changed)
        for _ in 0..<120 where fetchGeneration < target { try? await Task.sleep(for: .milliseconds(25)) }
        return fetchGeneration >= target
    }

    /// As `readNow`, every property and its form: a range that moved with another setting (a stream's bit rate with its
    /// resolution) isn't always in a read of what changed. 5 s at most.
    func readAllNow() async -> Bool {
        let target = fetchGeneration + (fetchInFlight ? 2 : 1)
        _ = await requestFetch(.full)
        for _ in 0..<200 where fetchGeneration < target { try? await Task.sleep(for: .milliseconds(25)) }
        return fetchGeneration >= target
    }
}

