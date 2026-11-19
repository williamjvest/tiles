@testable import CameraCore
import XCTest
@testable import SonySavona

/// The VENICE demo (Test Mode's stand-in) behaves like the other bodies: WB and FPS change, base ISO switches 800/3200
/// and moves the EI list.
final class VeniceDemoTests: XCTestCase {
    final class Latest: @unchecked Sendable {
        var value: CameraState?
    }

    func testDemoChangesWhatTheTilesChange() async throws {
        let backend = MockCameraBackend(state: MockCameraBackend.veniceSampleState(), label: "A",
                                        latency: .milliseconds(1), heartbeat: nil)
        let latest = Latest()
        let listening = Task { for await s in backend.updates { latest.value = s } }
        await backend.connect()
        await backend.send(CameraCommand.setKelvin(3200))
        await backend.send(CameraCommand.setTint(14))
        await backend.send(CameraCommand.setWhiteBalancePreset("5600K"))
        await backend.send(CameraCommand.setFrameRate("25"))
        await backend.send(CameraCommand.setBaseISO(3200))
        try await Task.sleep(for: .milliseconds(400))
        let final = latest.value ?? CameraState()
        listening.cancel()
        XCTAssertEqual(final.whiteBalance?.kelvin.shown, 5600)
        XCTAssertEqual(final.whiteBalance?.tint?.shown ?? 0, 0, "a preset sets tint back to 0")
        XCTAssertEqual(final.frameRate?.project.shown, "25")
        XCTAssertEqual(final.baseISO?.shown, 3200)
        XCTAssertEqual(final.iso?.shown, 3200, "switching base moves the EI to the new base")
    }

    func testBackendPresetIsWritable() {
        let sample = MockCameraBackend.veniceSampleState()
        XCTAssertTrue(sample.whiteBalance?.preset.isWritable ?? false)
        XCTAssertTrue(sample.frameRate?.project.isWritable ?? false)
        XCTAssertEqual(sample.baseISO?.options, [800, 3200])
    }
}

/// The VENICE page: every tile in its template is backed by the demo, so Test Mode shows the whole block.
final class VeniceLayoutTests: XCTestCase {
    func testDemoOffersEveryTemplateTile() {
        let sample = MockCameraBackend.veniceSampleState()
        let kinds: [WidgetKind] = LayoutTemplates.veniceCells.map { $0.0 }
        let missing = kinds.filter { !sample.offers($0) && $0 != .haLow }
        XCTAssertTrue(missing.isEmpty, "VENICE demo lacks controls the VENICE page shows: \(missing)")
    }

    func testVeniceGetsItsOwnBlock() {
        let sample = MockCameraBackend.veniceSampleState()
        let profile = CameraProfile(model: sample.model, offered: Set(WidgetKind.allCases.filter { sample.offers($0) }),
                                    make: .sony)
        XCTAssertTrue(profile.isVenice)
        let kinds = Set(LayoutTemplates.block(camera: UUID(), profile: profile, wide: true).map(\.kind))
        for kind in [WidgetKind.desqueeze, .frameGuides, .sensorFlip, .playback, .colorBars] {
            XCTAssertTrue(kinds.contains(kind), "\(kind) missing from the VENICE page")
        }
        // No Web GUI tile anywhere (its page and Tiles connected at once trip the camera up), and playback takes the
        // bottom row.
        XCTAssertFalse(kinds.contains(.webGUI))
        XCTAssertFalse(sample.offers(.webGUI))
        XCTAssertEqual(LayoutTemplates.veniceCells.first { $0.0 == .playback }?.3, 4)
    }

    /// The real VENICE 2's page: no lens reporting an iris, no HaLow tile off a mesh. The iris row goes, latency takes
    /// both identity rows, ND − and ND + sit beside ND, de-squeeze keeps its place in the format row, and every row is full.
    func testTheRealCamerasPageClosesUp() {
        var s = MockCameraBackend.veniceSampleState()
        s.iris = nil
        // The store offers the HaLow tile only on a mesh (`templateProfile`).
        let offered = Set(WidgetKind.allCases.filter { s.offers($0) }).subtracting([.haLow])
        let profile = CameraProfile(model: s.model, offered: offered, make: .sony)
        let block = LayoutTemplates.block(camera: UUID(), profile: profile, wide: true)
        XCTAssertFalse(block.contains { $0.kind == .iris || $0.kind == .haLow })
        XCTAssertEqual(block.first { $0.kind == .latency }?.h, 2)
        let nd = block.filter { [.ndPreset, .ndMinus, .ndPlus].contains($0.kind) }.sorted { $0.x < $1.x }
        XCTAssertEqual(nd.map(\.kind), [.ndPreset, .ndMinus, .ndPlus])
        XCTAssertEqual(Set(nd.map(\.y)).count, 1, "ND − and ND + beside ND")
        let desqueeze = block.first { $0.kind == .desqueeze }
        XCTAssertEqual(desqueeze?.w, 1)
        XCTAssertEqual(desqueeze?.y, block.first { $0.kind == .resolution }?.y)
        let bottom = block.map(\.maxY).max() ?? 0
        for row in 0..<bottom {
            let width = block.filter { $0.y <= row && row < $0.maxY }.map(\.w).reduce(0, +)
            XCTAssertEqual(width, 4, "half-row \(row) isn't full")
        }
    }
}

final class VeniceDesqueezeTests: XCTestCase {
    func testRatiosFollowSonysTable() {
        XCTAssertEqual(VeniceDesqueeze.options(forImager: "8.6K 3:2"), ["Off", "1.25x", "1.3x", "1.5x", "1.6x", "1.8x", "2.0x"])
        XCTAssertEqual(VeniceDesqueeze.options(forImager: "5.8K 17:9"), ["Off", "1.25x", "1.3x", "1.6x", "1.8x", "2.0x"])
        XCTAssertEqual(VeniceDesqueeze.options(forImager: "5.8K 6:5"), ["Off", "2.0x"])
        XCTAssertEqual(VeniceDesqueeze.options(forImager: "8.2K 2.39:1"), ["Off"])
        XCTAssertEqual(VeniceDesqueeze.options(forImager: "4K 4:3 Surround"), ["Off", "1.3x", "1.6x", "1.8x", "2.0x"])
        XCTAssertEqual(MockCameraBackend.veniceSampleState().desqueeze?.options.count, 7)
    }
}

final class VeniceManualTablesTests: XCTestCase {
    /// Sony's VENICE 2 manual (FW 2.0, p. 50–51): EI by base ISO, default shutter and WB steps, Select FPS by imager.
    func testTablesMatchTheManual() {
        XCTAssertEqual(VeniceTables.eiOptions(base: 800).first, 200)
        XCTAssertEqual(VeniceTables.eiOptions(base: 800).last, 3200)
        XCTAssertEqual(VeniceTables.eiOptions(base: 3200).first, 800)
        XCTAssertEqual(VeniceTables.eiOptions(base: 3200).last, 12800)
        XCTAssertEqual(VeniceTables.eiOptions(base: 2500).last, 10000)
        XCTAssertEqual(VeniceTables.shutterAngles, [5.6, 11.2, 22.5, 45, 90, 144, 172.8, 180, 360])
        XCTAssertEqual(VeniceTables.whiteBalanceSteps, ["3200K", "4300K", "5500K"])
        XCTAssertEqual(VeniceTables.selectFPS(imager: "8.6K 3:2").last, 30)
        XCTAssertEqual(VeniceTables.selectFPS(imager: "5.5K 2.39:1").last, 120)
        XCTAssertEqual(VeniceTables.projectFrameRates(imager: "8.6K 3:2"), ["23.98", "24", "25", "29.97"])
    }

    func testDemoLUTPerOutputAndEverywhere() {
        let s = MockCameraBackend.veniceSampleState()
        XCTAssertEqual(s.monitoring?.outputs.map(\.name), ["SDI 1/2", "SDI 3/4", "Monitor", "VF", "HDMI"])
        // Frame lines, the info overlay and a LUT on every output, HDMI included (the real VENICE 2's "hdmi" entry).
        for output in s.monitoring?.outputs ?? [] {
            XCTAssertNotNil(output.overlays[.frameGuides], output.name)
            XCTAssertNotNil(output.overlays[.statusText], output.name)
            XCTAssertNotNil(output.overlays[.lut], output.name)
        }
        // HDMI shows the same as the Monitor, as on the camera: its overlays are set there; its LUT is its own.
        let hdmi = s.monitoring?.outputs.last
        XCTAssertEqual(hdmi?.follows, "Monitor")
        XCTAssertEqual(hdmi?.overlays[.frameGuides]?.isWritable, false)
        XCTAssertEqual(hdmi?.overlays[.lut]?.isWritable, true)
        XCTAssertEqual(s.look?.value, true)
        XCTAssertTrue(s.offers(.viewAssist))
        XCTAssertEqual(s.frameRate?.variableName, "Select FPS")
        // The looks: presets, then the user 3D LUTs; a false color LUT among them isn't the LUT tile's switch here.
        XCTAssertEqual(s.lut?.options.first, "s709")
        XCTAssertFalse(s.offersFalseColorLUTSwap)
        XCTAssertEqual(s.modelName, "VENICE 2")
    }
}


/// Every list Tiles preloads for a VENICE 2, against Sony's VENICE 2 manual (MPC-3628 / MPC-3626, FW 2.0) and the
/// V3.00 release notes. Page numbers are the manual's.
final class VeniceManualCheckTests: XCTestCase {
    func testShutterSpeedsStartAtTheProjectRate() {
        // p. 72: Shooting > Shutter's defaults; footnote 1 and the default-speed table.
        XCTAssertEqual(VeniceTables.shutterSpeeds(projectRate: "24").first, "1/24")
        XCTAssertEqual(VeniceTables.shutterSpeeds(projectRate: "23.98").first, "1/24")
        XCTAssertEqual(VeniceTables.shutterSpeeds(projectRate: "25").first, "1/25")
        XCTAssertEqual(VeniceTables.shutterSpeeds(projectRate: "29.97").first, "1/30")
        XCTAssertEqual(VeniceTables.shutterSpeeds(projectRate: "47.95").first, "1/48")
        XCTAssertEqual(VeniceTables.shutterSpeeds(projectRate: "50").first, "1/50")
        XCTAssertEqual(VeniceTables.shutterSpeeds(projectRate: "59.94").first, "1/60")
        XCTAssertEqual(VeniceTables.shutterSpeeds(projectRate: "59.94").last, "1/2000")
    }

    func testProjectRatesByImagerMode() {
        // p. 5–6.
        XCTAssertEqual(VeniceTables.projectFrameRates(imager: "8.6K 17:9"), ["23.98", "24", "25", "29.97", "47.95"])
        XCTAssertEqual(VeniceTables.projectFrameRates(imager: "7.6K 16:9"), ["23.98", "24", "25", "29.97", "50", "59.94"])
        XCTAssertEqual(VeniceTables.projectFrameRates(imager: "8.2K 2.39:1").count, 7)
        XCTAssertEqual(VeniceTables.projectFrameRates(imager: "5.7K 16:9", model: "MPC-3626"),
                       ["23.98", "24", "25", "29.97", "50", "59.94"])
        XCTAssertEqual(VeniceTables.projectFrameRates(imager: "4K 4:3 Surround View", model: "MPC-3626"),
                       ["23.98", "24", "25", "29.97"])
        XCTAssertEqual(VeniceTables.projectFrameRates(imager: "6K 3:2", model: "MPC-3626").count, 7)
        XCTAssertEqual(VeniceTables.projectFrameRates(imager: "something new"), ["23.98", "24", "25", "29.97"])
    }

    func testSelectFPSByModeFormatAndBase() {
        // p. 49 (X-OCN), p. 50 (ProRes, and nothing under 8 at the high base).
        XCTAssertEqual(VeniceTables.selectFPS(imager: "8.2K 17:9").last, 60)
        XCTAssertEqual(VeniceTables.selectFPS(imager: "8.2K 2.39:1").suffix(2), [66, 72])
        XCTAssertEqual(VeniceTables.selectFPS(imager: "5.8K 17:9").last, 90)
        XCTAssertEqual(VeniceTables.selectFPS(imager: "5.5K 2.39:1", codec: "ProRes 4444 4K").last, 60)
        XCTAssertEqual(VeniceTables.selectFPS(imager: "5.5K 2.39:1", codec: "ProRes 422 HQ 4K").last, 75)
        XCTAssertEqual(VeniceTables.selectFPS(imager: "8.6K 3:2", highBase: true).first, 8)
        XCTAssertEqual(VeniceTables.selectFPS(imager: "6K 3:2", model: "MPC-3626", highBase: true).first, 1,
                       "the 6K's high base only limits ProRes")
        XCTAssertEqual(VeniceTables.selectFPS(imager: "6K 3:2", model: "MPC-3626", codec: "ProRes 4444 4K",
                                              highBase: true).first, 8)
        XCTAssertEqual(VeniceTables.selectFPS(imager: "4K 17:9", model: "MPC-3626").last, 110)
        XCTAssertEqual(VeniceTables.selectFPS(imager: "4K 4:3 Surround View", model: "MPC-3626").last, 30)
        XCTAssertEqual(VeniceTables.selectFPS(imager: "4K 2.39:1", model: "MPC-3626").last, 120)
        // V3.00: 33.33 at project 24, 25 and 50, where the mode goes past it.
        XCTAssertTrue(VeniceTables.selectFPS(imager: "8.2K 17:9", projectRate: "24").contains(33.33))
        XCTAssertFalse(VeniceTables.selectFPS(imager: "8.2K 17:9", projectRate: "23.98").contains(33.33))
        XCTAssertFalse(VeniceTables.selectFPS(imager: "8.6K 3:2", projectRate: "24").contains(33.33), "tops out at 30")
    }

    func testRecordingFormatsByModeAndRate() {
        // p. 64–70.
        XCTAssertEqual(VeniceTables.recordingFormats(imager: "8.6K 3:2", projectRate: "24").count, 9)
        XCTAssertEqual(VeniceTables.recordingFormats(imager: "8.6K 17:9", projectRate: "47.95"), ["X-OCN ST", "X-OCN LT"])
        XCTAssertEqual(VeniceTables.recordingFormats(imager: "8.2K 2.39:1", projectRate: "59.94"),
                       ["X-OCN ST", "X-OCN LT", "ProRes 4444 XQ 4K", "ProRes 4444 4K", "ProRes 422 HQ 4K"])
        XCTAssertEqual(VeniceTables.recordingFormats(imager: "7.6K 16:9", projectRate: "24"),
                       ["X-OCN XT", "X-OCN ST", "X-OCN LT", "ProRes 4444 XQ QFHD", "ProRes 4444 QFHD", "ProRes 422 HQ QFHD"])
        XCTAssertEqual(VeniceTables.recordingFormats(imager: "6K 1.85:1", model: "MPC-3626", projectRate: "24"),
                       ["X-OCN XT", "X-OCN ST", "X-OCN LT"])
    }

    func testDesqueezeByFormat() {
        // p. 59–60: ProRes has its own table.
        XCTAssertEqual(VeniceDesqueeze.options(forImager: "8.6K 3:2", codec: "ProRes 4444 4K"),
                       ["1.25x", "1.3x", "1.5x", "1.6x", "1.8x", "2.0x"])
        XCTAssertEqual(VeniceDesqueeze.options(forImager: "5.8K 6:5", codec: "ProRes 422 HQ 4K"), ["2.0x"])
        XCTAssertEqual(VeniceDesqueeze.options(forImager: "8.6K 17:9", codec: "ProRes 4444 4K"), ["Off"])
        XCTAssertEqual(VeniceDesqueeze.options(forImager: "4K 4:3 Surround View", model: "MPC-3626"),
                       ["Off", "1.3x", "1.6x", "1.8x", "2.0x"])
        XCTAssertEqual(VeniceDesqueeze.options(forImager: "4K 17:9 Surround View", model: "MPC-3626"),
                       ["Off", "1.25x", "1.3x", "1.6x", "1.8x", "2.0x"])
    }

    func testImagerModesBySensor() {
        XCTAssertEqual(VeniceTables.imagerModes(model: "MPC-3628").count, 11)
        XCTAssertEqual(VeniceTables.imagerModes(model: "MPC-3626").count, 13)
        XCTAssertEqual(VeniceTables.imagerModes(model: "MPC-3610"), [], "VENICE 1 isn't in this manual")
    }

    func testLogAndLogLegalAreNoLUT() {
        // p. 51 (Log), V3.00 (Log(Legal)).
        XCTAssertEqual(VeniceCameraBackend.lutIsOn(.string("Log")), false)
        XCTAssertEqual(VeniceCameraBackend.lutIsOn(.string("Log(Legal)")), false)
        XCTAssertEqual(VeniceCameraBackend.lutIsOn(.string("R709(800%)")), true)
        XCTAssertEqual(VeniceCameraBackend.lutIsOn(.string("Look")), true)
    }
}


/// Test Mode's VENICE: its lists follow the imager mode, format and base ISO, as the camera's do.
final class VeniceDemoListsTests: XCTestCase {
    final class Latest: @unchecked Sendable { var value: CameraState? }

    func testListsFollowTheImagerModeAndBase() async throws {
        let backend = MockCameraBackend(state: MockCameraBackend.veniceSampleState(), label: "A",
                                        latency: .milliseconds(1), heartbeat: nil)
        let latest = Latest()
        let listening = Task { for await s in backend.updates { latest.value = s } }
        await backend.connect()
        await backend.send(.setResolution("8.2K 2.39:1"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(latest.value?.frameRate?.variableRate?.options.last, 72)
        XCTAssertEqual(latest.value?.desqueeze?.options, ["Off"])
        XCTAssertEqual(latest.value?.frameRate?.project.options.count, 7)
        await backend.send(.setBaseISO(3200))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(latest.value?.frameRate?.variableRate?.options.first, 8, "nothing under 8 at base 3200")
        listening.cancel()
    }
}
