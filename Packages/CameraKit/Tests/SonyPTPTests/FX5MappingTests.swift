// FX5 (ILME-FX5, firmware 1.00): what its own property lists map to, over Wi-Fi with Access Authentication.
// Each fixture is a full SDIO_GetAllExtDevicePropInfo dataset: as found (Custom, ISO 5000 on the High base
// sensitivity) and in Flexible ISO. It lists the FX6's own codes, and each control Tiles reads from them was set
// through the app's path and read back (docs/fx5-controls.md).

import Testing
import Foundation
@testable import SonyPTP
import CameraCore

@Suite("FX5 mapping")
struct FX5MappingTests {
    static func props(_ name: String) throws -> [SDIDevicePropInfo] {
        try FX6MappingTests.props(name)
    }

    /// The control codes the FX5 declared at connect (fixtures/fx5-dump-2026-11-14.txt).
    static let controls: [UInt16] = [0xD2C8, 0xD2CD, 0xD2CE, 0xD2CF, 0xD2D0, 0xD2DD, 0xD2E2, 0xD2E4, 0xD2E5, 0xD2E7,
                                     0xD2EC, 0xD2ED, 0xD2EF, 0xD2F7, 0xD2F9, 0xD2FF, 0xD301, 0xD304, 0xD307, 0xD309,
                                     0xD30A, 0xF001, 0xF005]

    /// The FX5's short names for its assignable button functions (display list 0x0B), the ones these tests use. It
    /// numbers them differently from the FX6: only Base ISO/Sens. (0x03) is the same on both.
    static let assignableNames: [UInt16: String] = [0x03: "Base ISO/Sens.", 0x0C: "Iris", 0x18: "White Balance",
                                                    0x26: "Focus Hold", 0x30: "LCDVF M", 0x39: "S&Q Motion",
                                                    0x47: "Rec", 0x4F: "Rec Review", 0x50: "Last Clip",
                                                    0x6B: "False Colo"]

    /// Its base ISOs by the camera's names (display list 0x08): ISO 12800, 800 and 4000.
    static let baseISONames: [UInt8: Int] = [0x01: 12800, 0x02: 800, 0x03: 4000]

    static func state(_ name: String, model: String? = "ILME-FX5") throws -> CameraState {
        var state = CameraState()
        state.model = model
        StateMapper(props: try props(name), controls: controls)
            .map(into: &state, baseISONames: baseISONames, assignableNames: assignableNames)
        return state
    }

    static let asFound = "fx5-propinfo-2026-11-14"
    static let flexibleISO = "fx5-propinfo-flexible-iso-2026-11-14"

    @Test("Its bit rate, which it doesn't report, from its project rate, codec and format: 100 Mbps as found, read only")
    func bitRate() throws {
        let state = try Self.state(Self.asFound)
        #expect(state.fileFormat?.value == "XAVC S-L 422" && state.resolution?.value == "3840x2160")
        #expect(state.recordingSetting == Choice("100 Mbps", options: ["100 Mbps"], isWritable: false))
        #expect(try Self.state(Self.asFound, model: "ILME-FX6V").recordingSetting == nil, "an FX6's isn't worked out")
        // Sony's table: one rate where Quality doesn't matter, the range where it does; nothing for X-OCN.
        #expect(FX5BitRate.label(fps: 23.976, codec: "XAVC S-L 420", format: "3840x2160") == "60–100 Mbps")
        #expect(FX5BitRate.label(fps: 50, codec: "XAVC S-I 422", format: "4096x2160") == "500 Mbps")
        #expect(FX5BitRate.label(fps: 119.88, codec: "XAVC HS-L 422", format: "3840x2160") == "280 Mbps")
        #expect(FX5BitRate.label(fps: 59.94, codec: "XAVC HS-L 420", format: "3840x2160") == "45–150 Mbps")
        #expect(FX5BitRate.label(fps: 23.976, codec: "X-OCN LT", format: "3840x2160") == nil)
        #expect(FX5BitRate.rateKey(29.97) == "29.97" && FX5BitRate.rateKey(24) == "24" && FX5BitRate.rateKey(100) == "100")
    }

    @Test("The FX5 gets the FX6's own controls; an FX3, FX30 or BURANO doesn't")
    func proBody() {
        for model in ["ILME-FX5", "ILME-FX6V", "ILME-FX6"] { #expect(SonyProBody.has(model), "\(model)") }
        for model in ["ILME-FX3", "ILME-FX3A", "ILME-FX30", "MPC-2610", "MPC-3628"] { #expect(!SonyProBody.has(model), "\(model)") }
        #expect(!SonyProBody.has(nil))
        #expect(CameraProfile(model: "ILME-FX5", offered: []).isSonyProBody)
    }

    @Test("Custom works in ISO on an FX5: ISO 5000 to 409600 on High, and Low | Mid | High as the base, no gain")
    func custom() throws {
        let state = try Self.state(Self.asFound)
        let mode = try #require(state.shootingMode)
        #expect(mode.value == "Custom" && mode.isWritable && mode.options == ["Custom", "Flexible ISO", "Cine EI Quick", "Cine EI"])
        let iso = try #require(state.iso)
        #expect(iso.value == 5000 && iso.isWritable && iso.options.first == 5000 && iso.options.last == 409600)
        #expect(state.gain == nil && state.baseISO == nil)
        let base = try #require(state.baseSensitivity)
        #expect(base.value == "High" && base.isWritable && base.options == ["Low", "Mid", "High"])
        #expect(state.isoAuto?.value == false && state.isoAuto?.isWritable == true)
        #expect(state.offers(.iso))
    }

    @Test("Flexible ISO: ISO 800 to 25600, three base ISOs by the camera's names, no base sensitivity")
    func flexibleISO() throws {
        let state = try Self.state(Self.flexibleISO)
        #expect(state.shootingMode?.value == "Flexible ISO")
        let iso = try #require(state.iso)
        #expect(iso.value == 800 && iso.isWritable && iso.options.first == 800 && iso.options.last == 25600)
        let base = try #require(state.baseISO)
        #expect(base.value == 800 && base.isWritable && base.options == [800, 4000, 12800])
        #expect(state.baseSensitivity == nil && state.gain == nil)
    }

    @Test("LUT outputs in Flexible ISO: HDMI, Proxy/Live View and LCD/VF, as its menu; none reaches the recording")
    func lutOutputs() throws {
        let state = try Self.state(Self.flexibleISO)
        let outputs = try #require(state.monitoring?.outputs)
        #expect(outputs.map(\.id) == ["LUT1", "LUT2", "LUT3"])
        #expect(outputs.map(\.name) == ["HDMI", "Proxy/Live View", "LCD/VF"])
        #expect(outputs.allSatisfy { $0.overlays[.lut]?.value == false && $0.overlays[.lut]?.isWritable == true })
        #expect(state.look?.value == false && state.recordedLUT == nil)
        // Custom has no monitor LUT, as on an FX6.
        let custom = try Self.state(Self.asFound)
        #expect(custom.monitoring == nil && custom.look == nil && custom.recordedLUT == nil)
    }

    @Test("No ND or ECS; tally, CALL and the camera's buttons, which an FX6 hasn't")
    func whatItHas() throws {
        let state = try Self.state(Self.asFound)
        #expect(state.nd == nil && state.ndMode == nil && state.ndAuto == nil && state.ecs == nil)
        #expect(state.tally?.value == "Off" && state.tally?.options == ["Off", "Green", "Red"])
        #expect(state.call?.value == false && state.call?.isWritable == true)
        #expect(state.cameraButtons == [.menu, .home, .back, .clips, .up, .down, .left, .right, .enter])
        for kind in [WidgetKind.tally, .call, .cameraMenu, .shootingMode, .proxy, .focusDrive, .assignable] {
            #expect(state.offers(kind), "\(kind)")
        }
        for kind in [WidgetKind.ndPreset, .ndMode, .ecs, .zoomDrive] { #expect(!state.offers(kind), "\(kind)") }
        #expect(state.batteryPercent == 10 && state.batteryVolts == nil)
    }

    @Test("Codec of five and resolution settable; 23.98 project rate read-only; S&Q on at 24, settable")
    func recordingFormat() throws {
        let state = try Self.state(Self.asFound)
        let codec = try #require(state.fileFormat)
        #expect(codec.value == "XAVC S-L 422" && codec.isWritable)
        #expect(codec.options == ["XAVC HS-L 422", "XAVC HS-L 420", "XAVC S-I 422", "XAVC S-L 422", "XAVC S-L 420"])
        #expect(state.resolution?.value == "3840x2160" && state.resolution?.options == ["3840x2160", "1920x1080"])
        let fps = try #require(state.frameRate)
        #expect(fps.project.value == "23.98" && !fps.project.isWritable)
        #expect(fps.variable?.value == true && fps.variable?.isWritable == true && fps.variableRate?.value == 24)
    }

    @Test("Shutter angle settable, its speed read-only; WB on 3200K with Tiles' six, Auto and AWB")
    func shutterAndWhiteBalance() throws {
        let state = try Self.state(Self.asFound)
        #expect(state.shutterMode?.value == .angle && state.shutterMode?.isWritable == true)
        #expect(state.shutterAngle?.value == 180 && state.shutterAngle?.isWritable == true)
        #expect(state.shutterSpeed?.isWritable == false)
        let wb = try #require(state.whiteBalance)
        #expect(wb.preset.value == "3200K" && wb.preset.isWritable)
        #expect(wb.preset.options == ["2800K", "3200K", "4300K", "5000K", "5600K", "6500K", "Auto", "AWB"])
        #expect(wb.kelvin.value == 3200 && wb.kelvin.isWritable && wb.tint?.value == 0 && wb.tint?.isWritable == true)
    }

    @Test("Proxy off and settable; iris f/2.8 settable, auto iris read-only; the lens's focus driven, no zoom")
    func proxyIrisLens() throws {
        let state = try Self.state(Self.asFound)
        #expect(state.proxyRecording?.value == false && state.proxyRecording?.isWritable == true && state.proxyStatus == nil)
        #expect(state.iris?.value == 2.8 && state.iris?.isWritable == true && state.iris?.options.count == 19)
        #expect(state.irisAuto?.value == false && state.irisAuto?.isWritable == false)
        #expect(state.focalLength == 24)
        let focus = try #require(state.focusDrive)
        #expect(focus.maxSpeed == 8 && focus.isWritable && focus.position != nil)
        #expect(state.zoomDrive == nil)
    }

    @Test("Assignable buttons by the FX5's own numbering: Base ISO/Sens. and False Color pressable, never Last Clip (0x50)")
    func assignableButtons() throws {
        let state = try Self.state(Self.asFound)
        let buttons = state.assignableButtons
        #expect(buttons.map(\.id) == [1, 2, 3, 4, 5, 6, 10])
        #expect(buttons.map(\.function) == ["Iris", "White Balance", "Base ISO/Sens.", "False Colo", "LCDVF M", "Rec",
                                           "Focus Hold"])
        #expect(buttons.filter(\.isPressable).map(\.id) == [3, 4])
        // False Color is only a button function: button 4's light is the False Color tile, off as found.
        #expect(state.falseColor == Choice(false, options: [false, true]) && state.offers(.falseColor))
        #expect(state.falseColorHint == nil)
        // The FX6's checked functions are numbered differently here: not pressable under the FX5's numbers.
        #expect(!StateMapper.isPressable(function: 0x39, name: "S&Q Motion"))
        #expect(!StateMapper.isPressable(function: 0x4F, name: "Rec Review"))
        // Last Clip deletes the last take: refused by name whatever the list says.
        #expect(!StateMapper.isPressable(function: 0x50, name: "Last Clip", functions: [0x50: "Last Clip"]))
    }

    @Test("Playback on the live picture: Live | Review, and no clip caption from the disabled clip name and count")
    func playback() throws {
        let pb = try #require(StateMapper(props: try Self.props(Self.asFound), controls: Self.controls).playback())
        #expect(pb.capabilities.review && pb.capabilities.stop && pb.capabilities.nextPrevious)
        #expect(pb.inReview == false && pb.isPlaying == false)
        #expect(pb.clipName == nil && pb.clipNumber == nil && pb.clipCount == nil)
    }

    @Test("SteadyShot Standard of four, Imager Mode FF 5K 16:9 of the camera's five, and Push AF for the Autofocus tile")
    func steadyShotImagerAF() throws {
        let state = try Self.state(Self.asFound)
        let ss = try #require(state.steadyShot)
        #expect(ss.value == "Standard" && ss.isWritable && ss.options == ["Off", "Standard", "Active", "Dynamic Active"])
        let imager = try #require(state.imagerMode)
        #expect(imager.value == "FF 5K 16:9" && imager.isWritable)
        #expect(imager.options == ["FF 5K 17:9", "FF 5K 16:9", "FFc 4.5K 17:9", "FFc 4.5K 16:9", "S35 3.2K 16:9"])
        #expect(state.canAutoFocus && state.offers(.autoFocus) && state.offers(.steadyShot) && state.offers(.imagerMode))
        // An FX6 has none of the three.
        let fx6 = try FX6MappingTests.state(FX6MappingTests.lens)
        #expect(fx6.steadyShot == nil && fx6.imagerMode == nil && !fx6.canAutoFocus)
    }

    @Test("AF / MF from Focus Mode Setting: an FX5's settable (AF, autofocusing), an FX6's and a BURANO's display-only")
    func focusMode() throws {
        let fx5 = try Self.state(Self.asFound)
        let mode = try #require(fx5.focusMode)
        #expect(mode.value == "AF" && mode.options == ["AF", "MF"] && mode.isWritable)
        #expect(fx5.focusIsAuto, "Focus Mode status 0xE044: AF Operation")
        #expect(fx5.offers(.focusMode) && fx5.offers(.autoFocus))
        // As found, an FX6's lens and a BURANO's had it on MF, display-only: both shown, neither settable.
        let fx6 = try #require(try FX6MappingTests.state(FX6MappingTests.lens).focusMode)
        #expect(fx6.value == "MF" && fx6.options == ["AF", "MF"] && !fx6.isWritable)
        let burano = try #require(try BURANOMappingTests.state("burano-propinfo-2026-10-27").focusMode)
        #expect(burano.value == "MF" && burano.options == ["AF", "MF"] && !burano.isWritable)
        #expect(try !FX6MappingTests.state(FX6MappingTests.lens).focusIsAuto)
    }

    @Test("AF settings: Human Priority AF of six, Wide of three, transition 5 of 1–7, shift 5 of 1–5, AF Assist on")
    func afSettings() throws {
        let fx5 = try Self.state(Self.asFound)
        let subject = try #require(fx5.subjectRecognition)
        #expect(subject.value == "Human Priority AF" && subject.isWritable)
        #expect(subject.options == ["Human Only AF", "Human Priority AF", "Animal/Bird Prio. AF", "Animal Priority AF",
                                    "Bird Priority AF", "Off"])
        let area = try #require(fx5.focusArea)
        #expect(area.value == "Wide" && area.options == ["Wide", "Zone", "Flexible Spot"] && area.isWritable)
        #expect(fx5.afTransitionSpeed?.value == 5 && fx5.afTransitionSpeed?.options == Array(1...7))
        #expect(fx5.afSubjectShift?.value == 5 && fx5.afSubjectShift?.options == Array(1...5))
        #expect(fx5.afAssist?.value == true && fx5.offers(.afSettings))
        // An FX6 calls its subjects Face/Eye, its area display-only with the lens; a BURANO's are all display-only.
        let fx6 = try FX6MappingTests.state(FX6MappingTests.lens)
        #expect(fx6.subjectRecognition?.options == ["Face/Eye Only AF", "Face/Eye Priority AF", "Off"])
        #expect(fx6.subjectRecognition?.value == "Face/Eye Priority AF" && fx6.focusArea?.isWritable == false)
        let burano = try BURANOMappingTests.state("burano-propinfo-2026-10-27")
        #expect([burano.subjectRecognition?.isWritable, burano.focusArea?.isWritable, burano.afTransitionSpeed?.isWritable,
                 burano.afSubjectShift?.isWritable, burano.afAssist?.isWritable] == [false, false, false, false, false])
    }

    @Test("Imager Mode labels from the camera's packed value, and none for a size or aspect it doesn't name")
    func imagerLabels() {
        #expect(StateMapper.imagerModeLabel(0x0401_F401) == "FF 5K 16:9")
        #expect(StateMapper.imagerModeLabel(0x0501_C202) == "FFc 4.5K 17:9")
        #expect(StateMapper.imagerModeLabel(0x0401_4003) == "S35 3.2K 16:9")
        #expect(StateMapper.imagerModeLabel(0x0101_F401) == "FF 5K 3:2")
        #expect(StateMapper.imagerModeLabel(0x0401_7C02) == "FFc 3.8K 16:9")
        #expect(StateMapper.imagerModeLabel(0x0901_F401) == nil && StateMapper.imagerModeLabel(0x0401_F409) == nil)
    }

    @Test("Not a pro body: none of the FX6's own controls, though the FX5 lists the codes")
    func onlyAProBody() throws {
        let state = try Self.state(Self.flexibleISO, model: "MPC-2610")
        #expect(state.shootingMode == nil && state.proxyRecording == nil && state.monitoring == nil)
        #expect(state.focusDrive == nil && state.assignableButtons.isEmpty && state.baseSensitivity == nil)
    }
}
