// BURANO (MPC-2610, firmware 2.02): what its own property lists map to, over HaLow.
// Each fixture is a full SDIO_GetAllExtDevicePropInfo dataset from that camera: as found
// (burano-propinfo), in speed mode with its shutter off and on, and with the ND in VARIABLE.

import Testing
import Foundation
@testable import SonyPTP
import CameraCore

@Suite("BURANO mapping")
struct BURANOMappingTests {
    static func props(_ name: String) throws -> [SDIDevicePropInfo] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try parseSDIDevicePropInfoArray(Data(contentsOf: root.appendingPathComponent("fixtures/\(name).bin")))
    }

    /// The control codes the BURANO declared at connect (fixtures/burano-dump-2026-10-27.txt).
    static let controls: [UInt16] = [0xD2DD, 0xD2E4, 0xD2E5, 0xD2EC, 0xD2ED, 0xD2EF, 0xD309, 0xD30A, 0xF000, 0xF001, 0xF005, 0xF010]

    static func state(_ name: String, lutNames: [UInt16: String] = [:]) throws -> CameraState {
        var state = CameraState()
        StateMapper(props: try props(name), controls: controls).map(into: &state, lutNames: lutNames)
        return state
    }

    @Test("Codec reads X-OCN LT, and a list of one isn't offered as a choice")
    func codec() throws {
        let codec = try #require(try Self.state("burano-propinfo-2026-10-27").fileFormat)
        #expect(codec.value == "X-OCN LT")
        #expect(!codec.isWritable)
    }

    @Test("Project frame rate is fixed; S&Q offers its rates")
    func frameRate() throws {
        let fps = try #require(try Self.state("burano-propinfo-2026-10-27").frameRate)
        #expect(fps.project.value == "23.98")
        #expect(!fps.project.isWritable)
        #expect(fps.variable?.value == false)
        let rate = try #require(fps.variableRate)
        #expect(rate.value == 30)
        #expect(rate.options.first == 1 && rate.options.last == 60 && rate.options.count == 60)
        #expect(rate.isWritable)
    }

    @Test("Battery shows volts: the camera's display unit is voltage and 0xD218 is untaken")
    func batteryVolts() throws {
        let state = try Self.state("burano-propinfo-2026-10-27")
        #expect(state.batteryPercent == nil)
        #expect(state.batteryVolts == 14.2)
    }

    @Test("ND: Clear and the six STEP densities, on 0.6")
    func ndStep() throws {
        let nd = try #require(try Self.state("burano-propinfo-2026-10-27").nd)
        #expect(nd.preset.value == "0.6")
        #expect(nd.preset.options == ["Clear", "0.6", "0.9", "1.2", "1.5", "1.8", "2.1"])
        #expect(nd.preset.isWritable)
    }

    @Test("ND in VARIABLE: every 0.05 from 0.60 to 2.10")
    func ndVariable() throws {
        let nd = try #require(try Self.state("burano-propinfo-nd-variable-2026-10-27").nd)
        #expect(nd.preset.options.count == 32)          // Clear + 31 densities
        #expect(nd.preset.options.prefix(4) == ["Clear", "0.6", "0.65", "0.7"])
        #expect(nd.preset.options.last == "2.1")
    }

    @Test("Shutter speed is display-only in angle mode")
    func shutterAngleMode() throws {
        let state = try Self.state("burano-propinfo-2026-10-27")
        #expect(state.shutterMode?.value == .angle)
        #expect(state.shutterSpeed?.isWritable == false)
    }

    @Test("Speed mode with Shutter Setting off: the tile says Off, and offers Off with the speeds")
    func shutterSpeedModeOff() throws {
        let state = try Self.state("burano-propinfo-speed-off-2026-10-27")
        #expect(state.shutterMode?.value == .speed)
        let speed = try #require(state.shutterSpeed)
        #expect(speed.value == "Off")
        #expect(speed.options.first == "Off" && speed.options.contains("1/50"))
        #expect(speed.isWritable)
    }

    @Test("Speed mode with Shutter Setting on: the speed, settable")
    func shutterSpeedModeOn() throws {
        let speed = try #require(try Self.state("burano-propinfo-speed-on-2026-10-27").shutterSpeed)
        #expect(speed.value == "1/50")
        #expect(speed.isWritable)
    }

    @Test("Playback: playing and paused come from the playing speed, since 0xD02F stays 'Playing' through a pause")
    func playbackPlayingPaused() throws {
        let playing = try #require(StateMapper(props: try Self.props("burano-propinfo-playing-2026-10-27")).playback())
        #expect(playing.isPlaying == true)
        #expect(playing.capabilities.playPause && playing.capabilities.stop && playing.capabilities.recReview)
        let paused = try #require(StateMapper(props: try Self.props("burano-propinfo-paused-2026-10-27")).playback())
        #expect(paused.isPlaying == false)
        let live = try #require(StateMapper(props: try Self.props("burano-propinfo-2026-10-27")).playback())
        #expect(live.isPlaying == false)
    }

    /// The BURANO gets the Live | Review switch the FX3, VENICE, PYXIS and ALEXA have: in review while it's in
    /// Playback (0xD0BC 0x02), playing or paused, and not while it's live or rolling.
    @Test("Live | Review: in review while playing or paused, not live or recording")
    func liveReview() throws {
        for (name, reviewing) in [("burano-propinfo-2026-10-27", false), ("burano-propinfo-playing-2026-10-27", true),
                                  ("burano-propinfo-paused-2026-10-27", true), ("burano-propinfo-recording-2026-10-27", false)] {
            let pb = try #require(StateMapper(props: try Self.props(name)).playback())
            #expect(pb.capabilities.review, "\(name)")
            #expect(!pb.capabilities.live, "\(name): the switch is Live, so no Live button beside it")
            #expect(pb.inReview == reviewing, "\(name)")
        }
    }

    @Test("ND mode: STEP and VARIABLE, both settable")
    func ndMode() throws {
        let step = try #require(try Self.state("burano-propinfo-2026-10-27").ndMode)
        #expect(step.value == "Step")
        #expect(step.options == ["Variable", "Step"])
        #expect(step.isWritable)
        #expect(try Self.state("burano-propinfo-nd-variable-2026-10-27").ndMode?.value == "Variable")
    }

    @Test("Tally, CALL and color gamut read as the camera has them, all settable")
    func tallyCallGamut() throws {
        let state = try Self.state("burano-propinfo-2026-10-27")
        let tally = try #require(state.tally)
        #expect(tally.value == "Off" && tally.options == ["Off", "Green", "Red"] && tally.isWritable)
        let call = try #require(state.call)
        #expect(call.value == false && call.isWritable)
        let gamut = try #require(state.colorGamut)
        #expect(gamut.value == "S-Gamut3.Cine" && gamut.options == ["S-Gamut3.Cine", "S-Gamut3"] && gamut.isWritable)
        for kind in [WidgetKind.ndMode, .tally, .call, .colorGamut, .cameraMenu] { #expect(state.offers(kind), "\(kind)") }
    }

    @Test("White balance offers one-push AWB beside the Kelvin presets")
    func onePushAWB() throws {
        let wb = try #require(try Self.state("burano-propinfo-2026-10-27").whiteBalance)
        #expect(wb.preset.options.last == "AWB")
        #expect(wb.preset.options.contains("5600K"))
    }

    /// The FX3 lists Color Gamut (0xE001) settable too, so it gets that tile; no Home (its arrows are shooting shortcuts),
    /// no AWB button, tally, CALL or ND.
    @Test("The FX3 gets Color Gamut and none of the others")
    func fx3() throws {
        var fx3 = CameraState()
        StateMapper(props: try FX3PlaybackCapabilityTests.fx3Props(), controls: FX3PlaybackCapabilityTests.fx3Controls)
            .map(into: &fx3, lutNames: [:])
        #expect(fx3.offers(.colorGamut))
        for kind in [WidgetKind.ndMode, .tally, .call, .cameraMenu] { #expect(!fx3.offers(kind), "\(kind)") }
        #expect(fx3.whiteBalance?.preset.options.contains("AWB") == false)
        #expect(fx3.playback?.capabilities.review == true && fx3.playback?.capabilities.recReview == false)
    }

    @Test("Camera buttons: MENU (the Multi list), Home, Back, Display, Clips and the multi-selector")
    func cameraButtons() throws {
        #expect(try Self.state("burano-propinfo-2026-10-27").cameraButtons
                == [.menu, .home, .back, .display, .clips, .up, .down, .left, .right, .enter])
        // Without its control list nothing can be pressed.
        var bare = CameraState()
        StateMapper(props: try Self.props("burano-propinfo-2026-10-27")).map(into: &bare, lutNames: [:])
        #expect(bare.cameraButtons.isEmpty)
    }

    @Test("A take: Recorder Main Status 0x04 is recording")
    func recording() throws {
        let state = try Self.state("burano-propinfo-recording-2026-10-27")
        #expect(StateMapper(props: try Self.props("burano-propinfo-recording-2026-10-27")).recordingState().state == .recording)
        #expect(state.fileFormat?.isWritable == false)
    }

    @Test("LUT picker leaves out the slots the camera calls (No LUT), unless one is on")
    func lutEmptySlots() throws {
        // The display strings the camera gives camctl, by Base Look value
        var names: [UInt16: String] = [0x0001: "s709", 0x0002: "709(800%)", 0x0003: "S-Log3", 0x0004: "Warm",
                                       0x0005: "Cool", 0x0006: "Vintage", 0x0007: "Teal and Orange",
                                       0x010B: "Phntm_ARRI_Neutral_G11_Sl2sg3cine"]
        for slot in [0x0108, 0x0109, 0x010A] + Array(0x010C...0x0117) { names[UInt16(slot)] = "(No LUT)" }
        let lut = try #require(try Self.state("burano-propinfo-2026-10-27", lutNames: names).lut)
        #expect(lut.value == "s709")
        #expect(!lut.options.contains("(No LUT)"))
        #expect(lut.options == ["s709", "709(800%)", "S-Log3", "Warm", "Cool", "Vintage", "Teal and Orange",
                                "Phntm_ARRI_Neutral_G11_Sl2sg3cine"])
    }
}
