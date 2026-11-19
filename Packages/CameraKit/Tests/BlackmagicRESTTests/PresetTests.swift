// Settings Camera 10.3.1's API hasn't got, set through the camera's presets (BlackmagicPreset.swift): status text by
// output, what it shows, and the anamorphic de-squeeze. The fixture is a PYXIS 12K's preset, saved over the API
// (every overlay off, status text on but on SDI, SDI for the cinematographer, no de-squeeze).

import Testing
import Foundation
import CameraCore
@testable import BlackmagicRESTBackend

private func fixture() throws -> Data {
    try Data(contentsOf: try #require(Bundle.module.url(forResource: "pyxis-10.3.1", withExtension: "cset")))
}

@Suite("BlackmagicREST — presets")
struct PresetFileTests {
    @Test("A PYXIS preset reads as the camera was: status text by output, what it shows, the de-squeeze")
    func readsTheCamerasSettings() throws {
        let settings = PresetSettings(try PresetFile(fixture()))
        #expect(settings.statusText == [true, true, true, false])
        #expect(settings.statusTextContent == [.meters, .meters, .meters, .cinematographer])
        #expect(settings.desqueeze == "None")
    }

    @Test("A change touches that value alone, and everything else goes back byte for byte")
    func changesOneValue() throws {
        let data = try fixture()
        #expect(Proto.serialize(try #require(Proto.parse(data))) == data)
        var file = try PresetFile(data)
        try file.setStatusText(true, output: 3)
        try file.setStatusTextContent(.director, output: 3)
        try file.setDesqueeze("1.5x")
        let changed = PresetSettings(file)
        #expect(changed.statusText == [true, true, true, true])
        #expect(changed.statusTextContent.last == .director)
        #expect(changed.desqueeze == "1.5x")
        // Same size (one-byte values), and the sections it doesn't touch are the same bytes.
        #expect(file.data.count == data.count)
        for section in ["exposure", "lens", "ui"] {
            #expect(Self.section(section, of: file.data) == Self.section(section, of: data), "\(section)")
        }
        // And back.
        try file.setStatusText(false, output: 3)
        try file.setStatusTextContent(.cinematographer, output: 3)
        try file.setDesqueeze("None")
        #expect(file.data == data)
    }

    @Test("A value the preset hasn't got is added; an unknown factor or a number where a message is refused")
    func addsAMissingValue() throws {
        var file = try PresetFile(fixture())
        try file.set("transport", [Proto.Step(field: 1234)], to: 7)
        #expect(file.value("transport", [Proto.Step(field: 1234)]) == 7)
        #expect(throws: PresetError.self) { try file.setDesqueeze("3x") }
        #expect(throws: PresetError.self) { try file.set("metering", [Proto.Step(field: 32), Proto.Step(field: 8), Proto.Step(field: 1)], to: 1) }
    }

    @Test("A change goes as the section it's in, whole; an empty section is refused")
    func onlyTheChangedSection() throws {
        let data = try fixture()
        let original = try PresetFile(data)
        var file = original
        try file.setStatusTextContent(.director, output: 3)
        #expect(file.sectionsChanged(from: original) == ["metering"])
        let metering = try file.only(["metering"])
        #expect(metering.sectionNames == ["metering"])
        #expect(Self.section("metering", of: metering.data) == Self.section("metering", of: file.data))
        #expect(PresetSettings(metering).statusTextContent == [.meters, .meters, .meters, .director])
        try file.setDesqueeze("2.0x")
        #expect(file.sectionsChanged(from: original) == ["metering", "transport"])
        #expect(try file.only(["transport"]).sectionNames == ["transport"])
        #expect(original.sectionsChanged(from: original).isEmpty)
        // A section with no settings, or one the file hasn't got.
        let empty = Proto.serialize([Proto.Field(number: 1, wire: 0, varint: 1),
                                     Proto.Field(number: 10, wire: 2, bytes: Proto.serialize([
                                        Proto.Field(number: 1, wire: 2, bytes: Data("transport".utf8)),
                                        Proto.Field(number: 2, wire: 2, bytes: Data())]))])
        #expect(throws: PresetError.self) { try PresetFile(empty).only(["transport"]) }
        #expect(throws: PresetError.self) { try original.only(["nothing"]) }
    }

    @Test("The LUT in use is a file name in the monitoring section, read and changed there alone")
    func lutByName() throws {
        let data = try fixture()
        let original = try PresetFile(data)
        #expect(PresetSettings(original).lut == "Blackmagic Gen 5 Film to Extended Video.cube")
        var file = original
        try file.setLUT("TW Show LUT v2.cube")
        #expect(PresetSettings(file).lut == "TW Show LUT v2.cube")
        #expect(file.sectionsChanged(from: original) == ["metering"])
        #expect(PresetSettings(file).statusText == PresetSettings(original).statusText)
        try file.setLUT("Blackmagic Gen 5 Film to Extended Video.cube")
        #expect(file.data == data)
        #expect(throws: PresetError.self) { try file.setLUT("") }
    }

    @Test("Laid out as 10.3.1's: its fields there, an entry per output that agrees with the API; otherwise, why not")
    func layoutCheck() throws {
        let data = try fixture()
        let file = try PresetFile(data)
        let off: [MonitorOverlay: Bool] = [.lut: false, .frameGuides: false, .falseColor: false, .zebra: false, .cleanFeed: false]
        let outputs = ["LCD", "Front USB-C", "Rear USB-C", "SDI"].map { (name: $0, overlays: off) }
        #expect(file.layoutMismatch(outputs: outputs) == nil)
        // An overlay the API hasn't reported isn't compared.
        #expect(file.layoutMismatch(outputs: outputs.map { (name: $0.name, overlays: [:]) }) == nil)
        func entry(_ output: Int, _ field: Int) -> [Proto.Step] {
            [Proto.Step(field: PresetSettings.outputs, index: output), Proto.Step(field: field)]
        }
        // SDI's zebra on in the API: the preset must have it on too, and the other way round.
        var zebra = outputs
        zebra[3].overlays[.zebra] = true
        #expect(file.layoutMismatch(outputs: zebra) == "SDI's Zebra is on in the API and not in the preset")
        var zebraOn = file
        try zebraOn.set("metering", entry(3, 5), to: 1)
        #expect(zebraOn.layoutMismatch(outputs: zebra) == nil)
        #expect(zebraOn.layoutMismatch(outputs: outputs) == "SDI's Zebra is off in the API and not in the preset")
        // The LUT on one output: it's what says the entries are still in the API's order, on a camera with every
        // overlay off (the LCD's entry where SDI's was would pass on overlays alone).
        var lut = outputs
        lut[0].overlays[.lut] = true
        #expect(file.layoutMismatch(outputs: lut) == "LCD's LUT is on in the API and not in the preset")
        var lutOnLCD = file
        try lutOnLCD.set("metering", entry(0, 1), to: 1)
        #expect(lutOnLCD.layoutMismatch(outputs: lut) == nil)
        #expect(lutOnLCD.layoutMismatch(outputs: lut.reversed()) == "SDI's LUT is off in the API and not in the preset")
        // Outputs that don't tally.
        #expect(file.layoutMismatch(outputs: Array(outputs.dropLast())) == "4 outputs in its monitoring, 3 in the API")
        // The de-squeeze or the LUT somewhere else; the de-squeeze past the camera's list; a LUT that's no file name.
        let moved = try PresetFile(try #require(FakeBlackmagicCamera.renumbering(92, to: 93, inSection: "transport", of: data)))
        #expect(moved.layoutMismatch(outputs: outputs) == "transport has no field 92 (wire type 0)")
        let lutMoved = try PresetFile(try #require(FakeBlackmagicCamera.renumbering(100, to: 101, inSection: "metering", of: data)))
        #expect(lutMoved.layoutMismatch(outputs: outputs) == "metering has no field 100 (wire type 2)")
        #expect(FakeBlackmagicCamera.renumbering(1234, to: 1235, inSection: "transport", of: data) == nil)
        var far = file
        try far.set("transport", [Proto.Step(field: PresetSettings.desqueezeField)], to: 9)
        #expect(far.layoutMismatch(outputs: outputs) == "de-squeeze 9")
        var notALUT = file
        try notALUT.set("metering", [Proto.Step(field: PresetSettings.lutField)], to: "Gamma 2.4")
        #expect(notALUT.layoutMismatch(outputs: outputs) == "its LUT field isn't a .cube file name")
        // An on/off field that isn't; what status text shows past its four.
        for (field, value, said) in [(2, UInt64(3), "LCD's field 2 is 3"), (8, 2, "LCD's field 8 is 2"), (14, 9, "LCD's field 14 is 9")] {
            var odd = file
            try odd.set("metering", entry(0, field), to: value)
            #expect(odd.layoutMismatch(outputs: outputs) == said)
        }
    }

    static func section(_ name: String, of data: Data) -> Data? {
        Proto.parse(data)?.compactMap { field -> Data? in
            guard field.number == 10, let entry = Proto.parse(field.bytes),
                  entry.first(where: { $0.number == 1 }).map({ String(decoding: $0.bytes, as: UTF8.self) }) == name else { return nil }
            return field.bytes
        }.first
    }
}

@Suite("BlackmagicREST — settings through presets", .serialized)
struct PresetBackendTests {
    /// A PYXIS with its four outputs and its stream output, connected, its presets read.
    private func connected(_ change: (inout FakeBlackmagicCamera.Config) -> Void = { _ in })
        async throws -> (FakeBlackmagicCamera, BlackmagicCameraBackend, Task<Void, Never>, CameraState) {
        var config = FakeBlackmagicCamera.Config()
        config.displayNames = ["LCD", "FrontUSBC", "RearUSBC", "MainSDI", "Stream"]
        change(&config)
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        let state = try #require(await collectUntil(backend: backend) { $0.desqueeze != nil })
        return (cam, backend, t, state)
    }

    private func sdi(_ state: CameraState?) -> MonitorOutput? { state?.monitoring?.outputs.first { $0.id == "MainSDI" } }

    /// The backend's state once `done` holds, read from the backend itself rather than its update stream: 10 s at most.
    /// For the state a change ends in, which is the backend's now whatever the stream has queued (docs/testing.md).
    private func stateWhen(_ backend: BlackmagicCameraBackend, _ done: (CameraState) -> Bool) async -> CameraState? {
        for _ in 0 ..< 200 {
            let state = await backend.state
            if done(state) { return state }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    @Test("Connect reads them from a preset, which it leaves no trace of", .timeLimit(.minutes(1)))
    func readOnConnect() async throws {
        let (cam, _, t, state) = try await connected()
        defer { cam.stop(); t.cancel() }
        #expect(state.desqueeze?.value == "None" && state.desqueeze?.options.count == 7)
        #expect(state.monitoring?.outputs.map { $0.overlays[.statusText]?.value } == [true, true, true, false])
        #expect(sdi(state)?.statusTextContent?.value == .cinematographer)
        #expect(sdi(state)?.statusTextContent?.options == [.cinematographer, .director])
        #expect(state.monitoring?.outputs.first?.statusTextContent?.options == [.meters, .codecAndResolution])
        #expect(state.offers(.statusText) && state.offers(.statusTextContent) && state.offers(.desqueeze))
        #expect(cam.config.presets.isEmpty)
    }

    @Test("Status text on one output: loaded through a preset, shown straight away, and nothing left on the camera",
          .timeLimit(.minutes(1)))
    func statusTextOnOneOutput() async throws {
        let (cam, backend, t, _) = try await connected()
        defer { cam.stop(); t.cancel() }
        let send = Task { await backend.send(.setMonitorOverlay(.statusText, true, output: "MainSDI")) }
        let pending = await collectUntil(backend: backend) { sdi($0)?.overlays[.statusText]?.pending == true }
        #expect(pending != nil)
        await send.value
        let state = try #require(await stateWhen(backend) {
            sdi($0)?.overlays[.statusText]?.value == true && sdi($0)?.overlays[.statusText]?.pending == nil
        })
        #expect(state.monitoring?.outputs.map { $0.overlays[.statusText]?.value } == [true, true, true, true])
        #expect(cam.config.statusText["MainSDI"] == true && cam.presetLoads == 1)
        try? await Task.sleep(for: .milliseconds(400))   // a save just after a load is written late
        #expect(cam.config.presets.isEmpty)
    }

    @Test("SDI for the director, and the de-squeeze: each as the one section it's in", .timeLimit(.minutes(1)))
    func contentAndDesqueeze() async throws {
        let (cam, backend, t, _) = try await connected()
        defer { cam.stop(); t.cancel() }
        await backend.send(.setStatusTextContent(.director, output: "MainSDI"))
        #expect(cam.lastUploadSections == ["metering"])
        await backend.send(.setDesqueeze("1.8x"))
        #expect(cam.lastUploadSections == ["transport"])
        #expect(cam.emptySectionLoads == 0 && cam.presetLoads == 2)
        let state = await collectUntil(backend: backend) {
            sdi($0)?.statusTextContent?.value == .director && $0.desqueeze?.value == "1.8x"
        }
        #expect(state != nil)
        #expect(cam.config.statusTextContent["MainSDI"] == 4 && cam.config.desqueeze == 5)
        #expect(cam.config.statusTextContent["LCD"] == 1)
    }

    @Test("Status text off everywhere leaves an output on clean feed alone", .timeLimit(.minutes(1)))
    func everyOutputSkipsCleanFeed() async throws {
        let (cam, backend, t, connected) = try await connected { $0.overlays = ["MainSDI/cleanFeed": true]; $0.statusText["MainSDI"] = true }
        defer { cam.stop(); t.cancel() }
        #expect(sdi(connected)?.isCleanFeed == true)
        #expect(sdi(connected)?.setting(.statusText)?.isWritable == false)   // grayed in Monitoring Options
        await backend.send(.setMonitorOverlay(.statusText, false, output: nil))
        let state = await collectUntil(backend: backend) { $0.monitoring?.outputs.first?.overlays[.statusText]?.value == false }
        #expect(state?.monitoring?.onEverywhere(.statusText)?.value == false)
        #expect(cam.config.statusText == ["LCD": false, "FrontUSBC": false, "RearUSBC": false, "MainSDI": true])
    }

    @Test("Not during a take: grayed, and nothing loaded", .timeLimit(.minutes(1)))
    func notDuringATake() async throws {
        let (cam, backend, t, _) = try await connected()
        defer { cam.stop(); t.cancel() }
        #expect(await cam.subscribed(to: "/transports/0/record"))
        cam.setRecording(true)
        let rolling = try #require(await collectUntil(backend: backend) { $0.recording.state == .recording })
        #expect(rolling.desqueeze?.isWritable == false)
        #expect(sdi(rolling)?.overlays[.statusText]?.isWritable == false)
        #expect(sdi(rolling)?.statusTextContent?.isWritable == false)
        await backend.send(.setDesqueeze("2.0x"))
        #expect(cam.presetLoads == 0 && cam.config.desqueeze == 0)
        cam.setRecording(false)
        let idle = await collectUntil(backend: backend) { $0.recording.state == .idle && $0.desqueeze?.isWritable == true }
        #expect(idle != nil)
    }

    @Test("A preset read before the camera finished writing it is never loaded; one such read is tried again",
          .timeLimit(.minutes(1)))
    func partWrittenReads() async throws {
        let (cam, backend, t, _) = try await connected()
        defer { cam.stop(); t.cancel() }
        cam.setPartWrittenSaves(100)
        await backend.send(.setDesqueeze("1.5x"))
        #expect(cam.presetLoads == 0 && cam.config.desqueeze == 0)
        let refused = await backend.state
        #expect(refused.desqueeze?.value == "None" && refused.desqueeze?.pending == nil)

        cam.setPartWrittenSaves(1)
        await backend.send(.setDesqueeze("1.5x"))
        #expect(cam.presetLoads == 1 && cam.config.desqueeze == 2)
        #expect(await backend.state.desqueeze?.value == "1.5x")
    }

    @Test("A take started while a change was on its way: the change isn't loaded, and its preset goes",
          .timeLimit(.minutes(1)))
    func takeStartsMidChange() async throws {
        let (cam, backend, t, _) = try await connected { $0.takeStartsOnUpload = true }
        defer { cam.stop(); t.cancel() }
        await backend.send(.setDesqueeze("1.5x"))
        #expect(cam.presetLoads == 0 && cam.config.desqueeze == 0)
        // The take reaches the backend through the camera's WebSocket push, which can land just after the send returns
        // (2 s wasn't always enough on a busy machine; the loop below waits for it).
        var recording = false
        for _ in 0 ..< 100 where !recording {
            recording = await backend.state.recording.state == .recording
            if !recording { try? await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(recording)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(cam.config.presets.isEmpty)
    }

    @Test("Monitoring changed on the camera during a change: the copy isn't loaded over it", .timeLimit(.minutes(1)))
    func monitoringChangesMidChange() async throws {
        let (cam, backend, t, _) = try await connected { $0.monitoringChangesOnUpload = true }
        defer { cam.stop(); t.cancel() }
        await backend.send(.setMonitorOverlay(.statusText, true, output: "MainSDI"))
        #expect(cam.presetLoads == 0 && cam.config.statusText["MainSDI"] == false)
        #expect(cam.config.overlays["MainSDI/zebra"] == true)
        let state = await backend.state
        #expect(sdi(state)?.overlays[.zebra]?.value == true && sdi(state)?.overlays[.statusText]?.value == false)
        #expect(sdi(state)?.overlays[.statusText]?.pending == nil)
    }

    @Test("Asked for what it already is: nothing loaded", .timeLimit(.minutes(1)))
    func nothingToChange() async throws {
        let (cam, backend, t, _) = try await connected()
        defer { cam.stop(); t.cancel() }
        await backend.send(.setMonitorOverlay(.statusText, false, output: "MainSDI"))
        await backend.send(.setDesqueeze("None"))
        #expect(cam.presetLoads == 0)
    }

    @Test("An upload the camera doesn't name isn't loaded: the name could be an old state's", .timeLimit(.minutes(1)))
    func unnamedUpload() async throws {
        let (cam, backend, t, _) = try await connected { $0.unnamedUploads = true }
        defer { cam.stop(); t.cancel() }
        await backend.send(.setStatusTextContent(.director, output: "MainSDI"))
        #expect(cam.presetLoads == 0 && cam.config.statusTextContent["MainSDI"] == 3)
    }

    @Test("The LUT in use is offered; one used on the camera is learned; Tiles can go back to it", .timeLimit(.minutes(1)))
    func lutsLearned() async throws {
        let extended = "Blackmagic Gen 5 Film to Extended Video.cube", look = "Blackmagic Gen 5 Film Look.cube"
        let (cam, backend, t, state) = try await connected()
        defer { cam.stop(); t.cancel() }
        #expect(state.lut?.value == extended && state.lut?.options == [extended])
        #expect(state.offers(.lut))
        // Picked on the camera: seen at the next read (after a take, here; once a minute otherwise).
        cam.useLUTOnCamera(look)
        #expect(await cam.subscribed(to: "/transports/0/record"))
        cam.setRecording(true)
        _ = await collectUntil(backend: backend) { $0.recording.state == .recording }
        cam.setRecording(false)
        let learned = try #require(await collectUntil(backend: backend) { $0.lut?.value == look })
        #expect(learned.lut?.options == [look, extended])
        await backend.send(.setLUT(extended))
        #expect(cam.config.lut == extended && cam.lastUploadSections == ["metering"])
        #expect(await backend.state.lut?.value == extended)
    }

    @Test("LUTs from before are offered; one the camera hasn't got any more is turned down and taken off",
          .timeLimit(.minutes(1)))
    func lutsRemembered() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.displayNames = ["LCD", "FrontUSBC", "RearUSBC", "MainSDI", "Stream"]
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        defer { cam.stop() }
        let backend = makeBackendDirectly(cam: cam, knownLUTs: ["Deleted.cube", "Blackmagic Gen 5 Film to Video.cube"])
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }
        let state = try #require(await collectUntil(backend: backend) { $0.lut != nil })
        #expect(state.lut?.options == ["Blackmagic Gen 5 Film to Extended Video.cube", "Blackmagic Gen 5 Film to Video.cube",
                                       "Deleted.cube"])
        await backend.send(.setLUT("Blackmagic Gen 5 Film to Video.cube"))
        #expect(cam.config.lut == "Blackmagic Gen 5 Film to Video.cube")
        await backend.send(.setLUT("Deleted.cube"))
        #expect(cam.presetLoads == 2 && cam.config.lut == "Blackmagic Gen 5 Film to Video.cube")
        let after = await backend.state
        #expect(after.lut?.value == "Blackmagic Gen 5 Film to Video.cube" && after.lut?.pending == nil)
        #expect(after.lut?.options.contains("Deleted.cube") == false)
    }

    @Test("Connected mid-take: read when the take ends, not during it", .timeLimit(.minutes(1)))
    func connectedMidTake() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.displayNames = ["LCD", "FrontUSBC", "RearUSBC", "MainSDI", "Stream"]
        config.recording = true
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        defer { cam.stop() }
        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }
        #expect(await collectUntil(backend: backend) { $0.monitoring?.zebraLevel != nil } != nil)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await backend.state.desqueeze == nil && cam.presetRequests == 0)
        cam.setRecording(false)
        let state = await collectUntil(backend: backend) { $0.desqueeze?.isWritable == true }
        #expect(sdi(state)?.statusTextContent?.value == .cinematographer)
    }

    @Test("Connected during playback: no preset read until the camera's back in live, then one", .timeLimit(.minutes(1)))
    func notDuringPlayback() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.displayNames = ["LCD", "FrontUSBC", "RearUSBC", "MainSDI", "Stream"]
        config.playbackMode = "Output"
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        defer { cam.stop() }
        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }
        #expect(await collectUntil(backend: backend) { $0.monitoring?.zebraLevel != nil } != nil)
        try? await Task.sleep(for: .milliseconds(300))   // when the read would have been
        let during = await backend.state
        #expect(cam.presetRequests == 0 && during.desqueeze == nil)
        cam.setTransportMode("InputPreview")
        #expect(await collectUntil(backend: backend) { $0.desqueeze?.value == "None" } != nil)
        #expect(cam.presetRequests > 0 && cam.config.presets.isEmpty)
    }

    @Test("Another model's presets are left alone: the fields were found on a PYXIS", .timeLimit(.minutes(1)))
    func otherModels() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.displayNames = ["LCD", "FrontUSBC", "RearUSBC", "MainSDI", "Stream"]
        config.productName = "Cinema Camera 6K"
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        defer { cam.stop() }
        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }
        #expect(await collectUntil(backend: backend) { $0.monitoring?.zebraLevel != nil } != nil)
        try? await Task.sleep(for: .milliseconds(300))
        await backend.send(.setDesqueeze("1.5x"))
        let state = await backend.state
        #expect(state.desqueeze == nil && !state.offers(.statusText) && !state.offers(.statusTextContent))
        #expect(cam.presetRequests == 0 && cam.config.desqueeze == 0)
    }

    @Test("Other software laid out as 10.3.1: its presets are used, and the Activity Log says so", .timeLimit(.minutes(1)))
    func otherSoftwareLaidOutTheSame() async throws {
        let (cam, backend, t, state) = try await connected {
            $0.softwareVersion = "10.3.3"
            // Overlays on, so the preset's agree with the API's for a reason.
            $0.overlays = ["LCD/frameGuide": true, "RearUSBC/cleanFeed": true, "MainSDI/zebra": true]
            $0.displayLUTEnabled = ["LCD": true, "FrontUSBC": true, "RearUSBC": false, "MainSDI": false]
            $0.falseColorEnabled = ["FrontUSBC": true]
        }
        defer { cam.stop(); t.cancel() }
        #expect(state.desqueeze?.value == "None" && state.offers(.statusText) && state.offers(.statusTextContent))
        await backend.send(.setDesqueeze("1.5x"))
        // Should the change not land, what the camera and the backend had: the fake dropping a binary upload
        // is diagnosed here.
        let changed = await stateWhen(backend) { $0.desqueeze?.value == "1.5x" && $0.desqueeze?.pending == nil }
        let warnings = await backend.state.warnings
        #expect(changed != nil, """
            loads \(cam.presetLoads), requests \(cam.presetRequests), warnings \(warnings), log: \(ActivityLog.shared.text
                .split(separator: "\n").filter { $0.contains("127.0.0.1:\(cam.port):") }.joined(separator: " | "))
            """)
        #expect(cam.config.desqueeze == 2 && cam.presetLoads == 1 && cam.config.presets.isEmpty)
        let look = "Blackmagic Gen 5 Film Look.cube"
        await backend.send(.setLUT(look))
        #expect(cam.config.lut == look && cam.lastUploadSections == ["metering"] && cam.presetLoads == 2)
        let log = ActivityLog.shared.text
        #expect(log.contains("127.0.0.1:\(cam.port): PYXIS 12K, Camera 10.3.3"))
        #expect(log.contains("127.0.0.1:\(cam.port): Camera 10.3.3: its presets match 10.3.1's layout"))
    }

    @Test("Other software laid out otherwise: its presets are read, never loaded, and the Activity Log says why",
          .timeLimit(.minutes(1)))
    func otherSoftwareLaidOutOtherwise() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.displayNames = ["LCD", "FrontUSBC", "RearUSBC", "MainSDI", "Stream"]
        config.softwareVersion = "10.4"
        config.presetDesqueezeMoved = true
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        defer { cam.stop() }
        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }
        #expect(await collectUntil(backend: backend) { $0.monitoring?.zebraLevel != nil } != nil)
        try? await Task.sleep(for: .milliseconds(300))   // its preset read is over
        await backend.send(.setDesqueeze("1.5x"))
        await backend.send(.setMonitorOverlay(.statusText, true, output: "MainSDI"))
        let state = await backend.state
        #expect(state.desqueeze == nil && !state.offers(.statusText) && !state.offers(.statusTextContent))
        #expect(cam.presetRequests > 0 && cam.presetLoads == 0 && cam.config.presets.isEmpty)
        #expect(cam.config.desqueeze == 0 && cam.config.statusText["MainSDI"] == false)
        #expect(ActivityLog.shared.text.contains("127.0.0.1:\(cam.port): Camera 10.4: its presets don't match 10.3.1's layout "
                                                 + "(transport has no field 92 (wire type 0))"))
    }

    @Test("A camera whose presets don't list its outputs gets none of it", .timeLimit(.minutes(1)))
    func outputsThatDontTally() async throws {
        var config = FakeBlackmagicCamera.Config()
        config.displayNames = ["LCD", "HDMI"]
        let cam = FakeBlackmagicCamera(config: config)
        try await cam.start()
        defer { cam.stop() }
        let backend = makeBackendDirectly(cam: cam)
        let t = Task.detached { await backend.connect() }
        defer { t.cancel() }
        #expect(await collectUntil(backend: backend) { $0.monitoring?.zebraLevel != nil } != nil)
        try? await Task.sleep(for: .milliseconds(300))   // its preset read (refused) is over
        let state = await backend.state
        #expect(state.desqueeze == nil && !state.offers(.statusText) && !state.offers(.statusTextContent))
        #expect(state.monitoring?.outputs.count == 2)
    }
}
