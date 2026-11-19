// FX6 (ILME-FX6V, firmware 6.00): what its own property lists map to, over Wi-Fi with Access Authentication.
// Each fixture is a full SDIO_GetAllExtDevicePropInfo dataset from that camera: as found (fx6-propinfo), with the
// shutter in speed mode and off, the ND on PRESET and white balance on Automatic (all three at once), and paused in
// playback. docs/fx6-controls.md has the rest of the session.

import Testing
import Foundation
@testable import SonyPTP
import CameraCore

@Suite("FX6 mapping")
struct FX6MappingTests {
    static func props(_ name: String) throws -> [SDIDevicePropInfo] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try parseSDIDevicePropInfoArray(Data(contentsOf: root.appendingPathComponent("fixtures/\(name).bin")))
    }

    /// The control codes the FX6 declared at connect (fixtures/fx6-dump-2026-10-29.txt).
    static let controls: [UInt16] = [0xD2C8, 0xD2DD, 0xD2E4, 0xD2E5, 0xD2EC, 0xD2ED, 0xD2EF, 0xD2FE, 0xF000, 0xF001,
                                     0xF005, 0xF010]

    /// The camera's short names for its assignable button functions (display list 0x0B), the ones these tests use.
    static let assignableNames: [UInt16: String] = [0x03: "Base ISO/Sens.", 0x21: "Focus Hold", 0x23: "VFx3/x6",
                                                    0x31: "S&Q Motion", 0x42: "Rec Review", 0x43: "Last Clip",
                                                    0x4D: "Display", 0x5C: "Volume", 0x65: "Home", 0x67: "Menu"]

    /// As the backend maps it: the model known (the FX6's own controls are read only for one), and its names.
    static func state(_ name: String, baseISONames: [UInt8: Int] = [:], model: String? = "ILME-FX6V",
                      rolling: Bool = false) throws -> CameraState {
        var state = CameraState()
        state.model = model
        if rolling { state.recording = RecordingControl(state: .recording) }
        StateMapper(props: try props(name), controls: controls)
            .map(into: &state, baseISONames: baseISONames, assignableNames: assignableNames)
        return state
    }

    static let asFound = "fx6-propinfo-2026-10-29"
    static let changed = "fx6-propinfo-speed-off-nd-preset-wb-auto-2026-10-29"
    static let paused = "fx6-propinfo-paused-2026-10-29"
    /// With an autofocus lens on (24 mm, f/2.8), as found otherwise.
    static let lens = "fx6-propinfo-lens-2026-10-29"
    static let custom = "fx6-propinfo-custom-2026-10-29"
    static let cineEI = "fx6-propinfo-cine-ei-2026-10-29"
    /// The lens fixture with ECS and proxy recording on, the iris on Auto and the SDI/HDMI LUT off.
    static let ecsProxy = "fx6-propinfo-ecs-proxy-iris-auto-lut1-off-2026-10-29"

    @Test("Codec, resolution and project frame rate are read-only; S&Q is settable, 1 to 120")
    func recordingFormat() throws {
        let state = try Self.state(Self.asFound)
        #expect(state.fileFormat?.value == "XAVC I" && state.fileFormat?.isWritable == false)
        #expect(state.resolution?.value == "3840x2160" && state.resolution?.isWritable == false)
        let fps = try #require(state.frameRate)
        #expect(fps.project.value == "23.98" && !fps.project.isWritable)
        #expect(fps.variable?.value == false && fps.variable?.isWritable == true)
        let rate = try #require(fps.variableRate)
        #expect(rate.value == 60 && rate.isWritable)
        #expect(rate.options.count == 62 && rate.options.contains(1) && rate.options.contains(120))
    }

    @Test("ISO 800 to 10000 on the low base; base ISO 800 or 12800 by the camera's names for Low and High")
    func iso() throws {
        let iso = try #require(try Self.state(Self.asFound).iso)
        #expect(iso.value == 800 && iso.options.first == 800 && iso.options.last == 10000 && iso.isWritable)
        let base = try #require(try Self.state(Self.asFound, baseISONames: [0x02: 800, 0x01: 12800]).baseISO)
        #expect(base.value == 800 && base.options == [800, 12800] && base.isWritable)
    }

    @Test("Shutter: angle settable, and the speed display-only while in angle mode")
    func shutterAngle() throws {
        let state = try Self.state(Self.asFound)
        #expect(state.shutterMode?.value == .angle && state.shutterMode?.isWritable == true)
        #expect(state.shutterAngle?.value == 180 && state.shutterAngle?.isWritable == true)
        #expect(state.shutterSpeed?.isWritable == false)
    }

    @Test("Speed mode with the shutter off: Off, and the speeds offered with it")
    func shutterSpeedOff() throws {
        let state = try Self.state(Self.changed)
        #expect(state.shutterMode?.value == .speed)
        let speed = try #require(state.shutterSpeed)
        #expect(speed.value == "Off" && speed.options.first == "Off" && speed.options.contains("1/50"))
        #expect(speed.isWritable)
    }

    @Test("ND: Clear and every 0.05 from 0.6 to 2.1 in VARIABLE, settable; read-only on PRESET")
    func nd() throws {
        let state = try Self.state(Self.asFound)
        let nd = try #require(state.nd)
        #expect(nd.preset.value == "0.6" && nd.preset.isWritable)
        #expect(nd.preset.options.count == 32 && nd.preset.options.prefix(3) == ["Clear", "0.6", "0.65"])
        #expect(nd.preset.options.last == "2.1")
        let mode = try #require(state.ndMode)
        #expect(mode.value == "Variable" && mode.options == ["Preset", "Variable"] && mode.isWritable)
        let preset = try Self.state(Self.changed)
        #expect(preset.ndMode?.value == "Preset")
        #expect(preset.nd?.preset.value == "0.6" && preset.nd?.preset.isWritable == false)
    }

    @Test("White balance: Kelvin presets and Auto in Manual, Auto in Automatic, and the Kelvin as the label in playback")
    func whiteBalance() throws {
        let manual = try #require(try Self.state(Self.asFound).whiteBalance)
        #expect(manual.preset.value == "4500K" && manual.preset.isWritable)
        #expect(manual.preset.options == ["2800K", "3200K", "4300K", "5000K", "5600K", "6500K", "Auto"], "Tiles' six, as on every camera")
        #expect(manual.tint?.value == 0 && manual.tint?.isWritable == false)
        let auto = try #require(try Self.state(Self.changed).whiteBalance)
        #expect(auto.preset.value == "Auto" && auto.preset.isWritable && auto.preset.options.contains("4300K"))
        #expect(!auto.kelvin.isWritable)
        let paused = try #require(try Self.state(Self.paused).whiteBalance)
        #expect(paused.preset.value == "4500K" && !paused.preset.isWritable)
    }

    @Test("Playback: Live | Review, live as found and paused in review")
    func playback() throws {
        let live = try #require(StateMapper(props: try Self.props(Self.asFound), controls: Self.controls).playback())
        #expect(live.capabilities.review && live.capabilities.playPause && live.capabilities.stop)
        #expect(live.inReview == false && live.isPlaying == false)
        let paused = try #require(StateMapper(props: try Self.props(Self.paused), controls: Self.controls).playback())
        #expect(paused.inReview == true && paused.isPlaying == false)
    }

    @Test("Gamut, desqueeze and battery as the camera has them; no tally, CALL, camera buttons, or iris with this lens")
    func others() throws {
        let state = try Self.state(Self.asFound)
        #expect(state.colorGamut?.value == "S-Gamut3.Cine" && state.colorGamut?.isWritable == true)
        #expect(state.desqueeze?.value == "1.5x" && state.desqueeze?.options == ["Off", "1.3x", "1.5x", "2.0x"])
        #expect(state.batteryVolts == 19.8 && state.batteryPercent == nil)
        #expect(state.tally == nil && state.call == nil && state.cameraButtons.isEmpty && state.iris == nil)
        for kind in [WidgetKind.ndMode, .colorGamut] { #expect(state.offers(kind), "\(kind)") }
        for kind in [WidgetKind.tally, .call, .cameraMenu] { #expect(!state.offers(kind), "\(kind)") }
    }

    // MARK: The FX6's own controls

    @Test("Shooting mode: Movie Shooting Mode 0xE000 reads 0x0501, Flexible ISO, and offers the camera's four")
    func shootingMode() throws {
        let mode = try #require(try Self.state(Self.asFound).shootingMode)
        #expect(mode.value == "Flexible ISO" && mode.isWritable)
        #expect(mode.options == ["Custom", "Flexible ISO", "Cine EI Quick", "Cine EI"])
        #expect(try Self.state(Self.custom).shootingMode?.value == "Custom")
        #expect(try Self.state(Self.cineEI).shootingMode?.value == "Cine EI")
    }

    @Test("Custom works in dB: no ISO, gain −3 to 30 dB in the ISO tile; Cine EI shows EI as the ISO")
    func gain() throws {
        let custom = try Self.state(Self.custom)
        #expect(custom.iso == nil && custom.baseISO == nil)
        let gain = try #require(custom.gain)
        #expect(gain.value == 11 && gain.isWritable && gain.options.first == -3 && gain.options.last == 30 && gain.options.count == 34)
        #expect(custom.offers(.iso))
        let cineEI = try Self.state(Self.cineEI)
        #expect(cineEI.iso?.value == 800 && cineEI.iso?.isWritable == true && cineEI.gain == nil)
        #expect(try Self.state(Self.asFound).gain == nil)
    }

    @Test("LUT outputs: SDI/HDMI and VF as monitoring outputs, the recording's apart; no switch reaches the recording")
    func lutOutputs() throws {
        let state = try Self.state(Self.lens)
        let outputs = try #require(state.monitoring?.outputs)
        #expect(outputs.map(\.id) == ["LUT1", "LUT2"] && outputs.map(\.name) == ["SDI/HDMI", "VF"])
        #expect(outputs.allSatisfy { $0.overlays[.lut]?.value == true && $0.overlays[.lut]?.isWritable == true })
        #expect(state.look?.value == true)
        let recorded = try #require(state.recordedLUT)
        #expect(recorded.value == false && recorded.isWritable)
        // One output off: the LUT tile's switch is off, so a tap turns it on where it's off.
        let off = try Self.state(Self.ecsProxy)
        #expect(off.monitoring?.outputs.first?.overlays[.lut]?.value == false && off.look?.value == false)
        // Custom has no monitor LUT.
        #expect(try Self.state(Self.custom).monitoring == nil)
    }

    @Test("The LUT in the recording can't change during a take")
    func recordedLUTRolling() throws {
        #expect(try Self.state(Self.lens, rolling: true).recordedLUT?.isWritable == false)
    }

    @Test("Proxy recording, ECS and auto iris, on and off")
    func proxyECSIris() throws {
        let off = try Self.state(Self.lens)
        #expect(off.proxyRecording?.value == false && off.proxyStatus == nil)
        #expect(off.ecs?.on.value == false && off.ecs?.frequency == nil && off.ecs?.canStep == false)
        #expect(off.irisAuto?.value == false && off.iris?.value == 2.8 && off.iris?.isWritable == true)
        let on = try Self.state(Self.ecsProxy)
        #expect(on.proxyRecording?.value == true && on.proxyStatus == "Standby")
        let ecs = try #require(on.ecs)
        #expect(ecs.on.value && ecs.frequency == 240 && ecs.canStep)
        #expect(on.shutterAngle?.isWritable == false)
        #expect(on.irisAuto?.value == true && on.iris?.isWritable == false)
    }

    @Test("Lens: 24 mm; the focus driven up to speed 8, far to the right; no zoom without a power zoom")
    func lens() throws {
        let state = try Self.state(Self.lens)
        #expect(state.focalLength == 24)
        let focus = try #require(state.focusDrive)
        #expect(focus.maxSpeed == 8 && focus.isWritable)
        // 0xE089 = 10217 of 65535, and it falls as the focus goes farther: 0.84 of the way to far.
        #expect(abs((focus.position ?? 0) - (1 - 10217.0 / 65535)) < 0.0001)
        #expect(focus.distance == nil)  // 0xFFFFFFFF until the lens has moved
        #expect(state.zoomDrive == nil)
        // As found, before the lens said where it was: a drive, but no position or distance (both disabled, 0).
        let asFound = try #require(try Self.state(Self.asFound).focusDrive)
        #expect(asFound.position == nil && asFound.distance == nil)
    }

    @Test("Assignable buttons: named by the camera, pressable only for a function checked on one, never Last Clip Del.")
    func assignableButtons() throws {
        let buttons = try Self.state(Self.lens).assignableButtons
        #expect(buttons.map(\.id) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        #expect(buttons.map(\.function) == ["S&Q Motion", "Base ISO/Sens.", "Volume", "Base ISO/Sens.", "Menu", "Display",
                                           "VFx3/x6", "Rec Review", "Home", "Focus Hold"])
        #expect(buttons.filter(\.isPressable).map(\.id) == [1, 2, 4, 8])
        #expect(!StateMapper.isPressable(function: 0x43, name: "Last Clip"))
        // Not even from a list that had it: a press deletes the last take.
        #expect(!StateMapper.isPressable(function: 0x43, name: "Last Clip", functions: [0x43: "Last Clip"]))
        // Another language, or no names: nothing pressable.
        #expect(!StateMapper.isPressable(function: 0x31, name: "Ralenti"))
        #expect(!StateMapper.isPressable(function: 0x31, name: nil))
    }

    @Test("Not an FX6: none of its own controls, though the codes are in the list")
    func onlyAnFX6() throws {
        let state = try Self.state(Self.lens, model: "MPC-2610")
        #expect(state.shootingMode == nil && state.recordedLUT == nil && state.proxyRecording == nil && state.ecs == nil)
        #expect(state.irisAuto == nil && state.focusDrive == nil && state.assignableButtons.isEmpty && state.monitoring == nil)
    }

    /// The white balance switch off PRESET (on A or B, a memory): tint and the Kelvin settable, and one-push AWB.
    @Test("WB on a memory: tint settable, −20 as the camera had it, and AWB offered")
    func whiteBalanceMemory() throws {
        let wb = try #require(try Self.state("fx6-propinfo-wb-memory-2026-10-29").whiteBalance)
        #expect(wb.kelvin.value == 3461 && wb.kelvin.isWritable)
        let tint = try #require(wb.tint)
        #expect(tint.value == -20 && tint.isWritable)
        #expect(wb.preset.options.contains("AWB") && wb.preset.options.contains("Auto"))
    }

    @Test("Auto ND and AGC: on, the density and the ISO read but don't set; the ISO shows what AGC picked")
    func autoNDAndGain() throws {
        let auto = try Self.state("fx6-propinfo-auto-nd-agc-2026-10-29")
        #expect(auto.ndAuto?.value == true && auto.ndAuto?.isWritable == true)
        #expect(auto.nd?.preset.value == "0.6" && auto.nd?.preset.isWritable == false)
        #expect(auto.isoAuto?.value == true && auto.isoAuto?.isWritable == true)
        #expect(auto.iso?.value == 5000 && auto.iso?.isWritable == false)
        let manual = try Self.state(Self.lens)
        #expect(manual.ndAuto?.value == false && manual.isoAuto?.value == false && manual.iso?.isWritable == true)
    }

    /// AGC in Custom, where the camera works in dB: Gain dB Value keeps the manual 12 dB, Gain dB Current Value has
    /// what AGC picked (15), and ISO Current Sensitivity, disabled, carries the same 15.
    @Test("AGC in Custom: the gain AGC picked, read-only, and no ISO")
    func autoGainInDB() throws {
        let state = try Self.state("fx6-propinfo-custom-agc-2026-10-29")
        #expect(state.shootingMode?.value == "Custom")
        #expect(state.isoAuto?.value == true && state.isoAuto?.isWritable == true)
        #expect(state.gain?.value == 15 && state.gain?.isWritable == false)
        #expect(state.iso == nil)
    }

    /// The demo FX6 is what someone without one tries Tiles on: it offers the tiles a real one does, and leaves
    /// read-only what a real one won't take over the network.
    @Test("The demo FX6 offers what a real one does, read-only where it is")
    func demoMirrorsCamera() throws {
        let real = try Self.state(Self.lens, baseISONames: [0x01: 12800, 0x02: 800])
        let demo = MockCameraBackend.sampleState(body: .fx6)
        #expect(WidgetKind.allCases.filter { real.offers($0) != demo.offers($0) } == [])
        func writable<V>(_ choice: Choice<V>?) -> Bool? { choice?.isWritable }
        #expect(writable(demo.frameRate?.project) == writable(real.frameRate?.project))
        #expect(writable(demo.frameRate?.variableRate) == writable(real.frameRate?.variableRate))
        #expect(writable(demo.fileFormat) == writable(real.fileFormat))
        #expect(writable(demo.resolution) == writable(real.resolution))
        #expect(demo.shutterMode?.value == real.shutterMode?.value)
        #expect(writable(demo.shutterAngle) == writable(real.shutterAngle))
        #expect(writable(demo.shutterSpeed) == writable(real.shutterSpeed))
    }

    /// Gain Base Sensitivity 0xD021 is the base where the camera works in dB: in Custom, settable, on Low as found;
    /// disabled in the ISO modes, where the base ISO switch is the base.
    @Test("Custom's base sensitivity: Low or High, and none in Flexible ISO")
    func baseSensitivityInDB() throws {
        let custom = try Self.state(Self.custom)
        #expect(custom.baseSensitivity?.value == "Low" && custom.baseSensitivity?.isWritable == true)
        #expect(custom.baseSensitivity?.options == ["Low", "High"])
        #expect(try Self.state(Self.asFound).baseSensitivity == nil)
    }
}
