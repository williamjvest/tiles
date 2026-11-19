@testable import CameraCore
import XCTest
@testable import SonySavona

/// The VENICE backend end to end, against `FakeVeniceCamera` (VENICE 2, FW V4.00, savona-2.9.4):
/// what Tiles shows for it, and what each tile sends.
final class VeniceBackendTests: XCTestCase {
    final class Latest: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = CameraState()
        private var timecodes = 0
        var value: CameraState { lock.withLock { stored } }
        /// How many times the timecode the backend reports has changed.
        var timecodeChanges: Int { lock.withLock { timecodes } }
        func set(_ state: CameraState) {
            lock.withLock {
                if state.timecode != stored.timecode { timecodes += 1 }
                stored = state
            }
        }
    }

    private var camera: FakeVeniceCamera!
    private var backend: VeniceCameraBackend!
    private var latest: Latest!
    private var listening: Task<Void, Never>?

    override func setUp() async throws {
        camera = FakeVeniceCamera()
        try await camera.start()
        backend = VeniceCameraBackend(host: camera.host, user: "admin", password: camera.password)
        let latest = Latest()
        self.latest = latest
        let updates = backend.updates
        listening = Task { for await state in updates { latest.set(state) } }
        await backend.connect()
        try await until("connected") { $0.connection == .connected && $0.lut != nil }
    }

    override func tearDown() async throws {
        await backend.disconnect()
        listening?.cancel()
        camera.stop()
    }

    /// Waits for the state the backend reports to satisfy `condition`.
    private func until(_ what: String, timeout: Double = 5, _ condition: (CameraState) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(latest.value) {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what): \(latest.value.connection)") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func output(_ id: String) -> MonitorOutput? { latest.value.monitoring?.outputs.first { $0.id == id } }

    func testReadsTheCameraAsItIs() {
        let s = latest.value
        XCTAssertEqual(s.modelName, "VENICE 2", "the 8.6K imager modes it offers make it an MPC-3628")
        XCTAssertEqual(s.iso?.value, 800)
        XCTAssertEqual(s.baseISO?.value, 3200)
        XCTAssertEqual(s.baseISO?.options, [800, 3200])
        XCTAssertEqual(s.resolution?.value, "8.6K 3:2")
        XCTAssertEqual(s.fileFormat?.value, "X-OCN LT")
        // De-squeeze from the menu: "5" is 2.0x; every ratio it highlights; it restarts the image.
        XCTAssertEqual(s.desqueeze?.value, "2.0x")
        XCTAssertEqual(s.desqueeze?.options, ["Off", "1.25x", "1.3x", "1.5x", "1.6x", "1.8x", "2.0x"])
        XCTAssertEqual(s.desqueeze?.restartRequired.contains("1.3x"), true)
        XCTAssertEqual(s.desqueeze?.isWritable, true)
        // The look: the Monitor out shows it, user 3D LUT 5.
        XCTAssertEqual(s.lut?.value, "User 5: Rec709_v2025_LUT5.cube")
        XCTAssertEqual(Array(s.lut?.options.prefix(4) ?? []), ["s709", "R709(800%)", "S-Gamut3.Cine/SLog3", "S-Gamut3/SLog3"])
        XCTAssertTrue(s.lut?.options.contains("User 7: s709.cube") == true, "a loaded s709.cube is a LUT")
        XCTAssertFalse(s.lut?.options.contains { $0.hasPrefix("User 12:") } == true, "a slot on the factory s709 is empty")
        XCTAssertFalse(s.lut?.options.contains { $0.hasPrefix("ART") } == true, "no ART files loaded")
        XCTAssertFalse(s.offersFalseColorLUTSwap, "the FC LUT in slot 6 isn't the LUT tile's switch on a VENICE")
        // Outputs: HDMI shows the same as the Monitor, as the camera reports it.
        XCTAssertEqual(s.monitoring?.outputs.map(\.name), ["SDI 1/2", "SDI 3/4", "Monitor", "VF", "HDMI"])
        XCTAssertEqual(output("Hdmi")?.follows, "Monitor")
        XCTAssertEqual(output("Hdmi")?.overlays[.frameGuides]?.isWritable, false)
        XCTAssertEqual(output("Hdmi")?.overlays[.lut]?.value, true)
        XCTAssertEqual(output("Hdmi")?.overlays[.lut]?.isWritable, true, "its LUT is its own")
        XCTAssertNil(output("Sdi34")?.follows)
        XCTAssertEqual(output("Sdi34")?.overlays[.lut]?.value, false, "SDI 3/4 is on Log")
        // False color on the Monitor out and the viewfinder, from the buttons they're on; off.
        XCTAssertEqual(output("Monitor")?.overlays[.falseColor]?.value, false)
        XCTAssertEqual(output("Vf")?.overlays[.falseColor]?.value, false)
        XCTAssertNil(output("Sdi12")?.overlays[.falseColor])
        // Peaking: one switch for the viewfinder and the Monitor out.
        XCTAssertEqual(output("Vf")?.overlays[.focusAssist]?.value, false)
        XCTAssertEqual(output("Monitor")?.overlays[.focusAssist]?.value, false)
        XCTAssertEqual(output("Vf")?.overlays[.zebra]?.value, true)
        // Color bars: the menu item is locked, the camera's property isn't.
        XCTAssertEqual(s.colorBars?.value, false)
        XCTAssertEqual(s.colorBars?.isWritable, true)
        // Naming, time display, power.
        XCTAssertEqual(s.fileNaming?.cameraID?.value, "B")
        XCTAssertEqual(s.fileNaming?.reel?.value, 24)
        XCTAssertEqual(s.fileNaming?.position?.value, "C")
        XCTAssertEqual(s.timecodeShowsDuration?.value, false)
        XCTAssertEqual(s.batteryVolts, 14.6)
        XCTAssertNil(s.batteryPercent)
        XCTAssertNil(s.iris, "no lens reports")
    }

    func testEIGoesOutAsThePageWritesIt() async throws {
        await backend.send(.setISO(1600))
        try await until("EI 1600") { $0.iso?.value == 1600 }
        XCTAssertEqual(camera.setValues.last, ["Camera.Gain.ExposureIndex.Value": "1600EI"], "not 1600.0EI")
    }

    /// The camera puts the EI back where it last was on a base (or the bottom of the range); Tiles' switch puts it on the
    /// base, written once the camera has taken the base.
    func testTheBaseSwitchPutsTheEIOnTheBase() async throws {
        await backend.send(.setBaseISO(800))
        try await until("base 800, EI 800") { $0.baseISO?.value == 800 && $0.iso?.value == 800 }
        XCTAssertEqual(camera.value("Camera.Gain.ExposureIndex.Value"), "800EI")
        await backend.send(.setISO(1000))
        try await until("EI 1000") { $0.iso?.value == 1000 }
        await backend.send(.setBaseISO(3200))
        try await until("base 3200, EI 3200") { $0.baseISO?.value == 3200 && $0.iso?.value == 3200 }
        XCTAssertEqual(camera.value("Camera.Gain.ExposureIndex.Value"), "3200EI")
        XCTAssertEqual(Array(camera.setValues.suffix(2)), [["Camera.Gain.ISOValue": "ISO 3200"],
                                                           ["Camera.Gain.ExposureIndex.Value": "3200EI"]])
        // Back again: the camera would bring back 1000; Tiles puts it on 800.
        await backend.send(.setBaseISO(800))
        try await until("base 800 again, EI 800") { $0.baseISO?.value == 800 && $0.iso?.value == 800 }
    }

    func testFalseColorPressesTheButtonItIsOn() async throws {
        await backend.send(.setMonitorOverlay(.falseColor, true, output: "Monitor"))
        try await until("Monitor false color") { s in
            s.monitoring?.outputs.first { $0.id == "Monitor" }?.overlays[.falseColor]?.value == true
        }
        XCTAssertEqual(camera.keysPressed, ["Assignable.2"])
        // The camera reported that one button alone: the others stand.
        XCTAssertEqual(output("Vf")?.overlays[.falseColor]?.value, false)
        // Every output: only the one still off is pressed.
        await backend.send(.setFalseColor(true))
        try await until("VF false color") { $0.falseColor?.value == true }
        XCTAssertEqual(camera.keysPressed, ["Assignable.2", "VFAssignable.B"])
        await backend.send(.setFalseColor(true))
        XCTAssertEqual(camera.keysPressed.count, 2, "already on: no press, the button toggles")
        await backend.send(.setFalseColor(false))
        try await until("false color off") { $0.falseColor?.value == false }
        XCTAssertEqual(camera.keysPressed.suffix(2).sorted(), ["Assignable.2", "VFAssignable.B"])
    }

    func testPickingALookLoadsItAndPutsTheOutputsOnIt() async throws {
        await backend.send(.setLUT("User 1: User_Look_1_Base.cube"))
        try await until("user LUT 1") { $0.lut?.value == "User 1: User_Look_1_Base.cube" }
        // The same mode: the selection alone, as the page sends it.
        XCTAssertTrue(camera.setValues.contains { $0 == ["LUT.User3DLUT.FileID": ["cam": 1]] })
        XCTAssertFalse(camera.setValues.contains { $0["LUT.Mode"] != nil })
        // The viewfinder was on s709 itself: it goes to the look. SDI 3/4 was off (Log) and stays off.
        XCTAssertTrue(camera.setValues.contains { $0 == ["Output.Video.ViewFinder.LUT.Value": ["vf": "Look"]] })
        XCTAssertFalse(camera.setValues.contains { $0["Output.Video.SDI.LUT.Value"]?["sdi3"] != nil })
        XCTAssertEqual(camera.value("Output.Video.ViewFinder.LUT.Value"), ["hdmi": "Look", "monitor": "Look", "vf": "Look"])

        // Another mode: mode and preset together (proven on the camera).
        await backend.send(.setLUT("R709(800%)"))
        try await until("R709(800%)") { $0.lut?.value == "R709(800%)" }
        XCTAssertTrue(camera.setValues.contains { $0 == ["LUT.Mode": ["cam": "PresetLook"], "LUT.Preset": ["cam": "R709_800%"]] })

        // Turning SDI 3/4's LUT on shows the look there too.
        await backend.send(.setMonitorOverlay(.lut, true, output: "Sdi34"))
        try await until("SDI 3/4 on") { s in s.monitoring?.outputs.first { $0.id == "Sdi34" }?.overlays[.lut]?.value == true }
        XCTAssertEqual(camera.value("Output.Video.SDI.LUT.Value"), ["sdi1": "Look", "sdi3": "Look"])
    }

    /// Storage.Media.AvailableTime is seconds: 2770 is 46 minutes. Values under 1000 must not be treated as minutes
    /// directly, as that would misread them (600 s is 10 minutes, not 600).
    func testMediaTimeIsSeconds() async throws {
        try await until("46 min") { $0.mediaRemainingMinutes == 46 }
        camera.bodyChange(["Storage.Media.AvailableTime": ["media.1": 0, "media.2": 0, "media.4": 0, "media.5": 600]])
        try await until("10 min") { $0.mediaRemainingMinutes == 10 }
    }

    func testALookChangedOnTheBodyFollows() async throws {
        camera.bodyChange(["LUT.Mode": ["cam": "PresetLook"], "LUT.Preset": ["cam": "s709"]])
        try await until("s709") { $0.lut?.value == "s709" }
    }

    func testDesqueezeWritesTheMenuValue() async throws {
        await backend.send(.setDesqueeze("1.6x"))
        try await until("1.6x") { $0.desqueeze?.value == "1.6x" }
        XCTAssertTrue(camera.setValues.contains { $0 == ["P.System.Menu.RecOutDeanamoScaleSelect": "6"] })
    }

    func testColorBarsTakeTheWayThatIsOpen() async throws {
        // The menu item is locked: the camera's own property.
        await backend.send(.setColorBars(true))
        try await until("bars on") { $0.colorBars?.value == true }
        XCTAssertEqual(camera.setValues.last, ["Camera.ColorBar.Enabled": true])
        // Unlocked: the menu's switch, as the page writes it.
        camera.lockChange(["P.System.Menu.ColorBar.MenuItem": "Unlocked"])
        try await Task.sleep(for: .milliseconds(150))
        await backend.send(.setColorBars(false))
        try await until("bars off") { $0.colorBars?.value == false }
        XCTAssertEqual(camera.setValues.last, ["P.System.Menu.ColorBar": "0"])
    }

    func testLocksGreyTheTilesAndAnIgnoredWriteSettles() async throws {
        camera.lockChange(["P.System.Menu.ProjectImagerMode.MenuItem": "Locked", "Camera.Gain.ExposureIndex.Value": "Locked"])
        try await until("imager locked") { $0.resolution?.isWritable == false && $0.iso?.isWritable == false }
        // A locked EI takes the write and changes nothing; Tiles re-reads it rather than showing 1600 for good.
        await backend.send(.setISO(1600))
        try await until("pending shown") { $0.iso?.value == 1600 }
        try await until("settled back", timeout: 6) { $0.iso?.value == 800 }
        camera.lockChange(["P.System.Menu.ProjectImagerMode.MenuItem": "Unlocked"])
        try await until("imager unlocked") { $0.resolution?.isWritable == true }
    }

    func testAnOutputFollowingAnotherIsLeftOutOfWritesToEveryOutput() async throws {
        camera.bodyChange(["P.System.Menu.OutputFormat.Info.Sdi34": "2"])  // SDI 3/4: Same as Monitor
        try await until("SDI 3/4 follows") { s in s.monitoring?.outputs.first { $0.id == "Sdi34" }?.follows == "Monitor" }
        XCTAssertEqual(output("Sdi34")?.overlays[.frameGuides]?.isWritable, false)
        await backend.send(.setMonitorOverlay(.frameGuides, false, output: nil))
        try await until("frame lines off") { $0.monitoring?.onEverywhere(.frameGuides)?.value == false }
        let written = camera.setValues.flatMap(\.keys)
        XCTAssertTrue(written.contains("P.System.Menu.MarkerMonitorOnoff"))
        XCTAssertFalse(written.contains("P.System.Menu.MarkerSdi34Onoff"))
        XCTAssertFalse(written.contains("P.System.Menu.MarkerHdmiOnoff"))
    }

    func testAChainOfLinksEndsAtTheOutputWithSettingsOfItsOwn() async throws {
        // The VF's frame lines off; the Monitor showing the VF; SDI 3/4 Same as Monitor: SDI 3/4 shows the VF's.
        camera.bodyChange(["P.System.Menu.MarkerVfOnoff": "0"])
        camera.bodyChange(["P.System.Menu.MonitorOutSource": "1", "P.System.Menu.OutputFormat.Info.Sdi34": "2"])
        try await until("the chain") { s in s.monitoring?.outputs.first { $0.id == "Sdi34" }?.follows == "Monitor" }
        XCTAssertEqual(output("Monitor")?.follows, "Vf")
        XCTAssertEqual(output("Monitor")?.overlays[.frameGuides]?.value, false, "the Monitor shows the VF's")
        XCTAssertEqual(output("Sdi34")?.overlays[.frameGuides]?.value, false, "and SDI 3/4 the Monitor's, so the VF's")
        XCTAssertEqual(output("Sdi12")?.overlays[.frameGuides]?.value, true)
    }

    func testASecondClientIsTurnedAwayAndTheFirstCarriesOn() async throws {
        let second = VeniceCameraBackend(host: camera.host, user: "admin", password: camera.password)
        await second.connect()
        var failed = false
        for await state in second.updates {
            if case .failed = state.connection { failed = true; break }
            if state.connection == .connected { break }
        }
        XCTAssertTrue(failed, "the camera takes one client")
        XCTAssertGreaterThanOrEqual(camera.clientsTurnedAway, 1)
        await backend.send(.setDesqueeze("1.3x"))
        try await until("the first still works") { $0.desqueeze?.value == "1.3x" }
    }

    func testAPropertyListItNeverAnswersStillResolves() async throws {
        let silent = FakeVeniceCamera(silentPropertyList: true)
        try await silent.start()
        defer { silent.stop() }
        let other = VeniceCameraBackend(host: silent.host, user: "admin", password: silent.password)
        await other.connect()
        var read = CameraState()
        for await state in other.updates where state.connection == .connected && state.lut != nil {
            read = state
            break
        }
        XCTAssertEqual(read.desqueeze?.value, "2.0x")
        XCTAssertEqual(read.lut?.value, "User 5: Rec709_v2025_LUT5.cube")
        await other.disconnect()
    }

    func testLoadsALUTIntoASlotAsThePageDoes() async throws {
        let slots = try await backend.lutSlots()
        XCTAssertEqual(slots.count, 16)
        XCTAssertEqual(slots[0].name, "User_Look_1_Base.cube")
        XCTAssertNil(slots[11].name, "slot 12 holds the factory s709")
        try await backend.importLUT(data: Data(repeating: 0x41, count: 4096), name: "Show LUT: v2", slot: 12)
        XCTAssertEqual(camera.uploads.last?.fields["DestinationID"], "12")
        XCTAssertEqual(camera.uploads.last?.fileName, "Show LUT_ v2.cube", "a character the camera's names can't hold is _")
        XCTAssertEqual(camera.uploads.last?.size, 4096)
        try await until("in the LUT list") { $0.lut?.options.contains("User 12: Show LUT_ v2.cube") == true }
        let after = try await backend.lutSlots()
        XCTAssertEqual(after[11].name, "Show LUT_ v2.cube")
        // Too big for the camera's page: refused before anything is sent.
        do {
            try await backend.importLUT(data: Data(count: VeniceCameraBackend.largestLUT + 1), name: "big", slot: 13)
            XCTFail("a file over the camera's limit was sent")
        } catch LUTImportError.tooLarge {}
    }

    func testTimecodeCountsAtTheProjectRateAndRunsBetweenReports() async throws {
        // 25p: frame 24 is the last of its second, not the next second's first.
        camera.bodyChange(["P.System.Menu.SystemFrequency": "4", "P.Clip.Mediabox.TimeCode.Value": "10:00:00:24"])
        try await until("25p timecode") { $0.timecode?.rate == 25 }
        XCTAssertEqual(latest.value.timecode?.string(at: Date()), "10:00:00:24")
        // Free run: ten reports a tenth of a second apart, made from the wall clock as a camera's are. The clock runs here
        // between them, and the ones it already shows change nothing.
        let start = Date()
        let clock = TimecodeClock(hours: 10, minutes: 0, seconds: 1, frames: 0, rate: 25, fps: 25, anchor: start, isRunning: true)
        let before = latest.timecodeChanges
        for _ in 0..<10 {
            camera.bodyChange(["P.Clip.Mediabox.TimeCode.Value": .string(clock.string(at: Date()))])
            try await Task.sleep(for: .milliseconds(100))
        }
        try await until("running") { $0.timecode?.isRunning == true }
        XCTAssertLessThan(latest.timecodeChanges - before, 5, "ten reports the running clock agrees with are not ten changes")
        // One it doesn't (a jam) re-anchors it.
        camera.bodyChange(["P.Clip.Mediabox.TimeCode.Value": "11:00:00:00"])
        try await until("jammed") { $0.timecode?.string(at: Date()).hasPrefix("11:00:00") == true }
    }

    func testReconnectsAfterTheCameraLetsGo() async throws {
        await backend.disconnect()
        try await until("disconnected") { $0.connection == .disconnected }
        await backend.connect()
        try await until("connected again") { $0.connection == .connected }
        await backend.send(.setDesqueeze("1.3x"))
        try await until("1.3x") { $0.desqueeze?.value == "1.3x" }
    }
}

final class VeniceNamesTests: XCTestCase {
    func testLUTFileNamesFollowTheCamerasRule() {
        XCTAssertEqual(VeniceCameraBackend.cubeFileName("Show LUT"), "Show LUT.cube")
        XCTAssertEqual(VeniceCameraBackend.cubeFileName("Show.cube"), "Show.cube")
        XCTAssertEqual(VeniceCameraBackend.cubeFileName("A/B:C \"D\""), "A_B_C _D_.cube")
        XCTAssertEqual(VeniceCameraBackend.cubeFileName(String(repeating: "x", count: 80))?.count, 63)
        XCTAssertNil(VeniceCameraBackend.cubeFileName("  "))
        XCTAssertNil(VeniceCameraBackend.cubeFileName("///"))
    }

    func testTimecodeRatesFromTheProjectRate() {
        XCTAssertEqual(VeniceCameraBackend.timecodeRates(project: "23.98", highestFrame: 0).rate, 24)
        XCTAssertEqual(VeniceCameraBackend.timecodeRates(project: "23.98", highestFrame: 0).fps, 23.976, accuracy: 0.001)
        XCTAssertEqual(VeniceCameraBackend.timecodeRates(project: "25", highestFrame: 0).rate, 25)
        XCTAssertEqual(VeniceCameraBackend.timecodeRates(project: "29.97", highestFrame: 0).rate, 30)
        XCTAssertEqual(VeniceCameraBackend.timecodeRates(project: "59.94", highestFrame: 20).rate, 30, "frame pairs")
        XCTAssertEqual(VeniceCameraBackend.timecodeRates(project: "59.94", highestFrame: 45).rate, 60)
        XCTAssertEqual(VeniceCameraBackend.timecodeRates(project: "50", highestFrame: 10).rate, 25)
        XCTAssertEqual(VeniceCameraBackend.timecodeRates(project: nil, highestFrame: 0).rate, 24)
    }

    func testBaseISOPairFromTheReading() {
        XCTAssertTrue(VeniceCameraBackend.baseISOPair(model: "VENICE", reading: "ISO 2500") == (500, 2500))
        XCTAssertTrue(VeniceCameraBackend.baseISOPair(model: "VENICE", reading: "ISO 800") == (800, 3200))
        XCTAssertTrue(VeniceCameraBackend.baseISOPair(model: "MPC-3610", reading: nil) == (500, 2500))
    }

    func testMenuTables() {
        XCTAssertEqual(VeniceMenu.value(VeniceMenu.desqueeze, label: "1.6x"), "6")
        XCTAssertEqual(VeniceMenu.label(VeniceMenu.desqueeze, value: "4"), "1.8x")
        XCTAssertEqual(VeniceMenu.labels(VeniceMenu.desqueeze, allowed: ["0", "6"]), ["Off", "2.0x"])
        XCTAssertEqual(VeniceMenu.followed("2"), "Monitor")
        XCTAssertNil(VeniceMenu.followed("4"))
        XCTAssertNil(VeniceMenu.followed("5"))
        XCTAssertEqual(VeniceCameraBackend.presetLabel("R709_800%"), "R709(800%)")
        XCTAssertEqual(VeniceCameraBackend.presetValue("R709(800%)"), "R709_800%")
        XCTAssertTrue(VeniceCameraBackend.isEmptySlot("s709"))
        XCTAssertFalse(VeniceCameraBackend.isEmptySlot("s709.cube"))
    }
}
