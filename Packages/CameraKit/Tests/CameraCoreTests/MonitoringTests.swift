import Testing
import Foundation
@testable import CameraCore

// Clean feed on an output hides every overlay there but the LUT (PYXIS), so its switches are grayed
// output by output, and the every-output switches leave that output out.

private func output(_ id: String, _ overlays: [MonitorOverlay: Bool]) -> MonitorOutput {
    MonitorOutput(id: id, name: id, overlays: overlays.mapValues { Choice($0, options: [false, true]) })
}

@Test("Clean feed grays that output's overlays, not its LUT or clean feed, and not another output's")
func cleanFeedGreysItsOutput() {
    let sdi = output("MainSDI", [.cleanFeed: true, .lut: true, .zebra: false, .falseColor: true, .frameGuides: false])
    let lcd = output("LCD", [.cleanFeed: false, .zebra: false])

    #expect(sdi.isCleanFeed && !lcd.isCleanFeed)
    for overlay in [MonitorOverlay.zebra, .falseColor, .frameGuides] {
        #expect(sdi.setting(overlay)?.isWritable == false, "\(overlay) hidden by clean feed")
    }
    #expect(sdi.setting(.falseColor)?.value == true)   // still as set, for when clean feed is off
    #expect(sdi.setting(.lut)?.isWritable == true)
    #expect(sdi.setting(.cleanFeed)?.isWritable == true)
    #expect(sdi.setting(.safeArea) == nil)   // not reported stays not reported
    #expect(lcd.setting(.zebra)?.isWritable == true)
}

@Test("A switch on every output counts only the outputs that can show it")
func everyOutputSkipsCleanFeed() {
    let monitoring = MonitoringState(outputs: [
        output("LCD", [.cleanFeed: false, .falseColor: true, .lut: true]),
        output("MainSDI", [.cleanFeed: true, .falseColor: false, .lut: false]),
    ])
    // False color shows everywhere it can, so the switch is lit and still works.
    #expect(monitoring.onEverywhere(.falseColor)?.value == true)
    #expect(monitoring.onEverywhere(.falseColor)?.isWritable == true)
    // The LUT still reaches a clean feed, so SDI's counts.
    #expect(monitoring.onEverywhere(.lut)?.value == false)
}

@Test("With every output on clean feed the switch is grayed, and its tile stays on the page")
func everyOutputAllCleanFeed() {
    var state = CameraState()
    state.monitoring = MonitoringState(outputs: [
        output("LCD", [.cleanFeed: true, .zebra: true]),
        output("MainSDI", [.cleanFeed: true, .zebra: false]),
    ])
    let zebra = state.monitoring?.onEverywhere(.zebra)
    #expect(zebra?.value == false)
    #expect(zebra?.isWritable == false)
    #expect(state.offers(.zebra))
    #expect(state.monitoring?.onEverywhere(.cleanFeed)?.isWritable == true)   // clean feed itself can be turned off
}

// A one-tap monitoring tile can be set to one output in edit mode, so in
// use a tap only turns it on and off. Clean Feed is one of them, and starts on SDI.

@Test("A tile set to one output switches that output alone; without one, every output, as the tiles always did")
func aTileSwitchesItsOwnOutput() {
    var state = CameraState()
    state.make = .blackmagic
    state.monitoring = MonitoringState(outputs: [
        output("LCD", [.cleanFeed: false, .lut: true, .falseColor: true, .frameGuides: true]),
        output("MainSDI", [.cleanFeed: false, .lut: true, .falseColor: false, .frameGuides: false]),
    ])
    state.look = state.monitoring?.onEverywhere(.lut)
    state.falseColor = state.monitoring?.onEverywhere(.falseColor)

    let sdi = state.monitorSwitch(.falseColor, output: "MainSDI")
    #expect(sdi.choice?.value == false && sdi.choice?.isWritable == true)
    #expect(sdi.command(true) == .setMonitorOverlay(.falseColor, true, output: "MainSDI"))
    let lcd = state.monitorSwitch(.frameGuides, output: "LCD")
    #expect(lcd.choice?.value == true)
    #expect(lcd.command(false) == .setMonitorOverlay(.frameGuides, false, output: "LCD"))

    let every = state.monitorSwitch(.falseColor, output: nil)
    #expect(every.choice == state.falseColor)
    #expect(every.command(true) == .setFalseColor(true))
    #expect(state.monitorSwitch(.lut, output: nil).command(true) == .setLook(true))
    #expect(state.monitorSwitch(.frameGuides, output: nil).choice?.value == false)
    #expect(state.monitorSwitch(.cleanFeed, output: nil).command(true) == .setMonitorOverlay(.cleanFeed, true, output: nil))
}

@Test("A tile on SDI grays while SDI's clean feed hides its overlay; SDI's LUT and Clean Feed tiles stay live")
func aTileOnACleanFeedOutputGreys() {
    var state = CameraState()
    state.make = .blackmagic
    state.monitoring = MonitoringState(outputs: [output("MainSDI", [.cleanFeed: true, .lut: true, .falseColor: false])])
    #expect(state.monitorSwitch(.falseColor, output: "MainSDI").choice?.isWritable == false)
    #expect(state.monitorSwitch(.lut, output: "MainSDI").choice?.isWritable == true)
    let clean = state.monitorSwitch(.cleanFeed, output: "MainSDI")
    #expect(clean.choice?.value == true && clean.choice?.isWritable == true)
    #expect(clean.command(false) == .setMonitorOverlay(.cleanFeed, false, output: "MainSDI"))
}

@Test("A tile set to one output never switches every output: grayed until the outputs are read, or without that output")
func anOutputTileNeverFallsBackToEveryOutput() {
    // Right after connect, a Blackmagic camera's look and false color are its first output's: the outputs come next.
    var state = CameraState()
    state.make = .blackmagic
    state.look = Choice(true, options: [false, true])
    state.falseColor = Choice(false, options: [false, true])
    #expect(state.monitorSwitch(.falseColor, output: "MainSDI").choice == nil)
    #expect(state.monitorSwitch(.lut, output: "MainSDI").choice == nil)
    #expect(state.monitorSwitch(.falseColor, output: "MainSDI").command(true) == .setMonitorOverlay(.falseColor, true, output: "MainSDI"))
    state.monitoring = MonitoringState(outputs: [output("LCD", [.falseColor: false])])
    #expect(state.monitorSwitch(.falseColor, output: "MainSDI").choice == nil)
}

@Test("On a camera without outputs (Sony), the LUT and False Color tiles are its own switches, whatever output they carry")
func aSonyCameraIgnoresATilesOutput() {
    var state = CameraState()
    state.make = .sony
    state.look = Choice(true, options: [false, true])
    state.falseColor = Choice(false, options: [false, true])
    #expect(state.monitorSwitch(.lut, output: "MainSDI").choice == state.look)
    #expect(state.monitorSwitch(.lut, output: "MainSDI").command(false) == .setLook(false))
    #expect(state.monitorSwitch(.falseColor, output: "MainSDI").command(true) == .setFalseColor(true))
    #expect(!state.setsOverlaysPerOutput)
}

@Test("Clean Feed is offered where an output reports it and starts on SDI; the other overlays start on every output")
func cleanFeedStartsOnSDI() {
    var state = CameraState()
    #expect(!state.offers(.cleanFeed))
    let monitoring = MonitoringState(outputs: [
        output("LCD", [.cleanFeed: false, .falseColor: false]),
        output("MainSDI", [.cleanFeed: true, .falseColor: false]),
    ])
    state.monitoring = monitoring
    #expect(state.offers(.cleanFeed))
    #expect(monitoring.defaultOutput(for: .cleanFeed) == TileOutput(id: "MainSDI", name: "MainSDI"))
    #expect(monitoring.defaultOutput(for: .falseColor) == nil)
    // No SDI out: clean feed starts on every output, as anything else would be a guess.
    #expect(MonitoringState(outputs: [output("LCD", [.cleanFeed: false])]).defaultOutput(for: .cleanFeed) == nil)
    #expect(WidgetKind.allCases.filter { $0.monitorOverlay != nil }
                == [.falseColor, .look, .viewAssist, .zebra, .focusAssist, .frameGuides, .cleanFeed, .statusText])
    #expect(WidgetKind.allCases.filter(\.takesOutput) == WidgetKind.allCases.filter { $0.monitorOverlay != nil } + [.statusTextContent])
}

@Test("A Blackmagic camera's learned LUTs are saved with its profile, and profiles from before still load")
func profileKeepsLearnedLUTs() throws {
    let profile = CameraProfile(model: "PYXIS 12K", offered: [.lut], make: .blackmagic, luts: ["A.cube", "B.cube"])
    let back = try JSONDecoder().decode(CameraProfile.self, from: JSONEncoder().encode(profile))
    #expect(back.luts == ["A.cube", "B.cube"] && back == profile)
    let old = try JSONDecoder().decode(CameraProfile.self, from: Data(#"{"model":"PYXIS 12K","offered":["lut"]}"#.utf8))
    #expect(old.luts == nil)
}
