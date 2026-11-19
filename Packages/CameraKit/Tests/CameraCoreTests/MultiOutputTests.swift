import Foundation
import Testing
@testable import CameraCore

// A monitoring tile on several outputs (e.g. the LUT on SDI 1/2 and SDI 3/4, not the monitor).

private func veniceLike(lut: [String: Bool]) -> CameraState {
    var s = CameraState()
    s.connection = .connected
    s.make = .sony
    s.monitoring = MonitoringState(outputs: lut.keys.sorted().map { id in
        MonitorOutput(id: id, name: id, overlays: [.lut: Choice(lut[id]!, options: [false, true])])
    })
    return s
}

@Test func severalOutputsLightOnlyWhenAllAreOn() {
    let s = veniceLike(lut: ["Sdi12": true, "Sdi34": false, "Monitor": true])
    let both = s.monitorSwitch(.lut, outputs: ["Sdi12", "Sdi34"])
    #expect(both.choice?.value == false)
    #expect(both.commands(true) == [.setMonitorOverlay(.lut, true, output: "Sdi12"), .setMonitorOverlay(.lut, true, output: "Sdi34")])
    let lit = s.monitorSwitch(.lut, outputs: ["Sdi12", "Monitor"])
    #expect(lit.choice?.value == true)
}

@Test func severalOutputsSkipOnesTheCameraDoesntHave() {
    let s = veniceLike(lut: ["Sdi12": true])
    let toggle = s.monitorSwitch(.lut, outputs: ["Sdi12", "Gone"])
    #expect(toggle.choice?.value == true)
    #expect(toggle.commands(false) == [.setMonitorOverlay(.lut, false, output: "Sdi12")])
    #expect(s.monitorSwitch(.lut, outputs: ["Gone", "AlsoGone"]).choice == nil, "none of them here: greyed")
}

@Test func oneOutputAndEveryOutputWorkAsBefore() {
    let s = veniceLike(lut: ["Sdi12": true, "Sdi34": true])
    #expect(s.monitorSwitch(.lut, outputs: ["Sdi12"]).commands(false) == [.setMonitorOverlay(.lut, false, output: "Sdi12")])
    #expect(s.monitorSwitch(.lut, outputs: []).commands(false) == [.setLook(false)])
}

@Test func severalOutputsSaveAndOldLayoutsStillRead() throws {
    var widget = PageWidget(kind: .falseColor, cameraID: UUID(), x: 0, y: 0, w: 1, h: 2)
    widget.setTargets([TileOutput(id: "Sdi12", name: "SDI 1/2"), TileOutput(id: "Sdi34", name: "SDI 3/4")])
    #expect(widget.output?.id == "Sdi12", "a build from before several outputs switches the first")
    let data = try JSONEncoder().encode(widget)
    let back = try JSONDecoder().decode(PageWidget.self, from: data)
    #expect(back.targets.map(\.id) == ["Sdi12", "Sdi34"])

    // A layout saved before `outputs` existed: one output.
    var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    old.removeValue(forKey: "outputs")
    let oldWidget = try JSONDecoder().decode(PageWidget.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(oldWidget.targets.map(\.id) == ["Sdi12"])

    widget.setTargets([])
    #expect(widget.output == nil && widget.outputs == nil, "none chosen is every output")
}
